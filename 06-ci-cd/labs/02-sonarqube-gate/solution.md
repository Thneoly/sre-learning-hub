# Lab 05 · 解答：SonarQube 质量门禁

> 配套 task.md 使用。环境：一台装有 Docker 的 Ubuntu VM（10G 内存），可经代理拉取 docker.io 镜像。

## 第 0 步：设计——gate 拦的是什么

```
开发 push ──▶ CI（02 章 .gitlab-ci.yml）
                 ├─ lint / build / test ……（机器可判的"对错"）
                 ├─ sonar-scanner 分析 ──▶ SonarQube 计算 quality gate
                 │                            ├─ 新代码重复密度 > 3%  ──▶ ERROR
                 │                            ├─ 安全热点未处理        ──▶ ERROR
                 │                            └─ （覆盖率 ≥80%）       ──▶ 本 lab 排除焦点
                 └─ deploy job：curl project_status，非 OK 即 exit 1 —— 门禁落点
```

两个容易混的说法先对齐：**UI 和 scanner 日志里显示 FAILED/PASSED，Web API 里对应的枚举是 ERROR/OK**（`/api/qualitygates/project_status` 的 `projectStatus.status`）。判分脚本查的是 API 值，evidence 落盘文件里应该看到 `"status":"ERROR"` 与 `"status":"OK"`。

## 第 1 步：内核参数前置（不做必挂）

SonarQube 内嵌 Elasticsearch 启动时做 bootstrap check，`vm.max_map_count` 不足直接退出：

```bash
# [Ubuntu VM] 立即生效 + 持久化
sudo sysctl -w vm.max_map_count=524288
echo 'vm.max_map_count=524288' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sysctl -n vm.max_map_count          # 预期：524288
```

## 第 2 步：compose 起 sonarqube + postgres

```yaml
# 文件: ~/labs/sonar-lab/docker-compose.yml
services:
  sonar-db:
    image: postgres:16
    container_name: sonar-db
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: sonar
      POSTGRES_DB: sonar
    volumes:
      - sonar_pgdata:/var/lib/postgresql/data
    mem_limit: 512m

  sonarqube:
    image: sonarqube:lts-community
    container_name: sonarqube
    depends_on:
      - sonar-db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://sonar-db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: sonar
      SONAR_ES_JAVA_OPTS: "-Xms512m -Xmx512m"   # 压内嵌 ES 堆，2g 限制才够用
    ports:
      - "9000:9000"
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs
    mem_limit: 2g

volumes:
  sonar_pgdata:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
```

镜像版本说明：`sonarqube:lts-community` 滚动指向官方当前 LTS；PostgreSQL 的受支持版本随 LTS 变化（16 是写作时的稳妥选择），**版本兼容矩阵以 Sonar 官方文档为准**（延伸阅读第 2 条）。

```bash
# [Ubuntu VM]
mkdir -p ~/labs/sonar-lab/{src,evidence} && cd ~/labs/sonar-lab
# 放入上面 docker-compose.yml 后：
docker compose up -d
watch -n5 "curl -s http://localhost:9000/api/system/status"   # 等 status 从 STARTING 变 UP（约 2~3 分钟）
```

内存账：2g + 512m ≈ 2.6G，加上宿主已有负载远低于 10G；`docker stats` 可复核两个容器被 limit 压住。

## 第 3 步：改密码、发 token、建项目（全走 API）

```bash
# [Ubuntu VM]
URL=http://localhost:9000
# 1) 首次登录强制改密的 API 等价物（admin/admin → Lab05Sonar123）
curl -su admin:admin -X POST \
  "$URL/api/users/change_password?login=admin&previousPassword=admin&password=Lab05Sonar123" \
  -o /dev/null -w '%{http_code}\n'            # 预期：204
# 2) 生成分析 token（scanner 认证用，不再支持账密分析）
TOKEN=$(curl -su admin:Lab05Sonar123 -X POST \
  "$URL/api/user_tokens/generate?login=admin&name=lab05" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
echo "$TOKEN" > ~/labs/sonar-lab/.token       # 本地留存，别提交到任何 git 仓库
# 3) 建项目（key=demo-app；用户 token 不会自动建项目，必须先建）
curl -su admin:Lab05Sonar123 -X POST \
  "$URL/api/projects/create?name=demo-app&project=demo-app" \
  -o /dev/null -w '%{http_code}\n'            # 预期：200（重复创建为 400）
```

