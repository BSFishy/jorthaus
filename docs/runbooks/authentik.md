---
description: Operate Authentik's direct CSI configuration and scheduled PostgreSQL password rotation
---

# Authentik credentials

Authentik reads its static OpenBao configuration from the Secrets Store CSI
mount at `/run/secrets/jorthaus/static`. Its PostgreSQL login role is
`authentik_app`; the NOLOGIN `authentik` role owns the database and grants the
application role its database privileges.

OpenBao manages the application password through
`postgres/static-creds/authentik-static`. The password rotates every 180 days.

## Terraform application-configuration access

The `terraform` Authentik service account holds the
`jorthaus-terraform-apps` role. The role permits application-configuration
objects managed in `terraform/apps` (applications, proxy providers, flows,
stages, bindings, the embedded outpost, and the disabled bootstrap-account
resource). It has no token or RBAC-administration permissions.

`terraform/authentik-admin` declaratively manages that role, its permissions,
and the service account's role assignment. It runs only with a human-admin API
token supplied through `AUTHENTIK_ADMIN_TOKEN`; the token is never stored in
Terraform or OpenBao. Initialize and import the existing objects once, then
use this root whenever a new application type needs permissions:

```zsh
read -r -s "AUTHENTIK_ADMIN_TOKEN?Human-admin Authentik API token: "
echo
export AUTHENTIK_ADMIN_TOKEN
just import-authentik-admin
just plan-authentik-admin
just apply-authentik-admin
unset AUTHENTIK_ADMIN_TOKEN
```

`jorthaus-admins` remains a manually administered superuser group. Terraform
reads it as a data source for application access bindings; it does not manage
its membership or superuser status. This keeps the application-configuration
token outside the administrative access path.

### Rotate the Terraform API token

The `terraform` API token is stored only at OpenBao path
`authentik/terraform`, key `token`. Authentik API-token expiration is set from
the tenant's **Default token duration** when the token is created; set that
value before creating a replacement token.

1. Create a replacement API token for the `terraform` service account in
   Authentik. Do not use its app password.
2. Write the replacement token without placing it in shell history:

   ```zsh
   read -r -s "NEW_AUTHENTIK_TOKEN?New Authentik API token: "
   echo
   printf '%s' "$NEW_AUTHENTIK_TOKEN" | vault kv put -mount=authentik terraform token=-
   unset NEW_AUTHENTIK_TOKEN
   ```

3. Confirm the replacement works, then revoke the previous API token:

   ```bash
   just plan-apps
   ```

## Scheduled password rotation

PostgreSQL accepts one password per role. A static-role rotation invalidates
the prior password immediately, while CSI mounts refresh asynchronously.
Perform each rotation in a maintenance window and immediately create new
Authentik pods rather than waiting for the CSI rotation poll.

1. Confirm both deployments are available and use direct CSI:

   ```bash
   kubectl -n authentik get deploy authentik-server authentik-worker
   kubectl -n authentik get pods
   ```

2. Rotate the OpenBao static role without printing its credential:

   ```bash
   vault write -f postgres/rotate-role/authentik-static
   ```

3. Immediately create new pods with fresh CSI mounts and wait for both rolling
   rollouts. The deployment strategy keeps existing available replicas until
   replacement pods become Ready.

   ```bash
   kubectl -n authentik rollout restart deploy/authentik-server deploy/authentik-worker
   kubectl -n authentik rollout status deploy/authentik-server --timeout=360s
   kubectl -n authentik rollout status deploy/authentik-worker --timeout=360s
   ```

4. Verify every replacement pod is Ready and inspect recent logs for database
   authentication failures. Test the mounted credentials from a pod without
   printing their values, then confirm the Authentik login flow in a browser.

A container restart inside an existing pod does not create a fresh CSI mount.
Use a Deployment rollout or pod replacement for this procedure.
