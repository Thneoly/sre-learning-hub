# 09 · Harbor：企业镜像仓库

> 模块：06-cicd-iac-gitops ｜ 建议时长：4 小时 ｜ 关联认证：CKS-供应链安全（辅助：trivy/cosign 落到仓库侧）/ —（无直接考点，国内企业 registry 事实标准）

## 学习目标

- 能解释本地 registry:2 在企业场景的五个不足（无 UI/项目权限/扫描/复制/审计），并说明 Harbor 各组件分别补哪一块
- 能在单机 Docker 环境离线安装 Harbor（v2.x，含 Trivy），完成 push/pull/项目/机器人账户/retention 的完整闭环
- 能设计复制规则（push/pull、跨数据中心容灾）与代理缓存项目（代理 Docker Hub 省带宽与外网依赖）
- 能把"Trivy 扫描策略 + 阻止拉取 + cosign 签名验证"组装成仓库侧的供应链闸门，并说明它与 CI、集群准入的分工边界
- 能执行 Harbor 日常运维动作：gc、备份、版本升级路径、自签证书换发

## 1. 为什么本地 registry:2 不够

第 03 章 docker 模块与 08 章 Helm 都用 `docker run registry:2` 起过本地仓库（../03-docker/labs/08-local-registry/，08 章实战步骤 6 的 chart-registry）。它作为**协议实现**完全合格——Harbor 底层用的也是同一个 Distribution。但把它当**企业仓库**用，五个缺口立刻暴露：

| # | 缺口 | registry:2 的现状 | 运维痛感 |
|---|---|---|---|
| 1 | 无 UI | 只有 REST API（curl /v2/_catalog） | 老板问"仓库里都有啥"，你只能贴 JSON |
| 2 | 无项目权限 | 要么裸奔要么全局 htpasswd，一种角色通吃 | 没法做"team-a 只能碰自己的项目、CI 只能 push 不能删" |
| 3 | 无扫描 | 完全没有漏洞概念 | 带着几十个 CRITICAL 的镜像一路推到生产 |
| 4 | 无复制 | 单点，冷备靠 rsync 数据目录 | 机房级容灾、上下游仓库同步全靠人写脚本 |
| 5 | 无审计 | 没有操作日志 | "谁推的这个后门镜像"无法回答（等保/审计红项） |

第 2、3、5 三条对 CKS 视角尤其致命——供应链安全的四段防线（../07-cks/04-supply-chain-security.md 第 1 节的"仓库段"）在裸 registry 上是空的。

## 2. Harbor 架构：包着 Distribution 的一组服务

```
              浏览器(harbor.example.com)          docker/helm/cosign 客户端
                       │ HTTPS 443                      │ push/pull/签名(OCI API)
                       ▼                                ▼
     ┌──────────────────────── nginx(反向代理, 容器入口) ─────────────────────┐
     │        │                                │                            │
     │        ▼                                ▼                            │
     │  portal(Web UI 静态页)           core(API/认证/RBAC/webhook/配额/      │
     │                                  审计日志：所有"管理面"逻辑在这)        │
     │                                       │        │                     │
     │              ┌────────────────────────┤        ▼                     │
     │              ▼                        │   registry(Distribution：    │
     │  jobservice(异步任务：复制/retention/  │    镜像与 OCI 制品的实际存储， │
     │    gc/扫描调度，任务状态进 DB)          │    鉴权交 core 的 token 服务) │
     │              │                        │        │                     │
     │              ▼                        ▼        ▼                     │
     │        postgres(项目/用户/策略/审计)   redis(缓存/session)  storage(卷) │
     │                                       │                              │
     │  trivy(内置漏洞扫描器，core 经扫描适配器调用)                           │
     └───────────────────────────────────────────────────────────────────────┘
```

读图要点：

