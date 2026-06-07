# Documentation

This directory contains documentation for the jort.haus homelab.

Use the docs in this directory to understand:

- how the homelab is structured
- how systems are built and deployed
- why particular technical choices were made
- operational expectations and workflows
- future plans and intended direction

## Current docs

- [`disk-images.md`](./disk-images.md) — how VM disk images are built with Nix, which image variant is used, and how those images are consumed by OpenTofu and Proxmox
- [`environment.md`](./environment.md) — repository-side environment configuration and external Proxmox/network assumptions required by the current setup
- [`agenix.md`](./agenix.md) — how agenix is integrated into the repo for encrypted secrets such as Cloudflare credentials

## Expectations

Documentation in this directory should reflect the current state of the repository.
When implementation changes, the related docs should be updated in the same change whenever practical.
