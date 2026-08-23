#!/usr/bin/env bash
# install-docker.sh — 在 Ubuntu 22.04/24.04 上通过 apt 官方源安装 Docker CE + compose-plugin
# 用途：03-docker 模块的练习机。k8s 集群本身用 containerd，不需要本脚本。
#
# 用法：
#   sudo bash install-docker.sh                        # 官方源直连
#   sudo APT_MIRROR=mirrors.aliyun.com DOCKER_MIRROR=https://docker.m.daocloud.io bash install-docker.sh
#   sudo http_proxy=http://192.168.31.2:7890 https_proxy=http://192.168.31.2:7890 bash install-docker.sh
#
# 可选变量（均可在调用时覆盖）：
#   APT_MIRROR      Ubuntu/Docker apt 仓库的镜像站域名，留空用官方 archive.ubuntu.com / download.docker.com
#   DOCKER_MIRROR   Docker Hub registry mirror URL，留空则不配置
#   http_proxy / https_proxy / no_proxy   标准代理变量，会同步写入 Docker daemon 的 systemd drop-in
#
# 幂等：重复执行安全。已安装时跳过安装，只补配置。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

require_root

# ---------------------------------------------------------------------------
# 变量与环境准备
# ---------------------------------------------------------------------------
export APT_MIRROR="${APT_MIRROR:-}"
export DOCKER_MIRROR="${DOCKER_MIRROR:-}"
export http_proxy="${http_proxy:-}"
export https_proxy="${https_proxy:-}"
export no_proxy="${no_proxy:-localhost,127.0.0.1,10.96.0.0/12,172.31.0.0/16,.svc,.cluster.local}"

UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
case "${UBUNTU_CODENAME}" in
  jammy|noble) ;;
  *) log_warn "仅在 Ubuntu 22.04(jammy)/24.04(noble) 验证过，当前: ${UBUNTU_CODENAME}，继续但风险自负" ;;
esac

if [ -n "${http_proxy}${https_proxy}" ]; then
  log_info "检测到代理: http_proxy=${http_proxy:-未设置} https_proxy=${https_proxy:-未设置}"
fi

banner "Step 1/5 · apt 前置依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg

banner "Step 2/5 · 添加 Docker 官方 apt 仓库（或镜像）"
install -m 0755 -d /etc/apt/keyrings
if [ -n "${APT_MIRROR}" ]; then
  # 镜像站目录结构与官方一致：mirrors.aliyun.com/docker-ce/ == download.docker.com/
  DOCKER_APT_HOST="${APT_MIRROR}/docker-ce/linux/ubuntu"
  UBUNTU_APT_HOST="${APT_MIRROR}/ubuntu"
else
  DOCKER_APT_HOST="download.docker.com/linux/ubuntu"
  UBUNTU_APT_HOST="archive.ubuntu.com/ubuntu"
fi
# keyring 只在缺失时下载，保证幂等
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL "https://${DOCKER_APT_HOST}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
else
  log_info "docker.gpg 已存在，跳过"
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://${DOCKER_APT_HOST} ${UBUNTU_CODENAME} stable
EOF

# 用了镜像源时，把 Ubuntu 主源也切过去（原文件备份一次，便于回退）
if [ -n "${APT_MIRROR}" ]; then
  if ! grep -q "${APT_MIRROR}" /etc/apt/sources.list 2>/dev/null; then
    [ -f /etc/apt/sources.list.bak ] || cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
  fi
  # 22.04 传统 sources.list 格式
  sed -i -E "s|https?://[a-z.]+ubuntu\.com/ubuntu|https://${APT_MIRROR}/ubuntu|g" \
    /etc/apt/sources.list 2>/dev/null || true
  # 24.04 的 deb822（*.sources）格式
  sed -i -E "s|URIs: https?://[a-z.]+ubuntu\.com/ubuntu|URIs: https://${APT_MIRROR}/ubuntu|" \
    /etc/apt/sources.list.d/*.sources 2>/dev/null || true
fi
apt-get update -y

banner "Step 3/5 · 安装 docker-ce + compose-plugin"
if pkg_installed docker-ce && pkg_installed docker-compose-plugin; then
  log_ok "docker-ce 与 docker-compose-plugin 已安装，跳过（当前 $(docker --version | cut -d, -f1)）"
else
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

banner "Step 4/5 · daemon.json（registry mirror / 日志上限）与代理 drop-in"
mkdir -p /etc/docker
MIRROR_BLOCK=""
if [ -n "${DOCKER_MIRROR}" ]; then
  MIRROR_BLOCK="  \"registry-mirrors\": [\"${DOCKER_MIRROR}\"],"
  log_info "配置 Docker Hub mirror: ${DOCKER_MIRROR}"
fi
# systemd drop-in 方式配代理（比改 /etc/default/docker 可靠）；仅在有代理时写入
if [ -n "${http_proxy}${https_proxy}" ]; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=${no_proxy}"
EOF
  log_info "已写入 docker.service 代理 drop-in"
fi
cat > /etc/docker/daemon.json <<EOF
{
${MIRROR_BLOCK}
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.17.0.0/16", "size": 24 },
    { "base": "172.18.0.0/16", "size": 24 }
  ]
}
EOF
systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker

banner "Step 5/5 · 验证"
docker --version
docker compose version
systemctl is-active docker >/dev/null && pass "docker 服务 running" || fail "docker 服务未运行"
if docker info 2>/dev/null | grep -q 'Server Version'; then
  pass "docker info 可达 daemon"
else
  fail "docker info 失败，排查: journalctl -u docker -n 50"
fi
# 拉取镜像验证链路（hello-world 极小；失败提示网络而不中断，便于离线环境）
if docker run --rm hello-world 2>/dev/null; then
  pass "hello-world 容器运行成功（拉取+运行链路正常）"
else
  log_warn "hello-world 拉取/运行失败——离线环境属预期；在线环境请检查 mirror/代理后重跑本脚本"
fi
cat <<'EOF'
免 sudo 提示（可选，重新登录生效）:
  sudo usermod -aG docker <你的用户名>
EOF
exit_report
