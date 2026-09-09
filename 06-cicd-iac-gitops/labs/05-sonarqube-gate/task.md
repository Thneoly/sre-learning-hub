# Lab 05 · SonarQube 质量门禁：让重复代码挡住流水线

> 难度：★★☆ ｜ 考点：代码质量门禁（Quality Gate）／重复代码治理／SonarQube API ｜ 前置：无（建议先读本模块 02 章，理解"门禁放在 CI 哪个位置"）｜ 预计 50~70 分钟

## 资源前置（先读再动手）

- compose 栈内存上限合计约 2.6G（sonarqube 限 2G + postgres 限 512M），本 VM 10G 内存足够，但**必须先做内核参数前置**：SonarQube 内嵌 Elasticsearch 要求 `vm.max_map_count ≥ 524288`，不改这个参数容器直接起不来（es bootstrap check 失败）。
- **内核参数前置（必做）**：`sudo sysctl -w vm.max_map_count=524288` 立即生效，并写入 `/etc/sysctl.d/99-sonarqube.conf` 持久化（判分脚本会查这两处）。
- **收尾要求**：先跑 check.sh 确认得分，再 `docker compose down -v`——判分脚本要用在线 API 与 evidence 落盘文件双重核验，down 之前先判分。evidence 文件保留，之后随时可复验落盘部分。

## 场景

Code Review 挡不住"复制粘贴式开发"：有人赶工把一段 40 行的报表逻辑原样复制了一份改了个函数名，测试全绿、功能正常，半年后这段逻辑改出三处 bug——因为同一个 bug 要修两遍。团队决定上 SonarQube 质量门禁：**重复代码密度超阈值的提交，quality gate 判 FAILED，CI 不许往下走**。

你要在一台 Ubuntu VM 上用 compose 起一套 SonarQube（lts 版 + PostgreSQL），造一个含大段重复代码的 Python 项目，亲眼看它被 gate 拦下（ERROR/FAILED），再修掉重复看它放行（OK/PASSED）——并把两次的判据落盘留证。这套 gate 接进 CI 的位置就在 02 章 `.gitlab-ci.yml` 的 test stage 之后（job 里 curl quality gate API，非 OK 即 `exit 1`）。

约定（判分脚本按此检查）：

| 项 | 值 |
| --- | --- |
| compose 目录 | `~/labs/sonar-lab/`（compose 文件、src/、evidence/ 都在这） |
| 服务地址 | `http://localhost:9000` |
| admin 密码 | 改为 `Lab05Sonar123`（check.sh 可用环境变量 `SONAR_ADMIN_PASSWORD` 覆盖） |
| 项目 key | `demo-app` |
| 证据文件 | `~/labs/sonar-lab/evidence/scan1.json`（第一次，ERROR）、`scan2.json`（第二次，OK） |

## 任务清单

1. 内核参数前置：临时 `sysctl -w` + 持久化 `/etc/sysctl.d/99-sonarqube.conf`。
2. 写 `~/labs/sonar-lab/docker-compose.yml`：`sonarqube`（镜像 `sonarqube:lts-community`，`mem_limit: 2g`，`SONAR_ES_JAVA_OPTS` 压 ES 堆到 512m）+ `sonar-db`（`postgres:16`，`mem_limit: 512m`，持久化卷）；`docker compose up -d` 并等 `/api/system/status` 返回 `UP`。
3. 初始化：用 API 把 admin 密码从 `admin/admin` 改为 `Lab05Sonar123`；生成分析 token；创建项目 `demo-app`。
4. **基线扫描（必做，gate 生效的前提）**：在 `~/labs/sonar-lab/src/` 先放一版**干净**的示例项目（单一实现、无重复），以 `sonar.projectVersion=1` 扫一次。原因：SonarQube 默认的"新代码"定义是 PREVIOUS_VERSION——**首次分析没有上一个版本可对比，new_* 指标全空、gate 条件全空、状态恒为 OK**；必须先落一个基线版本，后续提交里的重复代码才会落进"新代码窗口"被 gate 抓到（这正是 CI 里"门禁管增量"的语义）。
5. 把代码换成"事故版"：**一个 Python 文件，内含两段大段复制**（两个函数各约 40 行，函数体完全相同），bump `sonar.projectVersion=2` 再扫（加 `-Dsonar.qualitygate.wait=true` 让 scanner 等门禁结果并以非零码退出）；API 查 quality gate 状态为 **ERROR**（对应 UI/scanner 日志里的 FAILED）、重复密度明显超阈，把 `project_status` 的 JSON 存为 `evidence/scan1.json`。
6. 修掉重复：提取公共实现，两个入口函数变成薄封装；**bump `sonar.projectVersion=3`** 后再扫。
7. API 复查：gate 状态 **OK**（对应 PASSED）、重复密度降到阈值内，存为 `evidence/scan2.json`。
8. 运行判分脚本；通过后 `docker compose down -v` 收尾。

