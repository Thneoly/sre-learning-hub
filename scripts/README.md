# scripts · 练习集群基础设施

> 定位：**新建一套独立练习集群**，与 05-cka 题库环境（base VM `172.30.30.21`）完全隔离，可随时推倒重建。
> 目标环境：干净的 Ubuntu 22.04 / 24.04 VM（VMware），单 master 起步，可扩为多节点（见 `setup/MULTI-NODE.md`）。

## 学习目标

- 能在一台干净 Ubuntu VM 上用 `setup/` 脚本 10 分钟内搭出可做实验的单节点集群
- 能解释每个脚本动了系统的哪些地方（swap / sysctl / containerd / iptables），从而敢在玩坏后重置
- 能按快照策略配合 `faults/` 故障注入脚本做"破坏→排查→修复"循环

## 目录结构

```
scripts/
├── labctl.sh                  # 练习平台 CLI：list/show/check/scores/solution/fault/drill/timer
├── lib/
│   └── common.sh              # 公共函数库：颜色输出 / confirm 交互 / pass fail / 等待函数
├── setup/
│   ├── install-docker.sh      # Docker CE + compose-plugin 安装（03-docker 模块用）
│   ├── kubeadm-single-node.sh # 一键从裸机到可用集群（kubeadm + Calico + 组件）
│   ├── reset-cluster.sh       # kubeadm reset + 清理 CNI 残留
│   ├── install-prom-stack.sh  # Prometheus + Alertmanager + Grafana + node-exporter（08-pca 用）
│   └── MULTI-NODE.md          # VMware 克隆扩容为 1 master + 2 worker 指南
└── faults/                    # 12 个故障注入脚本 + FIXES.md（独立模块，本 README 不展开）
```

## 使用顺序

典型时间线（全新 VM 到能做 PCA 实验）：

```
第 1 步  [master] bash setup/install-docker.sh          仅 Docker 课程需要；纯 k8s 路线可跳过
   ↓      （做 03-docker 的 labs）
第 2 步  [master] bash setup/kubeadm-single-node.sh     约 5~10 分钟，含镜像拉取
第 3 步  [master] kubectl get nodes                     看到 Ready 即成功
   ↓      （做 04-k8s-fundamentals 章节实战 / 05-cka 的 labs）
第 4 步  [master] bash setup/install-prom-stack.sh      进入 08-pca 前执行
   ↓      （做 08-pca 的题库练习）
第 5 步  [master] bash ../faults/break-<name>.sh       按需注入故障练排错（<name> 见 faults/FIXES.md，先打快照！）
随时     [master] bash setup/reset-cluster.sh          集群玩坏了，重置后重跑第 2 步
```

脚本依赖关系：`setup/` 与 `faults/` 下的脚本都 `source ../lib/common.sh`，拷贝时带上 `lib/` 目录；
各 lab 目录的 `check.sh` 自带 helper、**不依赖** `lib/common.sh`，可单独拷到任意机器执行。

## labctl 练习平台（lab 的统一入口）

`labctl.sh` 是单文件 bash CLI（只依赖 bash/kubectl），把"读题 → 判分 → 记分 → 看答案 → 注故障 → 限时演练"串成一个闭环。
自动发现全仓库全部 lab（`*/labs/*/task.md`，当前 65 个），记分写入 `~/.labctl/scores.tsv`，需 root 的 `check.sh` 与故障脚本会自动走 sudo（密码默认 `123`，可用 `LABCTL_SUDO_PASS` 覆盖）。

```bash
# [master] 建议先做个别名：alias labctl='bash ~/hub/scripts/labctl.sh'
labctl --help                    # 中文自文档（子命令、lab 的四种写法、环境变量）
labctl list                      # 全部 lab：编号/难度/名称/✓ 最佳得分
labctl list 05                   # 只看 05-cka 模块（也可写 05-cka、cka）
labctl show 11                   # 读题（支持 11 / 11-rbac-role-binding / 05:11 / 完整路径）
labctl check 05:11               # 跑 check.sh 判分，PASS/FAIL 彩色回放，自动记分并与历史最佳对比
labctl scores                    # 记分板：最佳成绩/尝试次数/最近时间 + 完成数与平均得分率
labctl solution 11               # 确认后才显示 solution.md 前 80 行（防剧透，完整路径会给出）
labctl fault                     # 列出 12 个故障（难度/是否已注入）
labctl fault random              # 随机注入一个（3 秒倒计时，先打 VM 快照）
labctl fault restore coredns     # 恢复指定故障；restore all 全部恢复
labctl drill                     # 靶场抽卡：随机一条【靶场】现象 + 15 分钟限时提示（不阻塞）
labctl timer 15                  # 简易倒计时，到点响铃
```

记分文件格式 `日期时间|lab|得分|满分`，例：`2026-08-23 14:49:40|05-cka/labs/11-rbac-role-binding|8|8`。
推荐节奏（与 `SCENARIOS.md` 文末的限时演练法一致）：`list` 挑 lab → `show` 读题 → 动手做 → `check` 判分 → 卡住再 `solution` → 顺手 `fault random` 或 `drill` 做一轮限时排障。

## 安全警告（务必先读）

