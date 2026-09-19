---
title_juejin: '"会写脚本"是运维的分水岭：不是要不要学，是学到什么程度'
title_zhihu: '"会写脚本"是运维的分水岭：不是要不要学，是学到什么程度'
description: 社区共识与JD数据双验证：Shell做系统级、Python做复杂逻辑、Go是高级岗分界线。含健壮脚本骨架和实战路径。
category_id: "6809637769959178254"
tags: "后端,程序员"
column_id: "7686346277555716146"
---

# 凌晨两点磁盘告警：他 8 分钟定位根因，你 40 分钟还在清日志——这就是运维的分水岭

凌晨两点，磁盘告警把你吵醒。你登上服务器，手工清日志、重启服务，四十分钟才定位到根因，带着黑眼圈照常上班。

隔壁工位的同事被同一通告警吵醒。区别是，他半年前写的巡检脚本早就挂进了 crontab，告警一响，根因报告已经推到他手机上：哪个分区、哪个进程、占了多少，写得分明。他花八分钟看完报告、照着执行了清理动作，翻身接着睡。

同样被吵醒，差的是三十二分钟和一整晚的睡眠。差别不在勤快，也不在证书，而在一句被从业者反复印证的判断上：**会写脚本，是运维的分水岭**。"要不要学"不用再争——社区和用人数据给的是同一个答案；要争的是"学到什么程度"。这篇就把证据摊开，再把 Shell、Python、Go 各自的那条线画清楚。

## 1. 社区共识：这句话不是鸡汤，是十年的踩坑总结

把"分水岭"三个字定义清楚：不在"会不会敲命令"，也不在"能不能照着博客跑通一个脚本"，而在**能不能把重复的手工操作固化成可复用、可交接、进版本的代码**。

社区的说法高度一致。知乎上关于运维转型的主流论断一直很稳定：会写脚本是运维的分水岭，分工也讲得明白——Shell 做系统级任务，Python 做复杂逻辑。

V2EX 有个高赞帖（t/1135668）说得更直接："不涉及 coding 是没前途的"。纯手工运维没前途，这不是焦虑贩卖，是从业者用脚投票之后的总结。

另一个在职 SRE 的忠告（t/824678）值得单独拎出来："好好花时间在 Go/K8s/Linux 上，切忌啥都搞。"我的解读是，这句忠告有个隐含前提：脚本这关已经过了，才有资格谈聚焦。

关于"35 岁"的争论，社区的共识其实很冷静：被替代的是纯手工执行的那部分工作，不是这份职业本身。纯手工的运维份额在萎缩，高端 SRE 和运维开发在需求结构上依然坚挺——2025 年各城市 SRE/DevOps 行情较 2024 年回落了 2%-12%，AI Infra 方向却逆势走高——而分界线恰好压在"能不能写代码"上。

还有个反面案例值得记住：V2EX 上有人考了 CKA 加 CCNA 仍然难落地。证书是敲门砖不是护城河，能拿出手的脚本和工具才是——这个判断在多个社区被反复印证。

市场价也是两极：能写工具、能读源码的那一档，整体高出一截；纯手工执行的那部分，整体矮一截。行情随城市和年份波动明显，以各平台实时数据为准。

## 2. GitHub 硬数据：题库和路线图都在给这句话投票

社区的嘴可能骗人，GitHub 的数据不会。我拿三家高星仓库做了交叉验证（星数为 2026-08 的调研快照，以仓库实时数据为准），结论一致。

第一份证据是 bregman-arie/devops-exercises（84.2k 星）。这个仓库是运维考点题库，题量分布就是考点清单：Linux 一类 298 题，全库第三，只比 Kubernetes 的 341 题少一成多；主 README 的补充题里，Network 一个类目 72 题；Shell 还单独成类目，31 题。

Shell 类目看着只有 31 题，但别被骗了——Linux 那 298 题里，大量排查题的现场验证最终落到管道和脚本上。题量是显性的，脚本要求是隐性的，而且藏在每道题背后。

第二份是 milanm/DevOps-Roadmap（20.3k 星）的 12 步路线：Git → 编程语言 → Linux 与脚本 → 网络与安全 → 服务器管理 → 容器。脚本排在容器前面，这是路线图在明确告诉你地基的先后顺序。

