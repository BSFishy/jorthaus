# Routing and DNS

This document describes the current DNS and routing setup for the homelab, along with the intended split-horizon design.

## Goal

The homelab is intended to expose services through a single reverse proxy entrypoint:

- Traefik runs on the `infra` host
- services are addressed by hostname such as `hass.jort.haus`
- the router forwards inbound HTTP/HTTPS traffic to Traefik
- Traefik routes requests to internal services based on hostname

The desired end state is:

- local clients resolve service hostnames to the internal Traefik IP
- external/public DNS resolves the same hostnames to the public IP
- local traffic stays local
- remote traffic enters through the public IP and router port forwarding

This is a classic split-horizon DNS model.

## Current state

## Internal hosts

Current deployable hosts from `inventory.nix`:

- `home` → `10.1.4.10`
- `infra` → `10.1.4.11`
- `media` → `10.1.4.12`

Current network assumptions:

- network: `10.1.0.0/16`
- gateway: `10.1.0.1`

## Reverse proxy host

Traefik currently runs on:

- `infra`
- IP: `10.1.4.11`

Traefik currently listens on:

- port 80
- port 443

This is configured in:

- `modules/homelab/infra/traefik.nix`
- `modules/hosts/infra.nix`

The infra host firewall is opened for:

- TCP 80
- TCP 443

## Current service routes

The currently declared routed services are Home Assistant, Jellyfin, and Zigbee2MQTT.

Defined in:

- `modules/homelab/home/home-assistant.nix`
- `modules/homelab/home/zigbee2mqtt.nix`
- `modules/homelab/media/jellyfin.nix`

Current route data:

### Home Assistant

- hostname: `hass.jort.haus`
- backend host: `home`
- backend IP: `10.1.4.10`
- backend port: `8123`
- backend scheme: `http`

### Jellyfin

- hostname: `jellyfin.jort.haus`
- backend host: `media`
- backend IP: `10.1.4.12`
- backend port: `8096`
- backend scheme: `http`

### Zigbee2MQTT

- hostname: `zigbee.jort.haus`
- backend host: `home`
- backend IP: `10.1.4.10`
- backend port: `8080`
- backend scheme: `http`

Traefik uses this to generate:

- a hostname-based router for `hass.jort.haus`
- a backend pointing to `http://10.1.4.10:8123`
- a hostname-based router for `jellyfin.jort.haus`
- a backend pointing to `http://10.1.4.12:8096`
- a hostname-based router for `zigbee.jort.haus`
- a backend pointing to `http://10.1.4.10:8080`

## Current local DNS setup

Local DNS is currently managed through the UniFi provider in Terraform.

Defined in:

- `terraform/dns.tf`

Current record:

- `*.jort.haus` → `infra` host IP
- current resolved value: `10.1.4.11`

That means the current local DNS model is:

- UniFi provides internal DNS answers

## Current router port forwarding

Router port forwarding is also partially managed through the UniFi provider in Terraform.

Defined in:

- `terraform/dns.tf`

Current managed forward:

- public TCP `443` → `infra` `10.1.4.11:443`

This makes the `infra` Traefik host the current HTTPS ingress target managed by OpenTofu.
- all subdomains under `jort.haus` resolve locally to the internal Traefik host
- internal clients connect directly to Traefik on `infra`
- traffic stays on the LAN and does not need to leave via the public internet

For example:

- `hass.jort.haus` → `10.1.4.11`
- `jellyfin.jort.haus` → `10.1.4.11`
- `zigbee.jort.haus` → `10.1.4.11`

This wildcard local DNS setup means additional routed services under `*.jort.haus` do not need separate local DNS records as long as they should terminate at the same Traefik host.

## Current TLS setup

Traefik is configured to use:

- HTTP on port 80 with redirect to HTTPS
- HTTPS on port 443
- Cloudflare DNS challenge support through agenix-managed secrets

Cloudflare credentials are wired through:

- `modules/hosts/infra.nix`
- `modules/homelab/infra/traefik.nix`
- `secrets/cloudflare-token.env.age`

