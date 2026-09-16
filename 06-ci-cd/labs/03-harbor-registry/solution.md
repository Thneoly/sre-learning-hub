# Lab 04 · 解答：Harbor 私有镜像仓库

> 配套 task.md 使用。环境：一台装有 Docker（含 compose 插件）的 Ubuntu VM，≥4G 空闲内存、≥10G 空闲磁盘，可经代理 `172.30.30.1:7897` 访问 GitHub 与 Docker Hub。

## 第 0 步：设计——为什么是 Harbor，而不是继续用 registry:2

03-docker/labs/08 的裸 `registry:2` 只实现了 OCI 存取（`/v2/` API），企业里还缺四样东西，正好是本 lab 的任务链：

```
裸 registry:2（只有存储）                Harbor（仓库之上的治理层）
  push/pull ──────────────────────────▶ push/pull
                                        ├─ 项目（project）：隔离 + 成员/RBAC
                                        ├─ 机器人账户：CI 专用最小权限凭据
                                        ├─ retention：保留最近 N 个 tag，防仓库膨胀
                                        ├─ Trivy 集成：push 后一键扫描
                                        └─ replication：跨中心复制（可选）
```

与本模块其他章的衔接：02 章 4.3 节 CI 里配置的 `CI_REGISTRY/CI_REGISTRY_USER/CI_REGISTRY_PASSWORD` 三个变量，指向的就是这套 Harbor——机器人账户是那个 `CI_REGISTRY_PASSWORD` 的正确形态（可撤销、可限权，而不是管理员密码）；04 章里 ArgoCD 拉的镜像、07 章 overlay 里 `images.newTag` 指向的镜像，最终都落在这样一个私有仓库里。

## 第 1 步：下载离线包并解压

```bash
# [Ubuntu VM]
mkdir -p ~/labs/harbor-lab && cd ~/labs/harbor-lab
# 版本以 https://github.com/goharbor/harbor/releases 当前页为准（写作时为 v2.x）
VER=v2.12.3
curl -x http://172.30.30.1:7897 -fLO \
  "https://github.com/goharbor/harbor/releases/download/${VER}/harbor-offline-installer-${VER}.tgz"
ls -lh harbor-offline-installer-${VER}.tgz     # 约 700MB
tar xvf harbor-offline-installer-${VER}.tgz    # 解出 harbor/ 目录
cd harbor
```

为什么用 offline 包：它把全部组件镜像打包在 tgz 里，`install.sh` 用 `docker load` 从本地加载，不依赖安装过程中的外网拉取——生产内网装机也是这条路（在线包则是 install 时再拉镜像）。

## 第 2 步：改 harbor.yml（http 模式）

```bash
# [Ubuntu VM]
cd ~/labs/harbor-lab/harbor
cp harbor.yml.tmpl harbor.yml
MYIP=$(hostname -I | awk '{print $1}')   # 记下本机 IP，后面多处要用
```

编辑 `harbor.yml`，只动四处：

```yaml
# [文件 ~/labs/harbor-lab/harbor/harbor.yml] 关键改动（其余保持默认）
hostname: 172.30.30.51:8080        # ← 换成你的 <MYIP>:8080，镜像名前缀由此决定

http:
  # port for http, default is 80. If https enabled, this port will redirect to https port
  port: 8080                       # ← http 端口改 8080，避开常用 80

harbor_admin_password: Lab04Harbor # ← admin 的初始密码（首次登录用）

# https related config（整段保持注释——http 模式下任何 https 字段启用都会让安装校验失败）
#https:
#  port: 443
#  certificate: /your/certificate/path
#  private_key: /your/private/key/path
```

`data_volume: /data` 保持默认即可（安装时会自动创建）。生产上当然要 https + 上游 LB/LVS 的证书，本 lab 走 http 是为了把时间花在治理功能上；自签证书流程若想练，见官方 Configure HTTPS 文档（延伸阅读第 2 条）。