第三份是 mxssl/sre-interview-prep-guide（9.1k 星），SRE 备考指南里 Programming 是独立一章，和 Networking、Kubernetes 平级。roadmap.sh 的 devops 路线（138 个主题）同样把编程语言列为必经站。

这些星数和题量不是文献综述的谈资——背后是出题的权重：考纲把票投给哪，市场的考点就在哪。

三家交叉出的顺序共识：基础（Linux/网络/脚本）→ 容器/K8s → IaC/CI-CD → 可观测 → 云。不少转型路径都直接从容器层切入——我自己最早整理学习材料时也是这么排的——恰恰跳过了最底下这层 Linux 与脚本的地基。

再看 JD 侧，规律同样整齐：初中级写"熟悉 Shell、了解 Python"；高级和运维开发方向写"精通 Python/Go、能读源码、有 Operator 开发经验"。**三门语言不是三个选项，是三级台阶**：

| 语言 | 社区定位 | 典型场景 | 在 JD 里的位置 |
|---|---|---|---|
| Shell | 系统级任务 | 巡检、备份、批量执行、故障注入 | 初中级起必备 |
| Python | 复杂逻辑 | API 批量调用、日志分析、exporter | 中高级主力 |
| Go | 高级方向分界线 | Operator、读源码、云原生组件扩展 | 高级方向专属 |

## 3. Shell：必须守住的家底，但"能跑"不算会

结论放在前面：**Shell 是底线，不是加分项**。巡检、备份、日志轮转、批量执行这些系统级任务，Shell 永远是最短路径，没有之一。

但很多老运维的 Shell 停在"能跑就行"：一次性脚本能跑，放进 crontab 半年后没人敢动——这是常态，也正是分水岭真正的位置：**从"能跑"到"不炸"**。

看一个健壮脚本的骨架，三件套是 set -euo pipefail、trap 清理、参数校验：

```bash
#!/usr/bin/env bash
# 巡检脚本骨架：从"能跑"到"不炸"
set -euo pipefail      # 出错即停；未定义变量报错；管道任一环失败都算失败

LOG_DIR=${LOG_DIR:-/var/log}     # 默认值，允许环境变量覆盖
TEMP_FILE=$(mktemp)              # 别手拼 /tmp/xxx.$$
trap 'rm -f "$TEMP_FILE"' EXIT   # 正常退出、报错、Ctrl+C 都会走到这里

[[ $# -eq 1 ]] || { echo "用法: $0 <磁盘阈值>" >&2; exit 1; }
THRESHOLD=$1
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || { echo "阈值必须是整数" >&2; exit 1; }

df -P | awk -v t="$THRESHOLD" 'NR>1 && $5+0 > t {print $6, $5}'
```

Shell 过关的标准，列四条硬的：

- 能预判变量加不加引号的分词差异——相当一部分脚本事故出在 quoting 上；
- 每个进生产的脚本默认带 set -euo pipefail 和 trap；
- grep/sed/awk 三件套能组合出"从日志提取字段并汇总统计"；
- 会 xargs -P 或 pdsh 做批量并行，而不是 for 循环串行 ssh。

再往上一级是"工程化"：脚本要有用法提示、统一的日志格式（带时间戳、落文件）、幂等（重复跑不出错）。到了这个程度，你的脚本才能进 git、被同事 review、从个人手艺变成团队资产。

顺带一个高频坑：进了 crontab 的脚本，PATH 和交互 shell 不一样。很多"手动能跑、定时任务必炸"的事故都出在这——绝对路径加显式设置 PATH，是保命符。

版本提醒：关联数组和 mapfile 需要 bash 4 以上，macOS 自带的 3.2 不支持——写脚本前先确认目标机的 bash 版本，以各发行版文档为准。

## 4. Python：复杂逻辑的主力，学到"能交付工具"为止

Shell 的天花板很明确：没有像样的数据结构、异常处理吃力、并发别扭、调 REST API 全靠 curl 硬拼。跨过这条线，就该 Python 接棒。

Python 在 SRE 手里的定位是自动化主力：批量调 K8s API、分析 access log、写自定义 exporter、给内部平台写后端。社区共识"Python 做复杂逻辑"，指的就是这些场景。

