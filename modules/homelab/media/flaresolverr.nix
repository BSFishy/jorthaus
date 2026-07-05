{ config, lib, ... }:

let
  cfg = config.homelab;
  flaresolverr = cfg.flaresolverr;
in
{
  options.homelab.flaresolverr = {
    enable = lib.mkEnableOption "FlareSolverr on the media host";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8191;
      description = "HTTP port for FlareSolverr on the media host.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the FlareSolverr port in the host firewall.";
    };
  };

  config = lib.mkIf flaresolverr.enable {
    services.flaresolverr = {
      enable = true;
      inherit (flaresolverr) port openFirewall;
    };

    systemd.services.flaresolverr = {
      after = lib.optionals cfg.piaVpn.enable [ "pia-vpn.service" ];
      requires = lib.optionals cfg.piaVpn.enable [ "pia-vpn.service" ];
    };
  };
}