（可选）Trivy 漏洞库下载走代理：`harbor.yml` 末尾有被注释的 `proxy:` 段，取消注释并填 `http_proxy/https_proxy` 为 `http://172.30.30.1:7897`、`components` 列表含 `trivy`（字段名以随包 `harbor.yml.tmpl` 为准），否则首次扫描可能卡在漏洞库下载。改过 proxy 段后重跑一次 `sudo ./install.sh --with-trivy` 覆盖生效即可。

## 第 3 步：信任私有仓库 + 安装

```bash
# [Ubuntu VM] 先让 docker daemon 信任 <MYIP>:8080 的 http registry（localhost 之外的必做步骤）
# 注意：daemon.json 若已有其他配置项（如 03-docker 加过的镜像加速），合并保留，别整文件覆盖
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{ "insecure-registries": ["${MYIP}:8080"] }
EOF
sudo systemctl restart docker
```

```bash
# [Ubuntu VM] 安装（约 10~20 分钟：docker load 全部组件镜像 + prepare 生成配置 + 起 compose 栈）
cd ~/labs/harbor-lab/harbor
sudo ./install.sh --with-trivy
# 预期末尾输出：✔ ----Harbor has been installed and started successfully.----
docker compose ps    # nginx/portal/core/jobservice/registry/registryctl/postgresql/redis(或 valkey)/trivy-adapter
                      #   全部 Up（默认 10 个容器 + harbor-log；exporter 仅在启用 metrics 时运行，
                      #   v2.15 的缓存组件换成了 valkey，但容器名仍叫 redis）
```

`--with-trivy` 必须显式给：不加的话装出来的 Harbor 没有扫描器（install.sh usage 原文：Please set --with-trivy if needs enable Trivy in Harbor；官方文档同口径，截至 v2.13 仍需显式指定）。版本行为以随包 `install.sh --help` 为准。浏览器打开 `http://<MYIP>:8080`，`admin / Lab04Harbor` 登录。

## 第 4 步：建私有项目 demo

UI：**项目 → 新建项目** → 名称 `demo`，访问级别不勾"公开"（私有：匿名 pull 会被拒，这正是我们要的）。等价 API（后面 check.sh 用的是只读查询，这里演示写操作也可脚本化）：

```bash
# [Ubuntu VM]
curl -su admin:Lab04Harbor -X POST "http://127.0.0.1:8080/api/v2.0/projects" \
  -H 'Content-Type: application/json' \
  -d '{"project_name":"demo","metadata":{"public":"false"}}' -o /dev/null -w '%{http_code}\n'
# 预期：201（已存在则 409）
```

## 第 5 步：docker login 并 push 多个 tag

```bash
# [Ubuntu VM]
docker pull busybox:1.36                      # 经代理拉取基础镜像
docker login ${MYIP}:8080 -u admin -p Lab04Harbor
# WARNING! Using --password via the CLI is insecure...（生产用 --password-stdin；此处 lab 环境从简）
for i in 0 1 2 3 4; do
  docker tag busybox:1.36 ${MYIP}:8080/demo/demo-app:v1.0.${i}
  docker push ${MYIP}:8080/demo/demo-app:v1.0.${i}
done
```

预期每个 push 都以 `digest: sha256:...` 结束。UI 的 demo/demo-app 仓库里出现 5 个 tag。此刻回顾 03-docker/labs/08 学过的 `_catalog`/`tags/list` API——Harbor 完整实现了同一套 OCI Distribution 接口，外加 `api/v2.0` 这层治理 API。

## 第 6 步：机器人账户并用它重新 push

UI：项目 demo → **机器人账户 → 添加机器人**：名称 `push-bot`、过期时间 30 天、权限只勾 **Artifact 的 Push 和 Pull**（不给删除、不给项目管理）。创建完成的弹窗里是两样东西：

- 用户名：`robot$demo+push-bot`（Harbor 拼接出的全局唯一名）
- Secret：**只显示这一次**，关掉弹窗就得重建

```bash
# [Ubuntu VM] 换用机器人账户 push
docker logout ${MYIP}:8080
docker login ${MYIP}:8080 -u 'robot$demo+push-bot' -p '<弹窗里的secret>'
docker tag busybox:1.36 ${MYIP}:8080/demo/demo-app:v1.0.5
docker push ${MYIP}:8080/demo/demo-app:v1.0.5
```