## 验收标准

- `/etc/sysctl.d/` 下存在含 `vm.max_map_count=524288` 的配置文件，且 `sysctl -n vm.max_map_count` 当前值达标；
- compose 文件对 sonarqube/postgres 显式设了 `2g`/`512m` 内存限制；
- `evidence/scan1.json` 存在且 `projectStatus.status` 为 `ERROR`，其中 duplication 类 condition 为未通过；
- `evidence/scan2.json` 存在且 `projectStatus.status` 为 `OK`；
- 在线 API：`measures/search_history` 里 `duplicated_lines_density` 至少两条记录，最大值 ≥5、最小值 ≤3（一高一低对比成立）；当前 gate 状态 `OK`。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh
/path/to/check.sh          # 默认查 ~/labs/sonar-lab，可用参数覆盖目录
```

## 提示（卡住再看）

<details><summary>提示 1：compose 里哪些环境变量是必须的？</summary>

SonarQube 容器必须被告知数据库连接：`SONAR_JDBC_URL: jdbc:postgresql://sonar-db:5432/sonar`、`SONAR_JDBC_USERNAME/PASSWORD`；`SONAR_ES_JAVA_OPTS: "-Xms512m -Xmx512m"` 把内嵌 ES 的堆压下来，否则默认会要更多内存。postgres 容器要设 `POSTGRES_USER/PASSWORD/DB` 三个同名值（sonar/sonar/sonar）。完整文件见 solution 第 2 步。
</details>

<details><summary>提示 2：不改 admin 密码/token，直接扫不行吗？</summary>

SonarQube 9.9+/10.x 首次登录强制改密码；分析认证一律走 token（`-Dsonar.token=...`），scanner 不再接受用户名密码。改动都可以走 Web API（`/api/users/change_password`、`/api/user_tokens/generate`、`/api/projects/create`），不需要点 UI——完整 curl 序列见 solution 第 3 步。注意项目必须**先创建**再分析，用户 token 不会自动建项目。
</details>

<details><summary>提示 3：为什么第一次扫描除了重复代码外，还会被"覆盖率"条件拦？</summary>

默认 gate "Sonar way" 对**新代码**有多条条件（覆盖率 ≥80%、重复 ≤3%、安全热点=0……）。本实验没有测试代码，覆盖率条件会一起报 ERROR——所以扫描参数里加 `-Dsonar.coverage.exclusions=**` 把全部文件排除出覆盖率统计（无数据即不判该条件），把焦点收敛到重复代码上。生产里当然不该这么干：该写测试写测试，该调条件在 gate 设置里调。
</details>

<details><summary>提示 4：第二次扫描重复密度为什么不降？</summary>

两个原因按序排查：一是没改干净——Sonar 检测的是"≥10 行且语义相同的块"，只要还有一段 10 行以上的复制就照报；二是 `sonar.projectVersion` 没 bump，新代码窗口的对比基准不对。修复后把 version 递增再扫（solution 第 6 步）。历史值用 `/api/measures/search_history?metrics=duplicated_lines_density&component=demo-app` 看，那是判分脚本对比"一高一低"的数据源。另外注意：**重复提交那次扫描必须不是项目的首次分析**——首次分析没有 new code 基准，gate 条件为空、恒为 OK（见任务 4 的基线扫描）。
</details>

<details><summary>提示 5：scanner 容器怎么连到 SonarQube 和项目文件？</summary>

官方 `sonarsource/sonar-scanner-cli` 镜像默认把工作目录 `/usr/src` 当项目根。宿主机上 `-v ~/labs/sonar-lab/src:/usr/src` 挂项目、`--network host` 让容器内的 `http://localhost:9000` 直达宿主端口，token 用 `-Dsonar.token=$TOKEN` 传。不想用容器就下 zip 包（需本机 JDK 17+），两种方式 solution 都给了。
</details>