- **数据面与管理面分离**：push/pull 走 nginx → registry（Distribution），这是高频路径；core 只在鉴权（发 token）和管理操作时介入。registry 本身不校验密码，它问 core 的 token 服务"这个请求该不该放行"——所以 Harbor 的 RBAC 能精确到"项目 × 角色 × 动作"
- **jobservice 是所有耗时任务的宿主**：复制、retention、gc、扫描都是异步 job，失败去 jobservice 日志找原因
- **postgres 是单点心脏**：项目、用户、机器人、复制规则、审计日志全在里面，备份它就备份了 Harbor 的"控制面"（见第 7 节）
- **trivy 是可拔插的**：Harbor v2.x 内置 Trivy 作为默认扫描器，也能注册第三方扫描适配器；Clair 已淘汰，扫描器接口版本敏感处以官方文档为准

## 3. 核心概念

### 3.1 项目：公开与私有

Harbor 的权限边界是**项目**（project），不是仓库。命名格式 `harbor.example.com/<项目>/<镜像名>:<tag>`：

| 访客身份 | 私有项目 | 公开项目 |
| --- | --- | --- |
| 匿名 docker pull | 拒绝（401） | 允许 |
| UI 浏览 | 需登录且是成员 | 可看 |

- **私有是默认**。CI 推业务镜像、集群拉镜像，都走"项目 + 凭据"的正路
- **公开项目慎用**：内网演示、给全公司分发的基础镜像可以公开；把业务项目设公开等于给内网横向移动发通行证（镜像 = 可执行文件 + 内置凭据的重灾区）
- 公开 ≠ 免认证推送：push 永远需要凭据，匿名只是 pull 豁免
- K8s 侧对接：私有项目给 namespace 配 imagePullSecrets，secret 的来源就是下一节的机器人账户

### 3.2 机器人账户：CI 凭据的正确姿势

CI 需要 push/pull 凭据时，三个选项的对比：

| 方案 | 问题 |
| --- | --- |
| 用个人账号 | 人离职账号一禁，全线 CI 爆炸；审计里全是"张三"分不清人和机器 |
| 建个共享"ci"用户 | 好一点，但权限是全项目的，粒度太粗，密码轮换靠自觉 |
| **机器人账户（推荐）** | 项目级、可设过期时间、可随时吊销、secret 在 UI 随时可查 |

在项目 → Robot Accounts → New Robot Account 创建：起名（最终形如 `robot$demo+ci-push`）、勾权限（push/pull/scanner 等按需最小化）、设过期天数（如 90 天，到期前 CI 里换新 secret）。`docker login` 时用户名填完整的 `robot$...` 名，密码填生成的 secret。

与之配套的原则：**每个项目一套机器人，一台 CI 一套**。泄漏的影响面 = 机器人权限面，这套思路与第 02 章第 5 节"变量四件套"（masked/protected/Type: File/environment scope）是同一个最小权限思想的两端——凭据在 Harbor 侧收敛，注入在 GitLab 侧收敛。

### 3.3 Tag Retention 策略

每个 commit 都出镜像的流水线，一个月就能把磁盘吃穿（环境事实：练习 VM 磁盘 25G+，比生产敏感得多）。retention 策略按规则清理 tag，而非全量保留：

- 典型规则组合：`**`（所有 tag）保留最近 10 个；`v*.*.*`（发布 tag）全部保留或保留 90 天内；`latest` 永久保留
- 规则按序匹配，还支持"保留最近 N 天内拉取过的"（防误删仍在用的旧版本）；执行由 jobservice 异步完成，可配 cron 与 DRY RUN（先看会删什么）

顺序上的工程提醒：**retention 删的是 artifact 引用，磁盘空间要等 gc 才真正释放**（第 7 节），两者是一个链路的两步。

### 3.4 复制规则：push/pull 双向与容灾

复制（replication）是 Harbor 间同步镜像的能力，规则声明"源过滤器 → 目标 registry → 触发方式"：

| 方向 | 语义 | 典型场景 |
| --- | --- | --- |
| push | 本 Harbor 推到远端 | 总部构建 → 推给各机房/边缘节点的 Harbor |
| pull | 从远端拉回本 Harbor | 机房 B 主动从总部拉镜像；离线环境从公有源收编镜像 |

