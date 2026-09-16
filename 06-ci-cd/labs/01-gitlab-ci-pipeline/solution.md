# Lab 01 · 解答：GitLab CI 流水线

> 配套 task.md 使用。环境：一台装有 Docker 的 Ubuntu 22.04/24.04 VM，可访问外网拉镜像与 npm 包。

## 第 0 步：理解设计

四个 stage 的职责边界（和真实团队里的分工会对上）：

```
lint ──► build ──► test ──► image
 │         │         │        │
 │         │         │        └─ docker:27-cli 容器里 docker build
 │         │         └─ 装上 dist/*.whl 跑 pytest
 │         └─ python -m build 打 wheel，产物放 dist/，声明 artifacts
 └─ ruff 静态检查（最便宜的防线放最前面，失败立刻止损）
```

关键机制：

- **artifacts / dependencies**：`build` 把 `dist/` 声明为 artifacts，`test` 与 `image-build` 通过 `dependencies: [build]` 精确拉取（而不是默认拉全部前序 job 的产物）。与 Jenkins 的 archiveArtifacts/copyArtifact 对应。
- **stage 串行依赖**：后一个 stage 默认等前一个 stage 全部成功，所以 lint 失败时 build 根本不会启动。
- **预定义变量**：`CI_COMMIT_SHORT_SHA`（短 commit 哈希）、`CI_PIPELINE_IID`（pipeline 流水号）是 GitLab 注入的，用来给镜像打可追溯的 tag。

## 第 1 步：安装 gitlab-ci-local

```bash
# [Ubuntu VM]
# NodeSource 安装 Node.js 22（Ubuntu 22.04 自带 node 太老；gitlab-ci-local 新版
# 用到 Set.prototype.union 等 Node 22+ 特性，装 20 会报 "kn.union is not a function"）
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm install -g gitlab-ci-local
gitlab-ci-local --version
```

为什么选 gitlab-ci-local：它解析的是与 GitLab 同一份 `.gitlab-ci.yml`，语义（stage 顺序、artifacts 传递、预定义变量）在本地和线上一致，资源开销只有几个短生命周期的 job 容器。若偏好独立二进制，GitHub Releases 也提供（文件命名以 firecow/gitlab-ci-local 的 README 为准）。

## 第 2 步：准备项目骨架

```bash
# [Ubuntu VM]
mkdir -p ~/labs/ci-demo && cd ~/labs/ci-demo
git init --initial-branch=main
mkdir -p templates
```

`app.py`（Flask HTTP 服务，两个端点）：

```python
# 文件: ~/labs/ci-demo/app.py
from flask import Flask

app = Flask(__name__)


@app.get("/")
def index():
    return {"app": "ci-demo", "version": "0.1.0"}


@app.get("/health")
def health():
    return {"status": "ok"}
```

`test_app.py`（用 Flask 的 test_client，不需要真的监听端口）：

```python
# 文件: ~/labs/ci-demo/test_app.py
from app import app


def test_index():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json()["app"] == "ci-demo"


def test_health():
    client = app.test_client()
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}
```

`pyproject.toml`（显式声明 py-modules，避免 setuptools flat-layout 自动发现把 test_app 也打进包里）：

```toml
# 文件: ~/labs/ci-demo/pyproject.toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "ci-demo"
version = "0.1.0"
dependencies = ["flask"]

[tool.setuptools]
py-modules = ["app"]
```

`requirements.txt`：

```text
# 文件: ~/labs/ci-demo/requirements.txt
flask==3.0.3
pytest==8.3.3
```

`Dockerfile`（只 COPY wheel 进镜像，源码不进最终镜像，layer 更干净）：

```dockerfile
# 文件: ~/labs/ci-demo/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY dist/*.whl ./
RUN pip install --no-cache-dir ./*.whl
EXPOSE 5000
CMD ["python", "-c", "from app import app; app.run(host='0.0.0.0', port=5000)"]
```

## 第 3 步：编写 .gitlab-ci.yml

