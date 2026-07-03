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
  - configured serial device: `/dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_fc390a86e549ef118fc7cd8cff00cc63-if00-port0`
  - frontend port: `8080`
  - external hostname: `zigbee.jort.haus`
  - exposed through Traefik on `infra`
  - current Proxmox expectation: USB passthrough using the `zigbee-coordinator` resource mapping

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
  - hardware acceleration: VA-API via `/dev/dri/renderD128`
  - transcoding behavior: throttling enabled when playback is buffered ahead
  - firmware requirement: redistributable firmware enabled in NixOS for AMD GPU blobs
  - current Proxmox expectation: PCI passthrough using the `amd-igpu` resource mapping as `hostpci0`

- Media storage
  - module: `modules/homelab/media/storage.nix`
  - backend: additional Proxmox VM disk on the Ceph RBD-backed `media` datastore
  - guest device target: `/dev/disk/by-id/virtio-media`
  - partitioning: GPT with one XFS partition
  - filesystem label: `media`
  - mount point: `/srv/media`
  - backup policy: Proxmox backup disabled for this disk because the media payload is reproducible

## Notes

- Only HTTP/HTTPS services that should be reverse proxied are registered in `homelab.services.*`.
- Mosquitto is not registered there because MQTT is not routed through the current Traefik setup.
- Zigbee2MQTT is registered in `homelab.services.*` because its frontend is exposed through Traefik.
- If Mosquitto later needs authenticated users, secrets should be managed through agenix rather than committing credentials in the repo.
- For Zigbee coordinators, prefer a stable guest device path such as `/dev/serial/by-id/...` once the Proxmox passthrough device is identified.
- For Jellyfin GPU acceleration, the guest configuration assumes a render node at `/dev/dri/renderD128`; the Proxmox side must make the AMD iGPU available to the VM.
