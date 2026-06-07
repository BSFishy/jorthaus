# Agenix

This repository uses [agenix](https://github.com/ryantm/agenix) for encrypted secret management.

The current intended use is to manage secrets such as:

- Cloudflare API credentials for Traefik DNS challenge usage

## What is wired up

Agenix is integrated in three places.

### Flake input

`flake.nix` includes:

- `inputs.agenix`

### NixOS module integration

The agenix NixOS module is included in the shared module stack used by deployed hosts and the bootstrap image.

### Dev shell tooling

The default dev shell includes the `agenix` CLI, so after entering the flake dev shell you can run agenix commands directly.

## Host decryption identity

Deployed machines are configured to use their SSH host key for agenix decryption.

This is configured in:

- `modules/system/default.nix`

Current setting:

```nix
age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
```

That means a secret intended for a given host should be encrypted to that host's SSH host public key.

## Repository files

### Secret rules file

The agenix rules file is:

- `secrets.nix`

This is where recipients should be declared.

It currently includes:

- the workstation/admin key for `matt`
- comments showing where to add host SSH host public keys later

### Secret file directory

Encrypted secret files should live in:

- `secrets/`

## Cloudflare secret pattern

For Traefik, the current repository uses a single environment file secret:

- `secrets/cloudflare-token.env.age`

The encrypted secret should contain the Cloudflare environment variables directly, for example:

```text
CF_DNS_API_TOKEN=...
CF_ZONE_API_TOKEN=...
```

### Is the Cloudflare account ID needed?

For the current Traefik + Cloudflare DNS challenge setup, the Cloudflare account ID is not needed.

The only Cloudflare credential currently wired into the repository is:

- `CF_DNS_API_TOKEN`

So the separate account ID secret can be removed unless a future integration requires it.

## Traefik integration point

The Traefik module now supports:

- `homelab.traefik.cloudflareCredentialsFile`
- `homelab.traefik.acmeEmail`
- `homelab.traefik.acmeResolverName`

`homelab.traefik.cloudflareCredentialsFile` is intended to point at an agenix secret path, for example:

```nix
homelab.traefik.cloudflareCredentialsFile = config.age.secrets.cloudflare-token-env.path;
```

When set, the decrypted agenix file is added directly to:

- `services.traefik.environmentFiles`

so Traefik can consume the Cloudflare credentials from that decrypted environment file.

If both `cloudflareCredentialsFile` and `acmeEmail` are set, the Traefik module also wires:

- an ACME certificate resolver using the Cloudflare DNS challenge
- router `tls.certResolver` settings for generated routes

This is what allows Traefik to request HTTPS certificates automatically through Cloudflare.

## Infra host example scaffold

`modules/hosts/infra.nix` now wires in:

- `age.secrets.cloudflare-token-env`
- `homelab.traefik.cloudflareCredentialsFile`

using the encrypted Cloudflare token secret.

## Suggested workflow

### 1. Deploy the infra host

Create the VM and let it boot.

### 2. Collect the infra host SSH host public key

From the infra host, get:

- `/etc/ssh/ssh_host_ed25519_key.pub`

For example:

```bash
ssh matt@10.1.4.11 'cat /etc/ssh/ssh_host_ed25519_key.pub'
```

### 3. Add that key to `secrets.nix`

Add a binding such as:

```nix
infra = "ssh-ed25519 AAAA...";
```

Then include that host in the secret recipients, for example:

```nix
"secrets/cloudflare-token.env.age".publicKeys = [ matt infra ];
```

### Adding future hosts

When adding a new host that needs to decrypt secrets:

1. deploy the host
2. fetch its SSH host public key from `/etc/ssh/ssh_host_ed25519_key.pub`
3. add a named binding for that key in `secrets.nix`
4. add that binding to the recipient list of any secrets the host should decrypt

This is the step that is easiest to forget, so it should be part of the normal host bring-up checklist.

### 4. Create or edit the encrypted secret

Use:

```bash
just secret-edit cloudflare-token.env
```

and put in contents like:

```text
CF_DNS_API_TOKEN=...
CF_ZONE_API_TOKEN=...
```

### 5. Set the ACME registration email

In `modules/hosts/infra.nix`, set:

```nix
homelab.traefik.acmeEmail = "you@example.com";
```

### 6. Apply the infra host configuration

```bash
just switch infra
```

## Notes

- Until a host public key is added to `secrets.nix`, that host will not be able to decrypt secrets targeted at it.
- The current repository now wires the infra host to use `secrets/cloudflare-token.env.age` for Traefik environment variables.
- If a new host needs secrets later, remember to add its SSH host public key to `secrets.nix` and include it in the relevant recipient lists.
