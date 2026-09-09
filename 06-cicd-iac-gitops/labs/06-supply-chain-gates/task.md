# Lab 06 · 供应链闸门：cosign 签名验证 + Trivy 漏洞阈值，并让它们挡住 deploy

> 难度：★★★ ｜ 考点：供应链安全（镜像签名/漏洞闸门）／GitLab CI needs 依赖阻断部署 ｜ 前置：本模块 lab 01（gitlab-ci-local 用法）；概念先读 07-cks/04 章（trivy/digest/cosign 全链路）｜ 预计 60~80 分钟

## 资源前置（先读再动手）

- 本 lab 全程轻量：本地 `registry:2` + 几个短生命周期 job 容器，内存占用合计 <1G，10G VM 无压力。cosign 二进制约 30MB、Trivy 漏洞库首次下载约 40MB（走代理）。
- **收尾要求**：跑完 check.sh 后 `docker rm -f lab06-registry`（密钥对 `cosign.key/cosign.pub` 留在目录里供判分核对；results/ 证据文件保留）。本 lab 无 compose 栈。

## 场景

安全审计给出两条硬性要求，落进你们的交付流水线（02 章 `.gitlab-ci.yml`）：

1. **没签名的镜像不许部署**——发布者身份要能密码学验证（cosign 公私钥）；
2. **有 HIGH/CRITICAL 漏洞的镜像不许部署**——Trivy 扫描超阈即阻断。

你先在 VM 上把两道闸门手工跑通（签名→验证通过；未签名→验证失败；老镜像→漏洞超阈），再把它们写成 gitlab-ci-local 可执行的 verify job：**闸门 job 失败时，deploy job 因 needs 依赖不被执行**。概念全景（签名以 `.sig` tag 形式存进仓库、keyless 与 key pair 模式、digest 固定防的是什么）见 07-cks/04 章；把验证下沉到集群 admission 侧强制（而不是 CI 侧约定）的替代路线，见 07-cks/labs/09-imagepolicy-webhook。

约定（判分脚本按此检查，目录默认 `~/labs/supply-chain-lab/`）：

```
~/labs/supply-chain-lab/
├── cosign.key / cosign.pub          # 密钥对（判分核对公钥存在且为 PEM）
├── ci/                              # git 仓库 + .gitlab-ci.yml（闸门流水线）
└── results/
    ├── cosign_sign.exit             # 记录 0：签名成功
    ├── cosign_verify_signed.exit    # 记录 0：已签名镜像 verify 成功
    ├── cosign_verify_unsigned.exit  # 记录 1：未签名镜像 verify 失败
    ├── trivy_gate.exit              # 记录 1：老镜像 HIGH/CRITICAL 超阈被拦
    ├── pipeline-passed.log          # 闸门全过 → deploy 执行（含 DEPLOY OK）
    └── pipeline-blocked.log         # 闸门失败 → deploy 未执行（含 BLOCKED，无 DEPLOY OK）
```

## 任务清单

1. 安装工具：cosign（GitHub releases 下载二进制，走代理，版本以官方 releases 页为准）；trivy（apt 方式，与 07-cks/labs/01 提示 1 相同）。
2. 起本地仓库 `lab06-registry`（`registry:2`，`-p 5000:5000`，`--restart always`）；`MYIP=$(hostname -I | awk '{print $1}')`，`REG=${MYIP}:5000`；宿主 daemon.json 的 `insecure-registries` 合并加入 `${MYIP}:5000` 并重启 docker（lab04 加过的条目要保留）。（若 lab04 的 Harbor 仍在运行，`REG` 换成 `<MYIP>:8080`、项目用 `demo` 也完全可行，命令不变——主线按更轻的 registry:2 写。）
3. `docker pull alpine:3.20`（走代理），tag 成 `${REG}/demo/app:v1` 并 push——这是"好镜像"。`docker pull nginx:1.16`，tag 成 `${REG}/demo/legacy:v1` 并 push——这是"坏镜像"（已知高危老镜像，07-cks/labs/01 的同款样例）。
4. `export COSIGN_PASSWORD=...` 后 `cosign generate-key-pair`（离线/内网用 key pair 模式，生产 CI 常用 keyless，差异见 07-cks/04 章 §4）。
5. 对 `${REG}/demo/app:v1` 签名（注意 `--tlog-upload=false`，离线环境不连 Rekor；http registry 需 `--allow-insecure-registry`；**装了 cosign v3 的话还要加 `--use-signing-config=false`**，v3 移除了旧 flag 的默认兼容），退出码 0 记入 `results/cosign_sign.exit`；`cosign verify`（配 `--insecure-ignore-tlog`）退出码 0 记入 `results/cosign_verify_signed.exit`。签名与验证两侧用同一大版本的 cosign（v3 签名旧版验不过）。
6. 对未签名的 `${REG}/demo/legacy:v1` 执行同一条 verify，退出码**非零**记入 `results/cosign_verify_unsigned.exit`（新版 cosign v2.5+/v3 对"无签名"返回专属退出码 10，旧版返回 1——判分按"非零即被拒"）。
7. Trivy 闸门：`trivy image --severity HIGH,CRITICAL --exit-code 1 nginx:1.16`，退出码 1 记入 `results/trivy_gate.exit`（漏洞库每日更新，以实测为准；同款镜像在 07-cks/labs/01 也是必超阈的样例）。
8. 在 `ci/` 目录（git init + 至少一个 commit）写 `.gitlab-ci.yml`：stages `[verify, deploy]`；`verify-signature` job（**注意：官方 cosign 镜像是 distroless 无 shell**，用 `alpine` 镜像 `apk add cosign` 后跑 verify，失败时输出 `BLOCKED: ...` 再 exit 1）与 `scan-image` job（trivy 官方镜像配 `entrypoint: [""]` 跑 `--exit-code 1` 扫描，同样 BLOCKED 输出）在 verify stage；`deploy` job 用 **`needs: [verify-signature, scan-image]`** 声明依赖。
9. 用 gitlab-ci-local 跑两次并落盘：`IMAGE` 指向 `app:v1` → 全绿且 deploy 输出 `DEPLOY OK`（存 `results/pipeline-passed.log`）；改 `IMAGE` 指向 `legacy:v1` → 闸门 job 失败（输出含 `BLOCKED`）、deploy 未执行（日志中无 `DEPLOY OK`，存 `results/pipeline-blocked.log`）。
10. 运行判分脚本；通过后删除 lab06-registry 容器收尾。

