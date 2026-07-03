_:

{
  homelab = {
    home-assistant.enable = true;
    mosquitto.enable = true;
    zigbee2mqtt = {
      enable = true;
      serialPort = "/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_fc390a86e549ef118fc7cd8cff00cc63-if00-port0";
    };
  };
}
