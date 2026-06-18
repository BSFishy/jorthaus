{ config, lib, ... }:

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
  };

  config = lib.mkIf cfg.zigbee2mqtt.enable {
    services.zigbee2mqtt = {
      enable = true;
      settings = {
        mqtt.server = cfg.zigbee2mqtt.mqttServer;
        serial.port = cfg.zigbee2mqtt.serialPort;
      };
    };

    systemd.services.zigbee2mqtt = {
      after = [ "mosquitto.service" ];
      wants = [ "mosquitto.service" ];
      unitConfig.ConditionPathExists = cfg.zigbee2mqtt.serialPort;
    };
  };
}
