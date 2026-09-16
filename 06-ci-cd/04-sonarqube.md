# 04 · SonarQube：代码质量门禁

> 模块：06-ci-cd ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点，代码质量门禁事实标准；静态分析思想与 09-cks/04 的 trivy 同构）

## 学习目标

- 能解释质量门禁与测试门禁的分工：重复代码、坏味道、安全热点为什么是自动化测试测不出来的
- 能操作 Quality Gate（通过条件）、Quality Profile（规则集）与"新代码"定义，说清三大概念的关系
- 能计算 duplicated_lines_density，按四大维度（reliability/security/coverage/duplication）读一份 SonarQube 报告并定位问题
- 能把 sonar-scanner 接进 GitLab CI：token 注入、`sonar.qualitygate.wait=true` 阻塞流水线、PR decoration 的许可边界
- 能运维一套自管实例：postgres 依赖、Elasticsearch 内存与 vm.max_map_count、升级路径、误报治理

## 1. 定位：质量门禁 vs 测试门禁

第 02 章的 pipeline 里 test 阶段跑单测，那已经是"门禁"了——为什么还要 SonarQube？因为两者检查的对象不同：

| 维度 | 测试门禁（单测/e2e） | 质量门禁（SonarQube 静态分析） |
| --- | --- | --- |
| 检查方式 | 运行代码，观察行为 | 不运行，分析代码结构（规则引擎） |
| 能发现 | 逻辑错误、回归、边界条件 | 重复代码、坏味道、潜在 bug 模式、安全弱点 |
| 发现不了 | **重复代码、死代码、圈复杂度**——行为正确照样烂 | 逻辑错误——静态规则猜不到业务意图 |
| 反馈粒度 | 用例级 pass/fail | 行级 issue + 项目级度量 |

三个测试测不出的典型（面试常问）：

- **重复代码**：同一段逻辑复制两份，测试都过；下次改 bug 只改了一份，另一份成为暗雷。测试验证"每份都能跑"，没有任何用例会说"这两份一样"
- **坏味道**：500 行函数、5 层嵌套——行为完全正确，维护成本指数级上升。这是结构属性，不是行为属性
- **覆盖率本身**：覆盖了多少代码是测试自己的度量，只有分析工具能算出来

对应第 00 章三步工作法的第二步（反馈原则）：问题在 MR 里被静态分析拦下，成本是改几行；漏到生产，成本是故障与复盘。质量门禁就是把反馈点往左推——与 trivy 把镜像漏洞反馈点从"线上 CVE 通告"推到"CI 内"（09-cks/04 第 2.2 节）是同一个方向。

一句话分工：**测试门禁管"行为对不对"，质量门禁管"结构烂不烂"，两者都绿才放行**。

## 2. 核心概念：Quality Gate / Quality Profile / 技术债

三个概念一条依赖链：**规则 → 分析 → 度量 → 门禁条件**。

```
Quality Profile（规则集：激活哪些规则，按语言一份）
        │ 分析器执行规则 → 产出 issue 与度量
        ▼
度量指标（coverage / duplication density / rating / ...）
        │
        ▼
Quality Gate（一组"度量 ≥/≤ 阈值"的通过条件）
        │ 不满足 → FAILED
        ▼
CI 里 scanner 等待门禁结果（sonar.qualitygate.wait=true）→ 阻塞流水线
```

### 2.1 Quality Gate：通过条件

默认的 Sonar way 门禁，条件全部定义在**新代码**上（以实例 Quality Gates 页显示为准）：

| 条件 | 阈值（新代码） |
| --- | --- |
| Reliability rating | A |
| Security rating | A |
| Security hotspots reviewed | 100% |
| Maintainability rating | A |
| Coverage | ≥ 80% |
| Duplicated lines | < 3% |

两个设计要点：**只管新代码**——存量代码一票否决会让门禁第一天就永远红，团队学会绕过它（与 09-cks/04 trivy 门禁加 `--ignore-unfixed` 是同一个"门禁必须可通过才有效"的工程哲学）；**条件可自定义**——新建 gate 设为默认，项目也可单独指定。

