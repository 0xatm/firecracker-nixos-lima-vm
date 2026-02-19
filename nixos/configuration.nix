{ config, lib, pkgs, ... }:
let
  cfg = config.firecrackerLima;
in
{
  options.firecrackerLima = {
    enable = lib.mkEnableOption "Firecracker stack inside the Lima guest" // {
      default = true;
    };

    workdir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/firecracker-microvm";
    };

    apiSocket = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/firecracker.socket";
    };

    logPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/firecracker.log";
    };

    tapDevice = lib.mkOption {
      type = lib.types.str;
      default = "tap0";
    };

    tapIp = lib.mkOption {
      type = lib.types.str;
      default = "172.16.0.1";
    };

    maskShort = lib.mkOption {
      type = lib.types.str;
      default = "/30";
    };

    guestIp = lib.mkOption {
      type = lib.types.str;
      default = "172.16.0.2";
    };

    guestDns1 = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
    };

    guestDns2 = lib.mkOption {
      type = lib.types.str;
      default = "8.8.8.8";
    };

    guestMac = lib.mkOption {
      type = lib.types.str;
      default = "06:00:AC:10:00:02";
    };

    firecrackerStream = lib.mkOption {
      type = lib.types.str;
      default = "v1.13";
    };

    microvmVcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
    };

    microvmMemMib = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
    };

    rootfsSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
    };
  };

  config = lib.mkIf cfg.enable {
    # Keep the guest boot path declarative and persistent.
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.grub.enable = lib.mkForce true;
    boot.loader.grub.efiSupport = lib.mkDefault true;
    boot.loader.grub.device = lib.mkDefault "nodev";
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

    security.sudo.wheelNeedsPassword = lib.mkDefault false;
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
      WORKDIR=${cfg.workdir}
      API_SOCKET=${cfg.apiSocket}
      LOG_PATH=${cfg.logPath}
      TAP_DEV=${cfg.tapDevice}
      TAP_IP=${cfg.tapIp}
      MASK_SHORT=${cfg.maskShort}
      GUEST_IP=${cfg.guestIp}
      GUEST_DNS_1=${cfg.guestDns1}
      GUEST_DNS_2=${cfg.guestDns2}
      FC_MAC=${cfg.guestMac}
      FC_STREAM=${cfg.firecrackerStream}
      MICROVM_VCPUS=${toString cfg.microvmVcpus}
      MICROVM_MEM_MIB=${toString cfg.microvmMemMib}
      ROOTFS_SIZE=${cfg.rootfsSize}
    '';

    environment.etc."firecracker/scripts/init-first-run.sh" = {
      source = ./scripts/init-first-run.sh;
      mode = "0555";
    };

    environment.etc."firecracker/scripts/start-stack.sh" = {
      source = ./scripts/start-stack.sh;
      mode = "0555";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.workdir} 0755 root root -"
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
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f ${cfg.apiSocket}";
        ExecStart = "${pkgs.firecracker}/bin/firecracker --api-sock ${cfg.apiSocket}";
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
  };
}
