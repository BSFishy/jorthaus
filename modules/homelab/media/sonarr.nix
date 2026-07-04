{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
  sonarr = cfg.sonarr;
in
{
  options.homelab.sonarr = {
    enable = lib.mkEnableOption "Sonarr on the media host";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8989;
      description = "Sonarr Web UI port on the media host.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "sonarr.jort.haus";
      description = "External hostname for Sonarr.";
    };

    tvDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/media/tv";
      description = "Root directory for managed TV libraries.";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.qbittorrent.downloadDir}/complete";
      description = "Completed download directory Sonarr should import from.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Shared group for Sonarr and related media-management services.";
    };
  };

  config = lib.mkMerge [
    {
      homelab.services.sonarr = {
        host = inventory.media;
        port = sonarr.port;
        hostname = sonarr.hostname;
        scheme = "http";
      };
    }
    (lib.mkIf sonarr.enable {
    users.groups.${sonarr.group} = { };

    networking.firewall.allowedTCPPorts = [ sonarr.port ];

    services.sonarr = {
      enable = true;
      openFirewall = false;
      group = sonarr.group;
      settings = {
        auth.method = "External";
        server = {
          port = sonarr.port;
          bindaddress = "*";
        };
      };
    };

    systemd.services.sonarr-media-dirs = {
      description = "Prepare media directories for Sonarr";
      after = [ "srv-media.mount" ];
      requires = [ "srv-media.mount" ];
      before = [ "sonarr.service" ];
      requiredBy = [ "sonarr.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m 0775 -o sonarr -g ${sonarr.group} ${sonarr.tvDir}
        install -d -m 0775 -o sonarr -g ${sonarr.group} ${sonarr.downloadDir}
      '';
    };
  })
  ];
}
