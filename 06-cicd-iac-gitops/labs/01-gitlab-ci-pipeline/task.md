# Lab 01 · GitLab CI 流水线：lint → build → test → 镜像构建

> 难度：★★☆ ｜ 考点：CI/CD 流水线设计 / GitLab CI 语法 / 镜像构建流水线 ｜ 前置：03-docker 的 lab 01~02 ｜ 预计 40~60 分钟

## 场景

团队里有一个内部小工具（Python/Flask 写的 HTTP 服务），目前是"谁改谁手动打包"。你被要求把它接入 CI：每次提交后自动完成 **lint → 构建 wheel 产物 → 跑单元测试 → 构建容器镜像**，任何一个环节失败就阻塞后续环节。

问题是你手头只有一台 8GB 内存的 Ubuntu VM，起一套完整 GitLab（Omnibus + Runner）至少要 4GB+ 内存、20 分钟以上初始化时间。本 lab 的主线方案是用 **gitlab-ci-local**——一个用 Node.js 实现的本地 GitLab CI 执行器，直接读取与真实 GitLab 完全相同的 `.gitlab-ci.yml`，在本地把整条 pipeline 跑绿；文末再给完整 GitLab 的替代方案（方案 B，选做）。

## 任务清单

1. 准备项目目录 `~/labs/ci-demo`，`git init`，写入示例应用：`app.py`、`test_app.py`、`pyproject.toml`、`requirements.txt`、`Dockerfile`（内容可在卡住后参考 solution.md）。
2. 编写 `.gitlab-ci.yml`，stage 名与 job 名必须按下面的约定（判分脚本按此检查）：
   - `stages` 依次为 `lint`、`build`、`test`、`image`；
   - `lint` job：`image: python:3.12-slim`，script 里用 `ruff check .` 做静态检查；
   - `build` job：用 `python -m build --wheel` 打包，并把 `dist/` 声明为 `artifacts`；
   - `test` job：安装 build 的 artifacts 后跑 `pytest`，并通过 `dependencies` 显式引用 `build`；
   - `image-build` job（stage 为 `image`）：用 `docker:27-cli` 镜像执行 `docker build`，镜像 tag 里必须用到 `CI_COMMIT_SHORT_SHA` 或 `CI_PIPELINE_IID` 变量。
3. 安装并运行 gitlab-ci-local，把整条 pipeline 跑绿，确认四个 stage 全部通过。
4. 故意在 `app.py` 里引入一个 lint 错误（例如未使用的 import），push 后重跑，确认 `lint` job 失败且 `build`/`test`/`image` 不再执行；改回后 pipeline 恢复全绿。

## 验收标准

终态要求（在项目目录里可验证）：

- `~/labs/ci-demo/.gitlab-ci.yml` 存在且为合法 YAML，stages/job 结构符合上面第 2 条的约定；
- `gitlab-ci-local`（或方案 B 的真实 GitLab）能完整执行 pipeline，四个 job 全部 passed；
- `docker images` 能看到按 commit SHA 打 tag 的 `ci-demo` 镜像；
- 故意制造 lint 错误时，后续 stage 被阻塞（这验证了 stage 的串行依赖语义）。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
cd ~/labs/ci-demo
chmod +x /path/to/check.sh
/path/to/check.sh .          # 参数为项目目录，默认当前目录
```

## 提示（卡住再看）

<details><summary>提示 1：artifacts 和 dependencies 是什么关系？</summary>

`artifacts` 是 job 结束后上传暂存的一组文件；同一条 pipeline 里**后续 stage** 的 job 默认会下载所有前面 stage 的 artifacts。`dependencies` 用来显式声明"我只要哪些 job 的 artifacts"（设为 `[]` 则完全不下拉）。`test` 和 `image-build` 需要的是 `build` 产出的 `dist/*.whl`，所以 `dependencies: [build]`。这与 Jenkins 里"上游产物归档/拷贝"是同一个概念。
</details>

<details><summary>提示 2：gitlab-ci-local 怎么装、怎么跑？</summary>

gitlab-ci-local 需要 Node.js 22+。Ubuntu 22.04 自带的 node 太老，用 NodeSource 装 22.x（命令见 solution.md 第 1 步），然后 `sudo npm install -g gitlab-ci-local`。它必须在 git 仓库根目录运行（要读 git 历史计算 `CI_COMMIT_SHORT_SHA` 等变量），所有 job 在 Docker 容器里执行，所以本机 Docker daemon 必须在跑。跑全部 job 直接执行 `gitlab-ci-local`，只跑单个 job 用 `gitlab-ci-local lint`；`image-build` 需要 docker socket，运行时记得带 `--volume /var/run/docker.sock:/var/run/docker.sock`（见提示 3）。
</details>

<details><summary>提示 3：image-build job 里容器内怎么用 docker？</summary>

`image-build` 这个 job 本身跑在 `docker:27-cli` 容器里，里面的 `docker` CLI 默认连不上 daemon：这个镜像自带的默认 context 指向 `tcp://docker:2375`（给 dind 服务用的别名，本地并没有）。两步解决：job 的 `variables` 里设 `DOCKER_HOST: "unix:///var/run/docker.sock"`，并且运行时加 `--volume /var/run/docker.sock:/var/run/docker.sock` 把宿主机 socket 挂进 job 容器（gitlab-ci-local 不会自动挂；真实 GitLab 里这一步由 runner 的 `volumes` 配置完成）。
</details>

<details><summary>提示 4：怎么验证"lint 失败阻塞后续 stage"？</summary>

在 `app.py` 末尾加一行 `import os`（ruff 的 F401，未使用的 import），commit 后跑 `gitlab-ci-local`，观察输出：lint job 标记 failed，后面的 job 根本不会被创建。GitLab CI 里跨 stage 的默认依赖就是"前一个 stage 全部成功"，不需要额外写 `needs`/`rules`。注意别用模块顶层的 `unused_var = 1`——F841 只查函数内的局部变量，模块级赋值 ruff 默认不报，lint 会照样通过。
</details>
