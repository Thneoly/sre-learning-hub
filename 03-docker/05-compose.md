# 05 · Docker Compose：多容器应用与通往 Kubernetes 的桥

> 模块：03-docker ｜ 建议时长：2 小时 ｜ 关联认证：CKA-应用管理（Compose → K8s 对象映射）/ —（无直接考点，但概念迁移价值高）

本章命令默认在**装有 Docker 的 Ubuntu 22.04/24.04 VM** 上执行，标注为 `[任意节点]`；涉及 kubeadm 集群的命令标注为 `[master]`。

## 学习目标

- 能解释 Compose project 的隔离模型：project name 如何统一决定网络名、卷名、容器名
- 能操作 `depends_on` + `healthcheck` 实现带就绪条件的启动顺序，解释"启动顺序"与"就绪顺序"的差异
- 能使用 `profiles` 在同一份 compose.yaml 中切换开发/调试拓扑
- 能解释 project 默认网络中的内嵌 DNS（127.0.0.11）如何解析服务名，并与 K8s 的 ClusterDNS 对比
- 能把一份 compose.yaml 的字段逐一映射到 Deployment / Service / ConfigMap / PVC，并说出哪些 Compose 概念在 K8s 里刻意没有对应物

## 1. Compose 解决什么问题：project 是一等公民

单容器应用极少。一个典型 Web 应用至少是 `web + db + cache`，手工 `docker run` 三次、按顺序、配好网络，既难重复又难清理。Compose 用一份声明式 YAML 描述整张拓扑，`docker compose up -d` 一条命令拉起，`docker compose down` 一条命令拆除。

隔离靠 **project**：Compose 用 project name 给所有资源打标签并统一命名：

```
project: shop（目录名或 name: 字段）
├── 网络   shop_frontend / shop_backend        （自定义网络）
├── 卷     shop_dbdata                          （卷名加 project 前缀）
├── 容器   shop-web-1 / shop-db-1               （project-服务-序号）
└── 标签   com.docker.compose.project=shop      （贴在每个容器上）
```

两个 project 即使内容完全相同也互不干扰——这套"用隔离域包裹一组资源"的思想与 K8s 的 namespace 同源。注意用 v2 插件 `docker compose`（空格），老的单体 `docker-compose`（连字符）已 EOL：

```bash
# [任意节点]
sudo apt-get install -y docker-compose-v2
docker compose version      # 预期输出 Docker Compose version v2.x
```

## 2. 一份贯穿全章的 compose.yaml

```yaml
# [任意节点] 文件：~/compose-shop/compose.yaml
name: shop

services:
  web:
    image: nginx:1.27-alpine
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    networks:
      - frontend
      - backend

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: example
      POSTGRES_DB: shop
    volumes:
      - dbdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d shop"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 10s
    networks:
      - backend

  migrate:
    image: postgres:16-alpine
    profiles: ["tools"]
    depends_on:
      db:
        condition: service_healthy
    command: ["sh", "-c", "PGPASSWORD=example psql -h db -U postgres -d shop -c 'CREATE TABLE IF NOT EXISTS orders (id serial PRIMARY KEY);'"]
    networks:
      - backend

volumes:
  dbdata:

networks:
  frontend:
  backend:
```

要点：db 只挂 backend 网络，web 横跨两网；`migrate` 属于 `tools` profile，默认不启动；`name: shop` 需要 Compose v2.3+。

## 3. depends_on 与 healthcheck：从"启动顺序"到"就绪顺序"

`depends_on` 有两种写法，语义完全不同：

```yaml
# [任意节点] 片段：短语法——只保证"先启动 db 进程，再启动 web"
services:
  web:
    depends_on:
      - db

# [任意节点] 片段：长语法——等 db 的 healthcheck 变成 healthy 才启动 web
services:
  web:
    depends_on:
      db:
        condition: service_healthy
```

`condition` 支持三个值：

| condition | 含义 |
|---|---|
| `service_started` | 依赖容器进程启动（等价短语法） |
| `service_healthy` | 依赖的 healthcheck 报 healthy |
| `service_completed_successfully` | 依赖容器**跑完并退出码为 0**（一次性任务，如数据库迁移） |

关键认知：**进程起来 ≠ 服务就绪**。postgres 容器启动到真正可接受连接之间有数秒初始化窗口，短语法的 `depends_on` 救不了应用启动时的 `connection refused`——要么应用自带重试，要么用 condition + healthcheck 把等待前置到编排层。

healthcheck 字段速查：