```yaml
# 文件: ~/labs/ci-demo/.gitlab-ci.yml
stages: [lint, build, test, image]

variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.cache/pip"

lint:
  stage: lint
  image: python:3.12-slim
  script:
    - pip install ruff
    - ruff check .

build:
  stage: build
  image: python:3.12-slim
  script:
    - pip install build
    - python -m build --wheel
  artifacts:
    paths:
      - dist/

test:
  stage: test
  image: python:3.12-slim
  dependencies:
    - build
  script:
    - pip install dist/*.whl pytest
    - pytest -v

image-build:
  stage: image
  image: docker:27-cli
  dependencies:
    - build
  variables:
    IMAGE_TAG: "ci-demo:${CI_COMMIT_SHORT_SHA}"
    # docker:27-cli 自带的默认 context 指向 tcp://docker:2375（dind 服务别名），
    # 本地跑没有 dind，显式指回挂载进来的宿主机 socket
    DOCKER_HOST: "unix:///var/run/docker.sock"
  script:
    - docker build -t "$IMAGE_TAG" .
    - docker images "ci-demo"
```

逐条说为什么：

- `stages` 显式声明顺序，GitLab 按 list 顺序调度，stage 名是全局的；
- 每个 job 用 `image:` 指定执行环境（相当于该 job 的"一次性构建机"），lint/build/test 用 python 镜像、image-build 用 docker CLI 镜像，互不污染；
- `test` 装的是 `dist/*.whl`（打包产物）而不是源码 import，这一步真正验证"用户将来 pip install 到手的东西是好的"；
- `image-build` 的 tag 用 `CI_COMMIT_SHORT_SHA`，保证同一 commit 重建可追溯、不同 commit 不互相覆盖。

## 第 4 步：本地跑绿整条 pipeline

```bash
# [Ubuntu VM]
cd ~/labs/ci-demo
git add -A && git commit -m "init: ci pipeline"
# --volume 把宿主机 docker.sock 挂进 job 容器（image-build 的 docker build 要用；
# gitlab-ci-local 不会自动挂 socket，真实 GitLab 里这件事由 runner 的 volumes 配置做）
gitlab-ci-local --volume /var/run/docker.sock:/var/run/docker.sock
```

预期输出（节选）：四个 job 依次出现 `PASS`，最后有汇总行，形如：

```text
# [Ubuntu VM] gitlab-ci-local 输出（节选）
 ✔ lint     : passed
 ✔ build    : passed
 ✔ test     : passed
 ✔ image-build : passed
```

验证镜像确实产出：

```bash
# [Ubuntu VM]
docker images ci-demo
# REPOSITORY   TAG                 IMAGE ID       ...  
# ci-demo      <你的短commit SHA>   ...
```

## 第 5 步：验证 lint 失败会阻塞后续 stage

```bash
# [Ubuntu VM]
printf 'import os\n' >> app.py
git add -A && git commit -m "break: introduce lint error"
gitlab-ci-local --volume /var/run/docker.sock:/var/run/docker.sock
```

预期：`lint` job 报 ruff F401（`os` imported but unused）并 failed，`build`/`test`/`image-build` 不会被执行——stage 依赖天然截断了流水线。注意这里不能用模块顶层的 `unused_var = 1`：ruff 的 F841 只检查函数内的局部变量，模块级赋值默认不报，lint 会照样通过。回滚并复验全绿：

