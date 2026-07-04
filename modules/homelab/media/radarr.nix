{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
  radarr = cfg.radarr;
in
{
  options.homelab.radarr = {
    enable = lib.mkEnableOption "Radarr on the media host";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7878;
      description = "Radarr Web UI port on the media host.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "radarr.jort.haus";
      description = "External hostname for Radarr.";
    };

    moviesDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/media/movies";
      description = "Root directory for managed movie libraries.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.qbittorrent.downloadDir}/complete";
      description = "Completed download directory Radarr should import from.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Shared group for Radarr and related media-management services.";
    };
  };

  config = lib.mkMerge [
    {
      homelab.services.radarr = {
        host = inventory.media;
        port = radarr.port;
        hostname = radarr.hostname;
        scheme = "http";
      };
    }
    (lib.mkIf radarr.enable {
    users.groups.${radarr.group} = { };

    networking.firewall.allowedTCPPorts = [ radarr.port ];

    services.radarr = {
      enable = true;
      openFirewall = false;
      group = radarr.group;
      settings = {
        auth.method = "External";
        server = {
          port = radarr.port;
          bindaddress = "*";
        };
      };
    };

    systemd.services.radarr-media-dirs = {
      description = "Prepare media directories for Radarr";
      after = [ "srv-media.mount" ];
      requires = [ "srv-media.mount" ];
      before = [ "radarr.service" ];
      requiredBy = [ "radarr.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m 0775 -o radarr -g ${radarr.group} ${radarr.moviesDir}
        install -d -m 0775 -o radarr -g ${radarr.group} ${radarr.downloadDir}
      '';
    };
  })
  ];
}
