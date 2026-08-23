# Lab 07 · 容器安全加固：cap-drop / no-new-privileges / 非 root

> 难度：★★★ ｜ 考点：CKS-容器安全（最小权限三件套） ｜ 前置：lab 01、lab 06 ｜ 预计 30~40 分钟

## 场景

安全团队扫描后给出整改项：你们的业务容器全部以 root + 全套默认 capabilities 运行，一旦容器内 RCE，攻击者拿到的是"root 且带 14 项 capability"的立足点。整改要求：默认 capability 全部丢弃、禁止通过 setuid 提权、业务进程以非 root uid 运行、根文件系统只读。你要先跑一个 baseline 容器看清"默认有多松"，再逐项加固并验证每一项都真的生效——这些开关与 CKS 考试里 Pod `securityContext` 的 `capabilities.drop` / `allowPrivilegeEscalation` / `runAsNonRoot` / `readOnlyRootFilesystem` 一一对应。

## 任务清单

1. 起 baseline 容器 `lab07-base`（默认配置，alpine，`sleep infinity`），读 `/proc/self/status` 的 `CapEff`，用 `capsh --decode`（宿主机上）解出默认 capability 集合。
2. 起 `lab07-nocap`（`--cap-drop ALL`）：验证 `CapEff` 为全零；验证 `mount` 与 `ping` 这类依赖特权系统调用的操作被拒。
3. 起 `lab07-noroot`（`--user 1000:1000`）：验证 `id -u` 为 1000，且向 `/` 写文件被拒（rootfs 属主是 root）。
4. 演示 `no-new-privileges`：在 `--rm` 容器里造一枚 setuid 的 `cat`（`cp /bin/cat /tmp/rootcat && chmod 4755 /tmp/rootcat`），再以 uid 1000 读只有 root 能读的文件——不带 `--security-opt no-new-privileges` 时读取成功，带时 `Permission denied`（内核忽略 setuid 位）。对比一次成功一次失败。
5. 起整合容器 `lab07-hard`：`--user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp`，验证四项开关同时生效，且写入 `/tmp` 仍可用。
6. 用 `docker inspect` 逐字段核对 `lab07-hard` 的 `SecurityOpt` / `CapDrop` / `CapAdd` / `ReadonlyRootfs`，形成一份"终态证据"。

## 验收标准

- `lab07-base`：运行中，`CapEff` 非零（默认特权仍在）；
- `lab07-nocap`：运行中，`CapEff` 为 `0000000000000000`；
- `lab07-noroot`：运行中，`docker exec id -u` 返回 `1000`；
- `lab07-hard`：运行中，`SecurityOpt` 含 `no-new-privileges`，`CapDrop` 为 `ALL`，`ReadonlyRootfs` 为 `true`，且 `/tmp` 可写。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：默认到底给了哪些 capability？</summary>

`docker run --rm alpine sh -c 'grep CapEff /proc/self/status'` 拿到十六进制位图，宿主机上 `capsh --decode=<位图>` 解码。Docker 默认集合：CHOWN、DAC_OVERRIDE、FSETID、FOWNER、MKNOD、NET_RAW、SETGID、SETUID、SETFCAP、SETPCAP、NET_BIND_SERVICE、SYS_CHROOT、KILL、AUDIT_WRITE——没有 SYS_ADMIN、NET_ADMIN，但 SETUID/NET_RAW 这类仍是攻击面。
</details>

<details><summary>提示 2：no-new-privileges 在内核层怎么生效？</summary>

它把进程的 `no_new_privs` 位（prctl(PR_SET_NO_NEW_PRIVS, 1)）置 1：此后 execve 时内核**忽略**文件上的 setuid/setgid 位与文件 capability，子进程特权只降不升。注意它不影响已经持有的特权，只封"向上的通道"。
</details>

<details><summary>提示 3：--read-only 之后应用写不了日志怎么办？</summary>

把可写路径显式划出来：`--tmpfs /tmp`（内存盘）、`-v logdata:/var/log`（volume）。K8s 同理：`readOnlyRootFilesystem: true` + emptyDir/log volume。
</details>
