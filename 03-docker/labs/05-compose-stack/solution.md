# Lab 05 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker 与 docker compose 插件（`docker compose version` 可用）；能访问 Docker Hub。

## 目录结构与文件

```
~/lab05-stack/
├── app.py
├── requirements.txt
├── Dockerfile
├── nginx.conf
├── compose.yaml
└── check.sh        # 从 lab 目录拷来，与 compose.yaml 同目录
```

## 第 1 步：app.py

```bash
# [Ubuntu VM]
mkdir -p ~/lab05-stack && cd ~/lab05-stack
cat > app.py <<'EOF'
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

import redis


def build_response(path):
    if path == "/healthz":
        return 200, b"ok"
    if path == "/redis-ping":
        client = redis.Redis(host="redis", port=6379, socket_timeout=2)
        if client.ping():
            return 200, b"PONG"
        return 502, b"FAIL"
    return 200, b"hello from app"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            code, body = build_response(self.path)
        except Exception as exc:  # redis 不可达时返回 502，便于故障演练观察
            code, body = 502, str(exc).encode()
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    print("app listening on :8000, hostname=%s" % socket.gethostname(), flush=True)
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
EOF
```

## 第 2 步：requirements.txt 与 Dockerfile

```bash
# [Ubuntu VM]
cd ~/lab05-stack
cat > requirements.txt <<'EOF'
redis==5.0.8
EOF

cat > Dockerfile <<'EOF'
FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8000
CMD ["python", "app.py"]
EOF
```

注意两个细节（呼应 lab 02）：

- `requirements.txt` 与 `app.py` 分两次 COPY：改代码时不触发 pip 层重建，命中 cache；
- `--no-cache-dir` 不把 pip 缓存留在镜像层里。

## 第 3 步：nginx.conf

```bash
# [Ubuntu VM]
cd ~/lab05-stack
cat > nginx.conf <<'EOF'
server {
    listen 80;

    location / {
        proxy_pass http://app:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
```

`http://app:8000` 里的 `app` 会在 nginx 启动后由 Docker embedded DNS（127.0.0.11）解析——nginx 对 upstream 域名默认只在启动时解析一次，本实验服务 IP 固定足够；若 upstream 动态变化需用 `resolver 127.0.0.11 valid=10s;` + 变量形式 `proxy_pass http://$upstream;`。

## 第 4 步：compose.yaml

```bash
# [Ubuntu VM]
cd ~/lab05-stack
cat > compose.yaml <<'EOF'
services:
  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

  app:
    build: .
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')"]
      interval: 5s
      timeout: 3s
      retries: 5

  web:
    image: nginx:alpine
    ports:
      - "8085:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      app:
        condition: service_healthy
EOF
```

字段对照 Kubernetes：

| Compose | Kubernetes |
|---|---|
| service 名（DNS 名） | Service 名 + ClusterDNS |
| `depends_on: condition: service_healthy` | initContainer / readinessProbe 控制依赖 |
| healthcheck | livenessProbe/readinessProbe |
| `ports: "8085:80"` | Service type NodePort/port 映射 |
| `build: .` | 镜像由 CI/CD 构建后推 registry |
| 项目网络 `lab05_default` | Pod network（每 Pod 一 IP，靠 Service 寻址） |

## 第 5 步：启动并观察顺序

```bash
# [Ubuntu VM]
cd ~/lab05-stack
docker compose -p lab05 up -d --build
docker compose -p lab05 ps
```

预期最终状态：

```
NAME              IMAGE         COMMAND                  SERVICE   STATUS
lab05-app-1       lab05-app     "python app.py"          app       Up x seconds (healthy)
lab05-redis-1     redis:7-al... "docker-entrypoint.s…"   redis     Up x seconds (healthy)
lab05-web-1       nginx:alpine  "/docker-entrypoint.…"   web       Up x seconds
```

