# 02 · GitLab CI：从 pipeline 概念到多环境交付

> 模块：06-cicd-iac-gitops ｜ 建议时长：5 小时 ｜ 关联认证：—（无直接考点，国内企业级 CI 主力，实战必备）

## 学习目标

- 能解释 pipeline / stage / job 三层关系与 runner 的角色分工，读懂任意一条 pipeline 页面
- 能编写完整 `.gitlab-ci.yml`：stages、script、artifacts、cache、rules、needs、environment
- 能操作 docker 方式安装 GitLab Runner 并注册到实例（token 方式），排查 job 卡 pending
- 能搭建"构建镜像 → 推送 registry → 按分支/tag 部署到测试/生产"的完整流水线
- 能排查 dind/socket 模式下的 TLS、缓存不命中、变量泄露等常见故障

## 1. 概念模型：pipeline / stage / job / runner

GitLab CI 的世界观只有四个词：

```
push 代码 ──▶ GitLab 读取 .gitlab-ci.yml ──▶ 生成 pipeline
                                            │
   pipeline = 一次流水线实例                 ▼
   stage    = 阶段（串行排序）        ┌─────────────────────────┐
   job      = 任务（stage 内并行）    │ build │ test │ deploy    │  ← stages
   runner   = 执行器（干活机器）      │ job-a  │ job-c │ job-e    │  ← 同 stage
                                     │ job-b  │ job-d │ (manual) │    内并行
                                     └─────────────────────────┘
                                            │ 领取任务
                                            ▼
                              runner(docker executor)：起一个临时容器跑 job
```

- 同一 stage 内的 job **并行**，全部成功才进入下一 stage；任一失败则 pipeline 失败（默认）
- `needs` 可以打破 stage 串行，直接声明 job 依赖形成 DAG
- runner 是独立进程，靠轮询/长连接向 GitLab 领 job，跑完把日志与 artifacts 回传

## 2. `.gitlab-ci.yml` 全量语法

下面这份"注释即文档"的文件覆盖 90% 日常需求：

```yaml
# [文件 .gitlab-ci.yml] 仓库根目录
stages: [build, test, package, deploy]

variables:
  # 内置变量：CI_COMMIT_SHORT_SHA、CI_PROJECT_PATH、CI_COMMIT_TAG、CI_ENVIRONMENT_NAME
  APP_NAME: "demo-api"

default:
  image: docker:27            # 所有 job 的默认执行环境
  tags: [docker]              # 只由打了 docker 标签的 runner 领取
  before_script:
    - export IMAGE_TAG="${CI_REGISTRY}/${CI_PROJECT_PATH}:${CI_COMMIT_SHORT_SHA}"

build:
  stage: build
  script:
    - echo "编译 ${APP_NAME}，镜像将打成 ${IMAGE_TAG}"
    - mkdir -p dist && echo "artifact from ${CI_COMMIT_SHORT_SHA}" > dist/info.txt
  artifacts:                  # 产物：上传给 GitLab，供后续 stage 下载
    paths: [dist/]
    expire_in: 1 week         # 到期自动清理，防止仓库膨胀

test:
  stage: test
  image: alpine:3.20          # 覆盖默认镜像：测试不需要 docker
  script:
    - grep -q "artifact" dist/info.txt && echo "单测通过"
  rules:                      # 新语法，取代 only/except
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'

package:
  stage: package
  script:
    - docker build -t "$IMAGE_TAG" .
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - docker push "$IMAGE_TAG"

deploy-test:
  stage: deploy
  image: alpine:3.20
  script:
    - echo "滚动更新测试环境镜像为 $IMAGE_TAG"
  environment:                # 在 UI 上形成环境视图与部署历史
    name: test
    url: http://test.example.com
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'

deploy-prod:
  stage: deploy
  script:
    - echo "发布生产镜像 $IMAGE_TAG（人工确认后执行）"
  environment:
    name: production
    url: http://www.example.com
  rules:
    - if: '$CI_COMMIT_TAG'    # 只有打 tag 才出现在 pipeline 里
  when: manual                # 人工点击才执行——生产闸门
```

关键字速查：