这就是 02 章 4.3 节 `CI_REGISTRY_USER/CI_REGISTRY_PASSWORD` 的企业答案：CI 里配的应当是 `robot$demo+push-bot` + secret，泄露了撤销重发即可，权限边界只有"推/拉这个项目"。

```bash
# [Ubuntu VM] 只读确认机器人账户存在（check.sh 同款查询）
# Harbor 2.10+ 已移除 /projects/demo/robots（404）：项目机器人改从全局 /robots 接口按项目过滤查
# （不带 q 参数的 /robots 只返回 system 级机器人）；2.x 项目对象的字段名是 name（旧版才是 project_name）
PID=$(curl -su admin:Lab04Harbor "http://127.0.0.1:8080/api/v2.0/projects?page_size=100" \
  | python3 -c 'import sys,json; print(next(p["project_id"] for p in json.load(sys.stdin) if p["name"]=="demo"))')
curl -su admin:Lab04Harbor "http://127.0.0.1:8080/api/v2.0/robots?q=Level=project,ProjectID=${PID}" \
  | python3 -m json.tool | head -20
```

不方便开 UI 时也可用 API 建机器人（注意 2.10+ 的字段是 `duration`（-1=永不过期，正整数=天数）与 `level`，旧版的 `expires_at` 时间戳已被替代）：

```bash
# [Ubuntu VM] API 创建项目级机器人 push-bot（Push+Pull 权限），响应里的 secret 只出现这一次
cat > /tmp/robot.json <<'EOF'
{
  "name": "push-bot",
  "description": "CI push account",
  "duration": -1,
  "level": "project",
  "permissions": [
    {
      "kind": "project",
      "namespace": "demo",
      "access": [
        {"resource": "repository", "action": "pull"},
        {"resource": "repository", "action": "push"}
      ]
    }
  ]
}
EOF
curl -su admin:Lab04Harbor -X POST "http://127.0.0.1:8080/api/v2.0/robots" \
  -H 'Content-Type: application/json' -d @/tmp/robot.json
# 预期：{"id":1,"name":"robot$demo+push-bot","secret":"...","expires_at":-1,...}
```

## 第 7 步：retention 规则（保留最近 3 个 tag）

UI：项目 demo → **策略 → 保留策略（Retention）→ 添加规则**：

- 依据范围：仓库 `**`、tag `**`
- 保留策略：**保留最近推送的 3 个 artifacts**（by count）

保存后先点 **Dry Run**：预览会列出 `v1.0.0`、`v1.0.1`（最旧的）将被删除、其余保留——本 lab 到 Dry Run 为止，不点真实执行，让全部 tag 留给判分脚本。生产上这条规则通常配定时任务每周跑，配合 02 章 `.gitlab-ci.yml` 里按 commit SHA 打 tag的习惯，"每个 commit 一个 tag"的仓库才不会把磁盘吃爆。

```bash
# [Ubuntu VM] 只读确认规则（check.sh 同款查询）
# 注意：GET /api/v2.0/retentions?project_id=N 在新版 Harbor 返回 405（该路径只允许 POST 创建）；
#       正确姿势是先从项目 metadata.retention_id 拿规则 ID，再 GET /retentions/{id}
PID=$(curl -su admin:Lab04Harbor "http://127.0.0.1:8080/api/v2.0/projects?page_size=100" \
  | python3 -c 'import sys,json; print(next(p["project_id"] for p in json.load(sys.stdin) if p["name"]=="demo"))')
RID=$(curl -su admin:Lab04Harbor "http://127.0.0.1:8080/api/v2.0/projects/${PID}" \
  | python3 -c 'import sys,json; print((json.load(sys.stdin).get("metadata") or {}).get("retention_id",""))')
curl -su admin:Lab04Harbor "http://127.0.0.1:8080/api/v2.0/retentions/${RID}" | python3 -m json.tool
# 预期：rules 数组里 action == "retain"（新版是字符串），params.latestPushedK.num == 3
```

API 直接建规则也行（两个易错点：`tag_selectors[].extras` 必须是 **JSON 字符串**而非对象；缺 `trigger` 字段会让 core panic 成 500）：

