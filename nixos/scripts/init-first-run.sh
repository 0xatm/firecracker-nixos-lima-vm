#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/var/lib/firecracker-microvm}"
STATE_FILE="${WORKDIR}/.initialized"
FC_STREAM="${FC_STREAM:-v1.13}"
ROOTFS_SIZE="${ROOTFS_SIZE:-1G}"
TAP_IP="${TAP_IP:-172.16.0.1}"
GUEST_DNS_1="${GUEST_DNS_1:-1.1.1.1}"
GUEST_DNS_2="${GUEST_DNS_2:-8.8.8.8}"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  aarch64|arm64)
    FC_ARCH="aarch64"
    ;;
  x86_64|amd64)
    FC_ARCH="x86_64"
    ;;
  *)
    echo "Unsupported architecture for Firecracker assets: $ARCH_RAW" >&2
    exit 1
    ;;
esac

BASE_PREFIX="firecracker-ci/${FC_STREAM}/${FC_ARCH}"
S3_BUCKET_BASE="https://s3.amazonaws.com/spec.ccfc.min"
KERNEL_LIST_URL="${S3_BUCKET_BASE}/?prefix=${BASE_PREFIX}/vmlinux-5.10&list-type=2"
ROOTFS_LIST_URL="${S3_BUCKET_BASE}/?prefix=${BASE_PREFIX}/ubuntu-&list-type=2"

mkdir -p "$WORKDIR"

if [[ -f "$STATE_FILE" ]]; then
  exit 0
fi

echo "[init] Resolving latest Firecracker kernel + rootfs keys..."
KERNEL_XML="$(curl -fsSL "$KERNEL_LIST_URL")" || {
  echo "[init] Failed to fetch kernel index: ${KERNEL_LIST_URL}" >&2
  exit 1
}

ROOTFS_XML="$(curl -fsSL "$ROOTFS_LIST_URL")" || {
  echo "[init] Failed to fetch rootfs index: ${ROOTFS_LIST_URL}" >&2
  exit 1
}

KERNEL_KEY="$(printf '%s\n' "$KERNEL_XML" \
  | grep -oE "<Key>${BASE_PREFIX}/vmlinux-5\\.10\\.[0-9]{3}</Key>" \
  | sed -e 's#<Key>##' -e 's#</Key>##' \
  | sort -V \
  | tail -1 || true)"

ROOTFS_KEY="$(printf '%s\n' "$ROOTFS_XML" \
  | grep -oE "<Key>${BASE_PREFIX}/ubuntu-[0-9]+\\.[0-9]+\\.squashfs</Key>" \
  | sed -e 's#<Key>##' -e 's#</Key>##' \
  | sort -V \
  | tail -1 || true)"

if [[ -z "$KERNEL_KEY" || -z "$ROOTFS_KEY" ]]; then
  echo "[init] Failed to resolve kernel/rootfs keys from Firecracker artifact index." >&2
  exit 1
fi

KERNEL_URL="${S3_BUCKET_BASE}/${KERNEL_KEY}"
ROOTFS_URL="${S3_BUCKET_BASE}/${ROOTFS_KEY}"

if [[ ! -f "${WORKDIR}/vmlinux" ]]; then
  echo "[init] Downloading kernel: ${KERNEL_URL}"
  curl -fL --retry 3 --retry-delay 2 -o "${WORKDIR}/vmlinux" "$KERNEL_URL"
fi

if [[ ! -f "${WORKDIR}/rootfs.squashfs.upstream" ]]; then
  echo "[init] Downloading rootfs: ${ROOTFS_URL}"
  curl -fL --retry 3 --retry-delay 2 -o "${WORKDIR}/rootfs.squashfs.upstream" "$ROOTFS_URL"
fi

echo "[init] Unpacking rootfs and injecting SSH key..."
rm -rf "${WORKDIR}/squashfs-root"
unsquashfs -d "${WORKDIR}/squashfs-root" "${WORKDIR}/rootfs.squashfs.upstream"

# Ensure fcnet runs on normal boot. The upstream image wires fcnet to sshd,
# but some images use ssh.socket activation instead.
install -d -m 0755 "${WORKDIR}/squashfs-root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/fcnet.service \
  "${WORKDIR}/squashfs-root/etc/systemd/system/multi-user.target.wants/fcnet.service"

# Ensure default route + DNS are in place even if host-side SSH post-boot
# fixups are delayed.
install -d -m 0755 "${WORKDIR}/squashfs-root/usr/local/bin"
cat > "${WORKDIR}/squashfs-root/usr/local/bin/fc-network-fix.sh" <<EOF
#!/bin/sh
set -eu

i=0
while [ "\$i" -lt 30 ]; do
  if ip link show eth0 >/dev/null 2>&1; then
    break
  fi
  i=\$((i + 1))
  sleep 1
done

ip route replace default via ${TAP_IP} dev eth0 || true
printf 'nameserver %s\nnameserver %s\n' '${GUEST_DNS_1}' '${GUEST_DNS_2}' > /etc/resolv.conf
EOF
chmod 0755 "${WORKDIR}/squashfs-root/usr/local/bin/fc-network-fix.sh"

cat > "${WORKDIR}/squashfs-root/etc/systemd/system/fc-network-fix.service" <<'EOF'
[Unit]
Description=Ensure microVM default route and DNS
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fc-network-fix.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ln -sf /etc/systemd/system/fc-network-fix.service \
  "${WORKDIR}/squashfs-root/etc/systemd/system/multi-user.target.wants/fc-network-fix.service"

if [[ ! -f "${WORKDIR}/microvm.id_rsa" ]]; then
  ssh-keygen -q -t rsa -b 4096 -N "" -f "${WORKDIR}/microvm.id_rsa"
fi

install -d -m 0700 "${WORKDIR}/squashfs-root/root/.ssh"
install -m 0600 "${WORKDIR}/microvm.id_rsa.pub" "${WORKDIR}/squashfs-root/root/.ssh/authorized_keys"
chown -R root:root "${WORKDIR}/squashfs-root"

echo "[init] Building ext4 rootfs..."
truncate -s "${ROOTFS_SIZE}" "${WORKDIR}/rootfs.ext4"
mkfs.ext4 -q -F -d "${WORKDIR}/squashfs-root" "${WORKDIR}/rootfs.ext4"

echo "KERNEL_PATH=${WORKDIR}/vmlinux" > "${WORKDIR}/runtime.env"
echo "ROOTFS_PATH=${WORKDIR}/rootfs.ext4" >> "${WORKDIR}/runtime.env"
echo "KEY_PATH=${WORKDIR}/microvm.id_rsa" >> "${WORKDIR}/runtime.env"

touch "$STATE_FILE"
echo "[init] Initialization complete."