## 第 4 步：基线扫描（干净版先行——不做这步 gate 拦不住任何东西）

SonarQube 默认的"新代码"定义是 PREVIOUS_VERSION（与上一版本比）。**项目的首次分析没有对比基准：new_* 指标全空、gate 条件全空、状态恒为 OK**——直接扫重复代码是拦不下来的。所以先放一版干净代码扫出基线，后续的"事故提交"才会整个落进新代码窗口。

基线版就用第 6 步的修复版代码（单一 `_region_report` 实现 + 薄封装 `build_region_report_east`），写到 `src/app.py` 后先跑一遍确认功能正常（门禁拦的从来不是功能错误）：

```bash
# [Ubuntu VM] 基线扫描（version=1）
cd ~/labs/sonar-lab
docker run --rm --network host \
  -v ~/labs/sonar-lab/src:/usr/src \
  sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=demo-app \
  -Dsonar.projectName=demo-app \
  -Dsonar.projectVersion=1 \
  -Dsonar.sources=. \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login="$(cat .token)" \
  -Dsonar.coverage.exclusions='**'
# 预期：EXECUTION SUCCESS（此时 gate 状态 OK 属正常——首扫无 new code，不作为证据）
```

认证参数说明：官方 `sonarsource/sonar-scanner-cli` 滚动 latest（写作时为 8.x）配 SonarQube 9.9 LTS 实测**只认 `-Dsonar.login=<token>`**——传 `-Dsonar.token=` 会报 `Not authorized. Analyzing this project requires authentication`。旧版 scanner（≤7.x）两个参数等价；要么用 login，要么把镜像钉在旧 tag。

`--network host` 让容器内 `localhost:9000` 直达宿主端口；`-Dsonar.coverage.exclusions=**` 把文件排除出覆盖率统计（无数据即不触发"新代码覆盖率 <80%"条件，本实验聚焦重复代码——生产中不该这么干，见提示 3）。

## 第 5 步：事故版提交，看 gate 把它拦下

```python
# 文件: ~/labs/sonar-lab/src/app.py
"""demo-app：区域销售报表。build_region_report_west 是赶工时从 east 原样复制的
（连 "east" 字符串都没改——正是复制粘贴式开发的经典事故现场）。"""


def build_region_report_east(samples):
    total_amount = 0.0
    total_cost = 0.0
    count = 0
    by_city = {}
    for s in samples:
        if s.get("region") != "east":
            continue
        amount = float(s.get("amount", 0))
        cost = float(s.get("cost", 0))
        city = s.get("city", "unknown")
        total_amount += amount
        total_cost += cost
        count += 1
        c = by_city.setdefault(city, {"amount": 0.0, "cost": 0.0, "count": 0})
        c["amount"] += amount
        c["cost"] += cost
        c["count"] += 1
    lines = ["region=east", "count=%d" % count]
    if count:
        margin = (total_amount - total_cost) / total_amount * 100
        lines.append("total_amount=%.2f" % total_amount)
        lines.append("total_cost=%.2f" % total_cost)
        lines.append("margin=%.2f%%" % margin)
        for city in sorted(by_city):
            c = by_city[city]
            lines.append("city=%s amount=%.2f count=%d" % (city, c["amount"], c["count"]))
    else:
        lines.append("no data")
    return "\n".join(lines)


def build_region_report_west(samples):
    total_amount = 0.0
    total_cost = 0.0
    count = 0
    by_city = {}
    for s in samples:
        if s.get("region") != "east":
            continue
        amount = float(s.get("amount", 0))
        cost = float(s.get("cost", 0))
        city = s.get("city", "unknown")
        total_amount += amount
        total_cost += cost
        count += 1
        c = by_city.setdefault(city, {"amount": 0.0, "cost": 0.0, "count": 0})
        c["amount"] += amount
        c["cost"] += cost
        c["count"] += 1
    lines = ["region=east", "count=%d" % count]
    if count:
        margin = (total_amount - total_cost) / total_amount * 100
        lines.append("total_amount=%.2f" % total_amount)
        lines.append("total_cost=%.2f" % total_cost)
        lines.append("margin=%.2f%%" % margin)
        for city in sorted(by_city):
            c = by_city[city]
            lines.append("city=%s amount=%.2f count=%d" % (city, c["amount"], c["count"]))
    else:
        lines.append("no data")
    return "\n".join(lines)


def main(samples):
    print(build_region_report_east(samples))
    print(build_region_report_west(samples))


if __name__ == "__main__":
    main([
        {"region": "east", "city": "shanghai", "amount": "100.5", "cost": "40.0"},
        {"region": "east", "city": "hangzhou", "amount": "80.0", "cost": "30.0"},
    ])
```

