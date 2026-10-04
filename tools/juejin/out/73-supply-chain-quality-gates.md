---
title_juejin: '代码扫描绿、镜像扫描绿，供应链还是被打穿'
title_zhihu: '扫描绿灯是工具规则库的上限，不是供应链安全的下限'
description: '质量门禁与测试门禁分工、Quality Gate 与技术债、误报治理失效面、wait=true 闸门、Harbor 阻止拉取、cosign 验签、tag 可变陷阱——双绿灯之外，还有三条暗路。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686472562230312970"
---

# 代码扫描绿、镜像扫描绿，供应链还是被打穿

> 代码扫描拦「你写的代码烂不烂」，镜像扫描拦「你引入的依赖有没有已知漏洞」——两盏灯都亮，只证明「定义过的问题」没发生。**双绿灯是工具规则库的上限，不是系统安全的下限。**门禁之外还有三条暗路：永远红训练出来的绕过、漏洞库的时间差、tag 可变导致的「扫的不是跑的」。

## 一、开局复盘：每一步都合规，还是被打穿

构造典型案例——某团队的一次供应链事件复盘，时间线四行：

- MR 合并前：单测全绿，SonarQube 门禁 PASSED，新代码覆盖率 83%、重复率 2.1%
- 构建后：trivy 扫描 0 CRITICAL，镜像推入 Harbor，cosign 完成签名，正常上线
- 两周后安全通报：镜像底包爆出高危 CVE——扫描当天漏洞库还没收录这条
- 复盘再挖一层：`sonar.exclusions` 里躺着一条一年前加的排除，`internal/tools/` 整个目录从未被分析，硬编码凭据规则形同虚设

每一环都按流程走，每一环都没报错。错的是把「门禁通过」读成了「安全」。

**门禁拦得住定义过的问题，拦不住定义之外的世界。**下面依次拆：两扇门各管什么、SonarQube 的概念地图、误报治理的失效面、Harbor 补上什么、仓库运维三件事，最后正面回应「门禁越多交付越慢」这笔账。

## 二、先分清两扇门：测试门禁 vs 质量门禁

CI 里 test 阶段跑单测已经是门禁了，为什么还要静态分析？因为两者看的东西不同：

| 维度 | 测试门禁（单测/e2e） | 质量门禁（静态分析） |
| --- | --- | --- |
| 检查方式 | 运行代码，观察行为 | 不运行，规则引擎分析结构 |
| 能发现 | 逻辑错误、回归、边界条件 | 重复代码、坏味道、安全弱点 |
| 发现不了 | 重复代码、死代码、圈复杂度 | 逻辑错误——规则猜不到业务意图 |
| 反馈粒度 | 用例级 pass/fail | 行级 issue + 项目级度量 |

三个测试测不出的典型：重复代码——同一段逻辑复制两份，测试都过，下次改 bug 只改一份，另一份成暗雷；坏味道——500 行函数行为完全正确，维护成本指数级上升，这是结构属性不是行为属性；覆盖率本身——它是测试自己的度量，只有分析工具算得出来。

一句话分工：**测试门禁管行为对不对，质量门禁管结构烂不烂，都绿才放行**。

## 三、三个概念一条链：Gate、Profile、技术债

SonarQube 的概念地图是一条依赖链：**规则 → 分析 → 度量 → 门禁条件**。

Quality Profile 是规则集，每种语言一份，出厂默认 Sonar way；定制姿势是 copy 出来改（激活/停用规则、调 severity）再设默认。Profile 支持继承，大组织常用「公司级父 profile + 团队微调」。

分析器执行规则产出 issue 与度量；Quality Gate 是一组「度量 ≥/≤ 阈值」的通过条件，默认 Sonar way 的条件全部定义在新代码上：

| 条件（新代码） | 阈值 |
| --- | --- |
| Reliability rating | A |
| Security rating | A |
| Security hotspots reviewed | 100% |
| Maintainability rating | A |
| Coverage | ≥ 80% |
| Duplicated lines | < 3% |

两个设计要点。其一，**只管新代码**：存量代码一票否决会让门禁第一天就永远红，团队学会的只有绕过。其二，条件可自定义，项目也可单独指定。

技术债把「烂」量化成时间：SQALE 模型给每类 issue 标修复成本（人时），汇总成技术债，再除以重写成本（分母默认每行 30 分钟估算）得到技术债比率，Maintainability 的 A~E 就是比率切出来的：≤5% A、≤10% B、≤20% C、≤50% D。

