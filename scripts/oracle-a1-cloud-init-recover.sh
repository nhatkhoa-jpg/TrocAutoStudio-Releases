#!/usr/bin/env bash
set -Eeuo pipefail

: "${OCI_CONFIG:?}"
: "${OCI_PRIVATE_KEY:?}"
: "${OCI_SSH_PUBLIC_KEY:?}"
: "${GEMINI_API_KEY:?}"
: "${PHONE_WG_PUBLIC_KEY:?}"

INSTANCE_NAME="${INSTANCE_NAME:-troc-cloud-codex}"
VCN_NAME="${VCN_NAME:-troc-codex-vcn}"
PUBLIC_SUBNET_NAME="${PUBLIC_SUBNET_NAME:-troc-codex-public-subnet}"
SECURITY_LIST_NAME="${SECURITY_LIST_NAME:-troc-codex-public-sl}"
A1_SHAPE="VM.Standard.A1.Flex"
A1_OCPUS=2
A1_MEMORY_GB=12
BOOT_GB=50
WG_PORT=51820
STATUS_PORT=8788
APP_PORT=8787
ENROLL_PORT=8789
APP_SOURCE_REF="${APP_SOURCE_REF:-work/troc-ai-mobile-v1}"
TROC_AI_MODEL="${TROC_AI_MODEL:-gemini-3.5-flash-lite}"
GUEST_TEMPLATE="${GUEST_TEMPLATE:-scripts/oracle-a1-cloud-init-guest.sh}"

test -f "$GUEST_TEMPLATE"

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools >/dev/null
python -m pip install --disable-pip-version-check --quiet oci-cli
mkdir -p "$HOME/.oci"
printf '%s\n' "$OCI_PRIVATE_KEY" > "$HOME/.oci/oci_api_key.pem"
chmod 600 "$HOME/.oci/oci_api_key.pem"
printf '%s\n' "$OCI_CONFIG" > "$HOME/.oci/config"
if grep -q '^key_file=' "$HOME/.oci/config"; then
  sed -i "s#^key_file=.*#key_file=$HOME/.oci/oci_api_key.pem#" "$HOME/.oci/config"
else
  echo "key_file=$HOME/.oci/oci_api_key.pem" >> "$HOME/.oci/config"
fi
chmod 600 "$HOME/.oci/config"
export SUPPRESS_LABEL_WARNING=True
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
TENANCY_ID="$(awk -F= '/^tenancy=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config")"
REGION="$(awk -F= '/^region=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config")"
test -n "$TENANCY_ID"
[ -n "$REGION" ] || REGION='ap-singapore-2'
export OCI_TENANCY_OCID="$TENANCY_ID" OCI_REGION="$REGION"

echo "OCI region: $REGION"

umask 077
wg genkey > /tmp/bootstrap-client.key
wg pubkey < /tmp/bootstrap-client.key > /tmp/bootstrap-client.pub
BOOT_CLIENT_PUB="$(cat /tmp/bootstrap-client.pub)"
ENROLL_TOKEN="$(openssl rand -hex 24)"
RUNNER_IP="$(curl -fsS --max-time 20 https://api.ipify.org)"
test -n "$RUNNER_IP"
export BOOT_CLIENT_PUB ENROLL_TOKEN RUNNER_IP APP_SOURCE_REF TROC_AI_MODEL PHONE_WG_PUBLIC_KEY

echo "GitHub validation source: $RUNNER_IP/32"

VCN_ID="$(oci network vcn list --compartment-id "$TENANCY_ID" --display-name "$VCN_NAME" --all | jq -r '.data[] | select(."lifecycle-state"=="AVAILABLE") | .id' | head -n1)"
test -n "$VCN_ID"
SUBNET_ID="$(oci network subnet list --compartment-id "$TENANCY_ID" --vcn-id "$VCN_ID" --all | jq -r --arg n "$PUBLIC_SUBNET_NAME" '.data[] | select(."display-name"==$n and ."lifecycle-state"=="AVAILABLE") | .id' | head -n1)"
test -n "$SUBNET_ID"
IS_PRIVATE="$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."prohibit-public-ip-on-vnic"' --raw-output)"
test "$IS_PRIVATE" = 'false'
SL_ID="$(oci network security-list list --compartment-id "$TENANCY_ID" --vcn-id "$VCN_ID" --all | jq -r --arg n "$SECURITY_LIST_NAME" '.data[] | select(."display-name"==$n and ."lifecycle-state"=="AVAILABLE") | .id' | head -n1)"
test -n "$SL_ID"

WG_ONLY="$(jq -cn --argjson p "$WG_PORT" '[{source:"0.0.0.0/0",protocol:"17",isStateless:false,udpOptions:{destinationPortRange:{min:$p,max:$p}}}]')"
TEMP_INGRESS="$(jq -cn --arg src "$RUNNER_IP/32" --argjson wg "$WG_PORT" --argjson hp "$STATUS_PORT" '[{source:"0.0.0.0/0",protocol:"17",isStateless:false,udpOptions:{destinationPortRange:{min:$wg,max:$wg}}},{source:$src,protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:$hp,max:$hp}}}]')"
EGRESS='[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]'
oci network security-list update --security-list-id "$SL_ID" --ingress-security-rules "$TEMP_INGRESS" --egress-security-rules "$EGRESS" --force >/dev/null