| 关键字 | 作用 | 高频陷阱 |
|---|---|---|
| `stages` | 全局阶段顺序 | 未声明的 job 默认进 `test` stage |
| `script` | 要执行的 shell 命令 | 多行是逐条执行，任一非零退出即失败 |
| `artifacts` | job 间传文件（走 GitLab） | 只传 `paths` 列出的路径，`expire_in` 到期即删 |
| `cache` | job 间复用目录（走 runner 存储） | key 不同不命中；runner 分布式存储时建议 `key: $CI_COMMIT_REF_SLUG` |
| `rules` | 决定 job 是否创建 | 列表按序匹配，命中即停；`when: manual`/`when: delayed` 可附在规则里 |
| `needs` | DAG 依赖，越过 stage 排队 | `needs: [build]` 让 test 在 build 结束即开跑 |
| `environment` | 环境登记 + 部署记录 | 名字写错会凭空多一个环境 |
| `tags` | 选择 runner | job 卡 pending 的第一大原因 |

cache 与 artifacts 的本质区别：**cache 是"下次跑快点"的优化，随时可丢；artifacts 是"下游 job 要用"的传递，必须可靠**。依赖包目录用 cache，编译产物用 artifacts。

## 3. Runner 安装与注册（docker 方式）

前提：一台 Ubuntu VM（≥2C4G），已装 Docker，与 GitLab 网络互通。

```bash
# [任意Ubuntu] 启动 runner（config 持久化 + 挂载 docker.sock 供 job 构建/推送镜像）
docker run -d --name gitlab-runner --restart always \
  -v /srv/gitlab-runner/config:/etc/gitlab-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gitlab/gitlab-runner:alpine
```

注册需要 token。GitLab 16 起推荐在 UI 上创建 **project/instance runner**（Admin Area → CI/CD → Runners，或项目 Settings → CI/CD → Runners → New project runner），得到 `glrt-` 开头的 authentication token；旧版接口使用的 registration token 已标记废弃。字段名随版本演进，以官方文档为准。

```bash
# [任意Ubuntu] 用 glrt- token 非交互注册
docker exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "http://192.168.56.10:8080" \
  --token "glrt-xxxxxxxxxxxxxxxx" \
  --executor docker \
  --docker-image "docker:27" \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --docker-pull-policy if-not-present
```

```bash
# [任意Ubuntu] 验证注册结果（也可在 GitLab UI 的 Runners 页看到绿色在线）
docker exec gitlab-runner gitlab-runner verify
docker exec gitlab-runner cat /etc/gitlab-runner/config.toml | head -30
```

三个工程决策点：

1. **executor 选 docker**：job 在一次性容器里跑，环境干净、依赖镜像化；shell executor 会把宿主机搞脏且权限风险大
2. **构建镜像的两种方式**：
   - socket 绑定（上面这种）：job 容器复用宿主机 dockerd，简单但 job 等同 root，CKS 视角属高危
   - dind（`services: [docker:27-dind]`）：独立 daemon，隔离好但要处理 TLS 或设 `DOCKER_TLS_CERTDIR: ""` 关闭
3. `config.toml` 中 `concurrent` 控制全局并发，`pull_policy` 控制镜像拉取策略——国内拉 Docker Hub 慢时可在宿主机 daemon 配镜像加速（改 `/etc/docker/daemon.json` 后 `systemctl reload docker`）

## 4. 实战演练：完整跑通一条多环境 pipeline

### 4.1 起 GitLab（需 ≥4G 内存的 Ubuntu VM）

```yaml
# [文件 docker-compose.yml] GitLab CE 单机部署，宿主机 IP 假设 192.168.56.10
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: always
    shm_size: "256m"
    hostname: "192.168.56.10"
    environment:
      GITLAB_ROOT_PASSWORD: "Gitlab!Passw0rd"
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.168.56.10:8080'
        gitlab_shell_ssh_port = 2222
        puma['worker_processes'] = 2
        sidekiq['max_concurrency'] = 5
        prometheus_monitoring['enable'] = false
    ports:
      - "8080:8080"
      - "2222:22"
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
volumes:
  gitlab-config:
  gitlab-logs:
  gitlab-data:
```

