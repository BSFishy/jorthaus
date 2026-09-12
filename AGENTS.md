# Jorthaus agent guide

Jorthaus is a declarative NixOS and Kubernetes homelab. Keep durable desired
state in this repository; use operational commands to reconcile it rather than
making unrecorded changes on nodes or in the cluster.

## Layout

- `nix/`: NixOS hosts and reusable modules. `gaia-01` through `gaia-03` run
  k3s and the core services.
- `kubernetes/`: Helmfile releases and local configuration charts.
- `terraform/infra/`: UniFi, Cloudflare, DNS, and network infrastructure.
- `terraform/system/`: platform credentials and external service primitives.
- `terraform/apps/`: Authentik applications, flows, groups, and access policy.
- `terraform/authentik-admin/`: the restricted Terraform service account and
  its RBAC role; this root requires a temporary human-admin token.
- `secrets/`: agenix-encrypted secrets. Never add plaintext secrets to Git,
  manifests, Terraform variables, command history, or output.

## Normal workflow

Read the relevant configuration and `justfile` recipe first. Prefer the
project runners, which provide the expected environment and credentials:

- Nix: `just nix-check`, then `just switch gaia-01` (repeat per affected node).
- Kubernetes: `just k8s-diff <subject>`, then `just k8s-apply <subject>`.
- Terraform: run the matching `just plan-*` before `just apply-*`.

Treat plans, rendered manifests, API responses, and logs as evidence of backend
state. Verify user-visible behavior interactively when that is the outcome
being changed.

## Safety

- Do not use ad-hoc provider calls when a declared runner exists.
- For stateful workloads, freeze writers before modifying data, preserve
  byte-for-byte copies, and validate both transport and application structure.
- Apply cluster-wide networking and node changes incrementally; confirm node
  readiness and affected workloads after each rollout.
- `authentik-admin` is deliberately high privilege. Supply
  `AUTHENTIK_ADMIN_TOKEN` only at runtime, revoke temporary tokens after use,
  and apply that root before granting new capabilities to `terraform/apps`.
- Invitation URLs are bearer credentials: never put them in Terraform state or
  logs.

Keep changes scoped, validate formatting and diffs, stage only relevant files,
and leave unrelated local work untouched.
