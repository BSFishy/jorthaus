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

## Infra host

The `infra` host currently runs:

- Traefik
  - module: `modules/homelab/infra/traefik.nix`
  - listen ports: `80`, `443`
  - role: reverse proxy and TLS termination for HTTP/HTTPS homelab services

## Notes

- Only HTTP/HTTPS services that should be reverse proxied are registered in `homelab.services.*`.
- Mosquitto is not registered there because MQTT is not routed through the current Traefik setup.
- If Mosquitto later needs authenticated users, secrets should be managed through agenix rather than committing credentials in the repo.
