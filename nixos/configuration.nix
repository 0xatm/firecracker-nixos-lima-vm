{ lib, pkgs, ... }:
{
  # The Lima VM boot path is managed outside this module; don't try to install
  # or manage a bootloader from the layered Firecracker config.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    firecracker
    curl
    jq
    iproute2
    iptables
    netcat-openbsd
    openssh
    squashfsTools
    e2fsprogs
    util-linux
    gnugrep
    gawk
    coreutils
  ];

  environment.etc."firecracker/env".text = ''
    WORKDIR=/var/lib/firecracker-microvm
    API_SOCKET=/tmp/firecracker.socket
    LOG_PATH=/var/log/firecracker.log
    TAP_DEV=tap0
    TAP_IP=172.16.0.1
    MASK_SHORT=/30
    GUEST_IP=172.16.0.2
    FC_MAC=06:00:AC:10:00:02
    FC_STREAM=v1.13
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/firecracker-microvm 0755 root root -"
    "d /etc/firecracker 0755 root root -"
    "d /etc/firecracker/scripts 0755 root root -"
  ];

  systemd.services.firecracker = {
    description = "Firecracker API daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /tmp/firecracker.socket";
      ExecStart = "${pkgs.firecracker}/bin/firecracker --api-sock /tmp/firecracker.socket";
      Restart = "always";
      RestartSec = 1;
    };
  };

  systemd.services.firecracker-microvm-init = {
    description = "Initialize Firecracker microVM assets on first boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      bash
      coreutils
      curl
      gnugrep
      gawk
      gnused
      openssh
      squashfsTools
      e2fsprogs
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/etc/firecracker/env";
      ExecStart = "/etc/firecracker/scripts/init-first-run.sh";
      RemainAfterExit = true;
    };
  };

  systemd.services.firecracker-microvm-start = {
    description = "Configure and start Firecracker microVM";
    wantedBy = [ "multi-user.target" ];
    requires = [ "firecracker.service" "firecracker-microvm-init.service" ];
    after = [ "firecracker.service" "firecracker-microvm-init.service" ];
    path = with pkgs; [
      bash
      coreutils
      curl
      jq
      iproute2
      iptables
      openssh
      procps
      netcat-openbsd
    ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/etc/firecracker/env";
      ExecStart = "/etc/firecracker/scripts/start-stack.sh";
      TimeoutStartSec = "3min";
      RemainAfterExit = true;
    };
  };
}
