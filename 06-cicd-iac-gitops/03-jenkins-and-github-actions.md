# 03 · Jenkins 与 GitHub Actions：存量读写与云端流水线

> 模块：06-cicd-iac-gitops ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点，国内存量巨大，"能看懂能改"即可）

## 学习目标

- 能解释 Jenkins controller/agent 主从架构与 label 调度机制，说明为什么不能用单机 Jenkins 抗构建压力
- 能读懂声明式 Jenkinsfile（pipeline/agent/environment/stages/when/post），并能安全地改一个 step
- 能编写 GitHub Actions workflow（on/jobs/steps/uses/secrets），并解释 runs-on 与 self-hosted runner 的差异
- 能操作 docker 方式拉起 Jenkins 完成解锁与首个 pipeline，能给自己 GitHub 仓库接上 CI
- 能排查 Jenkins agent 连不上、国内访问 GitHub Actions 慢/超时两类高频问题

## 1. Jenkins 主从架构

Jenkins 的核心思想：**controller 只做调度和 UI，真正的构建跑在 agent 上**。

```
                 ┌──────────────────────────┐
   git push ───▶ │  Jenkins Controller      │
   (webhook)     │  UI + 调度 + 插件 + 凭据  │
                 └─────┬──────────┬─────────┘
            JNLP(50000)│          │SSH
                 ┌─────▼────┐ ┌───▼────────┐
                 │ agent-1  │ │ agent-2    │   ← 每个 agent 有 label：
                 │ label:   │ │ label:     │     docker / jdk17 / linux
                 │  docker  │ │  jdk17     │
                 └──────────┘ └────────────┘
                    跑构建 job      跑构建 job
```

- **agent（旧称 slave/node）**：一台机器或一个容器，跑 `agent.jar` 通过 JNLP（TCP 50000）反向连接 controller，或由 controller SSH 上门
- **label 调度**：pipeline 里声明 `agent { label 'docker' }`，只有带该标签的空闲 agent 领任务
- **executor**：每个 agent 上的并发槽位，`agent { label 'docker' }` 排队本质是在等 executor
- 为什么要主从：构建是 CPU/IO 密集型且依赖特定工具链（JDK、docker、浏览器），拆 agent 既隔离环境又水平扩容；controller 单机跑构建会拖垮 UI，也是安全大忌（构建脚本可逃逸影响调度核心）

安装要点（实验用 docker 即可）：

```bash
# [任意Ubuntu] Jenkins LTS 单机（生产应为 controller+agent 分离）
docker run -d --name jenkins --restart always \
  -p 8888:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  jenkins/jenkins:lts-jdk17

# [任意Ubuntu] 取初始管理员密码，浏览器开 http://<本机IP>:8888 完成解锁
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
# 选 "Install suggested plugins"，建管理员账号，进入首页
```

## 2. Jenkinsfile 声明式语法读法

声明式 pipeline 把流水线写成结构化 DSL，存进仓库（Pipeline as Code）。逐段拆解一份生产风格的样例：