运维价值：从「感觉这项目很烂」变成「还欠 37 人天」，能进迭代排期。

「新代码」可在全局或项目级定义：previous version（默认）、天数、参考分支。**MR 分析时新代码 = 相对目标分支的变更**——门禁只评你这次改了什么，不替历史背锅。

## 四、四大维度里，藏着一个可被操纵的指标

| 维度 | 对象 | Sonar way 阈值（新代码） | 典型修复 |
| --- | --- | --- | --- |
| Reliability | bug | rating A | 修掉 blocker/critical |
| Security | 漏洞 + 热点 | rating A + 热点 review 100% | 改写 + 热点逐条确认 |
| Coverage | 测试覆盖 | ≥ 80% | 补测试（不是删断言） |
| Duplication | 重复块 | < 3% | 抽公共函数 |

Security 维度分两类：vulnerability 是可被利用的缺陷（如 SQL 拼接），security hotspot 是「取决于用法的风险点」（如硬编码 IP）——热点不直接算失败，要求人工 review 逐条标记安全/不安全。

Duplication 的算法与陷阱：连续 ≥10 行 token 序列相同判为重复块（算法语言相关，此为 Java 默认实现的判定粒度），跨文件也比对。计算式 `duplicated_lines_density = duplicated_lines / lines × 100`，关键在分母——lines 统计的是**物理行（含注释行）**。

所以改名换空格骗不过 token 比对，往重复块里堆注释行却真能稀释比率。code review 看到「重复块里塞满注释」要警惕，唯一正解是抽公共函数。

再划一组容易混的边界：trivy 扫的是**制品**——依赖包的已知 CVE，你引入的别人的代码；SonarQube 扫的是**你写的源码**——SQL 拼接、硬编码凭据这类没有 CVE 编号的安全弱点。你自己的 bug 不在任何漏洞库里，任何镜像扫描器都发现不了，两者互不可替代。

## 五、CI 集成：一个参数决定门禁是闸门还是报表

最小集成三个易错点：token 走 masked CI 变量注入（不进文件）、scanner 镜像的 entrypoint 置空、`GIT_DEPTH: "0"`——浅克隆会报 blame 信息缺失，scanner 要全量历史算新代码。

```yaml
# [.gitlab-ci.yml 片段] 镜像 tag 生产上要钉版本
sonarqube-check:
  stage: test
  image:
    name: sonarsource/sonar-scanner-cli:latest
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"   # 分析缓存目录
    GIT_DEPTH: "0"          # 禁用浅克隆，scanner 要全量历史
  script:
    - sonar-scanner -Dsonar.qualitygate.wait=true
  allow_failure: false      # 显式写出，防被"顺手优化"成 true
```

灵魂在一个参数上：**wait=true，门禁由报表变闸门就差这一步**。不加它，scanner 上传完报告立刻 exit 0，门禁结果只存在于 UI 上，pipeline 全绿照常合并——要有人主动看报表才会发现 FAILED。

加上后 scanner 轮询服务端的门禁计算，FAILED 映射为非零退出码，job 红、下游 stage 不跑、MR 合并被卡。等待上限默认 300 秒（`sonar.qualitygate.timeout`），服务端慢就调大，而不是去掉。

PR decoration（分析结果回写 MR、issue 以行内评论出现在改动行上）是商业版能力，免费的 Community Build 不支持多分支/PR 分析。社区版的等价做法就是上面这套：MR 流水线跑分析 + wait=true 阻塞，合并按钮被 pipeline 状态卡住——反馈进 MR 的 pipeline 视图，而非行内评论。

## 六、误报治理：治理动作本身会变成新漏洞

静态分析必然有误报——规则猜不到业务意图。治理三件套，按影响面从小到大选：

1. **issue 级标注**：单条标 False Positive / Won't Fix，留审计痕迹、可复议，首选
2. **文件/路径排除**：`sonar.exclusions` 整段不分析；生成代码、vendored 依赖该排除，但别用整目录排除掩盖真问题
3. **规则级豁免**：`sonar.issue.ignore.multicriteria` 指定「某规则在某文件模式上不报」

失效面在哪？**每一层豁免都是一个永久生效的暗门**。一条值得贴在墙上的判断：排除项只增不减的实例，一年后门禁就是筛子。开局案例里把 `internal/tools/` 整目录豁免的配置，就是第 2 层被滥用的样子——它当初多半也是一条「合理排误报」的提交。