| 字段 | 含义 | 缺省 |
|---|---|---|
| test | `["CMD", ...]` 直接 exec；`["CMD-SHELL", ...]` 走 shell；`["NONE"]` 禁用 | 无 |
| interval | 两次探测间隔 | 30s |
| timeout | 单次探测超时 | 30s |
| retries | 连续失败多少次判 unhealthy | 3 |
| start_period | 宽限期，期间失败不计入 retries | 0s |

注意 `condition: service_healthy` 要求被依赖的服务**必须定义 healthcheck**，否则 `up` 直接报错。`docker compose up -d --wait` 会阻塞到所有服务 running/healthy 才返回（配 `--wait-timeout 60` 控制上限），是 CI 里最实用的姿势。

## 4. profiles：一份文件，多套拓扑

服务标了 `profiles: ["tools"]` 后默认不创建，显式启用才拉起：

```bash
# [任意节点]
docker compose up -d                      # migrate 不在其中
docker compose ps                         # 只有 web、db
docker compose --profile tools run --rm migrate   # 显式启用 profile 并跑一次性任务
# 也可用环境变量启用：COMPOSE_PROFILES=tools docker compose up -d
```

规则：未标 profiles 的服务永远启用；标了的服务只在 profile 激活时启用；**依赖链上引用了未激活 profile 的服务会直接报错**——所以 `web depends_on migrate` 这种写法要慎用。K8s 里没有对应物，分层部署靠 overlay/kustomize，这是 Compose 开发态便利与 K8s 声明态一致性的分野。

## 5. 网络模型：project 内嵌 DNS

每个 project 自动创建（或按声明创建）bridge 网络，Docker 在每个容器里注入内嵌 DNS：

```
        Docker host（project: shop）
┌─────────────────────────────────────────────────────┐
│  网络 shop_frontend          网络 shop_backend        │
│  ┌──────────┐               ┌───────────────┐        │
│  │ web      │────（web 两网都挂）────────────│        │
│  └──────────┘               │ web   ·  db   │        │
│                             └───────────────┘        │
│   每个容器 /etc/resolv.conf → nameserver 127.0.0.11  │
│   内嵌 DNS 负责把服务名解析为容器 IP（含网络别名）      │
└─────────────────────────────────────────────────────┘
        :8080 端口发布 → 宿主机（docker-proxy/iptables DNAT）
```

- **服务名即 DNS 名**（同网络内），等价于 K8s 里 Service 名即 DNS 名；旧机制 `links:` 已废弃，不要再用。
- 一个服务挂多个网络时，只在共同网络里可互解：`db` 在 backend，frontend-only 的容器解析不到 `db`——这是 compose 层面最接近 NetworkPolicy 的隔离手段。
- `ports: "8080:80"` 是发布到宿主机；容器间访问一律走服务名 + 容器端口（`http://web:80`），不写宿主机端口。
- 服务名解析出的 IP 是**容器 IP**，容器重建即变——这是"用 DNS 不用 IP"的根本原因，K8s 里 Endpoints 变化同理。

## 6. Compose → Kubernetes 映射表（本模块的桥）

| Compose 概念/字段 | K8s 对象/字段 | 备注 |
|---|---|---|
| `services.web` | Deployment（无状态）/ StatefulSet（db 类） | 一个 service ≈ 一组副本 |
| `image` | `containers[].image` | K8s 多了 `imagePullPolicy` |
| `deploy.replicas` | `spec.replicas` | compose 单机缺副本语义，`--scale` 顶替 |
| `ports: "8080:80"` | Service（NodePort/LoadBalancer）+ Ingress | ClusterIP 只在集群内，对应"不发布端口的 compose 服务" |
| 服务名 DNS 解析 | Service + ClusterDNS | 都是"名字 → 虚地址"，K8s 多一层 VIP/iptables |
| `healthcheck` | livenessProbe / readinessProbe / startupProbe | K8s 把"健康"拆成三类，语义见自测 2 |
| `depends_on condition` | **无直接对应**（initContainer、readiness 门控、应用重试） | K8s 刻意不做启动顺序 |
| `volumes: dbdata` | PVC（背后是 PV/StorageClass） | 卷从节点资源升级为集群资源 |
| bind mount 配置文件 | ConfigMap 挂载 | 内容进入 API 对象，可版本化 |
| `environment` / `env_file` | `env` + ConfigMap/Secret 引用 | 明文敏感值在 K8s 用 Secret |
| `secrets:`（文件型） | Secret（挂 `/run/secrets/<name>` 同名路径） | Secret 也只是 base64，不是加密 |
| `restart: unless-stopped` | `restartPolicy: Always`（Deployment 体系） | K8s 靠控制器重建，语义更强 |
| `deploy.resources.limits` | `resources.limits` | K8s 还有 requests 驱动调度 |
| `container_name` | 无（Pod 名系统生成） | 固定名阻碍 `--scale`，别养成依赖 |
| `profiles` | 无（overlay/kustomize 分层） | — |
| project 隔离 | namespace | 粒度从单机升级到集群 |
| `networks` 隔离 | NetworkPolicy | compose 只能"连不连网"，K8s 可到端口级 |