- **触发方式**：事件驱动（push 镜像即复制，秒级）或定时轮询；可覆盖 tag 过滤器（如只复制 `v*`）
- **跨数据中心容灾**的常见格局：两机房各一套 Harbor，双向复制同一批项目（或 A→B 单向 + B 只读兜底）。灾备演练验证的是"B 能拉、能补位"，这比"数据同步了"严苛——上游凭据、代理缓存配置也要演练
- 注意复制是**仓库层冗余**，不等于可用性冗余：DNS/负载均衡切换、CI 推送目标切换要提前写进预案（11 章交付平台会回到这个话题）

### 3.5 代理缓存：代理 Docker Hub

反向代理型项目（proxy cache project）让 Harbor 变成 Docker Hub 等上游的**缓存**：客户端 `docker pull harbor.example.com/dockerhub/library/nginx:1.27`，Harbor 本地没有时回源拉取、缓存、后续命中本地：

```
docker pull harbor.example.com/dockerhub/library/nginx:1.27
        │ 首次：Harbor 回源 docker.io ──(走代理出网)──▶ Docker Hub
        │ 之后：命中本地缓存，不再出网
        ▼
节点侧带宽与外网依赖双降；配合 daemon.json 的 registry-mirrors 更省
```

创建方式：新建项目时类型选 Proxy Cache，指定上游（Docker Hub / 其他 Harbor / 任意 OCI registry）。要点：

- 上游走代理出网：回源流量从 Harbor 的 registry 容器出去，本练习机 docker.io 已走代理 `172.30.30.1:7897`；离线安装器场景给回源配代理的方式以官方文档为准（Helm 部署形态另有 proxy 组件统一管理出网）
- 代理项目里**不能 push**（缓存必须与上游一致），因此基础镜像的"本地化改造"要推到普通项目再引用
- 拉取侧把镜像引用改成 Harbor 域名是收益前提——在 kustomize overlay（07 章 3.3 节 images 字段）或 CI 构建脚本里统一改写即可，一处生效

## 4. 镜像扫描：内置 Trivy 与"阻止拉取"

Trivy 的 CLI 用法（severity 过滤、`--exit-code` 门禁）第 07-cks/04 章已系统讲过，这里只讲仓库侧集成：

- **自动扫描**：项目配置里可勾选 push 时自动扫描；旧镜像可在 UI 手动触发或按时间重扫（漏洞库每天在变，昨天的干净镜像今天可能爆出 CVE）
- **扫描策略**：扫描结果只是数据，"多少严重度算不合格"的判定发生在**消费侧**——CI 里 `trivy image --severity CRITICAL --exit-code 1`（07-cks/04 第 2.2 节）、项目策略的阻止拉取开关（下条）、或集群侧准入策略（07-cks/04 第 5 节）
- **阻止拉取有漏洞镜像（Prevent vulnerable images from running）**：项目策略里的开关，勾选后 Harbor 在 pull 请求的 token 环节直接拒绝"扫描结果超过阈值"的镜像。这是**仓库侧闸门**：好处是所有客户端一视同仁（不用每个集群都配准入）；代价是把可用性押在扫描结果上——CI 必须先扫后推（先推后扫的镜像在扫描完成前会被拉断），且"无修复版本的 CRITICAL"会把自己锁死，开启前务必配好忽略策略（类比 trivy 的 `--ignore-unfixed`）

## 5. 签名验证：cosign 集成

07-cks/04 第 4 节讲过 cosign 的机制：签名作为附带制品存进仓库（`<repo>:sha256-<digest>.sig`），验证方持公钥校验。Harbor 与它的关系分三层：

