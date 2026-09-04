#!/usr/bin/env bash
set -Eeuo pipefail

: "${OCI_CONFIG:?}"
: "${OCI_PRIVATE_KEY:?}"
: "${GEMINI_API_KEY:?}"
: "${PHONE_WG_PUBLIC_KEY:?}"

INSTANCE_NAME="${INSTANCE_NAME:-troc-cloud-codex}"
VCN_NAME="${VCN_NAME:-troc-codex-vcn}"
PUBLIC_SUBNET_NAME="${PUBLIC_SUBNET_NAME:-troc-codex-public-subnet}"
SECURITY_LIST_NAME="${SECURITY_LIST_NAME:-troc-codex-public-sl}"
APP_SOURCE_REF="${APP_SOURCE_REF:-work/troc-ai-mobile-v1}"
TROC_AI_MODEL="${TROC_AI_MODEL:-gemini-3.5-flash-lite}"
GUEST_SCRIPT="${GUEST_SCRIPT:-scripts/oracle-a1-ssh-bootstrap-guest.sh}"
A1_SHAPE='VM.Standard.A1.Flex'
A1_OCPUS=2
A1_MEMORY_GB=12
BOOT_GB=50
WG_PORT=51820

test -f "$GUEST_SCRIPT"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-client wireguard-tools netcat-openbsd >/dev/null
python -m pip install --disable-pip-version-check --quiet oci-cli

mkdir -p "$HOME/.oci"
printf '%s\n' "$OCI_PRIVATE_KEY" > "$HOME/.oci/key.pem"
chmod 600 "$HOME/.oci/key.pem"
printf '%s\n' "$OCI_CONFIG" > "$HOME/.oci/config"
if grep -q '^key_file=' "$HOME/.oci/config"; then sed -i "s#^key_file=.*#key_file=$HOME/.oci/key.pem#" "$HOME/.oci/config"; else echo "key_file=$HOME/.oci/key.pem" >> "$HOME/.oci/config"; fi
chmod 600 "$HOME/.oci/config"
export SUPPRESS_LABEL_WARNING=True OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
TENANCY_ID="$(awk -F= '/^tenancy=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$HOME/.oci/config")"
REGION="$(awk -F= '/^region=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$HOME/.oci/config")"
[ -n "$REGION" ] || REGION='ap-singapore-2'
test -n "$TENANCY_ID"

echo "OCI region: $REGION"
RUNNER_IP="$(curl -fsS --max-time 20 https://api.ipify.org)"
test -n "$RUNNER_IP"
echo "Temporary SSH source: $RUNNER_IP/32"

VCN_ID="$(oci network vcn list --compartment-id "$TENANCY_ID" --display-name "$VCN_NAME" --all | jq -r '.data[]|select(."lifecycle-state"=="AVAILABLE")|.id' | head -n1)"
test -n "$VCN_ID"
SUBNET_ID="$(oci network subnet list --compartment-id "$TENANCY_ID" --vcn-id "$VCN_ID" --all | jq -r --arg n "$PUBLIC_SUBNET_NAME" '.data[]|select(."display-name"==$n and ."lifecycle-state"=="AVAILABLE")|.id' | head -n1)"
test -n "$SUBNET_ID"
test "$(oci network subnet get --subnet-id "$SUBNET_ID" --query 'data."prohibit-public-ip-on-vnic"' --raw-output)" = false
SL_ID="$(oci network security-list list --compartment-id "$TENANCY_ID" --vcn-id "$VCN_ID" --all | jq -r --arg n "$SECURITY_LIST_NAME" '.data[]|select(."display-name"==$n and ."lifecycle-state"=="AVAILABLE")|.id' | head -n1)"
test -n "$SL_ID"

WG_ONLY="$(jq -cn --argjson p "$WG_PORT" '[{source:"0.0.0.0/0",protocol:"17",isStateless:false,udpOptions:{destinationPortRange:{min:$p,max:$p}}}]')"
TEMP_INGRESS="$(jq -cn --arg src "$RUNNER_IP/32" --argjson p "$WG_PORT" '[{source:"0.0.0.0/0",protocol:"17",isStateless:false,udpOptions:{destinationPortRange:{min:$p,max:$p}}},{source:$src,protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:22,max:22}}}]')"
EGRESS='[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]'
oci network security-list update --security-list-id "$SL_ID" --ingress-security-rules "$TEMP_INGRESS" --egress-security-rules "$EGRESS" --force >/dev/null