工具提示：`kompose convert`（https://kompose.io，kubernetes SIG 项目）能自动做上面大半映射，但迁移后的探针、资源、策略仍要人工补齐。

## 实战演练：跑通 shop 项目并验证每个机制

```bash
# [任意节点] 步骤 1：写入两个文件
mkdir -p ~/compose-shop && cd ~/compose-shop
cat > nginx.conf <<'EOF'
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF
# 再把第 2 节的 compose.yaml 原样保存为 ./compose.yaml（vim/nano 或 heredoc 均可）
```

```bash
# [任意节点] 步骤 2：拉起并等待就绪
docker compose up -d --wait
# 预期输出：Container shop-db-1  Healthy / Container shop-web-1  Healthy
docker compose ps
# NAME         STATUS                 PORTS
# shop-web-1   Up 2 minutes (healthy) 0.0.0.0:8080->80/tcp
# shop-db-1    Up 2 minutes (healthy) 5432/tcp
docker network ls | grep shop      # shop_frontend、shop_backend 两个网络
```

```bash
# [任意节点] 步骤 3：验证内嵌 DNS 与服务名解析
docker compose exec web cat /etc/resolv.conf   # nameserver 127.0.0.11
docker compose exec web nslookup db
# Server: 127.0.0.11 → 解析出 shop_backend 网络里 db 的容器 IP
docker network inspect shop_backend --format '{{range .Containers}}{{.Name}} {{end}}'
# shop-web-1 shop-db-1 —— 只有这两个容器在 backend 网络里
```

```bash
# [任意节点] 步骤 4：跑 profile 里的一次性迁移并验证
docker compose --profile tools run --rm migrate
docker compose exec db psql -U postgres -d shop -c '\dt'
# 预期看到表 orders
```

```bash
# [任意节点] 步骤 5：观察就绪阻塞（healthcheck 真的在起作用）
docker compose pause db                  # 冻结 db，healthcheck 必然超时
docker compose up -d --wait --wait-timeout 60
# 预期：等待后报错退出（db unhealthy / 超时），返回码非 0
docker compose unpause db
docker compose ps                        # 恢复 healthy
```

```bash
# [任意节点] 步骤 6：清理（注意 -v 的含义）
docker compose down      # 删容器与网络；卷 shop_dbdata 保留，数据还在
docker compose down -v   # 连卷一起删，数据库数据彻底清空
```

### 桥接演练：把 web 服务手工翻译成 K8s 对象

```yaml
# [master] 文件：web-k8s.yaml —— compose.yaml 中 web 服务的"直译"
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-nginx-conf            # 对应 volumes: ./nginx.conf
data:
  default.conf: |
    server {
        listen 80;
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web                       # 对应 services.web
  labels:
    app: web
spec:
  replicas: 1                     # 对应 deploy.replicas
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        volumeMounts:             # bind mount → ConfigMap
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
          readOnly: true
        readinessProbe:           # healthcheck 在 K8s 拆成多类探针
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
      volumes:
      - name: nginx-conf
        configMap:
          name: web-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: web                       # 服务名即 DNS 名，对应 compose 服务名解析
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
```

