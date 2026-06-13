{ config, lib, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.mosquitto = {
    enable = lib.mkEnableOption "Mosquitto MQTT broker";

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "TCP port for the Mosquitto MQTT listener.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.mosquitto.enable [ cfg.mosquitto.port ];

    services.mosquitto = {
      enable = cfg.mosquitto.enable;
      listeners = [
        {
          port = cfg.mosquitto.port;
          omitPasswordAuth = true;
          settings.allow_anonymous = true;
        }
      ];
    };
  };
}