```groovy
// [文件 Jenkinsfile] 仓库根目录
pipeline {
    agent any                       // 任意可用 agent；生产写 agent { label 'docker' }

    environment {
        // credentials('id') 从 Jenkins 凭据库取值：自动生成 XXX_USR / XXX_PSW 两个变量
        REGISTRY    = 'registry.example.com'
        IMAGE       = "${REGISTRY}/demo/api:${env.BUILD_NUMBER}"
        DOCKER_CREDS = credentials('docker-registry')
    }

    options {
        timestamps()                          // 日志加时间戳
        timeout(time: 30, unit: 'MINUTES')    // 防僵尸构建
        disableConcurrentBuilds()             // 同一分支不并发
    }

    stages {
        stage('Checkout') {
            steps { checkout scm }            // 多分支 pipeline 自动检出触发的分支
        }
        stage('Build') {
            steps {
                sh './gradlew build'          // sh = 在 agent 上执行 shell
            }
        }
        stage('Test') {
            steps {
                sh './gradlew test'
            }
        }
        stage('Quality Gate') {
            when { branch 'PR-*' }            // 仅 PR 分支跑质量门禁
            steps {
                sh './gradlew check'
            }
        }
        stage('Dockerize') {
            when { buildingTag() }            // 打 tag 的构建才做镜像
            steps {
                sh 'echo "$DOCKER_CREDS_PSW" | docker login "$REGISTRY" -u "$DOCKER_CREDS_USR" --password-stdin'
                sh 'docker build -t "$IMAGE" .'
                sh 'docker push "$IMAGE"'
            }
        }
        stage('Deploy') {
            when { branch 'main' }
            steps {
                sh './deploy.sh "$IMAGE"'
            }
        }
    }

    post {
        success { echo "BUILD ${env.BUILD_NUMBER} 成功" }
        failure { echo "构建失败，请查日志" }
        always  { archiveArtifacts artifacts: 'build/libs/**', allowEmptyArchive: true }
    }
}
```

读法心法（改文件前先定位这五层）：

| 层级 | 关键字 | 你最常改的地方 |
|---|---|---|
| 全局 | `agent` / `environment` / `options` / `parameters` | 加环境变量、换 label |
| 阶段 | `stages` > `stage('名字')` | 加/删一个 stage |
| 条件 | `when { branch / buildingTag / expression }` | 调整某 stage 的触发条件 |
| 步骤 | `steps` > `sh / echo / script / checkout` | 改命令、加 `retry {}`、`withCredentials([])` |
| 收尾 | `post { always/success/failure }` | 产物归档、通知 |

- `environment` 里 `credentials('id')` 展开成 `变量名_USR`（用户名）与 `变量名_PSW`（密码），密码在日志中自动打码——**永远不要把密码写进 Jenkinsfile 明文**
- `when` 可以嵌套 `allOf/anyOf/not` 组合条件；`expression` 里写 Groovy 布尔表达式
- 声明式里塞 Groovy 逻辑用 `script { ... }` 块，但滥用会让 pipeline 变天书；公共逻辑抽 **Shared Library**（`@Library('my-lib') _`），这是大厂 Jenkins 的标配
- 声明式之外还有更老的 Scripted Pipeline（纯 Groovy），见到 `node { stage('x') { } }` 结构即是，读懂即可，新项目不要再用

## 3. GitHub Actions

### 3.1 workflow 结构

把 YAML 放进 `.github/workflows/` 即生效，一个仓库可以有多个 workflow：

```yaml
# [文件 .github/workflows/ci.yml]
name: ci

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch: {}        # 允许手动触发

jobs:
  test:
    runs-on: ubuntu-latest     # GitHub 托管的 runner（海外 VM）
    steps:
      - uses: actions/checkout@v4          # marketplace 里的官方 action：拉代码
      - name: Run tests
        run: |
          echo "run unit tests here"
          test -d .github && echo "repo ok"

  build-push:
    needs: test                          # 等 test 成功
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write                    # 允许推 ghcr.io
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}   # 每次运行自动签发的短期 token
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:latest
```

结构对照表：

| 概念 | 对应 | 说明 |
|---|---|---|
| workflow | `.github/workflows/*.yml` | 一次流水线定义，由 `on` 事件触发 |
| job | `jobs:` 下的一级条目 | 每个 job 在**全新 VM** 上跑（不是容器复用） |
| step | `steps:` 列表 | 同一 job 内串行；`run` 执行命令，`uses` 引用 action |
| action | marketplace 组件 | 如 `actions/checkout`，社区生态是 GHA 最大优势 |
| secrets | repo/org 级加密变量 | `${{ secrets.X }}` 引用，日志自动打码 |