两个函数体**逐字符相同**（各约 35 行）：Sonar 的重复检测（CPD，按 token 流比对，块阈值 ≥10 行）会把它们标成 duplicated block。`duplicated_lines_density`（重复行占比）预期 40% 上下——远超 Sonar way 的 3% 阈值。

```bash
# [Ubuntu VM] 先跑一下确认功能"正常"（门禁拦的从来不是功能错误）
python3 ~/labs/sonar-lab/src/app.py
```

scanner 用官方容器（免装 JDK；本机装 zip 包的替代方式见本步末尾）：

```bash
# [Ubuntu VM] 事故版扫描（version=2，bump 过版本；加 qualitygate.wait 让 scanner 等门禁）
cd ~/labs/sonar-lab
docker run --rm --network host \
  -v ~/labs/sonar-lab/src:/usr/src \
  sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=demo-app \
  -Dsonar.projectName=demo-app \
  -Dsonar.projectVersion=2 \
  -Dsonar.sources=. \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login="$(cat .token)" \
  -Dsonar.coverage.exclusions='**' \
  -Dsonar.qualitygate.wait=true
# 扫描日志末尾预期：
# INFO: ANALYSIS SUCCESSFUL ...
# ERROR: QUALITY GATE STATUS: FAILED - View details on ...  ← UI 用词 FAILED，且 exit code 非零
```

`-Dsonar.qualitygate.wait=true` 是 CI 里的门禁落点：scanner 等服务器算完 gate 再退出，FAILED 时以非零码结束，下游 job 自然被挡。不加它 scanner 只管"交报告"，日志里不会出现 QUALITY GATE STATUS 行。

落盘第一次的证据：

```bash
# [Ubuntu VM]
curl -su admin:Lab05Sonar123 \
  "$URL/api/qualitygates/project_status?projectKey=demo-app" -o evidence/scan1.json
python3 -m json.tool evidence/scan1.json
# 预期片段（注意条件对象的字段名是 metricKey / actualValue）：
# "status": "ERROR",
# "conditions": [
#   { "status": "ERROR", "metricKey": "new_duplicated_lines_density", "comparator": "GT",
#     "errorThreshold": "3", "actualValue": "73.4", ... },
#   ... ]
curl -su admin:Lab05Sonar123 \
  "$URL/api/measures/component?component=demo-app&metricKeys=duplicated_lines_density" 
# 预期：整体重复密度是个大数（如 "45.5"）
```

## 第 6 步：修掉重复，bump 版本再扫

提取公共实现，两个入口变成薄封装：

