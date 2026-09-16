# Lab 06 · 解答：供应链闸门

> 配套 task.md 使用。环境：一台装有 Docker 的 Ubuntu VM（已完成 lab 01，gitlab-ci-local 可用），可经代理 `172.30.30.1:7897` 访问 GitHub/docker.io/gcr.io/ghcr.io。

## 第 0 步：设计——两道闸门各拦什么，为什么放在 CI

09-cks/04 章给过供应链的分段图景，本 lab 落的是其中两段：

```
digest 固定（防部署漂移）  ≠  Trivy 扫描（防内容有毒）  ≠  cosign 签名（防发布者冒充）
        └─ 09-cks/04 §3          └─ 本 lab 闸门 1              └─ 本 lab 闸门 2

CI pipeline（gitlab-ci-local 模拟）：
   stage verify                          stage deploy
   ├─ verify-signature（cosign verify）──┐
   │    失败 → echo BLOCKED + exit 1      ├─ needs: [verify-signature, scan-image]
   └─ scan-image（trivy --exit-code 1）──┘    两道全绿才调度；任一失败即 blocked
        失败 → echo BLOCKED + exit 1
```

闸门放 CI 侧是"流水线约定"：没人绕过 CI 就没人能部署坏镜像。要挡住"绕过 CI 直接 kubectl apply"的人，得下沉到集群 admission 侧（ImagePolicyWebhook / Kyverno / sigstore policy-controller），那条路线见 09-cks/labs/09——CKS 考试视角下两者是互补的两层。

## 第 1 步：装 cosign 与 trivy

```bash
# [Ubuntu VM] cosign：官方 releases 的 Linux amd64 二进制
# 注意版本：本 lab 的 flag 组合按 v2 语义写，URL 里显式钉 v2 系（v2.6.1 为 v2 线最新）
# v3 已发布且有两处 breaking change，见下方"v3 差异"说明
curl -x http://172.30.30.1:7897 -fL \
  -o /tmp/cosign \
  https://github.com/sigstore/cosign/releases/download/v2.6.1/cosign-linux-amd64
sudo install -m 0755 /tmp/cosign /usr/local/bin/cosign
cosign version        # 预期：v2.6.1

# [Ubuntu VM] trivy：apt 仓库方式（与 09-cks/labs/01 提示 1 相同）
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version
```

**cosign v3 差异（若装了 v3.x）**：`--tlog-upload=false` 已被移除——默认启用的 signing-config 与它互斥，需再加 `--use-signing-config=false`（`cosign sign --key ... --tlog-upload=false --use-signing-config=false --allow-insecure-registry --yes ...`）；且 v3 签名旧版 v2 客户端验不过（"no matching signatures"），**签名方与验证方要用同一大版本**。另外新版（v2.5+/v3）对"无签名"的 verify 返回专属退出码 **10**（旧版是 1）——本 lab 的判分按"非零即被拒"处理。

## 第 2 步：起本地 registry 并推入一好一坏两个镜像

```bash
# [Ubuntu VM]
mkdir -p ~/labs/supply-chain-lab/{ci,results} && cd ~/labs/supply-chain-lab
docker run -d --name lab06-registry --restart always -p 5000:5000 registry:2
MYIP=$(hostname -I | awk '{print $1}'); REG="${MYIP}:5000"; echo "REG=$REG"

# 宿主信任 http registry（daemon.json 已有其他条目则合并保留，别整文件覆盖）
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{ "insecure-registries": ["${MYIP}:5000"] }
EOF
sudo systemctl restart docker     # registry 带 --restart always 会自动回来

docker pull alpine:3.20           # 好镜像（干净、小）
docker pull nginx:1.16            # 坏镜像（2019 年的老版本，HIGH/CRITICAL 必超阈）
docker tag alpine:3.20 ${REG}/demo/app:v1
docker tag nginx:1.16 ${REG}/demo/legacy:v1
docker push ${REG}/demo/app:v1
docker push ${REG}/demo/legacy:v1
```

镜像地址必须用 `${MYIP}:5000` 而不是 `127.0.0.1:5000`：后面 CI job 跑在容器里，容器内的 127.0.0.1 是它自己（提示 1 的坑）。若 lab04 的 Harbor 还在跑，`REG` 换成 `${MYIP}:8080`、直接用 `demo` 项目里的 `demo/demo-app` tag 即可，后续命令一字不改。

## 第 3 步：生成密钥对并签名"好镜像"

