# Lab 04 · Harbor 私有镜像仓库：项目、机器人账户、保留策略与漏洞扫描

> 难度：★★★ ｜ 考点：企业级镜像仓库（Harbor）／项目隔离／CI 专用账户／retention／push 即扫 ｜ 前置：03-docker/labs/08-local-registry（registry 与 insecure-registries 概念）、本模块 02 章（CI 里 `CI_REGISTRY*` 变量怎么用）｜ 预计 60~90 分钟

## 资源前置（先读再动手）

- Harbor 全栈（core / registry / jobservice / harbor-db / redis / trivy）约需 **4G 空闲内存**、`/data` 所在盘 **≥10G 空闲**。本 VM 10G 内存，动手前 `docker ps` 与 `free -h` 确认没有别的重组件在抢资源（若 10 章 SonarQube 在跑，先 `docker compose down`）。
- 离线安装包约 700MB（走代理下载），`install.sh` 要加载约 2~3G 的本地镜像，全程 10~20 分钟，属本模块最重的 lab。
- **收尾要求**：跑完 check.sh 并确认得分后，`cd ~/labs/harbor-lab/harbor && sudo docker compose down`（数据卷保留，重做 lab 只需再 `sudo ./install.sh --with-trivy`；彻底清理再加 `-v` 并删 `/data`，见 solution 末尾）。**先判分再 down**——check.sh 依赖 Harbor API 在线。

## 场景

团队目前 CI 直接推个人 Docker Hub 账号，问题一堆：没有项目级隔离、CI 里用的是管理员密码、半年下来仓库里堆了两百个没用的 tag、镜像有没有漏洞全靠人肉。你决定在一台 Ubuntu VM 上用 Harbor 官方离线安装包搭一套企业级仓库：**私有项目 → 机器人账户给 CI → retention 保住磁盘 → Trivy push 即扫**。这四个能力正好对应本模块 02 章 4.3 节里 `CI_REGISTRY_USER/PASSWORD` 变量的"企业版答案"。

约定（判分脚本按此检查，均为只读 API 查询）：

| 项 | 值 |
| --- | --- |
| Harbor 地址 | `http://<VM-IP>:8080`（http 模式，免自签证书流程） |
| admin 密码 | `Lab04Harbor`（harbor.yml 里改，check.sh 可用环境变量 `HARBOR_ADMIN_PASSWORD` 覆盖） |
| 私有项目 | `demo` |
| 仓库 | `demo/demo-app`，tag `v1.0.0` 起步 |
| 安装目录 | `~/labs/harbor-lab/`（SIMULATED 降级分支也认这里） |

## 任务清单

1. 走代理（`172.30.30.1:7897`）从 GitHub releases 下载 **harbor offline installer** tgz（版本以官方 releases 页为准），解压到 `~/labs/harbor-lab/harbor`。
2. 复制 `harbor.yml.tmpl` 为 `harbor.yml` 并修改：`hostname: <VM-IP>:8080`、`http.port: 8080`、`harbor_admin_password: Lab04Harbor`、**注释掉整个 https 段**（http 模式）。宿主机 `/etc/docker/daemon.json` 的 `insecure-registries` 加 `"<VM-IP>:8080"`（已有配置项要合并保留），`sudo systemctl restart docker`。
3. `sudo ./install.sh --with-trivy` 完成安装——`--with-trivy` 必须显式给：不加的话装出来的 Harbor 没有扫描器（install.sh usage 原文：Please set --with-trivy if needs enable Trivy in Harbor；官方文档同口径，截至 v2.13 仍需显式指定，以随包 `install.sh --help` 为准），浏览器登录 `http://<VM-IP>:8080` 验证。
4. 建私有项目 `demo`（不勾选"访问级别-公开"）。
5. `docker login <VM-IP>:8080`（admin），把 `busybox:1.36` 依次打 tag 并 push 成 `demo/demo-app:v1.0.0` ~ `v1.0.4` 共 5 个 tag。
6. 在项目里创建**机器人账户** `push-bot`（权限：Artifact push + pull），`docker logout` 后用它重新 login，push `v1.0.5`——体会"CI 只拿到最小权限凭据"。
7. 配置 **retention 规则**：保留最近 3 个 tag（按 count），先执行"Dry Run"预览要删哪些（本 lab 不要求真实删除，保留全部 tag 供判分）。
8. 对已 push 的镜像触发 **Trivy 扫描**，在 UI 查看漏洞报告（busybox 很小，预期 0 或极少量漏洞，重点是扫描链路通）。
9. （可选）配置一条**复制策略**（replication rule）：目标随意（如另一个假想 endpoint），filter `demo/**`，不启用自动执行——体会跨中心同步的配置形态。
10. 运行判分脚本；通过后按"资源前置"要求 compose down。