1. **存储层（天然支持）**：cosign 的签名就是一个 OCI artifact，Harbor v2.x 对 OCI 制品与引用（referrers）的支持意味着签名 tag 能正常 push/pull，UI 里挂在镜像的 Artifacts 列表下可见
2. **展示与验证**：Harbor 支持在 UI 显示镜像的 cosign 签名状态（配置公钥后可见"已签名"标记），让"这个镜像签没签"在仓库页一眼可辨，而不是人人手敲 `cosign verify`
3. **准入层（真正挡人的地方不在 Harbor）**：签名验证必须发生在**部署时**——sigstore policy-controller、Kyverno 或 OPA Gatekeeper 做集群准入（07-cks/04 第 5 节的 admission 链路）。Harbor 的角色是"签名与公钥的管理面 + 展示面"

历史注脚：Harbor 曾用 Notary v1 做签名，v2.9.0 起已移除（ChartMuseum 也在 v2.8 移除，chart 分发改走 OCI——见第 8 节），新部署的签名路线就是 cosign（或 notation），版本细节以官方文档为准。

流水线编排顺序（CI 内三步，缺一不可，串起 07-cks/04 与本模块 labs/06-supply-chain-gates 的双闸门设计）：

```
CI package job:
  docker build → trivy 扫描(--exit-code 1，漏洞闸门)
               → docker push
               → cosign sign --key <CI 里的私钥>(07-cks/04 第 4 节，签名闸门)
集群侧:
  Kyverno/policy-controller 验签失败 → Pod 创建被拒(07-cks/04 第 5 节)
```

"扫得干净、签得可信、部署不漂移"——三句口诀的仓库侧落点全在本节。

## 6. Helm Chart 的 OCI 仓

08 章实战步骤 6 已把 chart 推进过 `oci://localhost:5000/charts`（registry:2）。Harbor 对 chart 的支持是同一件事的企业版：

- **统一入口**：镜像与 chart 同一个项目、同一个域名、同一套 RBAC——`helm push mychart-1.2.3.tgz oci://harbor.example.com/charts`，`helm install --version 1.2.3 oci://harbor.example.com/charts/mychart`
- 按第 3.1 节创建私有项目 charts，pull 前要 `helm registry login -u robot$charts+ci-pull harbor.example.com`（机器人账户直接复用）
- Harbor 2.x 面向 OCI 制品设计：镜像、chart、cosign 签名、SBOM 都是 artifact，统一享受项目权限/retention/复制/审计——"chart 单独买一套 Nexus"的老方案在 CNCF 栈里失去必要性。版本史注：ChartMuseum（HTTP chart 仓库）在 v2.8 被移除，`helm repo add` 那套 http 形态不再是 Harbor 的能力；helm 3.8+ 才有 `helm push` OCI（08 章实战步骤 6 已用）

## 7. 运维：gc、备份、升级、证书

### 7.1 磁盘回收（retention → gc 两步走）

```
retention 删 artifact 引用（DB 里"看不见了"）
        │  blob 还躺在 /data/registry —— 磁盘没降
        ▼
GC 删孤儿 blob（jobservice 执行，删文件系统里无 manifest 引用的层）
```

与 03 章 lab 08 的裸 registry 对比：那里要手敲 `/bin/registry garbage-collect`（且停写才能安全），Harbor 把它做成 UI 操作（Administration → Clean Up → Garbage Collection）：支持 DRY RUN（先看能释放多少）、可设 cron 定时（daily/weekly/custom cron）、可并行多 worker、勾选连带清理 untagged artifacts。两个行为细节：GC 运行期间仓库**不停机**（push/pull 照常，靠 2 小时时间窗保护刚上传未关联的层）；GC 按钮限频（每分钟至多一次）。

### 7.2 备份

需要备份的只有两块（以默认 /data 布局为准，布局随安装方式变化）：

```bash
# [VM] 1. 控制面数据：postgres（项目/用户/机器人/复制规则/审计日志）
docker exec harbor-db pg_dumpall -U postgres > harbor-db-$(date +%F).sql

# [VM] 2. 数据面：镜像 blob（停 Harbor 保证一致，或走文件系统快照）
docker compose -f /opt/harbor/docker-compose.yml down
tar -C /data -czf harbor-data-$(date +%F).tgz registry

# [VM] 3. 配置：tar -czf harbor-cfg-$(date +%F).tgz -C /opt/harbor harbor.yml
docker compose -f /opt/harbor/docker-compose.yml up -d   # 恢复服务
```

