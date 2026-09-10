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
