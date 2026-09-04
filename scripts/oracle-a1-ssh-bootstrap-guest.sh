#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/troc-ssh-bootstrap.log) 2>&1

echo "TROC_SSH_BOOTSTRAP_BEGIN $(date -Is)"
source /tmp/troc-bootstrap.env
: "${PHONE_WG_PUBLIC_KEY:?}"
: "${APP_SOURCE_REF:?}"
: "${TROC_AI_MODEL:?}"
test -s /tmp/gemini.env

apt_retry() {
  local attempt=1
  local max_attempts=60
  local rc=0
  while true; do
    set +e
    "$@"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && return 0
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "APT command still failing after ${attempt} attempts: $*" >&2
      return "$rc"
    fi
    echo "APT busy/transient failure (rc=$rc); retry ${attempt}/${max_attempts} in 5s..."
    attempt=$((attempt + 1))
    sleep 5
  done
}

# Fresh Ubuntu images commonly run apt/cloud-init for a short time after SSH becomes available.
# Retry instead of failing the whole A1 bootstrap on a transient dpkg/apt lock.
apt_retry apt-get update -y
apt_retry apt-get install -y --no-install-recommends \
  ca-certificates curl git jq unzip zip rsync tmux htop ripgrep \
  build-essential python3 python3-pip python3-venv openjdk-17-jdk-headless \
  docker.io gh wireguard-tools iptables iproute2

cat >/etc/sysctl.d/99-troc-vpn.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl --system >/dev/null

install -d -m 700 /etc/wireguard
umask 077
wg genkey > /etc/wireguard/server.key
wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
SERVER_KEY="$(cat /etc/wireguard/server.key)"
WAN_IF="$(ip route show default | awk '{print $5; exit}')"
test -n "$WAN_IF"
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_KEY}
MTU = 1380
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE

[Peer]
# phone-owner
PublicKey = ${PHONE_WG_PUBLIC_KEY}
AllowedIPs = 10.77.0.10/32
EOF
chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/server.key
systemctl enable --now wg-quick@wg0

systemctl enable --now docker
usermod -aG docker ubuntu || true
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt_retry apt-get install -y nodejs
fi
npm install -g npm@latest @google/gemini-cli @openai/codex

if ! swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  [ -f /swapfile ] || { fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096; }
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

install -d -m 700 /etc/troc-ai /var/lib/troc-ai /srv/troc-work/queue /srv/troc-work/running /srv/troc-work/done /srv/troc-work/failed
install -m 600 /tmp/gemini.env /etc/troc-ai/gemini.env
cat >>/etc/troc-ai/gemini.env <<EOF
TROC_AI_MODEL=${TROC_AI_MODEL}
TROC_AI_HOST=10.77.0.1
TROC_AI_PORT=8787
TROC_AI_STATE_DIR=/var/lib/troc-ai
TROC_AI_QUEUE_DIR=/srv/troc-work/queue
EOF
rm -f /tmp/gemini.env /tmp/troc-bootstrap.env

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 --retry-delay 3 "https://github.com/nhatkhoa-jpg/TrocAutoStudio-Releases/archive/refs/heads/${APP_SOURCE_REF}.tar.gz" | tar -xz -C "$tmp"
src="$(find "$tmp" -type d -name troc-ai | head -n1)"
test -n "$src"
node --check "$src/server.mjs"
rm -rf /opt/troc-ai
cp -a "$src" /opt/troc-ai
chown -R root:root /opt/troc-ai
chmod -R go-w /opt/troc-ai
rm -rf "$tmp"
trap - EXIT

cat >/etc/systemd/system/troc-ai.service <<'UNIT'
[Unit]
Description=Trọc AI private mobile gateway
After=network-online.target wg-quick@wg0.service
Wants=network-online.target wg-quick@wg0.service
[Service]
Type=simple
User=root
WorkingDirectory=/opt/troc-ai
EnvironmentFile=/etc/troc-ai/gemini.env
ExecStart=/usr/bin/node /opt/troc-ai/server.mjs
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/troc-ai /srv/troc-work
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNIT

cat >/usr/local/sbin/troc-ai-update <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 --retry-delay 2 https://github.com/nhatkhoa-jpg/TrocAutoStudio-Releases/archive/refs/heads/main.tar.gz | tar -xz -C "$tmp"
src="$(find "$tmp" -type d -name troc-ai | head -n1)"
[ -n "$src" ] || exit 0
node --check "$src/server.mjs"
rm -rf /opt/troc-ai.new
cp -a "$src" /opt/troc-ai.new
chown -R root:root /opt/troc-ai.new
chmod -R go-w /opt/troc-ai.new
rm -rf /opt/troc-ai.prev
[ ! -d /opt/troc-ai ] || mv /opt/troc-ai /opt/troc-ai.prev
mv /opt/troc-ai.new /opt/troc-ai
rm -rf /opt/troc-ai.prev
systemctl restart troc-ai.service
UPDATE
chmod 755 /usr/local/sbin/troc-ai-update
cat >/etc/systemd/system/troc-ai-update.service <<'UNIT'
[Unit]
Description=Update Trọc AI from main
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/troc-ai-update
UNIT
cat >/etc/systemd/system/troc-ai-update.timer <<'UNIT'
[Unit]
Description=Poll Trọc AI updates
[Timer]
OnBootSec=8min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
UNIT

cat >/usr/local/bin/troc-health <<'HEALTH'
#!/usr/bin/env bash
set +e
echo '===TROC_HEALTH_BEGIN==='
uname -a
echo "CPU=$(nproc)"
free -h
df -h /
echo "NODE=$(node --version 2>/dev/null)"
echo "GEMINI=$(gemini --version 2>/dev/null)"
echo "CODEX=$(codex --version 2>/dev/null)"
echo "DOCKER=$(systemctl is-active docker 2>/dev/null)"
echo "WG=$(systemctl is-active wg-quick@wg0 2>/dev/null)"
echo "TROC_AI=$(systemctl is-active troc-ai 2>/dev/null)"
wg show wg0 2>/dev/null
echo '===TROC_HEALTH_END==='
HEALTH
chmod 755 /usr/local/bin/troc-health

systemctl daemon-reload
systemctl enable --now troc-ai.service troc-ai-update.timer
sleep 3
systemctl is-active --quiet wg-quick@wg0
systemctl is-active --quiet docker
systemctl is-active --quiet troc-ai.service
curl -fsS --max-time 10 http://10.77.0.1:8787/api/health | jq -e '.ok==true and .gemini_ready==true' >/dev/null

echo "WG_PUBLIC_KEY=$(cat /etc/wireguard/server.pub)"
echo "TROC_SSH_BOOTSTRAP_READY $(date -Is)"