```bash
# [任意Ubuntu] 启动并等待就绪（首次初始化约 3~5 分钟）
cd ~ && mkdir -p gitlab-server && cd gitlab-server   # 把 docker-compose.yml 放这里
docker compose up -d
docker logs -f gitlab 2>&1 | grep -m1 "gitlab Reconfigured!" || true
# 浏览器打开 http://192.168.56.10:8080，root / Gitlab!Passw0rd 登录
```

GitLab 自带 container registry（`CI_REGISTRY` 等变量自动指向它），单机演示需再配端口，本文直接用变量注入外部 registry 信息，两种都可行。

### 4.2 建项目并推送代码

```bash
# [本地Windows] 也可在任意 Ubuntu 上操作；先在 UI 建 blank project：demo-api
git clone http://192.168.56.10:8080/root/demo-api.git
cd demo-api
```

```dockerfile
# [文件 Dockerfile] 仓库根目录：一个最小的可运行镜像
FROM alpine:3.20
COPY dist/info.txt /app/info.txt
CMD ["cat", "/app/info.txt"]
```

把第 2 节的 `.gitlab-ci.yml` 放进仓库根目录，再准备构建产物目录：

```bash
# [本地Windows]
git add . && git commit -m "ci: add pipeline" && git push
```

### 4.3 配置 secrets

在项目 **Settings → CI/CD → Variables** 添加（这就是"密钥不进代码"的落点）：

| Key | Value | 勾选 | 说明 |
|---|---|---|---|
| `CI_REGISTRY_USER` | registry 用户 | masked | 登录 registry |
| `CI_REGISTRY_PASSWORD` | registry 密码 | masked, protected | 同上 |
| `CI_REGISTRY` | registry 地址 | protected | 如 `registry.example.com` |

注意：GitLab 内置的 `CI_REGISTRY*` 变量会被同名自定义变量覆盖，自建 registry 时这么用最直观。`protected` 变量只在受保护分支/tag（默认 main 与 tag）的 pipeline 中注入——生产凭据务必勾上。

### 4.4 验证多环境行为

```bash
# [本地Windows] 触发测试环境部署
git commit --allow-empty -m "chore: trigger" && git push
# UI 预期：build → test → package → deploy-test 全绿，出现 test 环境页

# 触发生产（带人工闸门）
git tag -a v0.1.0 -m "first release" && git push origin v0.1.0
# UI 预期：deploy-prod 处于 manual 状态，点 ▶ 后执行
```

命令行侧验证（装 gitlab-runner 机器上）：

```bash
# [任意Ubuntu] 观察 runner 领任务与 job 容器生命周期
docker exec gitlab-runner gitlab-runner list
docker ps --filter label=com.gitlab.gitlab-runner.type=build
```

## 5. 多环境与 secrets 管理要点

- **环境分层靠 rules 而不是复制 pipeline**：分支 → test 环境；tag → prod 环境 + `when: manual`。测试全自动、生产人工确认，是风险与效率的平衡点
- **环境权限**：Settings → CI/CD → Protected environments 可限制谁能往 production 部署（deployer 角色分离）
- **变量四件套**：`masked`（日志打码，需 ≥8 字符且单行）、`protected`（仅保护分支/tag 可见）、`Type: File`（值写进临时文件，变量值为路径，适合 kubeconfig/ssh 私钥）、`environment scope`（只注入指定环境）
- **不要做的事**：把密码写进 `.gitlab-ci.yml` 明文、写进镜像 label、`echo $PASSWORD` 调试后忘了删（masked 会被打码，但别依赖它）
- 更高要求时接 Vault / 云 KMS：CI 只拿短期 token 换真实凭据，变量里不落长期密钥

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| job 一直 pending，提示 no runner | job 的 `tags` 与 runner 标签不匹配，或 runner 离线 | UI Runners 页核对标签；`gitlab-runner verify` |
| docker build 报 `Cannot connect to the Docker daemon` | dind 模式 TLS 校验失败或 socket 未挂载 | socket 模式确认 volumes 挂载；dind 模式加 `variables: DOCKER_TLS_CERTDIR: ""` |
| cache 每次都重新下载依赖 | cache key 不稳定或 runner 是分布式存储 | `cache: key: {files: [package.json]}`；确认策略 `policy: pull-push` |
| 下游 job 找不到上游文件 | 产物没进 artifacts，或 expire 已过 | 补 `artifacts: paths`；查 job 页的 artifact 下载链接是否还在 |
| `deploy-prod` 拿不到密码变量 | 变量勾了 protected，而 tag 未设为 protected tag | Settings → Repository → Protected tags 加 `v*` |
| pipeline 无故重复跑 | push 规则同时匹配 push 和 MR 事件 | rules 里显式区分 `$CI_PIPELINE_SOURCE` |

