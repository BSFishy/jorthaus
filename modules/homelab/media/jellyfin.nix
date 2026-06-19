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
  };

  config = {
    homelab.services.jellyfin = {
      host = inventory.media;
      port = cfg.jellyfin.port;
      hostname = cfg.jellyfin.hostname;
      scheme = "http";
    };

    services.jellyfin = {
      enable = cfg.jellyfin.enable;
      openFirewall = cfg.jellyfin.enable;
    };
  };
}
