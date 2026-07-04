{ config, lib, pkgs, ... }:

let
  cfg = config.homelab;
  mediaStorageInit = pkgs.writeShellScriptBin "media-storage-init" ''
    set -euo pipefail

    ${config.system.build.formatScript}
    mkdir -p ${lib.escapeShellArg cfg.media-storage.mountPoint}
    mount_unit=$(systemd-escape --path --suffix=mount ${lib.escapeShellArg cfg.media-storage.mountPoint})
    systemctl start "$mount_unit"
  '';
in
{
  options.homelab.media-storage = {
    enable = lib.mkEnableOption "Ceph-backed media storage for the media host";

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-id/virtio-media";
      description = "Stable block device path for the media data disk.";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/srv/media";
      description = "Filesystem mount point for the Jellyfin media library disk.";
    };

    fsLabel = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Filesystem label for the media library disk.";
    };
  };

  config = lib.mkIf cfg.media-storage.enable {
    disko.devices.disk.media = {
      device = cfg.media-storage.device;
      type = "disk";
      content = {
        type = "gpt";
        partitions.media = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = cfg.media-storage.mountPoint;
            extraArgs = [ "-L" cfg.media-storage.fsLabel ];
          };
        };
      };
    };

    fileSystems.${cfg.media-storage.mountPoint} = {
      device = lib.mkForce "/dev/disk/by-label/${cfg.media-storage.fsLabel}";
      fsType = "xfs";
      options = [
        # Allow the host to boot and switch cleanly before the data disk has
        # been initialized on a freshly recreated VM.
        "nofail"
        "x-systemd.device-timeout=5s"
      ];
    };

    environment.systemPackages = [ mediaStorageInit ];
  };
}
