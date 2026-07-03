{ config, inventory, lib, ... }:

let
  cfg = config.homelab;
in
{
  options.homelab.zigbee2mqtt = {
    enable = lib.mkEnableOption "Zigbee2MQTT";

    serialPort = lib.mkOption {
      type = lib.types.str;
      default = "/dev/ttyACM0";
      description = "Serial device path for the Zigbee coordinator passed through to the home VM.";
    };

    mqttServer = lib.mkOption {
      type = lib.types.str;
      default = "mqtt://127.0.0.1:${toString cfg.mosquitto.port}";
      description = "MQTT broker URL used by Zigbee2MQTT.";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = "zigbee.jort.haus";
      description = "External hostname for the Zigbee2MQTT frontend.";
    };

    frontendPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Listen port for the Zigbee2MQTT frontend.";
    };
  };

  config = lib.mkMerge [
    {
      homelab.services.zigbee2mqtt = {
        host = inventory.home;
        port = cfg.zigbee2mqtt.frontendPort;
        hostname = cfg.zigbee2mqtt.hostname;
        scheme = "http";
      };
    }
    (lib.mkIf cfg.zigbee2mqtt.enable {
      networking.firewall.allowedTCPPorts = [ cfg.zigbee2mqtt.frontendPort ];

      services.zigbee2mqtt = {
        enable = true;
        settings = {
          mqtt.server = cfg.zigbee2mqtt.mqttServer;
          serial = {
            port = cfg.zigbee2mqtt.serialPort;
            adapter = "zstack";
          };
          availability.enabled = true;
          advanced.last_seen = "ISO_8601_local";
          frontend = {
            enabled = true;
            host = "0.0.0.0";
            port = cfg.zigbee2mqtt.frontendPort;
          };
        };
      };

      systemd.services.zigbee2mqtt = {
        after = [ "mosquitto.service" ];
        wants = [ "mosquitto.service" ];
        unitConfig.ConditionPathExists = cfg.zigbee2mqtt.serialPort;
      };
    })
  ];
}