1. **仅用于练习环境**。脚本会关闭 swap、修改内核参数、重写 containerd 配置、执行 `kubeadm init`、清空 iptables——这些操作对生产环境是破坏性的。不要在任何承载真实业务的机器上运行。
2. **网络隔离**。练习集群默认没有认证加固（Grafana 用弱口令、NodePort 直接暴露、metrics-server 关闭了 kubelet 证书校验），只应运行在 NAT / Host-only 网络的 VM 里，不要把 NodePort 映射到公网。
3. **root 权限**。除 `lib/common.sh` 外所有脚本都需要 root（脚本内 `require_root` 会自动判断）。运行前用 `vim` 通读一遍再执行——看懂安装脚本本身就是 CKA 备考的一部分。
4. **与题库环境隔离**。05-cka 题库操作手册依赖 `172.30.30.21` 那套既有集群；本模块新建的集群使用独立 VM 和独立网段（默认 podCIDR `172.31.0.0/16`，可 `--cidr` 覆盖），两者互不影响。

## VMware 快照策略（强烈建议）

注入故障前打快照，是练习环境最省时间的习惯：

```
快照点 1  装好 OS、更新完 apt 之后                —— "clean-os"
快照点 2  kubeadm-single-node.sh 跑完、节点 Ready   —— "cluster-ready"
快照点 3  prom-stack 装完、Grafana 可登录           —— "monitoring-ready"
快照点 4  每次运行 scripts/faults/*.sh 之前        —— 命名如 "before-break-coredns"
```

操作入口：

```text
[本地Windows] VMware Workstation：VM → Snapshot → Take Snapshot
[本地Windows] vSphere Client：右键虚拟机 → Snapshots → Take Snapshot
```

恢复快照比 `reset-cluster.sh` 更快，但会丢掉快照之后的所有集群状态（etcd 数据一并回滚）；只想清集群、不想回滚整个 OS 时用 `reset-cluster.sh`。故障修复练习的节奏建议：先手工排查，实在修不出来再回快照，然后对照 `faults/FIXES.md` 复盘。

## 环境要求

| 项目 | 最低 | 建议 |
|------|------|------|
| CPU | 2 vCPU | 4 vCPU |
| 内存 | 2 GB | 4~8 GB |
| 磁盘 | 20 GB | 40 GB（装 prom-stack 后镜像约占 5 GB） |
| OS | Ubuntu 22.04 / 24.04（干净安装，无残留 docker/k8s 包） | 同左 |
| 网络 | VM 能访问互联网（直连、镜像源或代理任一） | NAT 模式 |

## 国内网络与代理

所有 setup 脚本支持两组可选变量（用法见各脚本头部注释）：

```bash
# [master] 方式一：镜像源（APT_MIRROR 换 apt 仓库，DOCKER_MIRROR 给 Docker Hub 加 registry mirror）
export APT_MIRROR=mirrors.aliyun.com
export DOCKER_MIRROR=https://docker.m.daocloud.io
```

```bash
# [master] 方式二：HTTP 代理（例：宿主机 7890 端口，VMware NAT 网关为 192.168.x.2）
export http_proxy=http://192.168.31.2:7890
export https_proxy=http://192.168.31.2:7890
export no_proxy=localhost,127.0.0.1,10.96.0.0/12,172.31.0.0/16,.svc,.cluster.local
```

kubeadm 控制面镜像在 `registry.k8s.io` 拉取失败时会自动切到 `registry.aliyuncs.com/google_containers` 兜底（`kubeadm-single-node.sh` Step 5 已处理）。

## 快速开始

```bash
# [本地Windows] 把仓库同步到 VM（也可 git clone 或用共享文件夹；IP 换成你的 VM）
scp -r D:/SRE/chat/learning-hub/scripts cka0000@172.31.30.11:~/
```

```bash
# [master] 在 VM 上执行
cd ~/learning-hub/scripts/setup 2>/dev/null || cd ~/scripts/setup
sudo bash kubeadm-single-node.sh --cidr 172.31.0.0/16
# 结束时脚本会打印验证清单与 kubeconfig 提示
```

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| 脚本中断在 `apt-get update` | 网络不通 / 镜像源没生效 | 设 `APT_MIRROR` 或代理后重跑（脚本幂等） |
| VM 重启后节点 NotReady | swap 又被挂上（fstab 注释失败） | `swapoff -a` 并检查 `/etc/fstab`，再重启 kubelet |
| `kubectl` 报 `connection refused localhost:8080` | kubeconfig 未就位 | `export KUBECONFIG=/etc/kubernetes/admin.conf`（root） |
| Prometheus/Grafana 页面打不开 | NodePort 端口记错或被占用 | `kubectl get svc -A | grep -E '30900|30903|30300'` 核对 |
| prom-stack Pod 一直 `ImagePullBackOff` | 无法访问 quay.io / docker.io | 配 `DOCKER_MIRROR`、代理，或走脚本末尾打印的离线路线 |

## 延伸阅读

- kubeadm 安装（官方）：https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Docker CE on Ubuntu（官方）：https://docs.docker.com/engine/install/ubuntu/
- Calico 自管部署（官方）：https://docs.tigera.io/calico/latest/getting-started/kubernetes-self-managed-onprem/onpremises
- kube-prometheus-stack chart（官方仓库）：https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