```python
# 文件: ~/labs/sonar-lab/src/app.py（修复版，整文件替换）
"""demo-app：区域销售报表。两段重复的报表逻辑已提取为 _region_report。"""


def _region_report(samples, region_code):
    total_amount = 0.0
    total_cost = 0.0
    count = 0
    by_city = {}
    for s in samples:
        if s.get("region") != region_code:
            continue
        amount = float(s.get("amount", 0))
        cost = float(s.get("cost", 0))
        city = s.get("city", "unknown")
        total_amount += amount
        total_cost += cost
        count += 1
        c = by_city.setdefault(city, {"amount": 0.0, "cost": 0.0, "count": 0})
        c["amount"] += amount
        c["cost"] += cost
        c["count"] += 1
    lines = ["region=%s" % region_code, "count=%d" % count]
    if count:
        margin = (total_amount - total_cost) / total_amount * 100
        lines.append("total_amount=%.2f" % total_amount)
        lines.append("total_cost=%.2f" % total_cost)
        lines.append("margin=%.2f%%" % margin)
        for city in sorted(by_city):
            c = by_city[city]
            lines.append("city=%s amount=%.2f count=%d" % (city, c["amount"], c["count"]))
    else:
        lines.append("no data")
    return "\n".join(lines)


def build_region_report_east(samples):
    return _region_report(samples, "east")


def build_region_report_west(samples):
    return _region_report(samples, "west")


def main(samples):
    print(build_region_report_east(samples))
    print(build_region_report_west(samples))


if __name__ == "__main__":
    main([
        {"region": "east", "city": "shanghai", "amount": "100.5", "cost": "40.0"},
        {"region": "east", "city": "hangzhou", "amount": "80.0", "cost": "30.0"},
    ])
```

顺带把复制粘贴埋的雷排了：west 函数现在真的按 `west` 过滤（原版里是没改掉的 `east`）。**version bump 到 3** 再扫：

```bash
# [Ubuntu VM]
cd ~/labs/sonar-lab
docker run --rm --network host \
  -v ~/labs/sonar-lab/src:/usr/src \
  sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=demo-app \
  -Dsonar.projectName=demo-app \
  -Dsonar.projectVersion=3 \
  -Dsonar.sources=. \
  -Dsonar.host.url=http://localhost:9000 \
  -Dsonar.login="$(cat .token)" \
  -Dsonar.coverage.exclusions='**' \
  -Dsonar.qualitygate.wait=true
# 预期：EXECUTION SUCCESS（gate PASSED，退出码 0）

curl -su admin:Lab05Sonar123 \
  "$URL/api/qualitygates/project_status?projectKey=demo-app" -o evidence/scan2.json
python3 -m json.tool evidence/scan2.json | head -8      # 预期："status": "OK"

# 三次的重复密度对比（判分脚本的"一高一低"数据源）：
curl -su admin:Lab05Sonar123 \
  "$URL/api/measures/search_history?metrics=duplicated_lines_density&component=demo-app" \
  | python3 -m json.tool
# 预期：history 三条记录——基线 0.0、事故版 73.4、修复版 0.0
```

把它接进 02 章 pipeline 的形态（本 lab 不实现，记下位置即可）：test stage 之后加一个 job，跑完 scanner 后 `curl -su $TOKEN@ $SONAR_URL/api/qualitygates/project_status?projectKey=$KEY | grep -q '"status":"OK"' || exit 1`——非 OK 即失败，deploy 自然被 stage 依赖挡住（写法与 lab 06 的 cosign/Trivy 闸门同构）。

本机安装 scanner 的替代方式：到 <https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/> 列表页取最新 zip（写作时为 7.x），`curl -x http://172.30.30.1:7897 -fLO <完整URL>` 后解压，把 `sonar-scanner-*/bin` 加进 PATH；scanner 7.x 需要本机 JDK 17+（`sudo apt-get install -y openjdk-17-jre-headless`），参数与容器版完全一致。

## 第 7 步：判分与收尾

