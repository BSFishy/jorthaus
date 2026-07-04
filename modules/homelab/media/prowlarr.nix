{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
  prowlarr = cfg.prowlarr;
in
{
  options.homelab.prowlarr = {
    enable = lib.mkEnableOption "Prowlarr on the media host";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9696;
      description = "Prowlarr Web UI port on the media host.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "prowlarr.jort.haus";
      description = "External hostname for Prowlarr.";
    };
  };

  config = lib.mkMerge [
    {
      homelab.services.prowlarr = {
        host = inventory.media;
        port = prowlarr.port;
        hostname = prowlarr.hostname;
        scheme = "http";
      };
    }
    (lib.mkIf prowlarr.enable {
      networking.firewall.allowedTCPPorts = [ prowlarr.port ];

      services.prowlarr = {
        enable = true;
        openFirewall = false;
        settings = {
          auth.method = "External";
          server = {
            port = prowlarr.port;
            bindaddress = "*";
          };
        };
      };
    })
  ];
}