注意：ghcr.io 要求镜像名全小写，若仓库名含大写需先转小写（如 `github.repository | lower`，可写在 step 里用 env 中转）。

### 3.2 国内可用性说明（重要工程事实）

- GitHub 托管 runner 在海外机房：clone 你的仓库、拉 docker 基础镜像、装依赖都从海外网络走，国内仓库大/依赖多时容易超时
- 代码推送/克隆本身国内可直连但时快时慢；`ghcr.io`、部分对象存储直连速率不稳定——**以实际网络为准**，不要在文档里写死"一定能通"
- 三个务实对策：
  1. **self-hosted runner**：在自己机房 Ubuntu VM 上装 runner（Settings → Actions → Runners → New self-hosted runner，网页会给出一模一样的下载与 `./config.sh --url ... --token ...` 命令），workflow 里改 `runs-on: self-hosted`。代码和产物都在内网闭环，但要自己保证 runner 机器的安全（fork 仓库的 PR 默认不注入 secrets，防投毒）
  2. 依赖走国内镜像源（pip/npm/apt 的 mirror 参数写在 workflow 里），把海外流量降到最低
  3. CI 产物（镜像）推国内 registry，部署侧只拉国内源
- 反向选型结论（与本章 Jenkins 呼应）：国内企业内网/强合规 → GitLab CI 或 Jenkins；开源项目/个人项目/海外协作 → GitHub Actions 最顺手。这套判断比"哪个更强"重要

## 4. 实战演练

### 4.1 Jenkins：跑通第一条 pipeline

```bash
# [任意Ubuntu] 前置：按第 1 节命令启动 Jenkins 并完成初始化
# 1) 新建任务：New Item → 名称 demo-pipeline → 类型 Pipeline → OK
# 2) Pipeline 区域：Definition 选 "Pipeline script"，粘贴第 2 节 Jenkinsfile
#    （自建任务没有 scm，先把 checkout scm 那个 stage 删掉再保存）
# 3) 点 Build Now
```

```bash
# [任意Ubuntu] 验证构建真的执行了
docker exec jenkins ls /var/jenkins_home/jobs/demo-pipeline/builds/1/
# 输出应含 build.xml、log 等文件；Console Output 里能看到 BUILD SUCCESS / 成功
```

改一个 step 再跑：把 `stage('Build')` 的 sh 命令换成 `sh 'echo hello from ${BUILD_NUMBER}'`，重新 Build Now，日志应打印 `hello from 2`——这就是"能看懂能改"的最小闭环。

### 4.2 GitHub Actions：给公开仓库接 CI

```bash
# [本地Windows] 需要一个 GitHub 账号与 git 环境
mkdir demo-ci && cd demo-ci && git init -b main
mkdir -p .github/workflows
# 把 3.1 的 ci.yml 放入 .github/workflows/，并加一个 README.md
git add . && git commit -m "ci: initial workflow"
git remote add origin https://github.com/<你的用户名>/demo-ci.git   # 先在网页上建好空仓库
git push -u origin main
```

验证：仓库 Actions 标签页出现 `ci` workflow 的一次运行；点开看到两个 job，`test` 绿、`build-push` 绿（推 ghcr 成功后 Packages 标签页出现镜像）。若 push 报 403，是仓库不存在或 token 权限问题，与 workflow 无关。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| Jenkins agent 一直离线 | JNLP 端口 50000 未放通 / agent 机器时间漂移 | 检查防火墙与 NTP；controller 网页 Manage Nodes 里看握手日志 |
| job 排队不执行 | 没有匹配 label 的 agent，或 executor=0 | 核对 `agent { label '...' }` 与节点标签；调大 # of executors |
| Jenkinsfile 改了不生效 | 任务用的是旧分支/旧 revision 的 Jenkinsfile | multibranch 重新扫描；或 Pipeline 定义改指向正确 SCM |
| GHA 里 `docker login` 失败 | GITHUB_TOKEN 缺 packages 权限 | job 加 `permissions: packages: write` |
| GHA clone/pull 超时 | 海外 runner 访问国内仓库慢，或反之 | 换 self-hosted runner；依赖走镜像源；浅克隆 `fetch-depth: 0` 慎用 |
| secrets 在 fork PR 里为空 | GHA 默认不向 fork 的 PR 注入 secrets | 属预期安全行为；需要验证的步骤改 `pull_request_target` 并严格审计（有被投毒风险，优先不用） |