```bash
# [Ubuntu VM]
cd ~/labs/supply-chain-lab
export COSIGN_PASSWORD='Lab06Cosign123'     # 私钥口令走环境变量，免交互
cosign generate-key-pair
# Private key written to cosign.key / Public key written to cosign.pub

cosign sign --key cosign.key --tlog-upload=false --allow-insecure-registry --yes ${REG}/demo/app:v1
echo $? > results/cosign_sign.exit          # 预期文件内容：0
```

三个 flag 的为什么：`--tlog-upload=false`——key pair 模式默认还要把签名记录上传公共 Rekor 日志，离线/代理环境会卡住（生产有条件联网时保留默认，多一份公共审计）；`--allow-insecure-registry`——http 明文仓库要显式放行；`--yes`——跳过 tag 签名确认交互。签名本体被写成 `${REG}/demo/app:sha256-<digest>.sig` 这个特殊 tag 推回仓库（09-cks/04 §4 讲过这个存储形态），`docker images`/Harbor UI 里能看到它。

## 第 4 步：verify 通过（exit 0）与被拒（exit 1）

```bash
# [Ubuntu VM]
cosign verify --key cosign.pub --insecure-ignore-tlog --allow-insecure-registry ${REG}/demo/app:v1
echo $? > results/cosign_verify_signed.exit
# 预期：打印 [{"critical":...}] 的签名载荷，退出码 0；文件内容 0

cosign verify --key cosign.pub --insecure-ignore-tlog --allow-insecure-registry ${REG}/demo/legacy:v1
echo $? > results/cosign_verify_unsigned.exit
# 预期：报错 no signatures found / 无匹配签名，退出码非零——新版 cosign（v2.5+/v3）返回 10，旧版返回 1
```

`--insecure-ignore-tlog` 与 sign 侧的 `--tlog-upload=false` 成对：没上传 Rekor 就不能要求验证方去查 Rekor，公私钥密码学校验仍然完整。legacy 镜像从未被签过名，验证失败——这就是"发布者身份"闸门：哪怕镜像内容被换掉、tag 被覆盖，没有私钥就造不出能通过验证的签名。

## 第 5 步：Trivy 漏洞闸门（exit 1）

```bash
# [Ubuntu VM] 首次运行先下载漏洞库（约 40MB，来自 ghcr.io；网络需代理就前置环境变量）
trivy image --severity HIGH,CRITICAL --exit-code 1 --quiet nginx:1.16
echo $? > results/trivy_gate.exit
# 预期：终端列出 HIGH/CRITICAL 漏洞明细，退出码 1；文件内容 1
```

`--exit-code 1` 把"扫出超阈漏洞"变成进程语义（09-cks/labs/01 的 image-gate.sh 就是把这个退出码包了一层脚本）——CI 里只需关心退出码，这就是"闸门"的最小实现。漏洞库每日更新，具体条数以实测为准。

## 第 6 步：把两道闸门写成 .gitlab-ci.yml

```yaml
# 文件: ~/labs/supply-chain-lab/ci/.gitlab-ci.yml
# REG 换成你的 <MYIP>:5000；IMAGE 行是两次实验的切换点
stages: [verify, deploy]

variables:
  IMAGE: "172.30.30.51:5000/demo/app:v1"

verify-signature:
  stage: verify
  # 注意：官方 cosign 镜像（gcr.io/projectsigstore/cosign）是 distroless，没有 sh——
  # gitlab-ci-local 的 script 要靠 sh 执行，job 会直接 exec: "sh": executable file not found。
  # 用 alpine + apk 装 cosign（社区仓库有 v2 线），既保住 shell 又与签名侧同大版本
  image: docker.io/library/alpine:3.20
  variables:
    HTTPS_PROXY: "http://172.30.30.1:7897"        # apk 与漏洞库走代理；网络可直连则删除
    HTTP_PROXY: "http://172.30.30.1:7897"
    NO_PROXY: "127.0.0.1,localhost,172.30.30.50,172.30.30.50:5000"
  script:
    - apk add --no-cache cosign >/dev/null
    # 整条命令用单引号包住：行内 "BLOCKED: " 的冒号+空格在裸 YAML 里会被解析成 mapping
    - 'cosign verify --key cosign.pub --insecure-ignore-tlog --allow-insecure-registry "$IMAGE" || { echo "BLOCKED: $IMAGE 未通过签名校验，禁止部署"; exit 1; }'

scan-image:
  stage: verify
  image:
    name: docker.io/aquasec/trivy:latest
    entrypoint: [""]                              # trivy 镜像 ENTRYPOINT 是 trivy 自身，不覆盖会把 sh 当子命令
  variables:
    HTTPS_PROXY: "http://172.30.30.1:7897"
    HTTP_PROXY: "http://172.30.30.1:7897"
    NO_PROXY: "127.0.0.1,localhost,172.30.30.50,172.30.30.50:5000"
  script:
    - 'trivy image --severity HIGH,CRITICAL --exit-code 1 --quiet "$IMAGE" || { echo "BLOCKED: $IMAGE 存在 HIGH/CRITICAL 漏洞，禁止部署"; exit 1; }'

deploy:
  stage: deploy
  image: docker.io/library/alpine:3.20
  needs: [verify-signature, scan-image]           # DAG：两个闸门全绿才调度本 job
  script:
    - 'echo "DEPLOY OK: 发布镜像 $IMAGE（真实流水线里这里接 ArgoCD 的 Git 提交，见 04 章第 5 节）"'
```