pg_dump 恢复出来的实例**不含镜像数据**——所以"只备份了 DB"是最经典的假装备份；反过来只备 /data/registry 也丢控制面。两者一起才是完整恢复点。更省事的灾备路线其实是第 3.4 节的复制：让另一个 Harbor 天然热备着数据面。

### 7.3 升级

```bash
# [VM] 官方升级路径（v2.x 通用节奏，命令以当前版本文档为准；跨大版本逐级升不跳级）
# 1. 停服 + 双备份（配置目录整体挪走 + 数据库目录拷贝）
docker compose -f /opt/harbor/docker-compose.yml down
mv /opt/harbor /opt/harbor-bak            # 回滚就靠它
cp -r /data/database /opt/db-bak          # postgres 数据目录冷备
# 2. 解压新离线包，把旧 harbor.yml 拷进新目录
# 3. 用 prepare 镜像迁移 harbor.yml 的配置格式（离线包里自带同名镜像 tar）
docker run -it --rm -v /:/hostfs goharbor/prepare:v2.13.3 migrate -i /opt/harbor/harbor.yml
# 4. 安装新版：cd /opt/harbor && sudo ./install.sh --with-trivy
#    （数据库 schema 迁移由 core 容器启动时自动执行，失败看 harbor-core 日志）
# 5. 验证 push/pull、项目、机器人、复制规则齐全，再定级收编 /opt/harbor-bak
# 生产升级前先在测试实例演练一遍，窗口里只做"验证过的动作"
```

### 7.4 自签证书

练习环境给 `harbor.example.com` 签自签证书（生产用内部 CA 或 Let's Encrypt）：

```bash
# [VM] 生成自签证书（CN/SAN 写你实际访问 Harbor 用的名字，这里以域名+IP 双 SAN 为例）
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /opt/harbor/certs/harbor.key -out /opt/harbor/certs/harbor.crt \
  -subj "/CN=harbor.example.com" \
  -addext "subjectAltName=DNS:harbor.example.com,IP:172.30.30.21"

# harbor.yml 里 hostname 改回域名、https 段指向这对证书后重跑 ./install.sh；各 docker 客户端信任：
sudo mkdir -p /etc/docker/certs.d/harbor.example.com
sudo cp /opt/harbor/certs/harbor.crt /etc/docker/certs.d/harbor.example.com/ca.crt
# 集群侧：把 ca.crt 塞进 namespace 的 secret 并挂为 imagePullSecrets 的一部分，
# 或分发给节点（03-docker lab 08 提示 1 的 insecure-registries 是另一条不安全出路，仅限练习）
```

## 实战演练：VM 上跑通 Harbor

环境：candidate VM（10G 内存、25G+ 磁盘、docker 可用、docker.io 走代理 172.30.30.1:7897、离线包约 700MB 可下）。Harbor 全家桶吃 4G 左右内存，跑之前停掉不用的容器。

### 步骤 1：下载离线包并安装

```bash
# [VM] 版本号以 https://github.com/goharbor/harbor/releases 当前稳定版为准（示例用 v2.13.x）
cd /opt
VER=v2.13.3   # ← 动手前替换为 releases 页最新 patch
sudo curl -fL -o harbor.tgz \
  "https://github.com/goharbor/harbor/releases/download/${VER}/harbor-offline-installer-${VER}.tgz"
sudo tar xvf harbor.tgz && cd harbor

# [VM] 生成最小配置（练习先用 http；生产必须 https，见 7.4）
sudo cp harbor.yml.tmpl harbor.yml
sudo vim harbor.yml   # 改三处：hostname: 172.30.30.21（VM 对外 IP）
                      # 注释掉整个 https: 块与 certificate/private_key
                      # harbor_admin_password: Harbor!Passw0rd
```