```bash
# [Ubuntu VM] API 创建 retention（保留最近 3 个 tag，每周六 02:00 定时）
cat > /tmp/retention.json <<EOF
{
  "algorithm": "or",
  "rules": [{
    "action": "retain",
    "params": {"latestPushedK": {"unit": "count", "num": 3}},
    "scope_selectors": {"repository": [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}]},
    "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": "**",
                       "extras": "{\"untagged\":true}"}]
  }],
  "scope": {"level": "project", "ref": ${PID}},
  "trigger": {"kind": "Schedule", "settings": {"cron": "0 0 2 * * Sat"}}
}
EOF
curl -su admin:Lab04Harbor -X POST "http://127.0.0.1:8080/api/v2.0/retentions" \
  -H 'Content-Type: application/json' -d @/tmp/retention.json -w '%{http_code}\n'   # 预期 201
# Dry Run（只预览不删除）：
curl -su admin:Lab04Harbor -X POST "http://127.0.0.1:8080/api/v2.0/retentions/${RID}/executions" \
  -H 'Content-Type: application/json' -d '{"dry_run":true,"action":"dry"}'          # 预期 201
```

## 第 8 步：Trivy 扫描已 push 镜像

UI：demo → demo-app → 点开任一 artifact（如 v1.0.5）→ 右上 **SCAN**。首次扫描前 Harbor 要先下载 Trivy 漏洞库（数百 MB，走第 2 步配的 proxy；没配且下载失败时，扫描状态会停在 Error，去 `docker logs harbor-trivy` 看原因）。完成后 artifact 页出现漏洞统计（busybox 预期 0 或个位数）。

```bash
# [Ubuntu VM] 只读确认扫描状态
# 两个易错点：2.10+ 路径里的仓库名用项目内叶名 demo-app（旧版才是 %2F 编码的全名）；
#            scan_overview 默认不返回，必须显式 with_scan_overview=true
curl -su admin:Lab04Harbor \
  "http://127.0.0.1:8080/api/v2.0/projects/demo/repositories/demo-app/artifacts?with_tag=true&with_scan_overview=true" \
  | python3 -c 'import sys,json
for a in json.load(sys.stdin):
    so = a.get("scan_overview") or {}
    st = next(iter(so.values()), {}).get("scan_status", "未扫描")
    print(a["digest"][:15], [t["name"] for t in a.get("tags", [])], st)'
# 预期：至少一行状态为 Success
# 触发扫描（digest 从上面的列表取，URL 编码冒号）：
curl -su admin:Lab04Harbor -X POST \
  "http://127.0.0.1:8080/api/v2.0/projects/demo/repositories/demo-app/artifacts/sha256%3A<digest去前缀>/scan"
# 预期：202 Accepted（异步执行，数秒到数分钟后查 scan_overview）
```

把"扫描"变成"闸门"（存在 HIGH/CRITICAL 就不让进/不让部署）属于 lab 06 的主题，那里会把 Trivy `--exit-code 1` 放进 CI job；集群准入侧的强制（ImagePolicyWebhook 等）见 09-cks/labs/09。

## 第 9 步（可选）：复制策略

UI：**复制管理 → 目标 → 新建目标**（随便填一个假想对端，如 `http://172.30.30.99:8080`，不验证连通）；**复制管理 → 规则 → 新建规则**：名称 `demo-out`、源项目 `demo`、filter `demo/**`、目标选刚才的 endpoint、触发方式手动。保存即完成配置生成，不执行。这条规则在生产里的形态是"中心 Harbor → 各机房边缘 Harbor 的镜像分发"，与 Git 多 remote 同步是一个思路。

## 第 10 步：判分与收尾

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh && /path/to/check.sh
# 预期：MODE: full，7 项全 PASS，SCORE: 7/7