cleanup() {
  set +e
  sudo wg-quick down troc-bootstrap >/dev/null 2>&1 || true
  if [ -n "${TEST_PUB:-}" ] && [ -n "${PUBLIC_IP:-}" ]; then
    ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" "sudo wg set wg0 peer '$TEST_PUB' remove" >/dev/null 2>&1 || true
  fi
  oci network security-list update --security-list-id "$SL_ID" --ingress-security-rules "$WG_ONLY" --egress-security-rules "$EGRESS" --force >/dev/null 2>&1 || true
  rm -f /tmp/a1_ephemeral /tmp/a1_ephemeral.pub /tmp/troc-bootstrap.conf /tmp/gemini.env /tmp/troc-bootstrap.env
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f /tmp/a1_ephemeral
chmod 600 /tmp/a1_ephemeral
SSH_OPTS=(-i /tmp/a1_ephemeral -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

CURRENT="$(oci compute instance list --compartment-id "$TENANCY_ID" --display-name "$INSTANCE_NAME" --all | jq -c '[.data[]|select(."lifecycle-state"!="TERMINATED")]|sort_by(."time-created")|last')"
if [ "$CURRENT" != null ]; then
  OLD_ID="$(jq -r '.id' <<<"$CURRENT")"
  test "$(jq -r '.shape' <<<"$CURRENT")" = "$A1_SHAPE"
  awk -v v="$(jq -r '."shape-config".ocpus' <<<"$CURRENT")" 'BEGIN{exit !(v<=2)}'
  awk -v v="$(jq -r '."shape-config"."memory-in-gbs"' <<<"$CURRENT")" 'BEGIN{exit !(v<=12)}'
  echo "Replacing incomplete A1 $OLD_ID with ephemeral-SSH managed A1."
  oci compute instance terminate --instance-id "$OLD_ID" --preserve-boot-volume false --force >/dev/null
  for _ in $(seq 1 180); do
    S="$(oci compute instance get --instance-id "$OLD_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo TERMINATED)"
    [ "$S" = TERMINATED ] && break
    sleep 5
  done
  test "${S:-}" = TERMINATED
fi

AD="$(oci iam availability-domain list --compartment-id "$TENANCY_ID" --query 'data[0].name' --raw-output)"
IMAGE_ID="$(oci compute image list --compartment-id "$TENANCY_ID" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --shape "$A1_SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 1 --query 'data[0].id' --raw-output)"
test -n "$AD" && test "$AD" != null
test -n "$IMAGE_ID" && test "$IMAGE_ID" != null
CFG="$(jq -cn --argjson c "$A1_OCPUS" --argjson m "$A1_MEMORY_GB" '{ocpus:$c,memoryInGBs:$m}')"

INSTANCE_ID=''
for attempt in 1 2 3 4 5; do
  echo "A1 SSH launch attempt $attempt"
  set +e
  INSTANCE_ID="$(oci compute instance launch --compartment-id "$TENANCY_ID" --availability-domain "$AD" --display-name "$INSTANCE_NAME" --shape "$A1_SHAPE" --shape-config "$CFG" --image-id "$IMAGE_ID" --boot-volume-size-in-gbs "$BOOT_GB" --subnet-id "$SUBNET_ID" --assign-public-ip true --ssh-authorized-keys-file /tmp/a1_ephemeral.pub --query 'data.id' --raw-output 2>/tmp/a1-launch.err)"
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] && [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != null ]; then break; fi
  cat /tmp/a1-launch.err || true
  INSTANCE_ID=''
  sleep 20
done
if [ -z "$INSTANCE_ID" ]; then
  echo 'A1 was not reacquired; no paid fallback attempted.' >&2
  exit 1
fi

for _ in $(seq 1 180); do
  S="$(oci compute instance get --instance-id "$INSTANCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$S" = RUNNING ] && break
  sleep 5
done
test "$S" = RUNNING
VNIC_ID=''
for _ in $(seq 1 60); do
  VNIC_ID="$(oci compute vnic-attachment list --compartment-id "$TENANCY_ID" --instance-id "$INSTANCE_ID" --all | jq -r '.data[0]."vnic-id"//empty')"
  [ -n "$VNIC_ID" ] && break
  sleep 5
done
test -n "$VNIC_ID"
PUBLIC_IP="$(oci network vnic get --vnic-id "$VNIC_ID" --query 'data."public-ip"' --raw-output)"
test -n "$PUBLIC_IP" && test "$PUBLIC_IP" != null
echo "Public A1 running: $PUBLIC_IP"

SSH_READY=0
for _ in $(seq 1 120); do
  if ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" 'echo SSH_READY' 2>/dev/null | grep -q SSH_READY; then SSH_READY=1; break; fi
  sleep 5
