# Lab 01 · 解答与讲解

> 运行环境：一台 Ubuntu 24.04 VM（docker-ce 29.7.2，内存 10G，磁盘余约 25G，镜像拉取走已配代理）。镜像 `apache/hadoop:3.3.6`（约 2G 磁盘）；tag 以 Docker Hub `apache/hadoop` 页面为准，3.3.x 任一版本均可。命令全部在 `[任意节点]`（装 docker 的 VM）上执行。

## 第 1 步：启动容器

```bash
# [任意节点]
docker run -d --name hdfs-lab \
  --memory 3g --cpus 2 \
  -p 9870:9870 -p 8088:8088 \
  apache/hadoop:3.3.6 tail -f /dev/null

docker exec hdfs-lab bash -c 'hdfs version | head -2; echo CONF_DIR=$HADOOP_CONF_DIR'
# 预期: Hadoop 3.3.6
#       CONF_DIR=/opt/hadoop/etc/hadoop
```

镜像事实速记（实测 apache/hadoop:3.3.6）：

- Hadoop 装在 `/opt/hadoop`，但**没有设 `HADOOP_HOME` 环境变量**，`hadoop`/`hdfs`/`yarn` 靠 PATH 里的 `/opt/hadoop/bin` 直接可用；配置目录由 `HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop` 指定——写配置就用这个绝对路径；
- 镜像只带 **JRE**（`/usr/lib/jvm/jre/`），**没有 `jps`**（那是 JDK 工具），也没有 `which` 命令。查进程一律 `ps -ef | grep <角色名>`，效果等价（check.sh 同样做了这个回退）。

为什么这样起：

- `--memory 3g`：NN 堆默认约 1G，加上 DN/YARN 各角色，3G 够伪分布式用。这是 `03-docker` 讲过的 cgroup 限制——生产上 HDFS 角色的 JVM 堆必须小于容器/主机限制，否则被 OOM killer 干掉（现象：jps 里进程周期性消失）；
- `tail -f /dev/null` 让容器常驻，进程后面用 `--daemon start` 逐个拉起，避免 `start-dfs.sh` 对 SSH 的依赖；
- 9870 是 NN Web UI、8088 是 YARN RM Web UI。容器 IP 在宿主机可达，浏览器直接开 `http://<VM-IP>:9870`（`[本地Windows]`）。

## 第 2 步：写配置 → 格式化 → 逐角色启动

Hadoop 的 `etc/hadoop` 下默认装的是几乎空白的配置（`fs.defaultFS` 缺省为本地文件系统），伪分布式必须先把三份 XML 写进容器。用 `docker exec -i` 接 heredoc（注意路径用 `/opt/hadoop/etc/hadoop`：镜像没设 `HADOOP_HOME`，写 `$HADOOP_HOME/...` 会落到 `/etc/hadoop` 那个无关的空目录，配置完全不生效）：

```bash
# [任意节点] core-site.xml：所有角色寻址 NameNode 的入口
docker exec -i hdfs-lab bash -c 'cat > /opt/hadoop/etc/hadoop/core-site.xml' <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://localhost:9000</value>
  </property>
  <property>
    <name>hadoop.tmp.dir</name>
    <value>/data/hdfs-tmp</value>
  </property>
</configuration>
EOF

# [任意节点] hdfs-site.xml：副本数 1（单 DN 存不下 3 副本）、元数据与数据目录
docker exec -i hdfs-lab bash -c 'cat > /opt/hadoop/etc/hadoop/hdfs-site.xml' <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file:///data/hdfs-tmp/dfs/name</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file:///data/hdfs-tmp/dfs/data</value>
  </property>
</configuration>
EOF

# [任意节点] yarn-site.xml：RM/NM 同机，资源按容器限额声明
docker exec -i hdfs-lab bash -c 'cat > /opt/hadoop/etc/hadoop/yarn-site.xml' <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property>
    <name>yarn.resourcemanager.hostname</name>
    <value>localhost</value>
  </property>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
  <property>
    <name>yarn.nodemanager.resource.memory-mb</name>
    <value>2048</value>
  </property>
  <property>
    <name>yarn.nodemanager.resource.cpu-vcores</name>
    <value>2</value>
  </property>
  <property>
    <name>yarn.nodemanager.vmem-check-enabled</name>
    <value>false</value>
  </property>
</configuration>
EOF
```

格式化并启动（格式化**只做一次**）：

```bash
# [任意节点] 格式化 NameNode —— 生成新的 clusterID 与空 fsimage
docker exec hdfs-lab hdfs namenode -format -force -nonInteractive
# 预期末尾: Storage directory /data/hdfs-tmp/dfs/name has been successfully formatted.

# [任意节点] 逐角色启动（等价于生产上 systemd/supervisor 拉起各 daemon）
docker exec hdfs-lab bash -c '
hdfs --daemon start namenode
hdfs --daemon start secondarynamenode
hdfs --daemon start datanode
yarn --daemon start resourcemanager
yarn --daemon start nodemanager
sleep 3
ps -ef | grep java | grep -oE "NameNode|SecondaryNameNode|DataNode|ResourceManager|NodeManager" | sort
'
# 预期（五行齐）:
#       DataNode
#       NameNode
#       NodeManager
#       ResourceManager
#       SecondaryNameNode
```