```bash
# [VM] 安装。--with-trivy 必须显式给：不加的话装出来的 Harbor 没有扫描器
#     （install.sh usage 原文：Please set --with-trivy if needs enable Trivy in Harbor）
sudo ./install.sh --with-trivy
# 预期结尾：✔ ----Harbor has been installed and started successfully.----
docker compose -f /opt/harbor/docker-compose.yml ps --format "table {{.Name}}\t{{.Status}}"
# 预期：nginx/portal/core/jobservice/registry/registryctl/postgresql/redis/exporter/trivy 全部 Up
```

注意：install.sh 调用的是 **docker compose 插件**（v2 语法，不是老的 docker-compose 二进制）；报 compose 不可用就先装插件再跑。

### 步骤 2：项目 + 机器人 + push

UI 操作（http://172.30.30.21，admin / Harbor!Passw0rd，登录后立即改密）：

1. 新建项目 `demo`，访问级别 Private
2. 项目 demo → Robot Accounts → 添加：名 `ci-push`，过期 90 天，权限勾 push + pull，复制生成的 secret（只显示一次）
3. Administration → Configuration → Authentication：确认"仅系统管理员可建项目"按需开关

```bash
# [VM] 用机器人登录并推一个镜像（nginx:alpine 可从 lab 08 的本地副本复用或重新拉）
docker login 172.30.30.21 -u 'robot$demo+ci-push' -p '<机器人secret>'
docker tag nginx:alpine 172.30.30.21/demo/api:v0.1
docker push 172.30.30.21/demo/api:v0.1
# 预期：层上传成功，UI 项目 demo 里出现镜像 api，tag v0.1

# 未登录验证私有性（预期 401 unauthorized），然后配 insecure 信任再拉回：
docker logout 172.30.30.21
docker pull 172.30.30.21/demo/api:v0.1 2>&1 | head -2
# http registry 要客户端信任（同 03 章 lab 08 提示 1）：
echo '{"insecure-registries":["172.30.30.21"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
docker login 172.30.30.21 -u 'robot$demo+ci-push' -p '<机器人secret>'
docker pull 172.30.30.21/demo/api:v0.1    # 预期：重新拉回成功
```

### 步骤 3：扫描 + 阻止拉取

```text
UI：项目 demo → api → v0.1 → Scan（或项目配置勾选 Automatically scan images on push）
预期：几分钟出 CVE 报告，按 CRITICAL/HIGH/... 分组

UI：项目 demo → Policy → 勾选 Prevent vulnerable images from running 并选严重度阈值
     （另一个开关 Prevent latent vulnerable images from running：未扫描的镜像也拒拉）
验证：对一个 CRITICAL 超阈值的 tag 尝试 docker pull，预期被 Harbor 拒绝并提示策略原因
```

### 步骤 4：retention + gc 闭环

```text
UI：项目 demo → Policy → Tag Retention：Add Rule
     保留策略：retain the most recently pushed #10 images（所有 ** tag）
     RETENTION DRY RUN → 看会删哪些 → EXECUTE
UI：Administration → Clean Up → Garbage Collection
     DRY RUN 看可释放空间 → GC NOW
     完成后在 History 里核对 freed 空间
```

### 步骤 5：代理缓存项目（省外网带宽）与清理

```text
UI：新建项目 dockerhub，类型选 Proxy Cache，上游 docker.io（项目名会进 pull 路径）
```

```bash
# [VM] 从自己的 Harbor 拉"上游镜像"（Docker Hub 官方镜像在 library/ 命名空间下）
docker pull 172.30.30.21/dockerhub/library/alpine:3.20   # 首次回源（可依赖已配代理）
docker pull 172.30.30.21/dockerhub/library/alpine:3.20   # 第二次命中本地缓存，不再出网

# 实验完保留环境供 labs/04-harbor-registry 复用；彻底回收时：
cd /opt/harbor && sudo docker compose down -v      # -v 连数据卷一起删
sudo rm -rf /opt/harbor /opt/harbor.tgz
```