### 2.2 Quality Profile：规则集

每种语言一份规则集，出厂默认 Sonar way。定制姿势：copy Sonar way → 改（激活/停用规则、调 severity）→ 设为默认。规则库覆盖 bug 模式（如空 except）、安全弱点（如硬编码凭据）、维护性（函数过长）。Profile 支持**继承**（父 profile 更新规则后子 profile 跟进），大组织常用"公司级父 profile + 团队微调"。

### 2.3 技术债：把烂量化成时间

SonarQube 用 SQALE 模型给每类 issue 标注**修复成本**（remediation effort，单位人时），汇总成技术债；再除以"重写这些代码的估算成本"得到**技术债比率**（technical debt ratio，分母默认按每行 30 分钟估算）。Maintainability rating 的 A~E 就是比率切出来的：≤5% A、≤10% B、≤20% C、≤50% D、再往上 E（阈值以官方 metric 定义为准）。运维价值：技术债从"感觉这项目很烂"变成"还欠 37 人天"，可以进迭代计划排期偿还。

### 2.4 新代码怎么定义

全局或项目级设置：previous version（上次版本后算新，默认）/ 天数（如 30 天）/ 参考分支。**MR 分析时新代码 = 相对目标分支的变更**——这决定了门禁只评审"你这次改了什么"，不替历史背锅。

## 3. 四大维度详解

### 3.1 Reliability（可靠性）——bug

分析器按 bug 类规则找出"几乎肯定是错的代码"（空指针解引用、资源不关闭、死循环条件）。度量是 bug 数按 severity 分级；Reliability rating A~E 由**最严重等级**决定：A=干净（无 info 以上问题），B=有 minor，C=有 major，D=有 critical，E=有 blocker（阈值以官方 metric 定义为准）。

### 3.2 Security（安全性）——漏洞与热点

两类对象：**vulnerability**（可被利用的安全缺陷，如 SQL 拼接）与 **security hotspot**（"取决于用法的风险点"，如硬编码 IP、加密强度）——热点不直接算失败，要求人工 review 后标记"安全/不安全"，Sonar way 门禁要求新代码热点 reviewed 100%。这与 09-cks/04 供应链扫描互补：trivy 扫"依赖包的 CVE"（你引入的别人的代码），SonarQube 扫"你自己写的代码"的安全弱点。

### 3.3 Coverage（覆盖率）

行覆盖 + 条件覆盖的合成指标。它把测试与静态分析连起来：分析器读 CI 产出的覆盖率报告（Go 的 coverage.out、Jacoco 的 xml，参数形如 `sonar.go.coverage.reportPaths`），没有测试数据该维度就是 0%。门禁盯"新代码覆盖率 ≥80%"——存量不追、增量必测。

### 3.4 Duplication（重复度）——duplicated_lines_density 的计算

```
duplicated_lines_density (%) = duplicated_lines / lines × 100

检测算法（语言相关，以 Java 默认为例）：
  连续 ≥10 行 token 序列相同 → 标记为一个 duplicated block
  跨文件也比对（copy-paste 不换文件名也逃不掉）
  参与判定的行计入 duplicated_lines
```

关键在分母：`lines` 统计的是**物理行**（含注释行；剔除注释与空行的是另一个指标 ncloc），所以往重复块里**加注释确实会稀释重复率**——改名/换空格骗不过 token 比对，但堆注释行能拉低比率，这正是该指标可被操纵的一面。阈值上，Sonar way 要求**新代码**重复率 <3%——存量代码 15% 很常见、可以慢慢还，新 MR 里再复制粘贴一段 10 行的代码就是过不去。排障时看报告里的 duplication 视图：哪些 block、跨哪些文件，一目了然。

