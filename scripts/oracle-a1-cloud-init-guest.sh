#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/troc-cloud-init.log) 2>&1

echo "TROC_BOOTSTRAP_BEGIN $(date -Is)"
BOOT_CLIENT_PUB='__BOOT_CLIENT_PUB__'
PHONE_PUB='__PHONE_PUB__'
ENROLL_TOKEN='__ENROLL_TOKEN__'
APP_REF='__APP_REF__'
APP_MODEL='__APP_MODEL__'

mkdir -p /var/lib/troc-bootstrap /etc/troc-bootstrap
printf '%s\n' STARTING > /var/lib/troc-bootstrap/status
printf '%s\n' "$BOOT_CLIENT_PUB" > /etc/troc-bootstrap/bootstrap.peer
printf '%s\n' "$ENROLL_TOKEN" > /etc/troc-bootstrap/enroll.token
chmod 600 /etc/troc-bootstrap/enroll.token

# Bring up the private management tunnel before the heavier developer toolchain.
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl python3 wireguard-tools iptables iproute2
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
# bootstrap-validator
PublicKey = ${BOOT_CLIENT_PUB}
AllowedIPs = 10.77.0.2/32

[Peer]
# phone-owner
PublicKey = ${PHONE_PUB}
AllowedIPs = 10.77.0.10/32
EOF
chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/server.key
systemctl enable --now wg-quick@wg0
cp /etc/wireguard/server.pub /var/lib/troc-bootstrap/server.pub
printf '%s\n' WIREGUARD_READY > /var/lib/troc-bootstrap/status

cat >/etc/systemd/system/troc-bootstrap-status.service <<'UNIT'
[Unit]
Description=Temporary Trọc bootstrap status server
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/var/lib/troc-bootstrap
ExecStart=/usr/bin/python3 -m http.server 8788 --bind 0.0.0.0 --directory /var/lib/troc-bootstrap
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now troc-bootstrap-status.service

# Persistent developer/worker toolchain.
apt-get install -y --no-install-recommends git jq unzip zip rsync tmux htop ripgrep build-essential python3-pip python3-venv openjdk-17-jdk-headless docker.io gh
systemctl enable --now docker
usermod -aG docker ubuntu || true
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 --retry-delay 3 "https://github.com/nhatkhoa-jpg/TrocAutoStudio-Releases/archive/refs/heads/${APP_REF}.tar.gz" | tar -xz -C "$tmp"
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
ConditionPathExists=/etc/troc-ai/env
[Service]
Type=simple
User=root
WorkingDirectory=/opt/troc-ai
EnvironmentFile=/etc/troc-ai/env
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

# A1 pulls app-only updates from main. This avoids requiring SSH/Run Command for normal UI upgrades.
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
if [ -f /etc/troc-ai/env ]; then systemctl restart troc-ai.service; fi
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

cat >/usr/local/sbin/troc-remove-bootstrap-peer <<'REMOVE'
#!/usr/bin/env bash
set -euo pipefail
PUB="$(cat /etc/troc-bootstrap/bootstrap.peer)"
wg set wg0 peer "$PUB" remove || true
python3 - "$PUB" <<'PY'
from pathlib import Path
import sys
p=Path('/etc/wireguard/wg0.conf')
pub=sys.argv[1].strip()
text=p.read_text()
blocks=text.split('\n[Peer]\n')
keep=[blocks[0]]
for block in blocks[1:]:
    if f'PublicKey = {pub}' not in block:
        keep.append(block)
p.write_text(keep[0] + ''.join('\n[Peer]\n'+b for b in keep[1:]))
PY
systemctl disable --now troc-enroll.service 2>/dev/null || true
systemctl disable --now troc-bootstrap-status.service 2>/dev/null || true
rm -f /etc/troc-bootstrap/enroll.token
REMOVE
chmod 700 /usr/local/sbin/troc-remove-bootstrap-peer

cat >/usr/local/sbin/troc-enroll.py <<'PY'
import json, os, subprocess, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
TOKEN=open('/etc/troc-bootstrap/enroll.token').read().strip()
MODEL='__APP_MODEL__'
class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        if self.path != '/enroll':
            self.send_error(404); return
        try:
            n=int(self.headers.get('content-length','0'))
            if n < 2 or n > 8192:
                raise ValueError('size')
            data=json.loads(self.rfile.read(n))
            if data.get('token') != TOKEN:
                self.send_error(403); return
            key=str(data.get('key','')).strip()
            if len(key) < 16 or len(key) > 4096:
                raise ValueError('key')
            os.makedirs('/etc/troc-ai', exist_ok=True)
            with open('/etc/troc-ai/env.tmp','w') as f:
                f.write('GEMINI_API_KEY='+key+'\n')
                f.write('TROC_AI_MODEL='+MODEL+'\n')
                f.write('TROC_AI_HOST=10.77.0.1\nTROC_AI_PORT=8787\n')
                f.write('TROC_AI_STATE_DIR=/var/lib/troc-ai\nTROC_AI_QUEUE_DIR=/srv/troc-work/queue\n')
            os.chmod('/etc/troc-ai/env.tmp',0o600)
            os.replace('/etc/troc-ai/env.tmp','/etc/troc-ai/env')
            subprocess.run(['systemctl','daemon-reload'],check=True)
            subprocess.run(['systemctl','enable','--now','troc-ai.service'],check=True)
            subprocess.run(['systemctl','enable','--now','troc-ai-update.timer'],check=True)
            open('/var/lib/troc-bootstrap/status','w').write('ENROLLED\n')
            subprocess.Popen(['systemd-run','--unit=troc-remove-bootstrap-peer','--on-active=180s','/usr/local/sbin/troc-remove-bootstrap-peer'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            body=b'{"ok":true}'
            self.send_response(200)
            self.send_header('content-type','application/json')
            self.send_header('content-length',str(len(body)))
            self.end_headers(); self.wfile.write(body)
            threading.Thread(target=self.server.shutdown,daemon=True).start()
        except Exception:
            self.send_error(400)
HTTPServer(('10.77.0.1',8789),H).serve_forever()
PY
chmod 700 /usr/local/sbin/troc-enroll.py
sed -i "s#__APP_MODEL__#${APP_MODEL}#g" /usr/local/sbin/troc-enroll.py
cat >/etc/systemd/system/troc-enroll.service <<'UNIT'
[Unit]
Description=One-time Trọc AI secret enrollment over WireGuard
After=wg-quick@wg0.service
Requires=wg-quick@wg0.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/troc-enroll.py
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
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
systemctl enable --now troc-enroll.service
printf '%s\n' READY_FOR_ENROLL > /var/lib/troc-bootstrap/status
echo "TROC_BOOTSTRAP_READY $(date -Is)"
