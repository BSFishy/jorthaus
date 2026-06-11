{ config, lib, pkgs, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.<service> = {
    enable = lib.mkEnableOption "<Service Name>";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Listen port for <Service Name>.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.<service>.enable [ cfg.<service>.port ];

    systemd.services.<service> = lib.mkIf cfg.<service>.enable {
      description = "<Service Name>";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig.ExecStart = pkgs.writeShellScript "run-<service>" ''
        exec ${pkgs.bash}/bin/bash -lc 'echo starting <service> on port ${toString cfg.<service>.port}; sleep infinity'
      '';
    };
  };
}
