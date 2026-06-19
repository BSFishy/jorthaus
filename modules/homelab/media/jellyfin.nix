{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.jellyfin = {
    enable = lib.mkEnableOption "Jellyfin";

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin.jort.haus";
      description = "External hostname for Jellyfin.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8096;
      description = "Listen port for Jellyfin.";
    };

    renderDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/renderD128";
      description = "Render device Jellyfin should use for VA-API hardware acceleration.";
    };
  };

  config = {
    homelab.services.jellyfin = {
      host = inventory.media;
      port = cfg.jellyfin.port;
      hostname = cfg.jellyfin.hostname;
      scheme = "http";
    };

    hardware.enableRedistributableFirmware = cfg.jellyfin.enable;
    hardware.graphics.enable = cfg.jellyfin.enable;

    services.jellyfin = {
      enable = cfg.jellyfin.enable;
      openFirewall = cfg.jellyfin.enable;
      forceEncodingConfig = true;

      hardwareAcceleration = {
        enable = cfg.jellyfin.enable;
        type = "vaapi";
        device = cfg.jellyfin.renderDevice;
      };

      transcoding = {
        enableHardwareEncoding = true;
        hardwareDecodingCodecs = {
          h264 = true;
          hevc = true;
          mpeg2 = true;
          vc1 = true;
          vp8 = true;
          vp9 = true;
        };
        hardwareEncodingCodecs = {
          hevc = true;
        };
      };
    };
  };
}