## 8. 对照表：本地 registry:2 vs Harbor

第 1 节五个缺口到这里全部有了着落，给出与 03-docker/labs/08（以及 08 章实战步骤 6 的 chart-registry）的最终对照：

| 维度 | registry:2（03 章 lab 08） | Harbor（本章） |
| --- | --- | --- |
| 本质 | 一个 Distribution 进程 | nginx + core/portal/jobservice + Distribution + postgres/redis/trivy 编排 |
| UI | 无（curl /v2/_catalog） | portal 完整管理界面 |
| 认证 | 无/htpasswd 全局一份 | 项目级 RBAC + 机器人账户 + OIDC/LDAP 对接 |
| 漏洞扫描 | 无 | 内置 Trivy，push 即扫，可阻止拉取 |
| 复制/容灾 | 无（rsync 数据目录） | push/pull 复制规则、事件/定时触发、跨机房容灾 |
| 生命周期 | 只增不减（手动 gc 命令、停写才安全） | retention 策略 + 在线 GC（dry-run/cron/多 worker） |
| 审计 | 无 | 谁在何时 push/pull/删，全进 postgres 可查 |
| chart | 可当 OCI 仓用（helm push oci://，08 章步骤 6） | 同为 OCI，且与镜像同项目同权限，享受 retention/复制 |
| 资源占用 | ~50MB 内存 | 4G+ 内存、多容器编排 |
| 定位 | 单机、开发、离线最小可用 | 团队/企业、多环境、有合规要求 |

选型一句话：**给自己用 registry:2 足够，给组织用上 Harbor**。两个门槛判据——出现"第二个团队"或出现"第二个机房"——满足任一条，裸 registry 就该退役了。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| push 报 `server gave HTTP response to HTTPS client` | http 部署但客户端按 https 连 | daemon.json 配 insecure-registries（见步骤 2），或给 Harbor 上 TLS（7.4） |
| docker login 报 unauthorized 但密码没输错 | 机器人用户名没带 `robot$项目+名` 全称，或 secret 复制带空格 | 用户名完整复制 UI 里的值；secret 重新生成 |
| 装完 UI 打不开、`docker compose ps` 里 core 反复重启 | 内存不足（全家桶约 4G）或 harbor.yml 缩进错 | `docker logs harbor-core` 看报错行；释放内存后重来 |
| 勾了阻止拉取后 CI 推完镜像立即被集群拉取失败 | push 后扫描未完成，镜像处于未评估状态 | CI 改为"推 → 扫描完成 → 再触发部署"；或对 CI 专用项目关掉该开关 |
| retention 删了 tag 但磁盘没降 | retention 只删引用，blob 要 GC 才释放 | 按 7.1 两步走；UI 里 GC DRY RUN 先估空间 |
| cosign 签名后 UI 没显示签名标记 | 未在项目/系统配置里上传 cosign 公钥 | 按官方文档配置公钥后重新查看 artifact |
| 复制规则一直 Failed | 目标 registry 凭据失效/网络不通/TLS 不信任 | Replication Rules → 编辑里点 Test Connection；jobservice 日志看具体错误 |
| 升级后项目/机器人全消失 | 升级未按官方路径（没跑 prepare migrate，或指了空的数据目录） | 恢复 7.2 备份重来；严格按官方逐级路径 |

## 自测

<details><summary>1. Harbor 的 registry 组件不校验密码，那 docker push 的鉴权发生在哪？这个设计换来了什么？</summary>

docker 客户端先向 core 的 token 服务证明身份（basic auth，机器人或用户），拿到一个声明"该身份在项目 X 有 push 权限"的短期 token，再持 token 访问 registry；registry 只验 token 不碰用户库。换来的是：鉴权逻辑集中在 core（RBAC/OIDC/LDAP 一处实现），数据面 registry 保持与上游 Distribution 一致、无状态可替换，token 短期化又缩小了凭据泄漏窗口。这与 K8s 的 ServiceAccount token 思路同构——都是"认证一次、授权凭据短期化"。