要点逐条：

- **job 镜像必须带 shell**：gitlab-ci-local 的 script 靠 `sh -c` 执行。官方 cosign 镜像是 distroless（无 sh，加 `entrypoint: [""]` 也没用），所以 verify-signature 用 alpine + `apk add cosign`；trivy 镜像是 alpine 底（有 sh），但 ENTRYPOINT 是 `trivy`，须 `entrypoint: [""]` 覆盖，否则报 `unknown command "sh" for "trivy"`；
- **`|| { echo "BLOCKED..."; exit 1; }`**：闸门失败的日志里有明确的 BLOCKED 标记，人和判分脚本都能一眼看出"是被闸门拦的，不是 job 环境坏了"；
- **`needs` 而非裸 stage 依赖**：02 章讲过 needs 声明 DAG——deploy 只等这两个闸门，未来 verify stage 里加第三个 job（比如 lab 05 的 SonarQube gate）不会自动阻塞 deploy，要阻塞就把它加进 needs，依赖关系显式可见；
- cosign 的私钥**不进** job（verify 只要公钥），私钥只存在于签名方——生产上签名是独立的一步（CI 的受保护环境或发布工程师本地）。

## 第 7 步：gitlab-ci-local 跑两次，一绿一红

```bash
# [Ubuntu VM]
cd ~/labs/supply-chain-lab/ci
git init --initial-branch=main
cp ../cosign.pub .                          # 公钥进仓库
git add -A && git commit -m "ci: supply chain gates"

# —— 第 1 次：好镜像，全绿 ——
sed -i "s#^  IMAGE: .*#  IMAGE: \"${REG}/demo/app:v1\"#" .gitlab-ci.yml
git add -A && git commit -m "ci: verify app:v1"
gitlab-ci-local > ../results/pipeline-passed.log 2>&1
tail -6 ../results/pipeline-passed.log
# 预期：verify-signature passed、scan-image passed、deploy passed，
#       且 deploy 的输出行含 "DEPLOY OK: 发布镜像 .../demo/app:v1"

# —— 第 2 次：坏镜像，闸门拦截 ——
sed -i "s#^  IMAGE: .*#  IMAGE: \"${REG}/demo/legacy:v1\"#" .gitlab-ci.yml
git add -A && git commit -m "ci: verify legacy:v1"
gitlab-ci-local > ../results/pipeline-blocked.log 2>&1; echo "pipeline exit=$?"
# pipeline exit=1：有 job 失败，整体非零——CI 引擎层面这次"发布"就到此为止
grep -E 'BLOCKED|DEPLOY OK' ../results/pipeline-blocked.log
# 预期：只有两行 BLOCKED（签名、漏洞各一条），没有任何 DEPLOY OK——deploy 未被调度
```

对照两次日志体会 02 章的调度语义：`needs` 声明的上游失败，下游 job 直接不创建/不调度（提示 4）。真实 GitLab 上这条 pipeline 的 deploy job 会显示为 blocked/created 且永不执行，直到有人把 `IMAGE` 指回通过闸门的镜像。

## 第 8 步：判分与收尾

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh && /path/to/check.sh
# 预期：13 项全 PASS，SCORE: 13/13