## 自测

<details><summary>1. stage 串行与 needs DAG 同时存在时，GitLab 如何调度？什么场景必须用 needs？</summary>

默认调度按 stage 墙推进；声明 `needs` 的 job 脱离 stage 顺序，只等它声明的上游 job 完成（并直接下载其 artifacts，跳过整层）。典型场景：一条 40 分钟的测试流水线里，e2e 测试只依赖 build 产物而不依赖 lint，用 needs 让两者并行，把关键路径从串行和压到最大单branch耗时。注意 needs 引用的 job 必须存在于同一 pipeline（rules 过滤后不存在会直接配置报错）。
</details>

<details><summary>2. 为什么说 cache 丢了不影响正确性，而 artifacts 丢了 pipeline 就挂？设计上应如何分别对待？</summary>

cache 只是加速（依赖包可以重新下载/编译），语义上"可丢弃"；artifacts 是 job 间的数据通道（测试报告、构建产物），丢了下游必失败。因此 cache 的 paths 可以随便清（runner 会自动重建），artifacts 必须设合理 expire_in 控制成本但不能随手禁用；对"既要快又要可靠"的产物，同时进 cache（加速）与 artifacts（可靠传递）也是合法做法。
</details>

<details><summary>3. socket 绑定与 dind 两种构建方式的安全模型差异是什么？为什么说前者在 CKS 视角是高危？</summary>

socket 绑定下，job 容器通过宿主机 `/var/run/docker.sock` 直接指挥宿主 dockerd：能挂载宿主机任意路径、`--privileged` 起特权容器，等于给了 job root 逃逸能力——任何能提交 `.gitlab-ci.yml` 的人都控制了 runner 宿主机。dind 为每个 job 起独立 daemon（常配 rootless/Kata），隔离边界清晰但成本高、要处理 TLS/网络。生产建议：构建集群与部署集群物理分开、构建用 dind 或 kaniko（无 daemon、以非 root 直接推 registry）。
</details>

<details><summary>4. masked 变量为什么有时无法创建？它在什么情况下仍可能泄露？</summary>

masked 要求值满足：单行、≥8 字符、只含 base64 友好字符（否则日志匹配打码会失效）。即使 masked，仍可能通过 `echo ${VAR:0:1}` 这类切片、写进文件再 cat、传给不脱敏的第三方工具等方式绕出。所以 masked 是"防手滑"不是"防恶意"，真正的隔离靠 protected scope + 环境权限 + 最小权限的部署凭据。
</details>

<details><summary>5. 如果 test 阶段想"失败但别挡住 deploy-test"（比如允许失败的冒烟测试），怎么写？语义上允许失败和忽略失败有何区别？</summary>

在 job 上加 `allow_failure: true`：job 失败时 pipeline 记为"带警告的通过"，后续 stage 照常执行；区别于 `rules: when`（根本不创建 job）。语义上"允许失败"= 这个信号仅供参考；"忽略"= 这个检查不存在。滥用 allow_failure 会让 pipeline 绿得毫无意义——只应对确实非阻断的检查开启。
</details>

## 延伸阅读

- `.gitlab-ci.yml` 全量关键字参考：<https://docs.gitlab.com/ee/ci/yaml/>
- Runner 安装与 register：<https://docs.gitlab.com/runner/register/>
- Docker executor 与 dind 官方文档：<https://docs.gitlab.com/ee/ci/docker/using_docker_build/>
- CI/CD 变量与 masked/protected 规则：<https://docs.gitlab.com/ee/ci/variables/>
