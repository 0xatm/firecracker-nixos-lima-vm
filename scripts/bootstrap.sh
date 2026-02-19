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
GUEST_MODULE_DIR="/etc/nixos/firecracker-lima-vm"
GUEST_OVERRIDES_PATH="/etc/nixos/fc-bootstrap-overrides.nix"
GUEST_BOOT_CONFIG_PATH="/etc/nixos/fc-bootstrap-config.nix"
GUEST_KEY_PATH="/var/lib/firecracker-microvm/microvm.id_rsa"
GUEST_STAGED_KEY="/tmp/microvm.id_rsa"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_uint() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid ${name}: ${value} (must be an integer)" >&2
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
    y|Y|yes|YES|Yes)
      return 0
      ;;
    *)
      echo "[bootstrap] Aborted; existing '${VM_NAME}' was not deleted."
      exit 1
      ;;
  esac
}

run_in_vm() {
  limactl shell "$VM_NAME" -- bash -lc "$1"
}

wait_for_shell() {
  local i
  for i in $(seq 1 90); do
    if limactl shell "$VM_NAME" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_shell_down() {
  local i
  for i in $(seq 1 60); do
    if ! limactl shell "$VM_NAME" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_file_in_vm() {
  local path="$1"
  local timeout_secs="$2"
  local i
  local loops=$((timeout_secs / 2))

  for i in $(seq 1 "$loops"); do
    if run_in_vm "test -f '$path'" >/dev/null 2>&1; then
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
  echo "[bootstrap] Removing existing '${VM_NAME}' for a clean bootstrap..."
  limactl stop "$VM_NAME" >/dev/null 2>&1 || true
  limactl delete -f "$VM_NAME"
fi

if [[ ! -f "$LIMA_TEMPLATE_PATH" ]]; then
  echo "[bootstrap] Missing Lima template: $LIMA_TEMPLATE_PATH" >&2
  exit 1
fi

TEMP_LIMA_TEMPLATE="$(mktemp "${STATE_DIR}/lima-template.XXXXXX.yaml")"
TEMP_OVERRIDES="$(mktemp "${STATE_DIR}/fc-overrides.XXXXXX.nix")"
TEMP_BOOT_CONFIG="$(mktemp "${STATE_DIR}/fc-boot-config.XXXXXX.nix")"
trap 'rm -f "${TEMP_LIMA_TEMPLATE}" "${TEMP_OVERRIDES}" "${TEMP_BOOT_CONFIG}"' EXIT

cat "$LIMA_TEMPLATE_PATH" >"$TEMP_LIMA_TEMPLATE"
cat >>"$TEMP_LIMA_TEMPLATE" <<EOF_APPEND
cpus: ${LIMA_CPUS}
memory: "${LIMA_MEMORY}"
disk: "${LIMA_DISK}"
EOF_APPEND

cat >"$TEMP_OVERRIDES" <<EOF_APPEND
{ ... }:
{
  firecrackerLima.microvmVcpus = ${MICROVM_VCPUS};
  firecrackerLima.microvmMemMib = ${MICROVM_MEM_MIB};
  firecrackerLima.rootfsSize = "${MICROVM_ROOTFS_SIZE}";
}
EOF_APPEND

cat >"$TEMP_BOOT_CONFIG" <<'EOF_APPEND'
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./firecracker-lima-vm/lima.nix
    ./fc-bootstrap-overrides.nix
    ./firecracker-lima-vm/configuration.nix
  ];
}
EOF_APPEND

echo "[bootstrap] Creating Lima instance '${VM_NAME}' from local template..."
limactl create --yes --name "$VM_NAME" "$TEMP_LIMA_TEMPLATE"
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
  exit 1
fi

if ! run_in_vm "sudo -n true" >/dev/null 2>&1; then
  echo "[bootstrap] Passwordless sudo is required in the Lima guest but is not available." >&2
  exit 1
fi

echo "[bootstrap] Staging NixOS module and scripts in guest..."
run_in_vm "set -euo pipefail; rm -rf '$GUEST_TMP_DIR'; mkdir -p '$GUEST_TMP_DIR'; sudo install -d -m 0755 /etc/nixos '$GUEST_MODULE_DIR/scripts'"

limactl copy \
  "${REPO_ROOT}/nixos/configuration.nix" \
  "${REPO_ROOT}/nixos/lima.nix" \
  "${REPO_ROOT}/nixos/lima-init.nix" \
  "${REPO_ROOT}/nixos/scripts/init-first-run.sh" \
  "${REPO_ROOT}/nixos/scripts/start-stack.sh" \
  "$TEMP_OVERRIDES" \
  "$TEMP_BOOT_CONFIG" \
  "${VM_NAME}:${GUEST_TMP_DIR}/"

run_in_vm "set -euo pipefail; \
  if [ ! -f /etc/nixos/hardware-configuration.nix ]; then \
    echo '[bootstrap] Missing /etc/nixos/hardware-configuration.nix; generating defaults'; \
    sudo nixos-generate-config >/dev/null; \
  fi; \
  sudo install -m 0644 '${GUEST_TMP_DIR}/configuration.nix' '${GUEST_MODULE_DIR}/configuration.nix'; \
  sudo install -m 0644 '${GUEST_TMP_DIR}/lima.nix' '${GUEST_MODULE_DIR}/lima.nix'; \
  sudo install -m 0644 '${GUEST_TMP_DIR}/lima-init.nix' '${GUEST_MODULE_DIR}/lima-init.nix'; \
  sudo install -m 0755 '${GUEST_TMP_DIR}/init-first-run.sh' '${GUEST_MODULE_DIR}/scripts/init-first-run.sh'; \
  sudo install -m 0755 '${GUEST_TMP_DIR}/start-stack.sh' '${GUEST_MODULE_DIR}/scripts/start-stack.sh'; \
  sudo install -m 0644 '${GUEST_TMP_DIR}/$(basename "$TEMP_OVERRIDES")' '$GUEST_OVERRIDES_PATH'; \
  sudo install -m 0644 '${GUEST_TMP_DIR}/$(basename "$TEMP_BOOT_CONFIG")' '$GUEST_BOOT_CONFIG_PATH'"

echo "[bootstrap] Building bootable NixOS generation..."
run_in_vm "set -euo pipefail; sudo env -u NIXOS_INSTALL_BOOTLOADER nixos-rebuild boot -I nixos-config='${GUEST_BOOT_CONFIG_PATH}'"

echo "[bootstrap] Rebooting Lima guest to activate declarative Firecracker services..."
run_in_vm "set -euo pipefail; sudo nohup bash -lc 'sleep 1; reboot' >/dev/null 2>&1 < /dev/null &"

if ! wait_for_shell_down; then
  echo "[bootstrap] Guest never appeared to leave the old session during reboot." >&2
  exit 1
fi

if ! wait_for_shell; then
  echo "[bootstrap] Guest did not come back after reboot." >&2
  exit 1
fi

run_in_vm "set -euo pipefail; \
  sudo systemctl start firecracker-microvm-start.service; \
  sudo systemctl is-enabled firecracker.service firecracker-microvm-init.service firecracker-microvm-start.service >/dev/null; \
  sudo systemctl is-active firecracker.service firecracker-microvm-start.service >/dev/null"

if ! wait_for_file_in_vm "$GUEST_KEY_PATH" 240; then
  echo "[bootstrap] Timed out waiting for generated microVM SSH key at ${GUEST_KEY_PATH}." >&2
  run_in_vm "sudo systemctl --no-pager --full status firecracker-microvm-init.service firecracker-microvm-start.service || true" || true
  exit 1
fi

GUEST_USER="$(run_in_vm "id -un" | tr -d '[:space:]')"
GUEST_GROUP="$(run_in_vm "id -gn" | tr -d '[:space:]')"
if [[ -z "$GUEST_USER" || -z "$GUEST_GROUP" ]]; then
  echo "[bootstrap] Failed to determine guest user/group for key export." >&2
  exit 1
fi

run_in_vm "set -euo pipefail; \
  sudo install -m 0600 -o '${GUEST_USER}' -g '${GUEST_GROUP}' '${GUEST_KEY_PATH}' '${GUEST_STAGED_KEY}'; \
  if [ -f '${GUEST_KEY_PATH}.pub' ]; then \
    sudo install -m 0644 -o '${GUEST_USER}' -g '${GUEST_GROUP}' '${GUEST_KEY_PATH}.pub' '${GUEST_STAGED_KEY}.pub'; \
  fi"

echo "[bootstrap] Exporting microVM SSH key to ${SSH_KEY_PATH}"
limactl copy "${VM_NAME}:${GUEST_STAGED_KEY}" "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"

if run_in_vm "test -f '${GUEST_STAGED_KEY}.pub'" >/dev/null 2>&1; then
  limactl copy "${VM_NAME}:${GUEST_STAGED_KEY}.pub" "${SSH_KEY_PATH}.pub"
fi

run_in_vm "rm -f '${GUEST_STAGED_KEY}' '${GUEST_STAGED_KEY}.pub'" || true

echo "[bootstrap] Complete. Connect with: ./connect.sh"
