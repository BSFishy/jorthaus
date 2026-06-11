{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.<service> = {
    enable = lib.mkEnableOption "<Service Name>";

    hostname = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "<service>.jort.haus";
      description = "External hostname for <Service Name>.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Listen port for <Service Name>.";
    };
  };

  config = {
    homelab.services.<service> = lib.mkIf cfg.<service>.enable {
      host = inventory.<host>;
      port = cfg.<service>.port;
      hostname = cfg.<service>.hostname;
      scheme = "http";
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.<service>.enable [ cfg.<service>.port ];

    services.<service> = {
      enable = cfg.<service>.enable;
      port = cfg.<service>.port;
    };
  };
}