```bash
# [master] 应用并验证
kubectl apply -f web-k8s.yaml
kubectl get deploy,svc,pod -l app=web
kubectl run test --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- http://web
# 预期输出 nginx 默认页 HTML —— 服务名解析 + Service 转发全链路打通
kubectl delete -f web-k8s.yaml
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 写了 `service_healthy` 但 `up` 报错 | 被依赖服务没定义 healthcheck | 给依赖服务补 healthcheck，或降级 `service_started` |
| app 启动即 `connection refused`，虽然用了 depends_on | 短语法只管启动顺序不管就绪 | 用 condition + healthcheck，或应用层重试 |
| `docker compose up -d --scale web=3` 报端口/名称冲突 | `ports: "8080:80"` 发布固定宿主机端口（或写了 container_name） | 去掉发布端口/固定名，或只 scale 无发布端口的服务 |
| 改了 Dockerfile/配置不生效 | `up` 不会自动 rebuild/重建未变化容器 | `docker compose up -d --build` |
| `restart: no` 被 YAML 解析成布尔 false | YAML 1.1 里 no/yes 是布尔 | 写 `restart: "no"`（带引号） |
| down 之后 postgres 旧密码还生效 | `down` 不删卷，数据目录残留 | 要重置数据用 `down -v` |
| `${VAR}` 展开结果和预期不符 | Compose 在**解析**文件时就做插值，不是容器运行时 | 默认值写 `${VAR:-default}`；运行时变量走 environment |

## 自测

1. K8s 刻意不实现 `depends_on`，为什么？生产里用什么机制替代它？

<details><summary>答案</summary>

分布式系统里"依赖服务就绪"无法可靠观测也不该由编排器背书：依赖可能中途挂掉、网络可能抖动，即使启动瞬间 healthy 也不能保证后续可用。K8s 把责任交还给应用：连接必须自带重试/熔断；就绪门控用 readinessProbe（不 ready 就不接流量）；初始化顺序用 initContainer（可天然表达 `service_completed_successfully` 语义）。Compose 的 condition 是单机便利，K8s 的哲学是"任何组件随时可能不存在"。

</details>

2. Compose 一个 healthcheck 字段，为什么到 K8s 被拆成 livenessProbe / readinessProbe / startupProbe 三种？各自控制什么？

<details><summary>答案</summary>

Compose 的 healthcheck 只有一个消费者——depends_on 的 condition。K8s 里健康有三种不同决策：liveness 失败 → 杀掉容器重启（进程死了没？）；readiness 失败 → 摘除 Service Endpoints（能接流量没？）；startupProbe → 慢启动应用完成前暂停前两者探测。一个探针无法同时回答"该重启吗"和"该导流量吗"——把"能干活"误判成"进程死"会造成重启风暴，反之则向死实例导流量。

</details>

3. 容器 `/etc/resolv.conf` 指向 127.0.0.11，这是谁？它解析不到外网域名时去哪查？

<details><summary>答案</summary>

127.0.0.11 是 dockerd 在容器网络命名空间里注入的内嵌 DNS 代理（不是独立容器）。它先查 project 内的服务名/别名，未命中则把查询转发给宿主机配置的上游 DNS（通常再由 systemd-resolved 或公司 DNS 递归）。K8s 对应物是 CoreDNS（ClusterIP 10.96.0.10），同样做"集群内名字本地应答 + 集群外转发"，K8s 还多出 ndots:5 这类搜索域行为。

</details>

4. `docker compose up -d --wait` 与 `depends_on condition: service_healthy` 的区别是什么？

<details><summary>答案</summary>

condition 控制**容器创建顺序**：web 的容器在 db healthy 之前根本不会被创建；`--wait` 不改顺序，只让 `up` 命令本身**阻塞到所有服务都 running/healthy 才返回**（并可配 --wait-timeout）。前者是拓扑内的时序约束，后者是对命令调用方（CI/脚本）的同步点，两者常配合使用。

</details>

5. `docker compose down -v` 之后，哪些资源没了、哪些还在？

<details><summary>答案</summary>

没了：容器、project 网络、卷（命名卷如 shop_dbdata，连带数据）。还在：镜像（volume 与镜像生命周期无关）、宿主机上 bind mount 的源文件（本来就是宿主局的文件）、Docker 全局配置。注意 `down`（不带 -v）保留卷——这既是"数据安全默认值"，也是"我要重置环境怎么数据还在"的经典困惑来源。

</details>

## 延伸阅读

- Compose 官方文档：https://docs.docker.com/compose/
- Compose 规范（字段权威定义）：https://github.com/compose-spec/compose-spec/blob/main/spec.md
- Compose 网络模型：https://docs.docker.com/compose/how-tos/networking/
- Compose profiles：https://docs.docker.com/compose/how-tos/profiles/
- 容器内嵌 DNS（Embedded DNS）：https://docs.docker.com/engine/network/
- K8s Service 与 DNS（对照阅读）：https://kubernetes.io/docs/concepts/services-networking/service/
- Compose → K8s 自动转换：https://kompose.io

---

上一章：[04 存储与数据卷](04-storage-volumes.md) ｜ 下一章：[06 容器安全最佳实践](06-security-best-practices.md) ｜ 配套练习：`labs/05-compose-stack`
