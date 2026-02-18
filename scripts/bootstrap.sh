#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_ENV_FILE="${REPO_ROOT}/.bootstrap.env"

if [[ -f "$BOOTSTRAP_ENV_FILE" ]]; then
    echo "[bootstrap] Detected and loading resource overrides from .bootstrap.env"
    set -a
    # shellcheck source=/dev/null
    source "$BOOTSTRAP_ENV_FILE"
    set +a
fi

VM_NAME="${LIMA_INSTANCE_NAME:-fc-nixos}"
STATE_DIR="${REPO_ROOT}/.state"
SSH_KEY_PATH="${STATE_DIR}/ssh/microvm.id_rsa"
LIMA_TEMPLATE_PATH="${LIMA_TEMPLATE_PATH:-${REPO_ROOT}/lima/nixos.yaml}"
LIMA_CPUS="${LIMA_CPUS:-4}"
LIMA_MEMORY="${LIMA_MEMORY:-4GiB}"
LIMA_DISK="${LIMA_DISK:-100GiB}"
MICROVM_VCPUS="${MICROVM_VCPUS:-1}"
MICROVM_MEM_MIB="${MICROVM_MEM_MIB:-1024}"
MICROVM_ROOTFS_SIZE="${MICROVM_ROOTFS_SIZE:-1G}"
GUEST_TMP_DIR="/tmp/fc-bootstrap"
GUEST_KEY_PATH="/var/lib/firecracker-microvm/microvm.id_rsa"
GUEST_STAGED_KEY="/tmp/microvm.id_rsa"
GUEST_STAGED_KEY_PUB="/tmp/microvm.id_rsa.pub"
GUEST_BASE_CONFIG="/etc/nixos/configuration.nix"
GUEST_MODULE_CONFIG="/etc/nixos/firecracker-module.nix"
GUEST_MERGED_CONFIG="/etc/nixos/fc-bootstrap-config.nix"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

instance_exists() {
    limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$VM_NAME"
}

confirm_recreate() {
    if [[ "${FC_BOOTSTRAP_FORCE:-0}" == "1" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        echo "[bootstrap] Existing '${VM_NAME}' detected, but no interactive TTY is available." >&2
        echo "[bootstrap] Re-run with FC_BOOTSTRAP_FORCE=1 to allow non-interactive deletion." >&2
        exit 1
    fi

    local answer
    read -r -p "[bootstrap] Lima instance '${VM_NAME}' exists and will be deleted. Continue? [y/N] " answer
    case "$answer" in
    y | Y | yes | YES | Yes)
        return 0
        ;;
    *)
        echo "[bootstrap] Aborted; existing '${VM_NAME}' was not deleted."
        exit 1
        ;;
    esac
}

require_uint() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Invalid ${name}: ${value} (must be an integer)" >&2
        exit 1
    fi
}

run_in_vm() {
    limactl shell "$VM_NAME" -- bash -lc "$1"
}