语法只学运维用得到的 20% 就够：数据结构、函数、异常、模块导入。别陷进语言细节的坑，目标是四周内交出第一个能用的工具，而不是把教程看完。

一个最小可用的批量探测工具，把 Python 的优势占齐了——并发、结构化输出、标准 CLI：

```python
#!/usr/bin/env python3
"""批量探测：并发和结构化输出，正是 Shell 不擅长的"""
import argparse
import concurrent.futures as cf
import json
import subprocess

def probe(host: str) -> dict:
    r = subprocess.run(
        ["ping", "-c", "1", "-W", "1", host],
        capture_output=True,   # 列表传参，不用 shell=True 拼字符串
    )
    return {"host": host, "alive": r.returncode == 0}

if __name__ == "__main__":
    p = argparse.ArgumentParser(description="批量 ping 探测")
    p.add_argument("hosts", nargs="+")
    p.add_argument("--workers", type=int, default=20)
    args = p.parse_args()

    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        result = list(ex.map(probe, args.hosts))
    print(json.dumps(result, ensure_ascii=False, indent=2))
```

Python 的过关标准，同样给硬指标：

- pathlib、subprocess、requests、argparse 四件套信手拈来；
- 会 venv 和依赖管理，脚本交给同事能直接跑，而不是"在我机器上是好的"；
- subprocess 一律列表传参，不写 shell=True 加字符串拼接——那是 SQL 注入的运维版；
- 能独立交付一个小工具：多线程巡检、简易 exporter、告警机器人这个量级。

如果你是网络背景转型过来的，这条建议专属给你：你的存量优势是协议和排障经验，把它"Linux 内核化"——用 Python 写 tcpdump 输出的解析、TIME_WAIT 的统计分析。**设备方向的知识在贬值，内核视角的网络能力在升值，脚本是兑换的媒介**。

社区流传的高频考题也在配合这个方向：三次握手在哪完成、TIME_WAIT 怎么排查、网卡收包到协议栈的路径——网络题几乎全部换成了 Linux 内核视角。而这类题的答案，最后都要落到"能用脚本现场验证"才算真的会。

## 5. Go：高级方向的门票，策略是先"读"后"写"

Go 在三门语言里是另一个物种。为什么高级方向点名要 Go？看生态就懂了：Kubernetes、Docker、Prometheus、etcd、Istio，清一色 Go。

**读懂它们、扩展它们（Operator、Admission Webhook、自定义 controller），Go 是唯一入口**。再加上单二进制部署、交叉编译、静态类型这些工程特性，"精通 Python/Go"成为高级方向的分界线毫不意外。

也有人问：为什么不是 Rust、不是 Java？答案很朴素——生态在哪，入口就在哪。读源码、提 PR、写扩展，对象全是 Go 代码。转型者时间有限，跟着生态走是胜率最高的选法。

一个 goroutine 并发探测的最小形态，感受下它和 Python 并发的差别：

```go
// 批量 HTTP 探测：goroutine + channel 的最小可用形态
package main

import (
	"fmt"
	"net/http"
	"time"
)

func main() {
	urls := []string{"https://kubernetes.io", "https://prometheus.io", "https://etcd.io"}
	client := &http.Client{Timeout: 3 * time.Second}
	ch := make(chan string, len(urls))
	for _, u := range urls {
		go func(u string) { // 显式传参，所有 Go 版本下都安全
			_, err := client.Get(u)
			if err != nil {
				ch <- fmt.Sprintf("FAIL %s", u)
				return
			}
			ch <- fmt.Sprintf("OK   %s", u)
		}(u)
	}
	for range urls {
		fmt.Println(<-ch)
	}
}
```

学到什么程度？分三档，按序推进：

- **第一档（读）**：能看懂典型 Go 程序的结构和错误处理，能改开源小工具的配置与逻辑；
- **第二档（用）**：goroutine + channel 写受控并发工具，把上面的探测器扩成带超时和结果聚合的巡检；
- **第三档（写）**：用 client-go 的 Informer 机制（ListWatch + 本地缓存 + 事件回调）写自定义组件。Informer 不是面试黑话，是 K8s 控制面的通用协作模式，吃透它，再读各类 controller 的代码就通了。