# 判分通过后再收尾（check.sh 依赖 API 在线，先判分后 down！）
cd ~/labs/harbor-lab/harbor
sudo docker compose down          # 容器停掉，/data 与数据卷保留
# 重做本 lab：sudo ./install.sh --with-trivy 即可恢复（数据还在）
# 彻底清理：sudo docker compose down -v && sudo rm -rf /data ~/labs/harbor-lab
```

若中途环境不允许装 Harbor（内存不足/必须提前关机），把 harbor.yml 放到 `~/labs/harbor-lab/harbor/`，再写一份 `~/labs/harbor-lab/install-plan.md`（内容含 robot 账户、retention、trivy 扫描三步的安装后操作计划），check.sh 会走 SIMULATED 分支按配置结构给分。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `docker login` 报 `server gave HTTP response to HTTPS client` | daemon 不信任 `<IP>:8080`（非 localhost 不自动 insecure） | daemon.json 的 `insecure-registries` 加该地址并重启 docker（见第 3 步） |
| `install.sh` 报 https 证书相关错误 | harbor.yml 的 https 段没注释干净 | `port: 443`、`certificate:`、`private_key:` 全部保持注释 |
| 安装卡在 `load image` 或起容器后大量 Restarting | 内存不足（Harbor 栈要 ~4G 空闲） | 停掉无关容器（如 SonarQube/GitLab）再装；`docker stats` 看实际占用 |
| 首次 SCAN 一直转圈或报错 | Trivy 漏洞库（数百 MB）下载失败 | harbor.yml 的 proxy 段给 trivy 配代理后重跑 install.sh；`docker logs harbor-trivy` 定位 |
| push 报 `unauthorized: authentication required` | 项目私有且没 login，或机器人权限只给了 pull | 用对应账户 login；机器人权限勾 Push+Pull |
| `curl /api/v2.0/...` 404 | 仓库名编码形式与版本不符 | 2.10+ 的 artifacts 路径用项目内叶名（`demo-app`，不编码）；旧版才用 `%2F` 全名（`demo%2Fdemo-app`） |
| 查项目机器人 404 | 2.10+ 移除了 `/projects/{name}/robots` | 用 `/robots?q=Level=project,ProjectID=<PID>`；无参 `/robots` 只返回 system 级 |
| POST /robots 报 `duration input: 0` | 用了旧版 `expires_at` 时间戳字段 | 2.10+ 改用 `duration`（-1 或天数）+ `level: "project"` |
| POST /retentions 500 且 core 日志 panic | 请求体缺 `trigger` 字段（空指针） | 补 `"trigger": {"kind": "Schedule", ...}`；`extras` 必须是 JSON 字符串 |
| artifacts 响应里没有 tags / scan_overview | 这两个字段默认不返回 | 查询串显式 `with_tag=true` / `with_scan_overview=true` |
| GET /retentions?project_id=N 返回 405 | 该路径只允许 POST（创建） | 从 `GET /projects/{PID}` 的 `metadata.retention_id` 取规则 ID，再 `GET /retentions/{id}` |
| 机器人 login 失败 | 用户名没带 `robot$demo+` 前缀，或 secret 复制时带了空格 | 用户名用 `robot$demo+push-bot`；secret 单引号包裹传给 `-p` |
| UI 打不开但容器都 Up | 防火墙拦 8080，或 hostname 填错 | `curl -I http://127.0.0.1:8080` 本机先通；`sudo ufw allow 8080/tcp` |

## 判分脚本结果

```text
# [Ubuntu VM]
$ /path/to/check.sh
MODE: full（Harbor API 在线，执行只读 API 判分）
PASS: Harbor API 可达且 admin 凭据有效
PASS: 私有项目 demo 存在
PASS: demo 项目下仓库列表非空
PASS: 仓库 demo/demo-app 存在带 tag 的 artifact
PASS: 已有镜像完成 Trivy 扫描（scan_status=Success）
PASS: demo 项目下存在机器人账户
PASS: retention 规则已配置（存在 retain 动作）

SCORE: 7/7
```

## 延伸阅读

- Harbor 官方文档（安装/配置）：https://goharbor.io/docs/
- Configure HTTPS（自签证书完整流程）：https://goharbor.io/docs/main/install-config/configure-https/
- Harbor API v2.0（本 lab 全部只读判分查询的依据）：https://harbor.dev/docs/dev-api/
- Vulnerability Scanning with Trivy：https://goharbor.io/docs/main/working-with-projects/project-configuration/vulnerability-scanning/