wait_for_shell() {
    local i
    for i in $(seq 1 60); do
        if limactl shell "$VM_NAME" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

require_cmd limactl
require_uint "LIMA_CPUS" "$LIMA_CPUS"
require_uint "MICROVM_VCPUS" "$MICROVM_VCPUS"
require_uint "MICROVM_MEM_MIB" "$MICROVM_MEM_MIB"
mkdir -p "${STATE_DIR}/ssh"

if instance_exists; then
    confirm_recreate
    echo "[bootstrap] Removing existing '${VM_NAME}' for a clean deterministic bootstrap..."
    limactl stop "$VM_NAME" >/dev/null 2>&1 || true
    limactl delete -f "$VM_NAME"
fi

if [[ ! -f "$LIMA_TEMPLATE_PATH" ]]; then
    echo "[bootstrap] Missing local Lima template: $LIMA_TEMPLATE_PATH" >&2
    exit 1
fi

TEMP_LIMA_TEMPLATE="$(mktemp "${STATE_DIR}/lima-template.XXXXXX.yaml")"
trap 'rm -f "${TEMP_LIMA_TEMPLATE}"' EXIT

cat "$LIMA_TEMPLATE_PATH" >"$TEMP_LIMA_TEMPLATE"
cat >>"$TEMP_LIMA_TEMPLATE" <<EOF
cpus: ${LIMA_CPUS}
memory: "${LIMA_MEMORY}"
disk: "${LIMA_DISK}"
EOF

echo "[bootstrap] Creating Lima instance '${VM_NAME}' from local template..."
limactl create \
    --yes \
    --name "$VM_NAME" \
    "$TEMP_LIMA_TEMPLATE"

limactl start "$VM_NAME"

if ! wait_for_shell; then
    echo "[bootstrap] Guest shell did not become ready in time." >&2
    echo "[bootstrap] Try: limactl restart ${VM_NAME}" >&2
    exit 1
fi

if ! run_in_vm "test -e /dev/kvm" >/dev/null 2>&1; then
    echo "[bootstrap] /dev/kvm is unavailable inside '${VM_NAME}'." >&2
    echo "[bootstrap] Nested virtualization is required for Firecracker." >&2
    echo "[bootstrap] Confirm with: limactl list -f yaml --all-fields ${VM_NAME} | grep nestedVirtualization" >&2
    echo "[bootstrap] If this still reports true, recreate the VM: ./scripts/reset.sh && ./scripts/bootstrap.sh" >&2
    exit 1
fi

echo "[bootstrap] Copying NixOS config + service scripts into the guest..."
run_in_vm "set -euo pipefail; rm -rf '${GUEST_TMP_DIR}'; mkdir -p '${GUEST_TMP_DIR}'"

limactl copy \
    "${REPO_ROOT}/nixos/configuration.nix" \
    "${REPO_ROOT}/nixos/scripts/init-first-run.sh" \
    "${REPO_ROOT}/nixos/scripts/start-stack.sh" \
    "${VM_NAME}:${GUEST_TMP_DIR}/"

run_in_vm "set -euo pipefail; \
  if command -v sudo >/dev/null 2>&1; then SUDO='sudo'; else SUDO=''; fi; \
  \$SUDO install -d -m 0755 /etc/nixos /etc/firecracker/scripts; \
  if [ ! -f '${GUEST_BASE_CONFIG}' ]; then \
    echo '[bootstrap] Missing base /etc/nixos/configuration.nix; generating default base config'; \
    \$SUDO nixos-generate-config >/dev/null; \
  fi; \
  if [ ! -f '${GUEST_BASE_CONFIG}' ]; then \
    echo '[bootstrap] Failed to create ${GUEST_BASE_CONFIG}' >&2; \
    exit 1; \
  fi; \
  \$SUDO cp '${GUEST_TMP_DIR}/configuration.nix' '${GUEST_MODULE_CONFIG}'; \
  \$SUDO cp '${GUEST_TMP_DIR}/init-first-run.sh' /etc/firecracker/scripts/init-first-run.sh; \
  \$SUDO cp '${GUEST_TMP_DIR}/start-stack.sh' /etc/firecracker/scripts/start-stack.sh; \
  \$SUDO sh -lc \"printf '%s\n' \
    'MICROVM_VCPUS=${MICROVM_VCPUS}' \
    'MICROVM_MEM_MIB=${MICROVM_MEM_MIB}' \
    'ROOTFS_SIZE=${MICROVM_ROOTFS_SIZE}' \
    > /etc/firecracker/env.local\"; \
  \$SUDO chmod 0644 /etc/firecracker/env.local; \
  \$SUDO chmod 0755 /etc/firecracker/scripts/init-first-run.sh /etc/firecracker/scripts/start-stack.sh; \
  \$SUDO sh -lc \"printf '%s\n' '{ ... }:' '{' '  imports = [' '    ${GUEST_BASE_CONFIG}' '    ${GUEST_MODULE_CONFIG}' '  ];' '}' > '${GUEST_MERGED_CONFIG}'\""

echo "[bootstrap] Applying NixOS configuration (nixos-rebuild switch)..."
run_in_vm "set -euo pipefail; \
  if command -v sudo >/dev/null 2>&1; then SUDO='sudo'; else SUDO=''; fi; \
  \$SUDO env -u NIXOS_INSTALL_BOOTLOADER nixos-rebuild switch -I nixos-config='${GUEST_MERGED_CONFIG}'"

echo "[bootstrap] Waiting for first-run initialization to generate SSH key..."
for _ in $(seq 1 180); do
    if run_in_vm "test -f '${GUEST_KEY_PATH}'" >/dev/null 2>&1; then
        break
    fi
    if run_in_vm "systemctl --failed --no-legend 2>/dev/null | grep -q 'firecracker-microvm-init\\.service'" >/dev/null 2>&1; then
        echo "[bootstrap] firecracker-microvm-init.service failed while waiting for key generation." >&2
        run_in_vm "sudo systemctl status firecracker-microvm-init --no-pager -l || true" || true
        run_in_vm "sudo journalctl -u firecracker-microvm-init -n 80 --no-pager || true" || true
        exit 1
    fi
    sleep 2
done

if ! run_in_vm "test -f '${GUEST_KEY_PATH}'" >/dev/null 2>&1; then
    echo "[bootstrap] Timed out waiting for guest key at ${GUEST_KEY_PATH}." >&2
    echo "[bootstrap] Check guest services:" >&2
    echo "  limactl shell ${VM_NAME} -- sudo systemctl status firecracker firecracker-microvm-init firecracker-microvm-start" >&2
    exit 1
fi

echo "[bootstrap] Copying guest SSH key back to host state directory..."
run_in_vm "set -euo pipefail; \
  user_uid=\"\$(id -u)\"; \
  user_gid=\"\$(id -g)\"; \
  sudo install -m 0600 '${GUEST_KEY_PATH}' '${GUEST_STAGED_KEY}'; \
  if [ -f '${GUEST_KEY_PATH}.pub' ]; then \
    sudo install -m 0644 '${GUEST_KEY_PATH}.pub' '${GUEST_STAGED_KEY_PUB}'; \
  fi; \
  sudo chown \"\${user_uid}:\${user_gid}\" '${GUEST_STAGED_KEY}' 2>/dev/null || true; \
  if [ -f '${GUEST_STAGED_KEY_PUB}' ]; then \
    sudo chown \"\${user_uid}:\${user_gid}\" '${GUEST_STAGED_KEY_PUB}' 2>/dev/null || true; \
  fi"

limactl copy "${VM_NAME}:${GUEST_STAGED_KEY}" "${SSH_KEY_PATH}"
chmod 600 "${SSH_KEY_PATH}" || true

if run_in_vm "test -f '${GUEST_STAGED_KEY_PUB}'" >/dev/null 2>&1; then
    limactl copy "${VM_NAME}:${GUEST_STAGED_KEY_PUB}" "${STATE_DIR}/ssh/microvm.id_rsa.pub"
fi

run_in_vm "rm -f '${GUEST_STAGED_KEY}' '${GUEST_STAGED_KEY_PUB}'" >/dev/null 2>&1 || true

echo "[bootstrap] Done. Connect with:"
echo "  ${REPO_ROOT}/connect.sh"
