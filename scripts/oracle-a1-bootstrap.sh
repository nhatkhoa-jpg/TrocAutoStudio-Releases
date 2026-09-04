#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git jq unzip zip rsync tmux htop ripgrep \
  build-essential python3 python3-pip python3-venv openjdk-17-jdk-headless \
  docker.io wireguard-tools iptables iproute2 gh

systemctl enable --now docker
usermod -aG docker ubuntu || true

if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
npm install -g npm@latest @google/gemini-cli @openai/codex

if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

cat >/etc/sysctl.d/99-troc-vpn.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl --system >/dev/null

install -d -m 700 /etc/wireguard
if [ ! -s /etc/wireguard/server.key ]; then
  umask 077
  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
fi
WAN_IF="$(ip route show default | awk '{print $5; exit}')"
test -n "$WAN_IF"
SERVER_KEY="$(cat /etc/wireguard/server.key)"
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_KEY}
MTU = 1380
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE
EOF
chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/server.key
systemctl enable --now wg-quick@wg0

install -d -o ubuntu -g ubuntu /opt/troc /srv/troc-work

cat >/usr/local/bin/troc-health <<'HEALTH'
#!/usr/bin/env bash
set -e
echo '===TROC_HEALTH_BEGIN==='
uname -a
echo "CPU=$(nproc)"
free -h
df -h /
echo "NODE=$(node --version 2>/dev/null || true)"
echo "NPM=$(npm --version 2>/dev/null || true)"
echo "GEMINI=$(gemini --version 2>/dev/null || true)"
echo "CODEX=$(codex --version 2>/dev/null || true)"
echo "DOCKER=$(docker --version 2>/dev/null || true)"
echo "DOCKER_SERVICE=$(systemctl is-active docker)"
echo "WG_SERVICE=$(systemctl is-active wg-quick@wg0)"
echo "WG_PUBLIC_KEY=$(cat /etc/wireguard/server.pub)"
wg show wg0
echo '===TROC_HEALTH_END==='
HEALTH
chmod 755 /usr/local/bin/troc-health

/usr/local/bin/troc-health