done
test "$SSH_READY" -eq 1
echo 'Ephemeral SSH bootstrap channel: READY'

umask 077
printf 'GEMINI_API_KEY=%s\n' "$GEMINI_API_KEY" > /tmp/gemini.env
printf 'PHONE_WG_PUBLIC_KEY=%q\nAPP_SOURCE_REF=%q\nTROC_AI_MODEL=%q\n' "$PHONE_WG_PUBLIC_KEY" "$APP_SOURCE_REF" "$TROC_AI_MODEL" > /tmp/troc-bootstrap.env
scp "${SSH_OPTS[@]}" /tmp/gemini.env /tmp/troc-bootstrap.env "$GUEST_SCRIPT" ubuntu@"$PUBLIC_IP":/tmp/
ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" "sudo mv /tmp/$(basename "$GUEST_SCRIPT") /tmp/oracle-a1-ssh-bootstrap-guest.sh && sudo chmod 700 /tmp/oracle-a1-ssh-bootstrap-guest.sh && sudo bash /tmp/oracle-a1-ssh-bootstrap-guest.sh"

SERVER_PUB="$(ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" 'sudo cat /etc/wireguard/server.pub' | tr -d '\r\n')"
test -n "$SERVER_PUB"
echo "WireGuard server public key: $SERVER_PUB"

wg genkey > /tmp/test-wg.key
wg pubkey < /tmp/test-wg.key > /tmp/test-wg.pub
TEST_PUB="$(cat /tmp/test-wg.pub)"
ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" "sudo wg set wg0 peer '$TEST_PUB' allowed-ips 10.77.0.2/32"
cat >/tmp/troc-bootstrap.conf <<EOF
[Interface]
PrivateKey = $(cat /tmp/test-wg.key)
Address = 10.77.0.2/32
MTU = 1380
[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 10.77.0.0/24
PersistentKeepalive = 25
EOF
sudo install -m 600 /tmp/troc-bootstrap.conf /etc/wireguard/troc-bootstrap.conf
sudo wg-quick up troc-bootstrap

HEALTH=''
for _ in $(seq 1 30); do
  HEALTH="$(curl -fsS --max-time 5 http://10.77.0.1:8787/api/health 2>/dev/null || true)"
  if jq -e '.ok==true and .gemini_ready==true' <<<"$HEALTH" >/dev/null 2>&1; then break; fi
  sleep 2
done
jq -e '.ok==true and .gemini_ready==true' <<<"$HEALTH" >/dev/null
echo "$HEALTH" | jq '{ok,service,model,gemini_ready,active_requests,queued_requests}'

set +e
CHAT_HTTP="$(curl -sS --max-time 120 -o /tmp/chat-smoke.json -w '%{http_code}' -H 'content-type: application/json' -d '{"message":"Chỉ trả lời đúng một từ: OK","history":[],"mode":"chat"}' http://10.77.0.1:8787/api/chat)"
CHAT_RC=$?
set -e
test "$CHAT_RC" -eq 0
if [ "$CHAT_HTTP" = 200 ]; then
  jq -e '.answer|length>0' /tmp/chat-smoke.json >/dev/null
  echo 'Trọc AI live Gemini chat smoke: PASS'
elif [ "$CHAT_HTTP" = 429 ]; then
  echo 'Trọc AI gateway works; Gemini Free returned quota cooldown during smoke.'
else
  cat /tmp/chat-smoke.json || true
  echo "Unexpected chat HTTP $CHAT_HTTP" >&2
  exit 1
fi

ssh "${SSH_OPTS[@]}" ubuntu@"$PUBLIC_IP" "sudo wg set wg0 peer '$TEST_PUB' remove; sudo /usr/local/bin/troc-health | head -n 40"
sudo wg-quick down troc-bootstrap
rm -f /tmp/test-wg.key /tmp/test-wg.pub /etc/wireguard/troc-bootstrap.conf
TEST_PUB=''
oci network security-list update --security-list-id "$SL_ID" --ingress-security-rules "$WG_ONLY" --egress-security-rules "$EGRESS" --force >/dev/null

printf 'RESULT_INSTANCE_ID=%s\nRESULT_PUBLIC_IP=%s\nRESULT_WG_SERVER_PUBLIC_KEY=%s\nRESULT_REGION=%s\n' "$INSTANCE_ID" "$PUBLIC_IP" "$SERVER_PUB" "$REGION"
echo 'A1 ephemeral-SSH bootstrap and private Trọc AI validation succeeded.'