## 验收标准

- 四个 exit code 记录文件存在且值正确（0 / 0 / 非零 / 1——cosign 无签名在新版返回 10、旧版返回 1）；
- `cosign.pub` 存在且为合法 PEM 公钥；
- `pipeline-passed.log` 含 `DEPLOY OK` 且不含 `BLOCKED`；`pipeline-blocked.log` 含 `BLOCKED` 且不含 `DEPLOY OK`；
- `.gitlab-ci.yml` 结构达标：verify-signature 用 `--key` 调 `cosign verify`、scan-image 用 `--exit-code 1` 调 `trivy`、deploy 的 `needs` 引用两个闸门 job。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh
/path/to/check.sh          # 默认查 ~/labs/supply-chain-lab，可用参数覆盖目录
```

## 提示（卡住再看）

<details><summary>提示 1：cosign 为什么连不上 registry / 报 TLS 错？</summary>

http 明文 registry 必须显式放行：sign 和 verify 都加 `--allow-insecure-registry`。另一个坑是 job 容器里访问 `127.0.0.1:5000`——容器里的 127.0.0.1 是它自己。一律用 `${MYIP}:5000`（宿主对外 IP，job 容器经 docker 网桥可达），宿主侧 docker push/pull 到这个地址则要求 daemon.json 的 `insecure-registries` 先加过它（07-cks/04 章 §4 与 03-docker/labs/08 提示 1 讲的都是这一步）。
</details>

<details><summary>提示 2：sign/verify 卡在 Rekor / transparency log？</summary>

cosign v2 默认把签名记录上传公共 Rekor 日志（需公网）。离线/代理不稳时：sign 加 `--tlog-upload=false`；verify 加 `--insecure-ignore-tlog`——公私钥密码学校验仍然完整，只是放弃公共审计日志（生产有条件联网时保留默认行为更好）。
</details>

<details><summary>提示 3：gitlab-ci-local 里 job 怎么用上 cosign/trivy？</summary>

job 的 `image` 要能跑 shell：**官方 cosign 镜像（gcr.io/projectsigstore/cosign）是 distroless、没有 sh**——gitlab-ci-local 的 script 靠 sh 执行，job 会直接报 `exec: "sh": executable file not found`（`entrypoint: [""]` 也救不了）。做法：verify job 用 `alpine:3.20` 镜像 + `apk add --no-cache cosign`（alpine 社区仓库有 v2 线，与签名侧同大版本）；trivy 用 `aquasec/trivy:latest` 但必须配 `entrypoint: [""]`（它的 ENTRYPOINT 是 trivy 自身，否则报 `unknown command "sh"`）。公钥 `cosign.pub` 就在 git 仓库根目录，job 容器的工作目录即项目目录，`cosign verify --key cosign.pub ...` 直接可用。trivy/apk 首次运行要联网，job 的 `variables` 里给 `HTTPS_PROXY/NO_PROXY`（走 172.30.30.1:7897，`NO_PROXY` 放行本机与 registry 地址），网络可直连就删掉。
</details>

<details><summary>提示 4：怎么确认 deploy 是"被 needs 阻断"而不是"自己失败"？</summary>

看 `pipeline-blocked.log`：两个闸门 job 的输出里有你 echo 的 `BLOCKED: ...` 与失败标记，而 deploy 那行根本没有任何执行输出（没有 DEPLOY OK、也没有 deploy 的报错）——它没被调度。这正是 02 章讲的 needs DAG 语义：下游 job 只等它声明的上游，上游失败即 blocked。对比 stage 串行（lab 01 里 lint 失败挡住后续全部），needs 让阻断关系显式化、可局部化。
</details>

<details><summary>提示 5：sed 换 IMAGE 两次跑，为什么要 commit？</summary>

gitlab-ci-local 读的是 git 仓库当前内容计算 `CI_COMMIT_SHORT_SHA` 等变量，改完 `.gitlab-ci.yml` 必须 `git add + commit` 再跑，否则部分预定义变量与 job 定义可能不一致。两次运行分别重定向到两个 log 文件：`gitlab-ci-local > ../results/pipeline-passed.log 2>&1`。
</details>