| 维度 | 对象 | Sonar way 阈值（新代码） | 典型修复 |
| --- | --- | --- | --- |
| Reliability | bug | rating A | 修掉 blocker/critical |
| Security | 漏洞 + 热点 | rating A + 热点 review 100% | 改写 + 热点逐条确认 |
| Coverage | 测试覆盖 | ≥ 80% | 补测试（不是删断言） |
| Duplication | 重复块 | < 3% | 抽公共函数 |

## 4. CI 集成：scanner、阻塞与 PR decoration

### 4.1 scanner 参数与最小配置

```properties
# [文件 sonar-project.properties] 仓库根目录
sonar.projectKey=demo-api                 # 实例内唯一，建项目时对上
sonar.sources=src                         # 源码目录（或由 CI 变量传入）
sonar.coverage.exclusions=**/*_test.go    # 测试文件不计入覆盖分母
# sonar.host.url 与 sonar.token 不写文件——CI 变量 SONAR_HOST_URL / SONAR_TOKEN 注入
```

```yaml
# [文件 .gitlab-ci.yml 片段] 官方推荐的 GitLab 集成形态（镜像 tag 生产上要钉版本）
sonarqube-check:
  stage: test
  image:
    name: sonarsource/sonar-scanner-cli:latest
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"   # 分析缓存目录
    GIT_DEPTH: "0"          # 关键：禁用浅克隆，scanner 要全量历史算 blame/新代码
  cache:
    key: "$CI_JOB_NAME"
    paths: [.sonar/cache]
  script:
    - sonar-scanner -Dsonar.qualitygate.wait=true
  allow_failure: false      # 默认即 false；显式写出防"顺手优化"成 true
  rules:                    # 与 02 章 rules 同一套语法
    - if: '$CI_COMMIT_BRANCH == "main"'
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
```

三个易错点：`GIT_DEPTH: "0"` 不给会报 blame 信息缺失；token 走 masked CI 变量（02 章第 5 节的变量纪律）；scanner 镜像的 entrypoint 要置空才能接自定义参数。

### 4.2 `sonar.qualitygate.wait=true`：阻塞流水线的机制

scanner 上传分析结果后默认"发射后不管"，job 立刻成功退出——门禁形同虚设。加上该参数后 scanner **轮询等待**服务端算出门禁状态：FAILED 则以非零退出码结束 job，pipeline 就红了。配套 `sonar.qualitygate.timeout`（默认 300 秒）控制等待上限。这就是"质量门禁"从报表变成闸门的那一个参数。

### 4.3 PR decoration：MR 页内联评论

PR decoration 指分析结果回写 DevOps 平台：MR 概览页显示门禁状态、issue 以**行内评论**出现在改动行上，作者在 MR 里就能看到"这一行空指针"而不用切到 SonarQube UI。**许可边界要注意**：这是商业版（SonarQube Server Developer Edition 及以上）能力，免费的 Community Build 不支持多分支/PR 分析（官方 feature comparison 为准）——社区版的做法就是 4.1 的形态：MR 流水线里跑分析 + `wait=true` 阻塞，MR 合并按钮被 pipeline 状态卡住，反馈进 MR 的 pipeline 视图而非行内评论。商业版则在全局配置 ALM 集成（GitLab Configuration：API URL + PAT），MR 触发的分析自动回写评论与门禁状态。

## 5. 误报治理：exclude 与基线

静态分析必然有误报（规则猜不到业务意图）。治理三件套，按影响面从小到大选：

1. **issue 级标注**：单条 issue 上标 False Positive / Won't Fix——留审计痕迹、可复议，影响面最小，首选
2. **文件/路径排除**：`sonar.exclusions`（整段不分析）与 `sonar.coverage.exclusions`（只从覆盖分母剔除）——生成代码、vendored 依赖、迁移脚本该排除；注意别用整目录排除掩盖真问题
3. **规则级豁免**：`sonar.issue.ignore.multicriteria` 指定"某规则在某文件模式上不报"——某规则确实不适配本团队时用，并同步在 Quality Profile 里评估停用