```bash
# [Ubuntu VM]
chmod +x /path/to/check.sh && /path/to/check.sh
# 预期：12 项全 PASS，SCORE: 12/12

# 判分通过后收尾（-v 连数据卷一起清；evidence/ 与 .token 留在 ~/labs/sonar-lab）
cd ~/labs/sonar-lab && docker compose down -v
rm -f .token    # token 随手清掉是好习惯
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| sonarqube 容器反复重启，日志有 `max virtual memory areas vm.max_map_count [65530] is too low` | 没做第 1 步内核参数 | `sysctl -w` + 写 `/etc/sysctl.d/`；改完 `docker restart sonarqube` |
| `api/system/status` 一直 `STARTING` | SonarQube 首次初始化要 2~3 分钟（建库、起 ES） | 等；`docker logs sonarqube -f` 看到 `SonarQube is operational` 再操作 |
| scanner 报 401/未授权 | token 拼错、token 带了换行、或仍在用账密 | 重新 `user_tokens/generate`；`echo -n` 或 `$(cat .token)` 去掉尾部换行 |
| scanner 8.x 报 `Not authorized. Analyzing this project requires authentication`（token 明明有效） | 最新 scanner-cli 镜像配 SQ 9.9 LTS 实测不认 `-Dsonar.token` | 改传 `-Dsonar.login=<token>`，或把 scanner 镜像钉在旧 tag |
| 第一次扫描 gate 就是 OK、conditions 为空 | 首次分析没有 new code 基准（PREVIOUS_VERSION 无上一版本可比），new_* 指标全空 | 先做第 4 步的基线扫描，事故版代码 bump 版本后再扫才会被拦 |
| scanner 报 `Could not find in project property 'sonar.projectKey'` 又确实传了 | 参数没透传进容器（引号丢失） | `-D` 参数原样放在 `docker run` 参数末尾，值加引号 |
| 分析报项目不存在 / 无权限 | 用户 token 不会自动建项目 | 先 `POST /api/projects/create`（第 3 步第 3 条） |
| 第一次扫描 gate ERROR 的条件里混着 Coverage | "Sonar way" 对新代码还有覆盖率条件 | 加 `-Dsonar.coverage.exclusions=**` 收敛焦点（仅实验用） |
| 第二次扫描重复密度还是旧值 | 没 bump `sonar.projectVersion`，或两函数还有 ≥10 行相同段 | version 递增重扫；按"≥10 行语义相同"标准查残留 |
| postgres 容器被 OOM kill | 数据库初始化峰值超 512m | 临时把 limit 提到 768m，初始化完成后再压回 |

## 判分脚本结果

```text
# [Ubuntu VM]
$ /path/to/check.sh
PASS: /etc/sysctl.d 下存在 vm.max_map_count=524288 的持久化配置
PASS: 当前 vm.max_map_count ≥ 524288
PASS: docker-compose.yml 存在（/home/cka/labs/sonar-lab/docker-compose.yml）
PASS: sonarqube 服务内存限制 2g
PASS: postgres 服务内存限制 512m
PASS: evidence/scan1.json 存在且 gate 状态为 ERROR（首次扫描被拦）
PASS: evidence/scan1.json 含 duplication 类未通过条件
PASS: evidence/scan2.json 存在且 gate 状态为 OK（修复后放行）
PASS: SonarQube 在线且状态 UP
PASS: 项目 demo-app 存在
PASS: duplicated_lines_density 历史一高一低（max≥5 且 min≤3，≥2 条记录）
PASS: 当前 quality gate 状态为 OK

SCORE: 12/12
```

## 延伸阅读

- SonarQube 官方文档（Quality Gates）：https://docs.sonarsource.com/sonarqube-server/latest/analyzing-code/quality-gates/
- 支持的平台与数据库版本矩阵：https://docs.sonarsource.com/sonarqube-server/latest/setting-up-and-operating/installation-requirements/requirements/prerequisites-and-overview/
- sonar-scanner CLI（参数全集）：https://docs.sonarsource.com/sonarqube-server/latest/analyzing-code/scanners/sonarscanner/
- Web API（本 lab 判分所用的 project_status / search_history）：https://docs.sonarsource.com/sonarqube-server/latest/extension-guide/web-api/
