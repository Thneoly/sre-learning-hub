# Lab 01 · 解答 —— Trivy 镜像扫描与高危镜像阻断

## 步骤 1：安装 Trivy

在 master 上用官方 apt 仓库安装（Ubuntu 22.04/24.04）：

```bash
# [master]
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO- https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version
```

验证（预期输出形如 `Version: 0.5x.x`）：

```bash
# [master]
trivy --version
```

为什么用 apt 而不是 `apt install trivy`：Ubuntu 官方源里的 trivy 版本很旧，漏洞库兼容性差；官方仓库滚动更新。

## 步骤 2：扫描 nginx:1.16

```bash
# [master]
trivy image --severity HIGH,CRITICAL nginx:1.16
```

要点：

- 首次运行会自动下载漏洞数据库（`~/.cache/trivy/db`），需要几分钟和出网；
- 预期输出表格中 `HIGH`/`CRITICAL` 两列均有数字，总计几十到上百条（CVE 会随库更新变化，数量以实际为准；2026-08 实测 nginx:1.16 为 166 条 HIGH/CRITICAL）；
- 对比扫描 `nginx:alpine`：

```bash
# [master]
trivy image --severity HIGH,CRITICAL nginx:alpine
```

当前最新的 alpine 基底镜像 HIGH/CRITICAL 为 0——这就是"升级即修复"的最廉价安全手段。
注意"干净镜像"会随漏洞库更新过期：debian 基底的旧 tag（如 nginx:1.27，2026-08 已扫出上百条 HIGH/CRITICAL）会逐渐积累未修复 CVE，教学/演示时要挑当前干净的镜像。

## 步骤 3：编写闸门脚本

```bash
# [master]
sudo tee /usr/local/bin/image-gate.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# image-gate.sh <image> —— HIGH/CRITICAL 漏洞镜像准入闸门
set -u
IMAGE="${1:?usage: image-gate.sh <image>}"
if trivy image --quiet --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed "$IMAGE"; then
  echo "GATE: ALLOW $IMAGE"
  exit 0
else
  echo "GATE: DENY $IMAGE (HIGH/CRITICAL vulnerabilities found)"
  exit 1
fi
EOF
sudo chmod +x /usr/local/bin/image-gate.sh
```

参数解释：

| 参数 | 作用 |
|---|---|
| `--severity HIGH,CRITICAL` | 只关心高危级别，降低噪音 |
| `--exit-code 1` | 有匹配漏洞时进程退出码 1，脚本据此判断 |
| `--quiet` | 压掉进度日志，CI/脚本友好 |
| `--ignore-unfixed` | 忽略尚无修复版本的 CVE（可选，减少误杀） |

## 步骤 4：测试闸门

```bash
# [master]
/usr/local/bin/image-gate.sh nginx:1.16; echo "exit=$?"
/usr/local/bin/image-gate.sh nginx:alpine; echo "exit=$?"
```

预期：

- `nginx:1.16` 打印 `GATE: DENY ...`，`exit=1`；
- `nginx:alpine` 打印 `GATE: ALLOW nginx:alpine`，`exit=0`。

## 步骤 5：创建 namespace 并留档结论

```bash
# [master]
kubectl create namespace cks-lab01

kubectl -n cks-lab01 create configmap image-gate-report \
  --from-literal=blocked=nginx:1.16 \
  --from-literal=allowed=nginx:alpine \
  --from-literal=tool=trivy

kubectl -n cks-lab01 get configmap image-gate-report -o yaml
```

为什么用 ConfigMap 而不是本地文件：结论进入集群后，审计方用 `kubectl` 就能读取，不依赖登录某台机器。

## 步骤 6：只部署通过闸门的镜像

```bash
# [master]
if /usr/local/bin/image-gate.sh nginx:1.16; then
  echo "不应到达这里"
fi

if /usr/local/bin/image-gate.sh nginx:alpine; then
  kubectl -n cks-lab01 run web --image=nginx:alpine
fi

kubectl -n cks-lab01 get pod web -o wide
```

预期 `web` 为 `Running`。被拒镜像根本没有发起 `kubectl run`——这是"客户端准入"，等同于把 CI 流水线的镜像扫描卡点搬到了手工部署流程。

## 生产化方向（理解即可）

```
开发者 --push--> Registry --webhook--> CI: trivy image 扫描
                                          | HIGH/CRITICAL? 
                                          +-- 是 --> 失败，镜像打标 quarantined
                                          +-- 否 --> 部署
                                                  |
 apiserver <---- Admission Webhook(OPA Gatekeeper/Kyverno) 再拦一道兜底
```

- 客户端闸门防"好人犯错"；集群内 admission（Gatekeeper / Kyverno 校验镜像 tag、registry 白名单）防"绕过流程"。两层都要有。
- Trivy 还能扫 IaC（`trivy config`）、文件系统（`trivy fs`）和 K8s 集群（`trivy kubernetes --report summary`），CKS 考试主要考 `trivy image`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `FATAL` 提示 DB 下载失败 | master 无出网或代理未配 | 配 `HTTPS_PROXY`，或先在有网机器 `trivy image` 预热再把 `~/.cache/trivy` 拷过去 |
| 首次扫描卡在 `Downloading Java DB`（~900MB） | trivy 新版（0.7x）第一次跑漏洞扫描会预下载 Java 漏洞库，扫非 Java 镜像纯属浪费 | 给命令加 `--offline-scan` 直接跳过（`--skip-java-db-update` 首次运行会拒绝）；或耐心等它下完，之后不再触发 |
| 脚本里 `trivy` 明明有漏洞却退出 0 | 忘了 `--exit-code 1` | 默认 trivy 无论是否发现漏洞都退出 0 |
| `image-gate.sh: Permission denied` | 没加执行权限 | `sudo chmod +x /usr/local/bin/image-gate.sh` |
| check.sh 报 `Pod web` 不存在 | 用 `kubectl run` 时没加 `-n cks-lab01`，落到了 default | 删掉重建，注意 namespace |

## 判分结果

按上述步骤完成后运行：

```bash
# [master]
cd 07-cks/labs/01-trivy-scan-admission
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: namespace cks-lab01 存在
PASS: ConfigMap image-gate-report 存在于 cks-lab01
PASS: ConfigMap 记录 blocked=nginx:1.16
PASS: ConfigMap 记录 allowed=nginx:alpine
PASS: ConfigMap 记录 tool=trivy
PASS: Pod web 为 Running 且镜像 nginx:alpine
PASS: 集群中不存在 nginx:1.16 的 Pod
PASS: /usr/local/bin/image-gate.sh 存在、可执行且调用 trivy

SCORE: 8/8
```