治理纪律三条：每条 exclude 写注释说明理由与到期条件（生成代码重生成时要复核）；定期巡检排除清单；给老仓库接门禁时先跑基线分析——首次分析全部代码都算新代码，必然大面积红，这一步只看报告不挂门禁，等新代码定义调好、噪音治理完，再上 wait=true。

**豁免清单本身就是攻击面，误报治理和漏洞防御是同一件事的两面。**

## 七、镜像侧：Harbor 补上裸 registry 的五个洞

裸 registry:2 作为协议实现完全合格（Harbor 底层也是同一个 Distribution），当企业仓库用，五个缺口立刻暴露：无 UI、无项目权限、无扫描、无复制、无审计。其中无项目权限、无扫描、无审计三条对供应链致命——带着几十个 CRITICAL 的镜像可以一路推到生产，「谁推的这个后门镜像」无法回答。

选型判据一句话：**出现第二个团队或第二个机房，裸 registry 就该退役**。

真正值钱的是四个能力。

**内置 Trivy 与阻止拉取**。push 时自动扫描，旧镜像可手动或按时间重扫（漏洞库每天在变）。项目策略勾选 Prevent vulnerable images from running 后，Harbor 在 pull 拉取 manifest 的环节直接拒绝扫描超阈值的镜像——所有客户端一视同仁，不用每个集群配准入。

代价也明确：CI 必须先扫后推（先推后扫的镜像在扫描完成前会被拉断），且「无修复版本的 CRITICAL」会把自己锁死，开启前务必配好忽略策略。

**cosign 签名验证**。签名作为附带制品存进仓库（`<repo>:sha256-<digest>.sig`），Harbor 天然支持存取，配好公钥后 UI 可见签名状态。但要清醒：**真正挡人的不在 Harbor，在集群准入**——policy-controller 或 Kyverno 在部署时验签，Harbor 的角色是签名的管理面与展示面。

历史注脚：Notary v1 已在 v2.9.0 移除，新部署的签名路线就是 cosign。

**机器人账户**。CI 凭据三选项：个人账号（人离职全线爆炸，审计分不清人机）、共享 ci 用户（权限全项目粒度太粗）、机器人账户——项目级、可设过期（如 90 天）、可随时吊销。原则：每项目一套、每台 CI 一套，泄漏影响面等于权限面。

```bash
docker login 172.30.30.21 -u 'robot$demo+ci-push' -p '<机器人secret>'
docker push 172.30.30.21/demo/api:v0.1
# 预期：层上传成功；用户名必须带完整 robot$项目+名，少一段就是 unauthorized
```

**Helm OCI 仓**。Harbor v2.x 里镜像、chart、签名、SBOM 都是 OCI artifact：同项目、同域名、同 RBAC，统一享受 retention/复制/审计——「chart 单独买一套 Nexus」的老方案失去必要性。ChartMuseum 在 v2.8 已移除，chart 分发走 `helm push` 到 OCI 仓（helm 3.8+）。

## 八、仓库运维三件事：gc、备份、升级

**gc：retention 删引用，gc 才删空间**。retention 删的是 artifact 引用（DB 里看不见了），blob 还躺在磁盘——两步是一个链路。Harbor 把 gc 做成 UI 操作：DRY RUN 先估可释放空间、可配 cron、可多 worker。

行为细节：gc 期间仓库不停机（2 小时时间窗保护刚上传未关联的层），gc 按钮每分钟至多触发一次。

**备份：两块一起才是完整恢复点**。「只备份了 DB」是最经典的假装备份——pg_dump 恢复出来的实例不含镜像数据；反过来只备 /data/registry 就丢控制面：

```bash
# 1. 控制面：项目/用户/机器人/复制规则/审计日志
docker exec harbor-db pg_dumpall -U postgres > harbor-db-$(date +%F).sql
# 2. 数据面：镜像 blob（先停 Harbor 保证一致，或走文件系统快照）
tar -C /data -czf harbor-data-$(date +%F).tgz registry
```

更省事的灾备是复制规则：让另一个 Harbor 天然热备数据面——但复制只是仓库层冗余，DNS 切换、CI 推送目标切换要另写预案。

**升级：不跳级、先双备份**。跨大版本逐级升，回滚全靠升级前那两份备份：