# 收尾：删掉 registry 容器（cosign.key/cosign.pub、results/ 保留供复验）
docker rm -f lab06-registry
# 旧镜像清理（可选）：docker rmi alpine:3.20 nginx:1.16 ${REG}/demo/app:v1 ${REG}/demo/legacy:v1
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| cosign sign/verify 报 TLS/`connection refused` | http registry 没加 `--allow-insecure-registry`，或地址用了 `127.0.0.1`（job 容器里的 localhost 不是宿主） | 加 flag；地址一律 `${MYIP}:5000` |
| cosign sign 长时间无响应最后超时 | 默认上传 Rekor 公共日志，网络不通 | `--tlog-upload=false`（verify 侧配 `--insecure-ignore-tlog`，两者成对） |
| verify 明明签过却报 no signatures found | 签名后用同 tag push 了不同内容（digest 变了，`.sig` 指向旧 digest） | 重新 sign；或按 09-cks/04 §3 用 digest 引用 |
| 宿主 `docker push ${MYIP}:5000/...` 报 HTTPS client | daemon.json 没加 `insecure-registries`（localhost 之外不自动放行） | 合并写入后 `systemctl restart docker`（见第 2 步） |
| job 容器里 trivy 卡在 DB 下载 | job 容器无法直连 ghcr.io | job `variables` 配 `HTTPS_PROXY`，`NO_PROXY` 放行 `${MYIP}:5000` 所在网段 |
| cosign job 的 script 被当参数吞掉 | cosign 镜像 ENTRYPOINT 是 cosign 自身 | `image.entrypoint: [""]` |
| cosign job 报 `exec: "sh": executable file not found` | 官方 cosign 镜像是 distroless，压根没有 shell | verify job 改用 `alpine` + `apk add cosign`（本 lab 第 6 步的写法） |
| trivy job 报 `unknown command "sh" for "trivy"` | trivy 镜像 ENTRYPOINT 是 trivy 自身 | `image.entrypoint: [""]` 覆盖入口 |
| deploy job 拉不动 `docker:27-alpine` | 旧 tag 可能已被 Docker Hub 下架 | deploy 只是 echo，用 `alpine:3.20` 即可 |
| sign 后 verify 仍 "no matching signatures" | 签名与验证的 cosign 大版本不一致（v3 签 v2 验不了），或同 tag 重 push 改了 digest | 两侧钉同一大版本；重新 sign |
| cosign v3 装 `--tlog-upload=false` 报 not supported | v3 默认启用 signing-config，与该 flag 互斥 | 追加 `--use-signing-config=false`，或装 v2.6.x |
| gitlab-ci-local 报不在 git 仓库/变量取不到 | 改了 `.gitlab-ci.yml` 没 commit | 每次 sed 后 `git add -A && git commit` 再跑 |
| trivy 扫 nginx:1.16 退出码是 0 | 漏洞库未下载成功（空库），或镜像其实没拉到本地 | 去掉 `--quiet` 看明细；确认 DB 版本行存在再重试 |

## 判分脚本结果

```text
# [Ubuntu VM]
$ /path/to/check.sh
PASS: cosign_sign.exit 存在且为 0（签名成功）
PASS: cosign_verify_signed.exit 存在且为 0（已签名镜像验证通过）
PASS: cosign_verify_unsigned.exit 存在且为 1（未签名镜像验证被拒）
PASS: trivy_gate.exit 存在且为 1（HIGH/CRITICAL 超阈被拦）
PASS: cosign.pub 存在且为 PEM 公钥
PASS: pipeline-passed.log 存在且含 DEPLOY OK
PASS: pipeline-passed.log 无 BLOCKED
PASS: pipeline-blocked.log 存在且含 BLOCKED
PASS: pipeline-blocked.log 无 DEPLOY OK（deploy 未执行）
PASS: .gitlab-ci.yml 存在且为合法 YAML
PASS: verify-signature job 调 cosign verify 且带 --key
PASS: scan-image job 调 trivy 且 --severity HIGH,CRITICAL 与 --exit-code 1
PASS: deploy job 通过 needs 依赖两个闸门 job

SCORE: 13/13
```

## 延伸阅读

- cosign 官方文档（key pair / keyless / Rekor）：https://docs.sigstore.dev/
- cosign releases（本 lab 二进制与 CI 镜像的版本出处）：https://github.com/sigstore/cosign/releases
- Trivy 官方文档（--exit-code 闸门用法）：https://trivy.dev/latest/docs/scanner/vulnerability/
- GitLab CI `needs` 关键字（DAG 依赖语义）：https://docs.gitlab.com/ee/ci/yaml/#needs
- 集群 admission 侧的镜像准入（本 lab CI 闸门的下沉替代）：09-cks/labs/09-imagepolicy-webhook