</details>

<details><summary>2. 阻止拉取有漏洞镜像的开关开在 Harbor（仓库侧），为什么说它和集群准入（07-cks/04 第 5 节）不是互相替代的关系？各自拦得住什么、拦不住什么？</summary>

Harbor 侧开关在 token 签发环节拒绝 pull，保护**所有**以它为仓库的客户端（包括没装准入策略的集群、裸 docker 主机），一处配置全局生效；但它只约束"经我这个 Harbor 的路径"，绕开仓库直连上游（比如节点直接 pull docker.io）就失效。集群准入（Kyverno/policy-controller）在 apiserver 的 admission 拦截，保护**这个集群**不管镜像来自哪个仓库，还能叠加签名验证（cosign）、仓库白名单等策略；代价是每个集群都要部署维护，且 kubelet 已缓存的镜像层不重新过 admission。生产组合拳：仓库侧挡大部分（含扫描结果），集群准入做最后一道（签名+仓库白名单）。

</details>

<details><summary>3. retention 规则删掉了 20 个旧 tag，运维反馈磁盘一点没降。解释机制并给出正确的空间回收操作序列。</summary>

retention 删除的是 artifact/tag 引用（数据库层"看不见了"），镜像层 blob 仍躺在 /data/registry——Distribution 的内容寻址存储允许同一 blob 被多个 manifest 引用，只有"无任何 manifest 引用"的 blob 才可删，这一步是 GC 的职责。正确序列：retention 执行（删引用）→ Administration → Clean Up → Garbage Collection（DRY RUN 预估 → GC NOW 真删）。另外注意 GC 有 2 小时保护窗，刚推送的层不会被误删；GC 在线执行不必停推拉。

</details>

<details><summary>4. 机器人账户设了 90 天过期。过期那天全公司的 CI 突然集体失败，如何设计才能避免这种"定时炸弹"？</summary>

三个动作组合：一，**监控/告警前置**——对机器人到期时间做巡检（Harbor API 可查），提前 7~14 天告警；二，**新旧重叠轮换**——新机器人生成后先在 CI 变量里并存验证，再切流量、最后吊销旧的，避免"先删旧的再建新的"的死锁窗口；三，**过期时间分层**——关键 CI 凭据 90 天，演示类 7 天，且到期日避开节假日。这也回应 3.2 节的原则：机器人账户的价值（可过期、可吊销）同时就是它的风险（会过期、被吊销），必须配套轮换流程而不是只享受好处。

</details>

<details><summary>5. 为什么 Harbor v2.8 移除 ChartMuseum 后"chart 仓库"没有消失？结合 OCI artifact 模型解释 chart、cosign 签名、SBOM 在 Harbor 里的统一地位。</summary>

因为 chart 的分发需求（版本化、拉取认证、retention、复制）没有消失，只是载体统一了：Harbor v2.x 把一切制品建模为 OCI artifact + referrers 关系——镜像是 artifact，helm chart 打包后推 oci:// 也是 artifact，cosign 签名是"指向某 digest"的附带 artifact，SBOM 同理。于是项目权限、retention 策略、复制规则、审计日志这些**管理能力对全部制品类型一次生效**，不需要每种制品单独一套仓库（ChartMuseum 时代的做法）。这也是第 6 节"镜像与 chart 同项目同权限"的底层原因：仓库管理的粒度从"镜像"泛化成了"制品"。

</details>

## 延伸阅读

- Harbor 官方文档（安装/配置/管理）：https://goharbor.io/docs/
- Harbor 架构与组件：https://github.com/goharbor/harbor/blob/main/ARCHITECTURE.md
- 复制规则与代理缓存：https://goharbor.io/docs/2.15.0/administration/replication/
- GC 与 retention：https://goharbor.io/docs/2.15.0/administration/garbage-collection/
- cosign（与 07-cks/04 第 4 节互参）：https://docs.sigstore.dev/