```bash
docker compose -f /opt/harbor/docker-compose.yml down
mv /opt/harbor /opt/harbor-bak            # 回滚就靠它
cp -r /data/database /opt/db-bak          # postgres 数据目录冷备
# 之后：解压新离线包 → 旧 harbor.yml 拷入新目录 → prepare 镜像迁移配置格式
# → ./install.sh --with-trivy 安装；schema 迁移由 core 容器启动时自动执行
```

生产升级前先在测试实例演练一遍，窗口里只做验证过的动作。

## 九、系统性失效：门禁外的三条暗路

回到开局的被打穿。门禁机制本身再对，也有三条系统性的暗路。

**暗路一：绕过文化。**门禁第一天就永远红，团队学会的不是写好代码，是绕过——exclude、手动跳过 job、把代码挪到没被扫描的目录。**永远红着的门禁等于没有门禁**。

**暗路二：漏洞库滞后。**昨天的干净镜像今天可能爆出 CVE——绿灯的真实语义是「截至扫描时刻，已知漏洞未超标」。所以仓库侧要开按时间重扫、trivy 数据库要更新，而不是把扫描当一次性仪式。

**暗路三：扫的不是跑的。**tag 是可变的：CI 里扫的是 digest A，部署清单引用的是 tag，tag 被重新 push 后指向 digest B——扫描结果和实际运行的镜像可以是两个制品【从业者判断】。

堵法两件：部署清单用 digest 固定，tag 仅供人类阅读；cosign 验签——签名指向的是 digest，tag 换了 digest 就对不上，验签直接失败。这也是签名闸门比扫描闸门更硬的原因【从业者判断】：**扫描判断质量，签名判断身份**。

三条暗路共同的解法不是再加一道门禁，而是把判定对象从「tag + 某次扫描结果」换成「digest + 签名」这个不可变锚点。

## 十、预埋反方：门禁越多，交付越慢

反对意见值得正面写：测试、质量、漏洞、签名四道闸门串在同一条 pipeline 上，每道加几分钟，MR 等待时间线性上涨；等待越长，开发者越有动力「先合并再补扫」——门禁多到一定程度，绕过从个别行为变成文化。这笔账是真的。

权衡靠三条设计原则，而不是砍门禁：

- **闸门职责正交**：行为（测试）、结构（SonarQube）、制品（trivy+cosign）各管一段，重叠的检查只留一处——重复门禁不会更安全，只会更慢
- **反馈都在 MR 里**：闸门全挂在 merge_request_event 触发的 pipeline 上，作者合并前看到全部问题，而不是上线后收到告警
- **每个门禁可解释、可通过**：FAILED 要能定位到具体条件（哪条规则、哪个 CVE、哪段重复），且正常工作流走得通

第三条最容易被忽略。门禁数量不是安全度量，每个门禁的可解释与可通过才是——拦得住的给得出原因、正常流程走得通，团队才不会把它当敌人。

## 教训

1. **测试管行为，静态分析管结构，镜像扫描管依赖**——三者对象不同，谁也不替代谁
2. **wait=true 是闸门与报表的分界线**，没有阻塞能力的门禁是装饰品
3. **豁免清单就是攻击面**，排除项只增不减，一年后门禁就是筛子
4. **绿灯是时点快照**：漏洞库滞后加上 tag 可变，「扫的」未必是「跑的」
5. **永远红着的门禁等于没有门禁**，可通过性与可解释性比数量重要

## 现在就做：三分钟自检

```text
1. 打开 sonar-project.properties，数一遍 exclusions 与 multicriteria 条目：
   每条能说出"谁加的、为什么、什么时候到期"吗？说不出的，今天就清理
2. Harbor 项目 → Policy：阻止拉取开了吗？配套的忽略策略配了吗？
   Administration → Clean Up → Garbage Collection：跑一次 DRY RUN，看能释放多少磁盘
3. 抽一个生产在跑的镜像：部署清单引用的是 tag 还是 digest？
   它最后一次扫描是什么时候——超过一周没重扫的，今天就补一次
```

评论区聊一个问题：你们 pipeline 里的门禁，哪一个是「大家都在等它、但又说不清它拦了什么」的？把它揪出来——要么给它写清通过条件，要么把它撤了。

本文的完整实验路径出自我的真机学习仓库——GitHub 搜 sre-learning-hub，CI/CD 模块的 SonarQube 与 Harbor 两章，从埋雷项目到双闸门流水线全部可复现。