治理纪律：**每条 exclude 有注释说明理由与到期条件**（生成代码重生成时要复核），定期巡检排除清单——排除项只增不减的实例，一年后门禁就是筛子。

## 6. 运维：postgres、ES 内存、升级、插件

- **postgres 是硬依赖**：内置 H2 仅限首次体验，生产必须外接 PostgreSQL（支持的大版本以官方 requirements 页为准）。分析结果、issue 状态、权限全在库里——备份 pg_dump 是实例备份的主体
- **Elasticsearch（search 节点）吃内存**：项目与 issue 的索引在 ES。容器/主机必须 `vm.max_map_count=524288`（否则 ES 起不来，最高频的安装故障）；内存可用 `sonar.search.javaOpts=-Xmx512m` 一类参数分级压缩——练习 VM（10G）按 512m 一档压到能跑，生产按代码量给到 1G~4G。web 与 compute engine 各自的 `sonar.web.javaOpts` / `sonar.ce.javaOpts` 同理
- **升级**：先备份 DB（不支持降级，回滚 = 恢复备份）；按官方支持路径逐级升（LTS → LTS 或跟随每版）；插件先确认兼容再升主程序；大版本升级前读 release notes 的 breaking changes
- **插件**：Marketplace 页装语言/框架插件，装完滚动重启；离线环境手动放 extensions/plugins 目录。插件是实例不稳定的第一嫌疑——升级失败先拔插件
- **与 GitLab/Harbor 抢内存**：10G 的 VM 跑不动 GitLab(4G)+Harbor(4G)+SonarQube(2.5G) 三件套，按 lab 分批起停，别硬塞

## 实战演练：门禁从报表变成闸门

环境：candidate VM（10G 内存、docker 可用）。先停掉 GitLab/Harbor 释放内存（在各自 compose 目录 `docker compose stop`；09 章清理命令带 `-v` 会连卷删除，只想暂停别照抄）。

### 步骤 1：起 SonarQube + postgres

```bash
# [VM] 内核参数（ES 必需，持久化写 /etc/sysctl.conf）
sudo sysctl -w vm.max_map_count=524288
echo 'vm.max_map_count=524288' | sudo tee -a /etc/sysctl.conf

mkdir -p ~/sonar-lab && cd ~/sonar-lab
```

```yaml
# [文件 docker-compose.yml] 练习配置；版本以官方下载页为准（community 标签滚动更新）。
# 需压内存时向 /opt/sonarqube/conf 挂载 sonar.properties 设 sonar.search.javaOpts 等（见第 6 节）
services:
  sonarqube:
    image: sonarqube:community            # Community Build（免费版，26.x 系列）
    container_name: sonarqube
    depends_on: [sonar-db]
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://sonar-db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: "Sonar!Passw0rd"
      SONAR_ES_BOOTSTRAP_CHECKS: "true"
    ports: ["9000:9000"]
    volumes:
      - sonar_data:/opt/sonarqube/data
      - sonar_extensions:/opt/sonarqube/extensions
      - sonar_logs:/opt/sonarqube/logs
  sonar-db:
    image: postgres:16
    container_name: sonar-db
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: "Sonar!Passw0rd"
      POSTGRES_DB: sonar
    volumes:
      - sonar_pg:/var/lib/postgresql/data
volumes:
  sonar_data:
  sonar_extensions:
  sonar_logs:
  sonar_pg:
```

```bash
# [VM] 启动并等就绪（首次初始化 2~3 分钟，等这行日志出现即服务可用）
docker compose up -d
docker logs -f sonarqube 2>&1 | grep -m1 "SonarQube is operational"
# 浏览器 http://<VM-IP>:9000，admin / admin 首登改密
```

### 步骤 2：埋雷项目 + 手动建项目

