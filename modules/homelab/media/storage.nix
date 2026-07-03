{ config, lib, ... }:

let
  cfg = config.homelab;
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
    };
  };
}