```bash
# [Ubuntu VM]
git revert HEAD --no-edit
gitlab-ci-local --volume /var/run/docker.sock:/var/run/docker.sock
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| image-build 报 `Cannot connect to the Docker daemon at unix:///var/run/docker.sock` 或 `Head "http://docker:2375/_ping": EOF` | job 容器里没有 docker socket：gitlab-ci-local **不会**自动挂载 `/var/run/docker.sock`；`docker:27-cli` 镜像自带的默认 context 又指向 `tcp://docker:2375`（不存在的 dind 服务） | job `variables` 里设 `DOCKER_HOST: "unix:///var/run/docker.sock"`，并用 `gitlab-ci-local --volume /var/run/docker.sock:/var/run/docker.sock` 运行（真实 GitLab 由 runner 的 `volumes` 配置完成挂载） |
| `gitlab-ci-local --version` 报 `TypeError: kn.union is not a function` | Node 版本过低：新版 gitlab-ci-local 用到 `Set.prototype.union`（Node 22+ 才有），而它自己声明的 `engines.node >=18` 过于宽松，npm 不会拦 | 装 Node 22（见第 1 步）后重装 `sudo npm install -g gitlab-ci-local` |
| build 报 `Multiple top-level modules discovered` | setuptools flat-layout 自动发现把 `app.py` 和 `test_app.py` 都当包内模块 | `pyproject.toml` 里显式 `py-modules = ["app"]`（本 solution 已处理） |
| `gitlab-ci-local` 报不在 git 仓库内 | 预定义变量要读 git 历史计算 | 在 `git init` 过的仓库根目录运行，且至少有一个 commit |
| ruff 对示例代码报 E502 之类风格错误 | ruff 默认规则集已含 pycodestyle E | 示例代码已通过默认规则；若你扩展了代码被拦，在 `pyproject.toml` 的 `[tool.ruff]` 里按团队规范调整（不建议直接全关） |

## 方案 B（选做）：真实 GitLab + Runner

资源充足（≥6GB 空闲内存、20 分钟初始化）时用完整版验证同一份 `.gitlab-ci.yml`：

```bash
# [Ubuntu VM]
sudo mkdir -p /srv/gitlab/{config,logs,data}
sudo docker run -d \
  --hostname gitlab.local \
  -p 8443:443 -p 8880:80 -p 2222:22 \
  --name gitlab \
  --shm-size 256m \
  -v /srv/gitlab/config:/etc/gitlab \
  -v /srv/gitlab/logs:/var/log/gitlab \
  -v /srv/gitlab/data:/var/opt/gitlab \
  --restart unless-stopped \
  gitlab/gitlab-ce:17.10.7-ce.0
```

浏览器打开 `http://<VM-IP>:8880`，root 初始密码在容器内 `/etc/gitlab/initial_root_password`（24 小时后自动删除，尽快改掉）。Runner 安装与注册（新版本用 UI 里生成的 authentication token，注册命令以 docs.gitlab.com 当前文档为准）：

```bash
# [Ubuntu VM]
docker run -d --name gitlab-runner --restart unless-stopped \
  -v /srv/gitlab-runner/config:/etc/gitlab-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gitlab/gitlab-runner:ubuntu-v17.10.1
```

把 `~/labs/ci-demo` push 到 GitLab 项目后，pipeline 的执行结果与 gitlab-ci-local 一致——这正是本 lab 用它做主线的原因。

## 判分脚本结果

```text
# [Ubuntu VM]
$ cd ~/labs/ci-demo && /path/to/check.sh .
PASS: .gitlab-ci.yml 存在
PASS: 文件是合法 YAML
PASS: stages 顺序为 [lint, build, test, image]
PASS: lint job 存在且 stage 为 lint
PASS: lint job image 为 python:3.12-slim 且执行 ruff check
PASS: build job 存在且 stage 为 build
PASS: build job 产出 artifacts（dist/）
PASS: test job 存在且执行 pytest
PASS: test job 通过 dependencies 引用 build 的 artifacts
PASS: image-build job 存在且执行 docker build
PASS: image-build 的 tag 使用 CI_COMMIT_SHORT_SHA 或 CI_PIPELINE_IID

SCORE: 11/11
```

## 延伸阅读

- GitLab CI 官方文档（pipeline 关键字）：https://docs.gitlab.com/ee/ci/yaml/
- gitlab-ci-local（firecow）：https://github.com/firecow/gitlab-ci-local
- ruff 官方文档：https://docs.astral.sh/ruff/
- python build 前端：https://build.pypa.io/en/stable/