```bash
# [VM] 两个文件：重复块 + 空 except + 无测试
mkdir -p ~/quality-demo/src && cd ~/quality-demo
cat > src/bill_a.py <<'EOF'
def calc_a(items, tax_rate, discount, threshold, bonus):
    total = 0
    for item in items:
        if item.price > 0:
            if item.qty > 0:
                if discount > 0:
                    total += item.price * item.qty * (1 - discount)
    try:
        apply_tax(total, tax_rate)
    except Exception:
        pass
    if total > threshold:
        total += bonus
    return total
EOF
sed 's/calc_a/calc_b/; s/apply_tax/apply_tax2/' src/bill_a.py > src/bill_b.py
```

UI：Projects → Create project（key `quality-demo`，local）→ 生成 token（My Account → Security，或建项目向导直接给）记下来。

### 步骤 3：容器里跑 scanner，看门禁红

```bash
# [VM] 用官方 scanner 镜像分析（host 网络直达 127.0.0.1:9000）
cat > sonar-project.properties <<'EOF'
sonar.projectKey=quality-demo
sonar.sources=src
EOF
docker run --rm --network host -v "$PWD:/usr/src" \
  -e SONAR_HOST_URL=http://127.0.0.1:9000 \
  sonarsource/sonar-scanner-cli:latest \
  -Dsonar.token=<你的token> -Dsonar.qualitygate.wait=true; echo "exit=$?"
# 预期：报告上传后 QUALITY GATE STATUS: FAILED，exit=1
# UI：quality-demo 项目页——Coverage 0.0%（无测试）、Duplication 高企（两个文件几乎整文件重复）、
#     Reliability 有 issue（空 except），四大维度全亮
```

门禁条件逐条对照 2.1 节的表：这就是 CI 里 pipeline 被打红的同一份数据。

### 步骤 4：治理到绿（复现第 5 节的三件套）

```bash
# [VM] 1) 演示脚本从覆盖分母剔除（ops 练习项目无单测），2) 删除复制的文件（重复归零）
cat > sonar-project.properties <<'EOF'
sonar.projectKey=quality-demo
sonar.sources=src
sonar.coverage.exclusions=src/**   # 理由：演示工程无测试，生产项目应补测试而不是排除
EOF
rm src/bill_b.py
# 3) UI：对空 except 的 issue 标 Won't Fix（或修掉它：改为记录日志）
```

```bash
# [VM] 重跑步骤 3 的 docker run ... -Dsonar.qualitygate.wait=true
# 预期：QUALITY GATE STATUS: PASSED，exit=0
```

一个值得停一秒的现象：第二次分析里 bill_a.py 一行没动，它的 issue 已算**旧代码**，门禁不再追究——这正是 2.4 节"只评增量、不替历史背锅"的现场体验。想让治理效果可见，把 bill_a.py 的 `except` 改成记录日志再分析一次，观察 Reliability 维度随新代码变化。

### 步骤 5：接进 GitLab CI

把 4.1 的 `sonarqube-check` job 塞进 02 章的 demo-api 流水线（stages 的 test 阶段），GitLab 项目 Settings → CI/CD → Variables 加 `SONAR_TOKEN`（masked）与 `SONAR_HOST_URL`。push 后预期：job 日志末尾出现门禁状态行，FAILED 时 job 红且后续 stage 不跑（02 章第 1 节：同 stage 全绿才放行）——质量门禁正式上岗。完整的 MR 双闸门设计见第 7 节。

### 步骤 6：清理

```bash
# [VM] 保留供 labs/05-sonarqube-gate 复用；彻底回收（-v 连数据卷一起删）：
cd ~/sonar-lab && docker compose down -v
docker rmi sonarsource/sonar-scanner-cli:latest 2>/dev/null || true
```

## 7. 组合设计：与 02 章 rules 拼出"PR 门禁流水线"

单点工具不成平台。把本章质量门禁、02 章 GitLab CI 骨架、09 章镜像闸门叠起来，就是 capstone 的 PR 门禁流水线（11 章交付平台的雏形）：