> 若你手上的镜像带 JDK（有 `jps`），用 `docker exec hdfs-lab jps` 能看到同样的五个角色名 + `Jps` 自身；`apache/hadoop:3.3.6` 只有 JRE，用上面的 `ps -ef` 即可。

为什么：

- **`hdfs --daemon start <角色>`** 不依赖 SSH，是单机/容器场景的标准做法；`--daemon stop <角色>` 对应停止。日志在 `$HADOOP_LOG_DIR`（本镜像为 `/var/log/hadoop/`，镜像没设 `HADOOP_HOME`，别去 `/opt/hadoop/logs` 找），排障第一现场；
- **SecondaryNameNode** 不是热备：它定期拉取 NN 的 fsimage+edits 合并后回推（checkpoint），防 edits 无限增长。NN 真正的高可用是 Active/Standby 双 NN + JournalNode（见 `16-bigdata/01-hdfs` 章）；YARN RM 高可用则用 ZooKeeper 做 leader 选举（`16-bigdata/06-zookeeper`，和 `12-data-streaming/kafka` 的 controller 选举同一套思路）。

## 第 3 步：解读 dfsadmin -report

```bash
# [任意节点]
docker exec hdfs-lab hdfs dfsadmin -report
```

关键输出（数值随容器磁盘浮动）：

```text
Configured Capacity: 62656290816 (58.36 GB)
Present Capacity: 52258021376 (48.67 GB)
DFS Remaining: 52251840512 (48.67 GB)
Live datanodes (1):

Datanode: /172.17.0.2:9866 (hdfs-lab)
  Configured Capacity: 62656290816 (58.36 GB)
  Last written: ...
```

逐项解读（SRE 值班最常用的三行）：

| 字段 | 含义 | 监控含义 |
| --- | --- | --- |
| Configured Capacity | DN 数据盘（`dfs.datanode.data.dir`）所在文件系统总量 | 容器 overlay 对应的宿主磁盘 |
| DFS Remaining | 可写入余量 | **写满 = 全集群写失败**，比 CPU 告警优先级高 |
| Live datanodes (1) | 已注册且心跳正常的 DN | 生产上掉一个 DN 会触发 under-replicated 告警 |

DN 掉线的判定链路：DN 心跳（默认 3s）超时 `dfs.namenode.heartbeat.recheck-interval`（默认约 10 分钟）后 NN 判 dead，其间是"stale"状态——排障时别一上来就重启 DN，先看心跳时间戳。NN 的这些指标都可经 JMX 暴露给 Prometheus（`08-pca` 的 jmx_exporter 思路，官方 `hadoop-hdfs` 集成文档为准）。

## 第 4 步：200MB 文件 → 块数与落点

```bash
# [任意节点]
docker exec hdfs-lab bash -c '
hdfs dfs -mkdir -p /labs
dd if=/dev/urandom of=/tmp/big.bin bs=1M count=200
time hdfs dfs -put /tmp/big.bin /labs/big.bin
hdfs fsck /labs/big.bin -files -blocks -locations
'
```

预期 fsck 输出（节选）：

```text
/labs/big.bin 209715200 bytes, 2 block(s):  OK
0. BP-1726747142-172.17.0.2:blk_1073741825 len=134217728 Live_repl=1
   Datanode info: [DatanodeInfoWithStorage[172.17.0.2:9866, DS-...]]
1. BP-1726747142-172.17.0.2:blk_1073741826 len=75497472 Live_repl=1
   Datanode info: [DatanodeInfoWithStorage[172.17.0.2:9866, DS-...]]

Status: HEALTHY
 Total blocks (validated):	2 (avg. block size 104857600 B)
```

解读：

- 默认块大小 `dfs.blocksize`=128MB：200MB = **128MB + 72MB 两块**，最后一块不必满；
- `Live_repl=1`：副本数按 `dfs.replication=1`（生产 3）；两块的 `Datanode info` 都指向唯一 DN——块放置策略首选本机/同机架，副本分散是 NN 调度结果；
- `Status: HEALTHY` 表示 fsck 未发现丢块/坏副本。**fsck 是只读诊断**，corrupt 文件的删除要另加 `-delete`（慎用）；
- 运维直觉：块大 → 顺序读吞吐高、NN 元数据少，但小文件浪费空间且 map 粒度粗；改块大小只影响**新写入**的文件。

## 第 5 步：500 个小文件 → NN 内存代价

```bash
# [任意节点]
docker exec hdfs-lab bash -c '
mkdir -p /tmp/small
for i in $(seq 1 500); do echo "small file $i" > /tmp/small/file-$i.txt; done
time hdfs dfs -put /tmp/small /labs/small
hdfs fsck /labs/small | grep -E "Total files|Total blocks|Total filesize"
'
# 预期: Total files: 500
#       Total blocks: 500        （每个文件 <128MB，各占 1 块）
#       Total filesize: ~7000 B  （真实数据不到 10KB）
```

