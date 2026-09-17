---
description: Operate Forgejo authentication and CSI-delivered runtime credentials
---

# Forgejo operations

Forgejo runs in the `forgejo` namespace. Its single replica uses the
`forgejo-data` SeaweedFS PVC, external PostgreSQL, Authentik OIDC, and the
`forgejo` Kubernetes service account.

## Runtime credential delivery

`SecretProviderClass/forgejo-openbao` mounts OpenBao data into the Forgejo pod
and synchronizes these namespace-local Kubernetes Secrets for the Helm chart:

| Secret | Keys | OpenBao source |
| --- | --- | --- |
| `forgejo-database` | `username`, `password` | `postgres/static-creds/forgejo-static` |
| `forgejo-oidc` | `key`, `secret` | `authentik/data/forgejo-oidc` |
| `forgejo-bootstrap` | `username`, `password` | `forgejo/data/bootstrap` |
| `forgejo-config` | `internal_token`, `lfs_jwt_secret`, `secret_key` | `forgejo/data/config` |

The CSI volume remains mounted in the long-lived Forgejo pod so the synchronized
Secrets stay present. Inspect Secret names and key sets only; never print their
values.

The PostgreSQL role is static. After its password rotates, validate the
refreshed database credential from the workload network path, then perform a
controlled Forgejo rollout because the chart writes environment-sourced values
to `app.ini` during pod initialization.

## OIDC access

Authentik authorizes the Forgejo application through bindings for
`jorthaus-forgejo` and `jorthaus-admins`. The `groups` claim contains only
those two group names, and `jorthaus-admins` maps to Forgejo administrator
permissions.

The Helm chart reconciles an existing OAuth source with `forgejo admin auth
update-oauth`. Optional flags omitted from chart values remain configured on
that existing source. Keep `requiredClaimName` and `requiredClaimValue`
explicitly empty in `kubernetes/forgejo/values/forgejo.yaml` so the chart clears
those source fields.

When diagnosing a failed login:

1. Inspect recent Forgejo pod logs for the OAuth callback outcome.
2. Verify the OAuth source with `forgejo admin auth list --vertical-bars` in the
   Forgejo pod.
3. Start each retry from `https://git.jort.haus/`. OAuth callback URLs are
   single-use; revisiting an earlier callback after a successful redirect can
   produce a session-mismatch HTTP 500.
4. Confirm the browser result interactively. Logs and database records alone do
   not establish that the user completed the login flow.

## Reconciliation checks

Review and apply desired state through the project runners:

```bash
just k8s-diff forgejo
just k8s-apply forgejo
```

Confirm the deployment is Ready, the PVC is Bound, the SSH LoadBalancer retains
`10.1.12.21`, and the HTTPS health endpoint succeeds before accepting traffic.
