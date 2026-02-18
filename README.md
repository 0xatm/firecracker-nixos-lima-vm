# Firecracker-on-Lima (Portable NixOS Stack)

This repository provides a portable, fresh-clone workflow to run a Firecracker microVM inside a NixOS Lima VM on Apple Silicon.

The goal is simple:
1. Clone this repo anywhere.
2. Bootstrap once.
3. Run one connect script from the host and land in the inner Firecracker VM.

## Quick Start

### 1) Install Lima

Use either Homebrew or Nix:

```bash
brew install lima
```

or

```bash
nix-env -iA nixpkgs.lima
```

### 2) Bootstrap the NixOS Lima VM

From the repository root:

```bash
./scripts/bootstrap.sh
```

What bootstrap does:
- removes any existing `fc-nixos` instance first (fresh deterministic bootstrap every run),
- creates a Lima VM from the vendored template at `lima/nixos.yaml` (instance name: `fc-nixos` by default),
- enables nested virtualization (`nestedVirtualization=true`),
- disables default host mounts (no home mount confusion),
- copies `nixos/configuration.nix` as a Firecracker module and layers it on top of the guest's base NixOS config,
- runs `sudo nixos-rebuild switch`,
- first-run service downloads/builds Firecracker guest assets,
- exports the Firecracker guest SSH key to `./.state/ssh/microvm.id_rsa`.

### 3) Connect to the inner Firecracker VM from host

```bash
./connect.sh
```

This script tunnels host SSH through Lima (`ProxyCommand`) and drops you into the Firecracker microVM.

## Daily Use

Start and connect in one step:

```bash
./connect.sh
```

`connect.sh` will:
- start the Lima VM if needed,
- ensure Firecracker services are started inside NixOS,
- open SSH into the inner microVM.

Re-run bootstrap only when you want to re-apply NixOS config/script changes:

```bash
./scripts/bootstrap.sh
```

Stop Lima instance:

```bash
./scripts/stop.sh
```

Reset everything (delete Lima instance + local `.state`):

```bash
./scripts/reset.sh
```

## Notes

- Default Lima instance name is `fc-nixos`.
- Override instance name with `LIMA_INSTANCE_NAME=<name>` for all scripts.
- Override template path with `LIMA_TEMPLATE_PATH=/absolute/path/to/nixos.yaml` if needed.
- `connect.sh` defaults to `root@172.16.0.2` and key `./.state/ssh/microvm.id_rsa`.
- First bootstrap can take several minutes due kernel/rootfs download and image build.
- Bootstrap is destructive for the Lima instance by design (it recreates `fc-nixos` to avoid drift).

## Guide Parity

The automated setup preserves the core requirements from the original Firecracker-on-Lima guide:
- nested virtualization is enabled on Lima (`nestedVirtualization=true`) so `/dev/kvm` is available,
- Firecracker is started with `--api-sock /tmp/firecracker.socket`,
- kernel and rootfs are pulled from the `firecracker-ci/v1.13/<arch>` artifact stream,
- guest networking uses `tap0` with `172.16.0.1/30` and guest `172.16.0.2`,
- host NAT/forwarding is configured and guest default route + DNS are set after boot.

## Repo Structure

- `scripts/bootstrap.sh` - create/start/configure NixOS Lima and apply guest config
- `scripts/stop.sh` - stop Lima instance
- `scripts/reset.sh` - delete Lima instance and local state
- `connect.sh` - host-to-Firecracker SSH helper
- `nixos/configuration.nix` - NixOS configuration applied inside Lima
- `nixos/scripts/init-first-run.sh` - one-time Firecracker guest asset initialization
- `nixos/scripts/start-stack.sh` - per-boot Firecracker + networking startup

## Troubleshooting

Check guest services:

```bash
limactl shell fc-nixos -- sudo systemctl status firecracker firecracker-microvm-init firecracker-microvm-start
```

Follow logs:

```bash
limactl shell fc-nixos -- sudo journalctl -u firecracker -u firecracker-microvm-init -u firecracker-microvm-start -f
```