两次上传对比（示例值，机制不变）：

| 上传对象 | 数据量 | HDFS 对象数 | 耗时构成 |
| --- | --- | --- | --- |
| big.bin | 200MB | 1 文件 / 2 块 | 网络与磁盘吞吐主导 |
| small 目录 | ~7KB | 500 文件 / 500 块 | 每文件一次 NN RPC + DN 建块，**元数据操作主导** |

NN 内存估算（Hadoop 官方文档经验值：**每个文件/目录/块对象约 150 字节堆内存**）：

- 500 个小文件 ≈ 500 INodeFile + 500 block 对象 ≈ 750 × 150B ≈ **约 110KB**——微不足道；
- 推到 1 亿个文件：1.5 × 10^8 个对象级别 → **20GB+ 堆起步**，再加上 block map、lease、缓存等管理结构，这就是"小文件问题"让 NN 无法水平扩展的原因。治理手段：入库前合并（HAR、`CombineFileInputFormat`）、或干脆走 `16-bigdata/05-olap-doris-starrocks` 的 OLAP 路线——Doris 的存储是列存 segment，天然聚合小记录。

另一个隐形成本：DN 的 **block report**（启动全量、运行期增量）对象数与小文件数成正比，集群重启风暴时 NN CPU 会被 block report 打满——表现为"重启后 30 分钟全集群不可写"。

## 第 6 步：safemode 进入与退出

```bash
# [任意节点] 触发前确认状态
docker exec hdfs-lab hdfs dfsadmin -safemode get
# 预期: Safe mode is OFF

# [任意节点] 人为进入
docker exec hdfs-lab hdfs dfsadmin -safemode enter
# 预期: Safe mode is ON

# [任意节点] 写入被拒
docker exec hdfs-lab bash -c 'echo new-data > /tmp/new.txt && hdfs dfs -put /tmp/new.txt /labs/new.txt'
# 预期: put: Cannot create file/labs/new.txt._COPYING_. Name node is in safe mode.

# [任意节点] 读取不受影响（NN 只读，元数据照常可查）
docker exec hdfs-lab hdfs dfs -cat /labs/small/file-1.txt
# 预期: small file 1

# [任意节点] 退出
docker exec hdfs-lab hdfs dfsadmin -safemode leave
# 预期: Safe mode is OFF
```

机制与生产对照：

- safemode 是 NN 的**只读保护态**：不接受任何命名空间修改（写路径全断），读/fsck 正常；
- 自动进入/退出的条件：NN 启动后等 DN block report 达到 `dfs.namenode.safemode.threshold-pct`（默认 0.999，即 99.9% 的块已上报）并延长 `dfs.namenode.safemode.extension`（默认 30s）才自动退出。**值班最常见场景**：DN 大批掉线/磁盘故障导致块上报不足，集群自动进 safemode 且退不出——处置顺序是先恢复 DN/磁盘，看 `hdfs dfsadmin -safemode get` 与 Web UI 的 missing blocks，确认数据面健康再手动 `leave`，切忌无脑 `-forceExit`；
- 主动 `enter` 的合法用途：维护窗口冻结写入（如备份 fsimage、做元数据操作）。

## 第 7 步：清理（check.sh 通过后再做）

```bash
# [任意节点] 删 HDFS 实验数据（-skipTrash 跳过回收站，立刻释放 DN 空间）
docker exec hdfs-lab bash -c 'hdfs dfs -rm -r -f -skipTrash /labs'

# [任意节点] 删容器内临时文件与容器本体
docker exec hdfs-lab bash -c 'rm -rf /tmp/big.bin /tmp/small /tmp/new.txt'
docker rm -f hdfs-lab
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Live datanodes (0) | 重复 format 产生新 clusterID，DN 拒绝注册 | 删 `/data/hdfs-tmp/dfs/data` 重启 DN（生产上等价于"误格式化 NN"） |
| put 报 Name node is in safe mode | safemode 未退出 | `safemode get` 看状态，先恢复 DN 再 `leave` |
| DataNode 起了但几秒后消失 | 容器内存不足被 OOM kill | 看 `/var/log/hadoop/hadoop-*datanode*`，调大 `--memory` |
| fsck 命令卡住 | NN RPC 拥塞或 safemode 检查中 | fsck 本身只读，等 fsck 自己超时；NN GC 看 jstat |

## 附：check.sh 通过结果

```text
# [任意节点]
$ chmod +x check.sh && ./check.sh
PASS: 容器 hdfs-lab 处于 Running
PASS: NameNode 进程已启动
PASS: DataNode 进程已启动
PASS: dfsadmin -report 显示 Live datanodes (1)
PASS: /labs/big.bin 存在于 HDFS
PASS: fsck /labs/big.bin 的 Total blocks (validated) 为 2
PASS: fsck /labs/small 的 Total files 为 500
PASS: safemode 已退出（Safe mode is OFF）

SCORE: 8/8
```

## 延伸阅读

- HDFS Users Guide：<https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsUsersGuide.html>
- dfsadmin / fsck 命令手册：<https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSCommands.html>
- 小文件与 NN 内存（官方架构指南）：<https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html>
