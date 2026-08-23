# Lab 01 · 副本集部署、故障转移与断连追平

> 难度：★★☆ ｜ 考点：SRE-MongoDB 复制链路与高可用 ｜ 前置：无（建议先读 11-middleware/mongodb/02） ｜ 预计 40~60 分钟

## 场景

你是值班 SRE。业务要上一个新服务，数据层选了 MongoDB，三节点副本集还没搭，你来。今天要演练三件事，都是生产真实发生过的：

1. 新业务上线前，把三节点副本集 `rs0` 搭起来，并验证写入能复制到全部从库；
2. 主机房的机器要打补丁（用 `rs.stepDown()` 模拟主库让位），验证集群自动选出新主、写入不中断、旧主回来后变从库；
3. 一台从库"宕机"（停容器），期间主库继续写入；恢复后验证它通过 oplog 自动追平。

环境：一台装有 Docker 的 Ubuntu 22.04/24.04 VM。全部操作在本机 bash 与 `docker exec` 内完成，不需要 kubeadm 集群。

约定（check.sh 按此判分，务必遵守）：

- 容器名 `mongo-rs1` / `mongo-rs2` / `mongo-rs3`，镜像 `mongo:7.0`，接入同一个 docker network
- 副本集名 `rs0`；成员地址用容器名 `mongo-rs1:27017` 等
- **`mongo-rs1` 初始为 PRIMARY（priority 调高），且演练后保持 SECONDARY 不抢回**
- 业务库 `app`、集合 `orders`，最终三个节点各有 **120 条**文档（第一阶段插 60 条，从库停机期间再插 60 条）

## 任务清单

1. 用 Docker 起三个 `mongo:7.0` 容器，均带 `--replSet rs0 --bind_ip_all`，接入同一 docker network。
2. 在 `mongo-rs1` 上 `rs.initiate`：`mongo-rs1` 设 `priority: 2`（保证它当选初始 PRIMARY），另两个成员默认优先级；等待集群出现 1 主 2 从。
3. 在主库写入 `app.orders` 前 60 条（`_id` 为 1~60），用直连（`directConnection=true`）验证两个从库都能查到 60 条。
4. 对 `mongo-rs1` 执行 `rs.stepDown(120)`，确认新主在 `mongo-rs2` 或 `mongo-rs3` 上产生、旧主变为 SECONDARY，且集群仍只有 1 个 PRIMARY。
5. 停掉从库容器 `mongo-rs3`（此时集群剩 2/3，多数派仍在）；在新主上继续写入后 60 条（`_id` 61~120，默认写关注即可成功），验证写入不受影响。
6. 重新启动 `mongo-rs3`，等待其通过 oplog 追平；最终验证：三节点各 120 条、恰好 1 主 2 从、`mongo-rs1` 为 SECONDARY。

## 验收标准

- `docker ps` 能看到 `mongo-rs1`、`mongo-rs2`、`mongo-rs3` 三个运行中的容器
- 任一节点 `rs.status()` 的 `set` 为 `rs0`，三个成员 stateStr 均为 `PRIMARY`/`SECONDARY`，且 `PRIMARY` 有且只有一个
- `mongo-rs1` 的 stateStr 为 `SECONDARY`（发生过故障转移且未抢回主）
- 三个节点直连查询 `db.getSiblingDB("app").orders.countDocuments({})` 均为 120
- 运行 `./check.sh` 输出 `SCORE: 10/10`

## 提示（卡住再看）

<details><summary>提示 1：rs.initiate 后一直只有一个成员有状态</summary>

三个容器刚起时彼此还没"认识"，initiate 只需要在其中一个节点执行一次，配置里写全三个成员地址。执行后等 10 秒左右再查 `rs.status()`，成员会从 STARTUP2 依次变成 SECONDARY。如果长期不变，检查 `--replSet rs0` 是否三个都带了、成员地址能否互通（同一 network 内容器名可解析）。
</details>

<details><summary>提示 2：连从库查询报 "not primary and secondaryOk=false"</summary>

默认只允许读主库。运维排查时用直连方式显式绕过：`mongosh "mongodb://localhost:27017/?directConnection=true"`（在对应容器内执行）。应用侧的正规做法是连接串里写 `readPreference=secondary`。注意直连且不带 readPreference 时某些操作仍会报错，可加 `readPreference=secondary` 查询参数。
</details>

<details><summary>提示 3：stepDown 之后怎么确认新主、以及写入该打到谁</summary>

`rs.status().members.forEach(m => print(m.name, m.stateStr))` 看谁变成 PRIMARY，之后 `docker exec` 进那个容器直连执行插入。stepDown 的参数 120 表示旧主 120 秒内不再竞选，配合它 priority=2 也抢不回，这保证了最终 `mongo-rs1` 是 SECONDARY。
</details>

<details><summary>提示 4：mongo-rs3 重启后怎么确认追平了</summary>

重启后先看 `rs.status()` 里它的 stateStr 回到 `SECONDARY`（STARTUP2/RECOVERING 都表示还没就绪），再直连 `countDocuments({})` 数到 120。60 条文档的 oplog 增量几秒内就能重放完；如果发现它进了 initial sync，说明它掉线时间超过了 oplog 窗口（本 lab 数据量小，不会发生）。
</details>
