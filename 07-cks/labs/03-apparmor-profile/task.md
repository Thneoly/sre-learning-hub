# Lab 03 · AppArmor Profile 限制 Nginx 文件写入

> 难度：★★★ ｜ 考点：CKS-系统加固（AppArmor） ｜ 前置：无 ｜ 预计 30~45 分钟

## 场景

一台跑对外 Nginx 的节点被注入过 webshell：攻击者向 `/tmp` 和 `/etc` 写文件并执行。你决定用 AppArmor 给 Nginx 容器加一层"最小权限"壳：除 Nginx 运行必需的路径外，其余文件一律不可写、敏感文件不可读。要求：

- Nginx 能正常启动并对外提供页面（读配置、写日志、写 pid 文件）；
- 向 `/tmp`、`/etc` 等任意路径写文件被拒（EACCES）；
- 读取 `/etc/shadow` 被拒；
- profile 加载到节点后，Pod 通过 annotation 引用它（`localhost/<profile>`）。

实验环境：单 master kubeadm 集群，Pod 调度在 master 上，AppArmor 已启用（`cat /sys/module/apparmor/parameters/enabled` 输出 `Y`）。

## 任务清单

1. 在节点上编写 `/etc/apparmor.d/docker-nginx-cks`：允许 nginx 运行所需的最小读写集（`/var/log/nginx/**`、`/var/run/nginx.pid` 等），显式 `deny` 对 `/etc/shadow` 的访问，其余写入靠 AppArmor 默认拒绝。
2. 用 `apparmor_parser` 加载 profile，用 `aa-status` 确认其处于 enforce 模式。
3. 创建 namespace `cks-lab03`，写 Pod `nginx-apparmor`（镜像 `nginx:1.27`），annotation `container.apparmor.security.beta.kubernetes.io/nginx: localhost/docker-nginx-cks`。
4. 验证三件事：Pod Running 且 curl 首页正常（可用 `kubectl exec ... -- curl -s -o /dev/null -w "%{http_code}" localhost`）；`kubectl exec ... -- touch /tmp/pwned` 失败（Permission denied）；`kubectl exec ... -- cat /etc/shadow` 失败（Permission denied）。

## 验收标准

- `sudo aa-status | grep docker-nginx-cks` 显示 profile 在 enforce 列表
- `kubectl -n cks-lab03 get pod nginx-apparmor` 为 Running，annotation 值为 `localhost/docker-nginx-cks`
- Pod 内 `touch /tmp/pwned` 与 `cat /etc/shadow` 均报 Permission denied
- Nginx 正常响应（exec 内 curl localhost 返回 200）

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/03-apparmor-profile
chmod +x check.sh
sudo ./check.sh    # 读内核 apparmor profile 列表需要 root；脚本内 kubectl 会自动选对 kubeconfig
```

## 提示（卡住再看）

<details><summary>提示 1：annotation 的 key 和 value</summary>

key 是 `container.apparmor.security.beta.kubernetes.io/<容器名>`（容器名要和 Pod spec 里的完全一致），value 有三种：`runtime/default`（容器运行时默认）、`localhost/<profile名>`（节点上已加载的 profile，profile 名是 `profile` 语句后面的标识，不是文件名）、`unconfined`（不限制）。
</details>

<details><summary>提示 2：profile 为什么不用写满 deny 规则</summary>

AppArmor 是默认拒绝模型：profile 里没出现允许规则的路径，读写都会被拒。所以"限制文件写"的写法是只 allow 白名单路径（`/var/log/nginx/** rw`），不需要枚举所有 deny；对敏感文件再显式 `deny /etc/shadow rwklx,` 是为了连 root 权限下的读也拦掉且日志可读性更好。
</details>

<details><summary>提示 3：exec 里的报错长什么样</summary>

`touch /tmp/pwned` 返回 `touch: /tmp/pwned: Permission denied`，退出码非 0——注意 Permission denied 来自内核 LSM 而非文件系统权限（容器里是 root，普通 DAC 不会拦）。可以在节点上看 `sudo dmesg | grep DENIED | tail` 找到 `apparmor="DENIED" profile="docker-nginx-cks"` 的审计记录。
</details>