cleanup() {
  set +e
  sudo wg-quick down troc-bootstrap >/dev/null 2>&1 || true
  oci network security-list update --security-list-id "$SL_ID" --ingress-security-rules "$WG_ONLY" --egress-security-rules "$EGRESS" --force >/dev/null 2>&1 || true
  rm -f /tmp/bootstrap-client.key /tmp/bootstrap-client.pub /tmp/troc-bootstrap.conf /tmp/guest-bootstrap.sh /tmp/cloud-init.yaml
}
trap cleanup EXIT

AD="$(oci iam availability-domain list --compartment-id "$TENANCY_ID" --query 'data[0].name' --raw-output)"
IMAGE_ID="$(oci compute image list --compartment-id "$TENANCY_ID" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --shape "$A1_SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 --query 'data[0].id' --raw-output)"
test -n "$AD" && test "$AD" != 'null'
test -n "$IMAGE_ID" && test "$IMAGE_ID" != 'null'

cp "$GUEST_TEMPLATE" /tmp/guest-bootstrap.sh
python3 - <<'PY'
from pathlib import Path
import os
p=Path('/tmp/guest-bootstrap.sh')
s=p.read_text()
repl={
    '__BOOT_CLIENT_PUB__': os.environ['BOOT_CLIENT_PUB'],
    '__PHONE_PUB__': os.environ['PHONE_WG_PUBLIC_KEY'],
    '__ENROLL_TOKEN__': os.environ['ENROLL_TOKEN'],
    '__APP_REF__': os.environ['APP_SOURCE_REF'],
    '__APP_MODEL__': os.environ['TROC_AI_MODEL'],
}
for old,new in repl.items():
    s=s.replace(old,new)
if '__BOOT_' in s or '__PHONE_' in s or '__ENROLL_' in s or '__APP_' in s:
    raise SystemExit('unresolved cloud-init template placeholder')
p.write_text(s)
PY
chmod 700 /tmp/guest-bootstrap.sh
SCRIPT_B64="$(base64 -w0 /tmp/guest-bootstrap.sh)"
cat >/tmp/cloud-init.yaml <<EOF
#cloud-config
package_update: false
write_files:
  - path: /root/troc-bootstrap.sh
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: ${SCRIPT_B64}
runcmd:
  - [bash, /root/troc-bootstrap.sh]
EOF
USER_DATA_B64="$(base64 -w0 /tmp/cloud-init.yaml)"
META="$(jq -cn --arg key "$OCI_SSH_PUBLIC_KEY" --arg ud "$USER_DATA_B64" '{ssh_authorized_keys:$key,user_data:$ud}')"

CURRENT="$(oci compute instance list --compartment-id "$TENANCY_ID" --display-name "$INSTANCE_NAME" --all | jq -c '[.data[] | select(."lifecycle-state" != "TERMINATED")] | sort_by(."time-created") | last')"
if [ "$CURRENT" != 'null' ]; then
  OLD_ID="$(jq -r '.id' <<<"$CURRENT")"
  OLD_SHAPE="$(jq -r '.shape' <<<"$CURRENT")"
  OLD_CPU="$(jq -r '."shape-config".ocpus' <<<"$CURRENT")"
  OLD_RAM="$(jq -r '."shape-config"."memory-in-gbs"' <<<"$CURRENT")"
  test "$OLD_SHAPE" = "$A1_SHAPE"
  awk -v v="$OLD_CPU" 'BEGIN{exit !(v<=2)}'
  awk -v v="$OLD_RAM" 'BEGIN{exit !(v<=12)}'
  echo "Replacing incomplete A1 $OLD_ID with cloud-init managed A1; no overlap."
  oci compute instance terminate --instance-id "$OLD_ID" --preserve-boot-volume false --force >/dev/null
  STATE=''
  for _ in $(seq 1 180); do
    STATE="$(oci compute instance get --instance-id "$OLD_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo TERMINATED)"
    [ "$STATE" = 'TERMINATED' ] && break
    sleep 5
  done
  test "$STATE" = 'TERMINATED'
fi

CFG="$(jq -cn --argjson c "$A1_OCPUS" --argjson m "$A1_MEMORY_GB" '{ocpus:$c,memoryInGBs:$m}')"
INSTANCE_ID=''
for attempt in 1 2 3 4 5; do
  echo "A1 cloud-init launch attempt $attempt"
  set +e
  INSTANCE_ID="$(oci compute instance launch --compartment-id "$TENANCY_ID" --availability-domain "$AD" --display-name "$INSTANCE_NAME" --shape "$A1_SHAPE" --shape-config "$CFG" --image-id "$IMAGE_ID" --boot-volume-size-in-gbs "$BOOT_GB" --subnet-id "$SUBNET_ID" --assign-public-ip true --metadata "$META" --query 'data.id' --raw-output 2>/tmp/a1-launch.err)"
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] && [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != 'null' ]; then break; fi
  cat /tmp/a1-launch.err || true
  INSTANCE_ID=''
  sleep 20