## 自测

<details><summary>1. 为什么 Jenkins 架构上强调"controller 不跑构建"？从性能与安全两方面回答。</summary>

性能：构建抢 CPU/内存/磁盘会拖慢 UI 与调度；agent 弹性扩容、按 label 隔离工具链（jdk17/docker/浏览器）。安全：构建代码来自任意提交者，若与 controller 同机执行，恶意 step 可直接读凭据库（凭据都存 controller）、篡改其他 job 配置。所以规范是 controller 只调度，构建全在受限 agent，agent 上再按信任级别分池。
</details>

<details><summary>2. 声明式 pipeline 里 credentials('docker-registry') 展开后有哪些变量？为什么密码用 --password-stdin 而不是 -p？</summary>

展开为 `docker-registry_USR` 和 `docker-registry_PSW` 两个环境变量（secret text/file 类型则各是一个）。`docker login -p` 会把密码写进命令行，出现在 `ps` 输出与 shell history 里；`--password-stdin` 从管道读入，密码只存在于环境变量与管道中，日志里被 Jenkins 自动打码，这是官方推荐姿势。
</details>

<details><summary>3. GitHub Actions 的 job 之间默认是什么关系？和 GitLab CI 的 stage 语义有何不同？</summary>

GHA 中没有 stage 这个强制层，job 默认全并行，需要顺序就用 `needs: [xxx]` 显式声明依赖——相当于"人人都要写 needs 的 DAG 模型"。GitLab CI 默认按 stage 强串行，`needs` 是打破串行的例外。思维迁移：从 GitLab 过来的人要主动给 GHA 加 needs，否则本应串行的 job 会同时起 VM 浪费额度。
</details>

<details><summary>4. self-hosted runner 解决了什么问题，引入了什么新风险？如何缓解？</summary>

解决：国内访问海外 runner/仓库慢、构建要访问内网资源（私有 registry、内网制品库）、数据不出域。新风险：runner 进程常驻内网机器并执行任意 workflow 代码，等于给了仓库写权限的人一台内网跳板；PR 投毒可在 workflow 里读环境里的敏感文件。缓解：runner 专用机/容器隔离并最小权限、仓库 Settings 里限制哪些 workflow 需要审批、fork PR 不触发敏感 workflow（默认不注入 secrets 的机制不要绕）、机密集中放 environments 的 protected secrets 并限制分支。
</details>

<details><summary>5. 同一套"构建镜像→测试→多环境部署"，你在什么条件下选 Jenkins 而不是 GitLab CI？</summary>

典型条件：存量 Java 团队已深耕 Jenkins 插件生态（SonarQube、发布审批、与老 CMDB 联动）；代码托管不在 GitLab（如自建 Gitea/企业内部 Gerrit），Jenkins 作为通用执行器可接任意 SCM；构建环境异构（大型机式专属工具链跑在特定 agent 上）。反之代码已在 GitLab 且团队规模不大，GitLab CI 少维护一个系统、YAML 即全部配置，维护成本显著更低。
</details>

## 延伸阅读

- Jenkins 声明式 pipeline 语法手册：<https://www.jenkins.io/doc/book/pipeline/syntax/>
- Jenkins 分布式构建（agent/node）：<https://www.jenkins.io/doc/book/using/using-agents/>
- GitHub Actions workflow 语法：<https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions>
- self-hosted runner 文档：<https://docs.github.com/actions/hosting-your-own-runners>