## 验收标准

- `curl -u admin:Lab04Harbor http://127.0.0.1:8080/api/v2.0/projects` 能返回项目列表（HTTP 200）；
- 项目列表含 `demo`；`demo` 下仓库非空且 `demo/demo-app` 至少有一个带 tag 的 artifact；
- 至少一个 artifact 的扫描状态为 `Success`（scan_overview）；
- `demo` 项目下存在机器人账户（API 可查）；
- retention API 能查到含 `retain` 动作的规则。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh
/path/to/check.sh          # Harbor 在线则走 full 模式；API 不可达自动降级 SIMULATED
```

## 提示（卡住再看）

<details><summary>提示 1：离线包从哪下、走代理怎么写？</summary>

Harbor 官方只发离线/在线安装包，地址在 `https://github.com/goharbor/harbor/releases`，资产名形如 `harbor-offline-installer-vX.Y.Z.tgz`（版本以该页为准，写作时最新为 v2.x）。走代理下载：

```bash
# [Ubuntu VM]
curl -x http://172.30.30.1:7897 -fLO \
  https://github.com/goharbor/harbor/releases/download/v2.12.3/harbor-offline-installer-v2.12.3.tgz
```

（示例版本号请替换为 releases 页当前值。）`tar xvf` 后进入 `harbor/` 目录操作。
</details>

<details><summary>提示 2：harbor.yml 改哪几处？https 段怎么处理？</summary>

最小改动四处：`hostname`（写 `IP:8080`，registry 的镜像名前缀就由它决定）、`http.port: 8080`、`harbor_admin_password`、把 `# https related config` 整段连同 `port: 443`、`certificate:`、`private_key:` 一起保持注释——http 模式下任何 https 字段留着都会让 `install.sh` 校验失败。`data_volume: /data` 保持默认（目录会自动创建）。
</details>

<details><summary>提示 3：docker login 报 "server gave HTTP response to HTTPS client"？</summary>

你的镜像名前缀用了 `<VM-IP>:8080` 而 daemon 不信任它（03-docker/labs/08 的提示 1 讲过：只有 localhost/127.0.0.1 默认按 insecure 处理）。把 `"<VM-IP>:8080"` 加进 `/etc/docker/daemon.json` 的 `insecure-registries` 数组（已有键要合并，别整个覆盖），`sudo systemctl restart docker` 后重新 login。
</details>

<details><summary>提示 4：机器人账户的"用户名"是什么？</summary>

不是你起的名字本身，而是 Harbor 拼接后的形式：项目内机器人显示为 `robot$demo+push-bot`。UI 创建完成后 secret **只显示一次**，马上用它 `docker login`（用户名 `robot$demo+push-bot`，密码即 secret）。用 API 查项目机器人：**Harbor 2.10+ 已移除 `GET /api/v2.0/projects/demo/robots`**（404），改查 `GET /api/v2.0/robots?q=Level=project,ProjectID=<PID>`（PID 从项目列表接口取，2.x 的项目对象字段叫 `name`；不带参数的 GET /robots 只返回 system 级机器人，必须带 `Level=project` 与 `ProjectID`）。
</details>

<details><summary>提示 5：扫描按钮在哪、怎么用 API 确认？</summary>

UI 路径：项目 demo → 仓库 demo-app → 选中某个 artifact → 右上 SCAN。命令行确认扫描结果（也是 check.sh 的做法）：

```bash
# [Ubuntu VM]（注意两点：2.10+ 路径里的仓库名用项目内叶名 demo-app，不再需要 %2F 编码；
#             scan_overview 字段默认不返回，必须显式 with_scan_overview=true）
curl -su admin:Lab04Harbor \
  "http://127.0.0.1:8080/api/v2.0/projects/demo/repositories/demo-app/artifacts?with_scan_overview=true" \
  | python3 -m json.tool | grep -i scan
```

（旧版 Harbor 的 URL 才是全名 `%2F` 编码形式 `demo%2Fdemo-app`。）首次扫描会先下载 Trivy 漏洞库（数百 MB），若卡在这一步，见 solution 的 proxy 配置。
</details>