done
if [ -z "$INSTANCE_ID" ]; then
  echo 'A1 was not reacquired. No paid fallback shape was attempted.' >&2
  exit 1
fi

STATE=''
for _ in $(seq 1 180); do
  STATE="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$STATE" = 'RUNNING' ] && break
  sleep 5
done
test "$STATE" = 'RUNNING'
VNIC_ID=''
for _ in $(seq 1 60); do
  VNIC_ID="$(oci compute vnic-attachment list --compartment-id "$TENANCY_ID" --instance-id "$INSTANCE_ID" --all | jq -r '.data[0]."vnic-id" // empty' 2>/dev/null || true)"
  [ -n "$VNIC_ID" ] && break
  sleep 5
done
test -n "$VNIC_ID"
PUBLIC_IP=''
for _ in $(seq 1 60); do
  PUBLIC_IP="$(oci network vnic get --vnic-id "$VNIC_ID" --query 'data."public-ip"' --raw-output 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != 'null' ] && break
  sleep 5
done
test -n "$PUBLIC_IP" && test "$PUBLIC_IP" != 'null'
echo "Public A1 running: $PUBLIC_IP"

SERVER_PUB=''
for _ in $(seq 1 240); do
  SERVER_PUB="$(curl -fsS --max-time 3 "http://${PUBLIC_IP}:${STATUS_PORT}/server.pub" 2>/dev/null | tr -d '\r\n' || true)"
  [ -n "$SERVER_PUB" ] && break
  sleep 5
done
test -n "$SERVER_PUB"
echo "WireGuard server public key: $SERVER_PUB"

cat >/tmp/troc-bootstrap.conf <<EOF
[Interface]
PrivateKey = $(cat /tmp/bootstrap-client.key)
Address = 10.77.0.2/32
MTU = 1380
[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 10.77.0.0/24
PersistentKeepalive = 25
EOF
chmod 600 /tmp/troc-bootstrap.conf
sudo cp /tmp/troc-bootstrap.conf /etc/wireguard/troc-bootstrap.conf
sudo chmod 600 /etc/wireguard/troc-bootstrap.conf
sudo wg-quick up troc-bootstrap

READY=''
for _ in $(seq 1 240); do
  READY="$(curl -fsS --max-time 3 http://10.77.0.1:${STATUS_PORT}/status 2>/dev/null | tr -d '\r\n' || true)"
  echo "Guest bootstrap status: ${READY:-waiting}"
  [ "$READY" = 'READY_FOR_ENROLL' ] && break
  sleep 5
done
test "$READY" = 'READY_FOR_ENROLL'

PAYLOAD="$(jq -cn --arg token "$ENROLL_TOKEN" --arg key "$GEMINI_API_KEY" '{token:$token,key:$key}')"
ENROLL_RESP="$(curl -fsS --max-time 20 -H 'content-type: application/json' -d "$PAYLOAD" http://10.77.0.1:${ENROLL_PORT}/enroll)"
jq -e '.ok==true' <<<"$ENROLL_RESP" >/dev/null
unset PAYLOAD ENROLL_RESP

HEALTH=''
for _ in $(seq 1 60); do
  HEALTH="$(curl -fsS --max-time 4 http://10.77.0.1:${APP_PORT}/api/health 2>/dev/null || true)"
  if jq -e '.ok==true and .gemini_ready==true' <<<"$HEALTH" >/dev/null 2>&1; then break; fi
  sleep 3
done
jq -e '.ok==true and .gemini_ready==true' <<<"$HEALTH" >/dev/null
echo "$HEALTH" | jq '{ok,service,model,gemini_ready,active_requests,queued_requests}'

set +e
CHAT_HTTP="$(curl -sS --max-time 120 -o /tmp/chat-smoke.json -w '%{http_code}' -H 'content-type: application/json' -d '{"message":"Chỉ trả lời đúng một từ: OK","history":[],"mode":"chat"}' http://10.77.0.1:${APP_PORT}/api/chat)"
CHAT_RC=$?
set -e
test "$CHAT_RC" -eq 0
if [ "$CHAT_HTTP" = '200' ]; then
  jq -e '.answer|length>0' /tmp/chat-smoke.json >/dev/null
  echo 'Trọc AI live Gemini chat smoke: PASS'
elif [ "$CHAT_HTTP" = '429' ]; then
  echo 'Trọc AI gateway works; Gemini Free returned quota cooldown during smoke.'
else
  cat /tmp/chat-smoke.json || true
  echo "Unexpected Trọc AI chat HTTP $CHAT_HTTP" >&2
  exit 1
fi

printf 'RESULT_INSTANCE_ID=%s\nRESULT_PUBLIC_IP=%s\nRESULT_WG_SERVER_PUBLIC_KEY=%s\nRESULT_REGION=%s\n' "$INSTANCE_ID" "$PUBLIC_IP" "$SERVER_PUB" "$REGION"
echo 'A1 cloud-init recovery and private Trọc AI validation succeeded.'
