#!/usr/bin/env bash
set -euo pipefail

API_SOCKET="${API_SOCKET:-/run/firecracker/firecracker.socket}"
WORKDIR="${WORKDIR:-/var/lib/firecracker-microvm}"
LOG_PATH="${LOG_PATH:-/var/log/firecracker.log}"

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
MASK_SHORT="${MASK_SHORT:-/30}"
GUEST_IP="${GUEST_IP:-172.16.0.2}"
FC_MAC="${FC_MAC:-06:00:AC:10:00:02}"

RUNTIME_ENV="${WORKDIR}/runtime.env"
if [[ -f "$RUNTIME_ENV" ]]; then
  # shellcheck source=/dev/null
  source "$RUNTIME_ENV"
fi

KERNEL_PATH="${KERNEL_PATH:-${WORKDIR}/vmlinux}"
ROOTFS_PATH="${ROOTFS_PATH:-${WORKDIR}/rootfs.ext4}"
KEY_PATH="${KEY_PATH:-${WORKDIR}/microvm.id_rsa}"

for f in "$KERNEL_PATH" "$ROOTFS_PATH" "$KEY_PATH"; do
  if [[ ! -f "$f" ]]; then
    echo "[start] Missing required file: $f" >&2
    exit 1
  fi
done

for _ in $(seq 1 50); do
  [[ -S "$API_SOCKET" ]] && break
  sleep 0.2
done

if [[ ! -S "$API_SOCKET" ]]; then
  echo "[start] Firecracker API socket not available: $API_SOCKET" >&2
  exit 1
fi

if [[ ! -e /dev/kvm ]]; then
  echo "[start] /dev/kvm is missing; nested virtualization is required." >&2
  exit 1
fi

state="$(curl -s --unix-socket "$API_SOCKET" http://localhost/ | jq -r '.state // empty' || true)"
if [[ "$state" == "Running" ]]; then
  echo "[start] microVM is already running; nothing to do."
  exit 0
fi

# Some Firecracker builds don't expose state on GET /. If SSH is already up,
# treat the microVM as running and avoid reconfiguring a live instance.
if ssh -i "$KEY_PATH" -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$GUEST_IP" true >/dev/null 2>&1; then
  echo "[start] Guest SSH is already reachable; assuming microVM is running."
  exit 0
fi

ip link del "$TAP_DEV" 2>/dev/null || true
ip tuntap add dev "$TAP_DEV" mode tap
ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
ip link set dev "$TAP_DEV" up

sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip6tables -P FORWARD ACCEPT >/dev/null 2>&1 || true
iptables -P FORWARD ACCEPT

HOST_IFACE="$(ip -j route list default | jq -r '.[0].dev // empty')"
if [[ -z "$HOST_IFACE" ]]; then
  echo "[start] Failed to detect host default route interface." >&2
  exit 1
fi

iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

fc_put() {
  local path="$1"
  local payload="$2"
  local attempt=1
  local resp http body

  while [[ $attempt -le 5 ]]; do
    resp="$(curl -sS -X PUT --unix-socket "$API_SOCKET" \
      -H 'Content-Type: application/json' \
      --data "$payload" \
      -w $'\n%{http_code}' \
      "http://localhost${path}" || true)"
    http="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
      return 0
    fi

    # If the VM is already started, reconfiguration endpoints return 400.
    if [[ "$body" == *"not supported after starting the microVM"* ]]; then
      echo "[start] ${path} rejected because microVM is already running."
      return 0
    fi

    if [[ $attempt -lt 5 ]]; then
      sleep 0.2
    fi
    attempt=$((attempt + 1))
  done

  echo "[start] Firecracker API PUT ${path} failed (HTTP ${http})." >&2
  if [[ -n "$body" ]]; then
    echo "[start] Response: ${body}" >&2
  fi
  return 1
}

touch "$LOG_PATH"
fc_put "/logger" "{\"log_path\":\"${LOG_PATH}\",\"level\":\"Debug\",\"show_level\":true,\"show_log_origin\":true}" || true

boot_args="console=ttyS0 reboot=k panic=1"
if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
  boot_args="keep_bootcon ${boot_args}"
fi

fc_put "/boot-source" "{\"kernel_image_path\":\"${KERNEL_PATH}\",\"boot_args\":\"${boot_args}\"}"
fc_put "/machine-config" '{"vcpu_count":1,"mem_size_mib":1024,"smt":false}'
fc_put "/drives/rootfs" "{\"drive_id\":\"rootfs\",\"path_on_host\":\"${ROOTFS_PATH}\",\"is_root_device\":true,\"is_read_only\":false}"
fc_put "/network-interfaces/net1" "{\"iface_id\":\"net1\",\"guest_mac\":\"${FC_MAC}\",\"host_dev_name\":\"${TAP_DEV}\"}"

sleep 0.05
fc_put "/actions" '{"action_type":"InstanceStart"}'

echo "[start] Waiting for guest SSH to become reachable..."
ssh_ready=0
probe_count=8
for i in $(seq 1 "$probe_count"); do
  echo "[start] SSH probe ${i}/${probe_count}..."
  if timeout 5s ssh -i "$KEY_PATH" \
    -o ConnectTimeout=3 \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$GUEST_IP" true >/dev/null 2>&1; then
    ssh_ready=1
    break
  fi
  sleep 1
done

if [[ "$ssh_ready" -eq 1 ]]; then
  echo "[start] Guest SSH is reachable; applying route and DNS defaults."
  timeout 12s ssh -i "$KEY_PATH" \
    -o ConnectTimeout=6 \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$GUEST_IP" \
    "ip route replace default via ${TAP_IP} dev eth0" >/dev/null 2>&1 || true
  timeout 12s ssh -i "$KEY_PATH" \
    -o ConnectTimeout=6 \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$GUEST_IP" \
    "printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf" >/dev/null 2>&1 || true
else
  echo "[start] Warning: guest SSH did not become ready within timeout; continuing."
fi

echo "[start] Firecracker microVM stack started."