The intended TLS flow is:

1. Traefik receives a request for a configured hostname
2. Traefik obtains or uses an ACME certificate
3. Traefik terminates TLS
4. Traefik proxies to the backend service on the internal network

## Router / port-forwarding model

The intended ingress model is:

- the router forwards public port 80 to `infra:80`
- the router forwards public port 443 to `infra:443`

Traefik is therefore the single HTTP/HTTPS entrypoint for the homelab.

That means backend hosts such as `home` do not need direct public exposure for these services.

## Intended split-horizon design

The intended design is:

### Internal DNS

Served by the local network / UniFi side.

Examples:

- `hass.jort.haus` → `10.1.4.11`
- `jellyfin.jort.haus` → `10.1.4.11`
- `zigbee.jort.haus` → `10.1.4.11`

Internal clients should hit Traefik directly over the LAN.

### External DNS

The intended external DNS provider is Cloudflare.

The current plan is:

- Cloudflare public DNS will point service hostnames to the public WAN IP
- remote traffic will be proxied through Cloudflare
- Cloudflare-originated traffic will then reach the homelab through the router port forwards to Traefik

Examples:

- `hass.jort.haus` → public WAN IP in Cloudflare DNS
- `jellyfin.jort.haus` → public WAN IP in Cloudflare DNS
- `zigbee.jort.haus` → public WAN IP in Cloudflare DNS

External clients should reach the service through Cloudflare rather than connecting directly to the raw public IP endpoint.

## Why split-horizon is desirable here

This allows:

- local clients to avoid unnecessary public round trips
- local access to continue working even when avoiding external proxying paths
- external access to use the same hostnames as internal access
- one consistent Traefik routing model for both local and remote access

## Request flow examples

### Local client request

1. local client resolves `hass.jort.haus`
2. UniFi/local DNS returns `10.1.4.11`
3. client connects to Traefik on `infra`
4. Traefik matches the hostname
5. Traefik proxies to `http://10.1.4.10:8123`

### Remote client request

1. remote client resolves `hass.jort.haus`
2. Cloudflare/public DNS returns the public-facing record
3. client connects through Cloudflare
4. Cloudflare forwards to the homelab public IP
5. router forwards 80/443 to `10.1.4.11`
6. Traefik matches the hostname
7. Traefik proxies to `http://10.1.4.10:8123`

## Operational guidance

### When adding a new routed service

You will generally need to update all of these layers:

1. Nix service routing declaration
   - add `homelab.services.<name>` metadata
2. backend service host config
   - ensure the service is enabled and reachable on the expected port
3. local DNS
   - point the hostname at the Traefik host internally
4. external DNS
   - point the hostname at the public IP externally
5. Traefik
   - generated automatically from the Nix service registry

## Current assumptions to remember

The current setup assumes:

- Traefik runs only on `infra`
- service hostnames resolve to Traefik, not to backend hosts
- Home Assistant trusts the `infra` host as a reverse proxy
- router forwards HTTP/HTTPS to Traefik
- UniFi local DNS provides a wildcard `*.jort.haus` record pointing to `infra`
- Cloudflare is used for DNS-challenge TLS issuance

## Planned remote access and filtering

The current remote-access plan is:

- Cloudflare public DNS will front public access
- remote traffic should go through Cloudflare
- the homelab should restrict accepted remote ingress to Cloudflare IP ranges

That means the desired end state is:

- local clients use UniFi/local DNS and connect directly to `infra`
- remote clients use Cloudflare-managed public DNS and reach the homelab through Cloudflare
- origin traffic that is not from Cloudflare should be denied for the public-facing HTTP/HTTPS entrypoints

## Future direction

The intended future direction is:

- full split-horizon DNS
- Cloudflare public DNS for remote access
- UniFi/local DNS for internal access
- Cloudflare-proxied remote traffic
- allowlisting Cloudflare IP ranges on the public ingress path
- Traefik as the single ingress point for all HTTP/HTTPS services
- additional services registered through the `homelab.services.*` registry and automatically routed by Traefik
