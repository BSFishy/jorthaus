{ config, inventory, lib, ... }:

{
  options = {
    homelab.home-assistant = {
      enable = lib.mkEnableOption "Home Assistant";
    };
  };

  config = {
    homelab.services.home-assistant = {
      host = inventory.home;
      port = 8123;
      hostname = "hass.jort.haus";
      scheme = "http";
    };

    services.home-assistant = {
      enable = config.homelab.home-assistant.enable;
      openFirewall = true;
      extraComponents = [
        # Keep NixOS' usual extra integrations and add the MQTT discovery
        # entity domains Zigbee2MQTT publishes.
        "default_config"
        "esphome"
        "met"
        "mqtt"
        "light"
        "sensor"
        "number"
        "select"
        "text"
        "update"
      ];
      extraPackages = ps: with ps; [
        paho-mqtt
        pymetno
        gtts
      ];

      config = {
        http = {
          server_port = 8123;
          use_x_forwarded_for = true;
          trusted_proxies = [
            inventory.infra.ipv4.address
          ];
        };
      };
    };
  };
}