启动顺序为 redis -> app -> web：web 的容器会等 app 变 healthy 才创建。用 `docker compose -p lab05 up -d --build` 的输出（或重放 `docker compose -p lab05 events`）能看到 `ContainerStart` 事件依次出现。容器命名规则：`<项目名>-<服务名>-<序号>`，因此固定为 `lab05-redis-1` / `lab05-app-1` / `lab05-web-1`。

网络验证：

```bash
# [Ubuntu VM]
docker network ls | grep lab05
docker inspect lab05-web-1 --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool | head -8
```

三个容器都在 `lab05_default` 网络里。

## 第 6 步：验证三条链路

```bash
# [Ubuntu VM]
curl -s http://localhost:8085/
# hello from app          （web 反代 -> app，DNS 解析 app 成功）

curl -s http://localhost:8085/redis-ping
# PONG                    （app 解析 redis 成功且协议连通）

docker exec lab05-app-1 python -c "import socket; print(socket.gethostbyname('redis'))"
# 172.x.x.x              （embedded DNS 直接证据）

docker compose -p lab05 logs app | tail -3
```

链路全景：

```
宿主机 :8085
   │ (DNAT, lab03 讲过的 nat 表路径)
   ▼
web (nginx:alpine, lab05_default)
   │ proxy_pass http://app:8000   ← embedded DNS 127.0.0.11 解析 "app"
   ▼
app (python, lab05_default)
   │ redis.Redis(host="redis")    ← 同一网络内再解析 "redis"
   ▼
redis (redis:7-alpine, lab05_default)
```

## 第 7 步：破坏演练

```bash
# [Ubuntu VM]
docker compose -p lab05 stop redis
curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://localhost:8085/redis-ping
# 502（app 连不上 redis，异常被 app 捕获后返回 502）

docker compose -p lab05 start redis
sleep 6
curl -s http://localhost:8085/redis-ping
# PONG 恢复
```

注意恢复后 app 不需要重启——healthcheck 是**持续探测**的（每 5 秒一次），app 只是临时故障，从未变 unhealthy。如果把 app `stop` 掉，web 会因为 upstream 不可达返回 502，这是后面排查 K8s readiness 门槛的思维原型：**没就绪就不要接流量**。

## 判分脚本结果

```bash
# [Ubuntu VM]
cd ~/lab05-stack
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: redis 服务运行中且 healthy
PASS: app 服务运行中且 healthy
PASS: web 服务运行中且发布 8085->80
PASS: curl http://localhost:8085/ 返回 hello from app
PASS: curl http://localhost:8085/redis-ping 返回 PONG
PASS: app 容器可解析服务名 redis
PASS: app 服务使用 compose 构建镜像 lab05-app

SCORE: 7/7
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| web 起来但 502 | app 未 healthy 就被访问 / app 名解析失败 | 检查 depends_on 长语法；`docker compose logs app` 看报错 |
| healthcheck 一直 starting | interval 太长或 test 命令在镜像里不存在 | app 镜像没 curl/wget，用 python urllib；缩短 interval |
| `port is already allocated` | 8085 被占用（前面 lab 的容器） | `ss -ltnp | grep 8085` 找到占用者换端口 |
| 改了 compose.yaml 不生效 | up 只对声明变化做增量 | `docker compose -p lab05 up -d --build` 重新收敛 |
| stop redis 后 curl 挂 5 秒才回 | app 的 socket_timeout=2 + 重试 | 属预期行为；生产上应加更短超时与熔断 |

## 清理

```bash
# [Ubuntu VM]
cd ~/lab05-stack
# docker compose -p lab05 down          # 保留容器供复查时不要执行
# docker compose -p lab05 down --rmi local   # 彻底清理时连本地构建镜像一起删
```

## 延伸阅读

- Compose 文件参考：https://docs.docker.com/compose/compose-file/
- Compose 网络与 DNS：https://docs.docker.com/compose/how-tos/networking/