```
开发者 push 分支 → 开 MR
┌────────────── GitLab pipeline（02 章骨架 + rules） ──────────────┐
│ test:        单测 + 覆盖率报告 ──────────▶ 测试门禁（行为）      │
│ sonar:       sonar-scanner + wait=true ──▶ 质量门禁（结构，本章）│
│ package:     docker build/push → Harbor（09 章）                 │
│              ├ trivy --exit-code 1 ──────▶ 漏洞闸门（09-cks/04） │
│              └ cosign sign ──────────────▶ 签名闸门（09-cks/04） │
│ deploy-test: rules 限定 main（02 章第 2 节 rules）               │
│ deploy-prod: rules tag + when: manual（生产人工闸门）            │
└── 全绿 → MR 可合并；任一红 → 合并被 pipeline 状态卡住 ───────────┘
```

设计原则三条：

- **闸门职责正交**：行为（测试）/ 结构（SonarQube）/ 制品（trivy+cosign）各管一段，重叠的检查只留一处——重复门禁不会更安全，只会更慢
- **反馈都在 MR 里**：四个闸门全部挂在 merge_request_event 触发的 pipeline 上（02 章 rules），作者在合并前看到全部问题；主干 pipeline 只做增量确认
- **每个门禁都可解释、可通过**：FAILED 一定要能定位到具体条件（哪条规则/哪个 CVE/哪段重复），且正常工作流走得通——永远红着的门禁等于没有门禁（2.1 节）

双闸门 lab（trivy+cosign）与本章 lab（sonar gate）分别是这套设计的两个切片，最终合流在 11 章。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| ES 起不来，日志报 max virtual memory areas 不足 | vm.max_map_count 未调 | sysctl -w vm.max_map_count=524288 并持久化（步骤 1） |
| scanner 报 Missing blame information / Could not find ref | 浅克隆，scanner 拿不到全量历史 | `GIT_DEPTH: "0"`（本地跑则别用 --depth clone） |
| CI 里分析成功但门禁从不阻塞 | 没加 `sonar.qualitygate.wait=true`，scanner 发射后不管 | 4.2 节参数加上；确认 job 未设 allow_failure: true |
| coverage 永远 0% | 没把覆盖率报告喂给 scanner | 按语言配 `sonar.<lang>.coverage.reportPaths`，且 CI 先跑测试再跑 sonar |
| 重复率比直觉高很多 | 生成的代码/vendored 目录进了分析 | `sonar.exclusions` 排除生成物；duplication 视图确认来源 |
| 首次分析后所有存量代码都被门禁打红 | 首次分析全部算"新代码" | 先跑一次基线分析再启用严格门禁；或临时用宽松 gate 过渡 |
| docker run scanner 连不上 9000 | 容器网络隔离（bridge 下 127.0.0.1 是容器自己） | `--network host`（Linux），或用宿主 IP |
| MR 里看不到行内评论 | 用的 Community Build（免费版无 PR 分析/装饰） | 按 4.3 节许可边界：要么走 pipeline 阻塞形态，要么上商业版 |
| 升级后起不来 | 插件与新版不兼容，或跳级升级 | 拔插件再起；按官方支持路径逐级升，先备份 DB |
| 实例越用越慢 | ES 索引膨胀、内存未调 | 调 `sonar.search.javaOpts`；清理旧项目的分析快照 |

## 自测

<details><summary>1. 两个 MR：A 把一个 30 行函数原样复制了一份，测试全绿；B 删了一个过时的测试用例，覆盖率降了 2%。测试门禁和质量门禁分别怎么评价它们？这说明什么？</summary>

A：测试门禁通过（行为没变，用例照跑照过），质量门禁失败（新代码重复率超 3%，duplication 视图直接标出复制块）。B：测试门禁可能通过（剩下的用例仍全绿），质量门禁失败（新代码覆盖率跌破 80%——删测试也算"新代码"的覆盖变化）。说明两者正交：测试只能看到行为面，结构面的退化（复制、删测试导致的覆盖收缩）只能由静态分析与度量发现。反过来纯逻辑错误（算错折扣率）静态分析多半无感、测试一抓一个准——所以第 1 节的结论是双门禁都绿才放行。

