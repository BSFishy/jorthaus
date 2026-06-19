# Services

This document records the application services currently enabled through the homelab NixOS modules.

## Home host

The `home` host currently runs:

- Home Assistant
  - module: `modules/homelab/home/home-assistant.nix`
  - listen port: `8123`
  - external hostname: `hass.jort.haus`
  - exposed through Traefik on `infra`

- Mosquitto
  - module: `modules/homelab/home/mosquitto.nix`
  - listen port: `1883`
  - exposure: LAN-only MQTT broker on the `home` host
  - current auth model: anonymous access is enabled

- Zigbee2MQTT
  - module: `modules/homelab/home/zigbee2mqtt.nix`
  - MQTT backend: `mqtt://127.0.0.1:1883` via local Mosquitto
  - default serial device: `/dev/ttyACM0`
  - current expectation: the Zigbee coordinator is passed through from Proxmox to the `home` VM as a USB device

## Infra host

The `infra` host currently runs:

- Traefik
  - module: `modules/homelab/infra/traefik.nix`
  - listen ports: `80`, `443`
  - role: reverse proxy and TLS termination for HTTP/HTTPS homelab services

## Media host

The `media` host currently runs:

- Jellyfin
  - module: `modules/homelab/media/jellyfin.nix`
  - listen port: `8096`
  - external hostname: `jellyfin.jort.haus`
  - exposed through Traefik on `infra`

## Notes

- Only HTTP/HTTPS services that should be reverse proxied are registered in `homelab.services.*`.
- Mosquitto is not registered there because MQTT is not routed through the current Traefik setup.
- Zigbee2MQTT is also internal-only and is not registered in `homelab.services.*`.
- If Mosquitto later needs authenticated users, secrets should be managed through agenix rather than committing credentials in the repo.
- For Zigbee coordinators, prefer a stable guest device path such as `/dev/serial/by-id/...` once the Proxmox passthrough device is identified.