对转型者，前两档性价比最高，第三档等 K8s 用熟了再上——顺序反了容易两头空。client-go 与集群版本的兼容矩阵，以 Kubernetes 官方文档为准；Go 版本以 go.dev 发布为准。

## 6. 社区流传的 279 个脚本，怎么用才不白拿

聊个具体资源。知乎上流传很久的《279 个开箱即用的 Shell 脚本》合集（搜标题能找到），主打防 DDoS、数据库备份、日志分析、系统监控这些高频场景。它的成色我不打包票——但这不重要，对老运维来说，任何这类合集的价值都不在"拿来就用"。

先泼冷水：收藏不等于会。"开箱即用"是下限不是上限。打开看两样：有没有 set -euo pipefail，有没有 trap 和参数校验——缺了这些，直接进生产就是隐患；而这恰好是它最大的价值所在。

正确的用法是三步，把它从资料变成训练场：

- **当阅读材料**：每天读两三个，看别人怎么拆解问题、处理边界，积累的是套路；
- **当改写素材**：挑十个，逐个补上健壮性三件套、日志函数、幂等处理——改完的那份才是你的；
- **当考题**：改完在测试机上故意输错参数、断网重跑，看它炸不炸。不炸，才算出师。

还有个隐藏福利：改别人的脚本是最快的学法。读十篇教程，不如把一个生产级脚本拆开再装回去——哪里处理了边界、哪里偷了懒，拆一遍全看见了。

想再进一步，配两个实战仓库：SadServers（3k 星，"症状→限时排查→验证"的闯关形态，有团队拿它做实操考核）和 trimstray/test-your-sysadmin-skills（11.8k 星，Junior 到 Guru 分级自测）。

也要听反方声音：DevOpsHiveHQ/dynamic-devops-roadmap（2.5k 星）直言线性路线图"无法帮你拿到第一份工作"，主张每轮做"写码→构建→部署→监控→故障"的小闭环。别等学完 Shell 再学 Python 再学 Go，用一个贯穿项目把三者串起来。

## 7. 写在最后：一份 90 天清单，今天就能动手

证据和方法都说完了，给一份可执行清单。不是"好好学习"那种空话，每条都按"做完有产物"设计——产物可以是脚本、工具，或一次实打实的改造。时间轴只有一条：90 天，从今天算。

1. **第 0 天（就是今天）**：把上周重复手工最多的一个操作写成脚本，必须带 set -euo pipefail、trap 和参数校验——这是整个 90 天的启动动作；
2. **第 30 天**：把 Shell 修到"不炸"：从 279 合集里挑 3 个读、1 个改，改造点就按第三节的三件套；
3. **第 60 天**：用 Python 交付一个工具：四件套各写一个 10 行小例子，合成一个能交付的巡检工具；
4. **第 90 天**：用 Go 读懂一个开源项目，改掉一处逻辑；
5. **贯穿 90 天**：把你目标岗位的技术要求里三门语言的表述各抄 10 条，按出现频率排序——分界线自己会浮出来。

这份清单的终点不是"学完"，是下一个凌晨两点：告警再响，接电话的是你的脚本，还是你。

这些内容我整理进了开源学习仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub) 的编程模块——Shell、Python、Go 三档进阶和配套自测都在里面，清单第 2、3 条要用的素材也在这套模块里，仓库同时放了在线阅读版。

从"能跑"到"不炸"，从"不炸"到"不用醒"——运维这条分水岭，值得用九十天跨过去。

最后留个互动：三门语言里，你卡在哪一档——"Shell 能跑但会炸"、"Python 会写但交付不了"，还是"Go 完全没碰过"？评论区报个档位，下一篇我挑人数最多的那一档展开写。

---

参考：bregman-arie/devops-exercises（84.2k★）· milanm/DevOps-Roadmap（20.3k★）· mxssl/sre-interview-prep-guide（9.1k★）· roadmap.sh/devops · trimstray/test-your-sysadmin-skills（11.8k★）· SadServers（3k★）· DevOpsHiveHQ/dynamic-devops-roadmap（2.5k★）· V2EX t/1135668 · t/824678（星数为 2026-08 调研快照，以各仓库实时数据为准）