</details>

<details><summary>2. duplicated_lines_density 的分母分子各是什么？"加注释"与"改名换空格"哪个骗得过检测？10 行阈值意味着什么？</summary>

分母 lines 统计物理行（注释行也计入；剔除注释/空行的是 ncloc 这个独立指标），分子 duplicated_lines 是落入重复块的行——所以注释行会进分母，往重复块里堆注释确实能稀释比率。10 行阈值是检测算法的粒度：连续 ≥10 行 token 序列相同才判重复块，比 10 行短的相似片段（如惯用的三行样板）不算，避免噪音。推论：把一段复制代码"改名加空行"骗不过检测（token 序列剔除空白与命名差异后仍相同），但加注释会稀释比率——这正是该指标的可被操纵面，code review 时看到"重复块里塞满注释行"要警惕；真正的解法只有抽公共函数。

</details>

<details><summary>3. `sonar.qualitygate.wait=true` 加之前与之后，CI 的失败模式有什么本质区别？为什么说没有它门禁是装饰品？</summary>

不加时 scanner 上传完报告立刻 exit 0——门禁结果只存在于 SonarQube UI 上，pipeline 全绿，合并不受任何影响；要有人主动去看报表才会发现 FAILED，这违背门禁的"自动阻断"定义（第 00 章反馈原则里"自动反馈"比"可见反馈"强一档）。加上后 scanner 轮询服务端的门禁计算结果，FAILED 映射为非零退出码，job 红、下游 stage 不跑、MR 合并按钮被卡——同一份数据从报表升格为闸门。注意等待有 timeout（默认 300s），服务端慢时调大而不是去掉。

</details>

<details><summary>4. 首次给一个有三年历史的仓库接 SonarQube，第二天开发集体抱怨"门禁永远红"。给出落地节奏。</summary>

节奏三步：一，先跑基线分析——首次分析把全部代码算新代码，必然大面积红，这一步只看报告不挂门禁（allow_failure 或手动 job）；二，把"新代码"定义调成 previous version 或参考分支，门禁只约束增量——存量问题进技术债清单按 2.3 节排期偿还，不挡合并；三，治理明显噪音（生成代码 exclusions、确凿误报标 False Positive）后再把 wait=true 上严。核心还是那条工程哲学（2.1 节）：门禁必须"可通过"才有效力，永远红的门禁训练出来的只有绕过技能。

</details>

<details><summary>5. 为什么 SonarQube 的安全维度和 trivy（09-cks/04）互不可替代？各覆盖供应链/代码的哪一段？</summary>

trivy 扫的是**制品**：镜像里 OS 包与语言依赖的已知 CVE（你引入的别人的代码），数据源是漏洞库；SonarQube 扫的是**你写的源码**：SQL 拼接、空 except、硬编码凭据这类没有 CVE 编号的安全弱点，数据源是规则引擎——你自己的 bug 不在任何 CVE 库里，任何镜像扫描器都发现不了。串在一条流水线上正好覆盖两段：源码阶段质量/安全门禁（本章），制品阶段漏洞/签名闸门（09 章与 09-cks/04），第 7 节的组合图就是两段的全景。

</details>

## 延伸阅读

- SonarQube 官方文档（Community Build / Server）：https://docs.sonarsource.com/sonarqube-server/
- Quality Gates 与条件定义：https://docs.sonarsource.com/sonarqube-server/latest/user-guide/quality-gates/
- GitLab CI 集成官方示例：https://docs.sonarsource.com/sonarqube-community-build/devops-platform-integration/gitlab-integration/
- sonar-scanner 参数参考（含 qualitygate.wait）：https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/analysis-parameters/
- Metric 定义（duplication / technical debt ratio）：https://docs.sonarsource.com/sonarqube-server/latest/user-guide/metric-definitions/
