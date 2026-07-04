# Services

This document records the application services currently enabled through the homelab NixOS modules.

## Home host

The `home` host currently runs:

- Home Assistant
  - module: `modules/homelab/home/home-assistant.nix`
  - listen port: `8123`
  - external hostname: `hass.jort.haus`
  - exposed through Traefik on `infra`
  - enabled integrations in repo include MQTT support and the Home Assistant mobile app integration
  - the mobile app integration is also explicitly enabled in Home Assistant config via `mobile_app: {}` so app registration endpoints are active
  - UI-managed automations, scripts, and scenes are loaded from `automations.yaml`, `scripts.yaml`, and `scenes.yaml`

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

- PIA VPN
  - module: `modules/homelab/media/pia-vpn.nix`
  - backend: `rcambrj/nix-pia-vpn` WireGuard-based PIA integration
  - tunnel interface: `wg0`
  - host networking model: outbound traffic from `media` is intended to use the VPN by default
  - local-network exceptions: destinations in `10.1.0.0/16` and `192.168.2.0/24` stay local so homelab-internal traffic does not hairpin through PIA
  - DNS bootstrap: `media` is pinned to the local gateway DNS resolver (`10.1.0.1`) so PIA bootstrap and normal host DNS keep working on the LAN
  - routing model: policy routing sends general outbound traffic through the PIA table while keeping the current PIA public control endpoints and local subnets reachable outside the tunnel as needed for bootstrap and local access
  - region selection: currently pinned to `us_chicago`; `maxLatency = 10.0` remains configured but is irrelevant while the region is pinned
  - current simplification: no extra kill-switch layer and PIA port forwarding remains disabled for now
  - credentials: `age.secrets.pia-media-env` decrypts `secrets/pia-media.env.age` on `media`

- qBittorrent
  - module: `modules/homelab/media/qbittorrent.nix`
  - Web UI port: `8081`
  - exposure: direct access on the `media` host only; not currently routed through Traefik
  - startup ordering: waits for `pia-vpn.service`
  - Web UI auth model: authentication is currently bypassed for all client subnets
  - default completed-download path: `/srv/media/downloads/complete`
  - default incomplete-download path: `/srv/media/downloads/incomplete`
  - shared permissions model: runs with the shared `media` group so Sonarr and Radarr can import from the completed-download directory

- Prowlarr
  - module: `modules/homelab/media/prowlarr.nix`
  - Web UI port: `9696`
  - external hostname: `prowlarr.jort.haus`
  - exposed through Traefik on `infra`
  - auth model: configured for external auth handling, matching the current Sonarr/Radarr pattern

- Sonarr
  - module: `modules/homelab/media/sonarr.nix`
  - Web UI port: `8989`
  - external hostname: `sonarr.jort.haus`
  - exposed through Traefik on `infra`
  - library root prepared by the repo: `/srv/media/tv`
  - completed-download source path prepared by the repo: `/srv/media/downloads/complete`
  - shared permissions model: uses the shared `media` group so it can import qBittorrent downloads into the TV library

- Radarr
  - module: `modules/homelab/media/radarr.nix`
  - Web UI port: `7878`
  - external hostname: `radarr.jort.haus`
  - exposed through Traefik on `infra`
  - library root prepared by the repo: `/srv/media/movies`
  - completed-download source path prepared by the repo: `/srv/media/downloads/complete`
  - shared permissions model: uses the shared `media` group so it can import qBittorrent downloads into the movie library

- Media storage
  - module: `modules/homelab/media/storage.nix`
  - backend: additional Proxmox VM disk on the Ceph RBD-backed `media` datastore
  - guest device target: `/dev/disk/by-id/virtio-media`
  - partitioning: GPT with one XFS partition
  - filesystem label: `media`
  - mount point: `/srv/media`
  - backup policy: Proxmox backup disabled for this disk because the media payload is reproducible
  - operational note: the `/srv/media` mount is `nofail` so a freshly recreated VM can boot before the blank disk is initialized
  - host helper: `/run/current-system/sw/bin/media-storage-init` formats the configured media disk if needed, creates `/srv/media`, and then starts the systemd mount unit
  - initialization workflow after recreating `media` with a fresh blank data disk: run `just switch media`, then `just media-storage-init`

## Notes

- Only HTTP/HTTPS services that should be reverse proxied are registered in `homelab.services.*`.
- Mosquitto is not registered there because MQTT is not routed through the current Traefik setup.
- Zigbee2MQTT is registered in `homelab.services.*` because its frontend is exposed through Traefik.
- If Mosquitto later needs authenticated users, secrets should be managed through agenix rather than committing credentials in the repo.
- For Zigbee coordinators, prefer a stable guest device path such as `/dev/serial/by-id/...` once the Proxmox passthrough device is identified.
- For Jellyfin GPU acceleration, the guest configuration assumes a render node at `/dev/dri/renderD128`; the Proxmox side must make the AMD iGPU available to the VM.
- For the PIA VPN on `media` to authenticate successfully, `secrets/pia-media.env.age` must contain valid `PIA_USER` and `PIA_PASS` values before running `just switch media`.
