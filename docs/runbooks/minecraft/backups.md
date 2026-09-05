---
description: Minecraft backup architecture and validation runbook
---

# Minecraft backups

The Minecraft server uses the itzg `minecraft` chart with the `mcbackup`
sidecar enabled. Backups are restic snapshots stored in Backblaze B2 through the
S3-compatible API.

## Live backup path

- Kubernetes namespace: `minecraft`
- Server release: `minecraft-server`
- Data PVC: `minecraft-server-datadir`
- Backup sidecar: `minecraft-server-mc-backup`
- Backup method: `restic`
- Restic host/name: `vanilla`
- Restic repository prefix: `restic/vanilla/`
- OpenBao source path: `backup/data/minecraft`
- Synced Kubernetes Secret: `minecraft-backup-restic`

Terraform provisions the B2 bucket and application key in
`terraform/system/minecraft-backup.tf`. The generated OpenBao secret contains:

- `restic_repository`
- `restic_password`
- `aws_access_key_id`
- `aws_secret_access_key`
- `aws_endpoint`
- `aws_region`
- `bucket_name`

The `minecraft-config` chart syncs OpenBao data into the Kubernetes Secret by
mounting `SecretProviderClass/minecraft-backup-openbao` in
`Deployment/minecraft-backup-secret-sync`.

## Verify the backup sidecar

```bash
kubectl -n minecraft get deploy minecraft-server minecraft-backup-secret-sync
kubectl -n minecraft get secret minecraft-backup-restic
kubectl -n minecraft logs deploy/minecraft-server -c minecraft-server-mc-backup --tail=200
```

A healthy backup log shows:

- RCON readiness
- `rcon-cli save-off`
- `rcon-cli save-all flush`
- `sync`
- a saved restic snapshot
- `rcon-cli save-on`

## Inspect restic snapshots

Use a temporary pod with the backup Secret mounted as environment variables:

```bash
kubectl -n minecraft run minecraft-restic-debug \
  --image=itzg/mc-backup:latest \
  --restart=Never \
  --env-from=secretRef=minecraft-backup-restic \
  --command -- sh -c 'sleep 3600'

kubectl -n minecraft wait --for=condition=Ready pod/minecraft-restic-debug --timeout=180s
kubectl -n minecraft exec minecraft-restic-debug -- restic snapshots --host vanilla
kubectl -n minecraft exec minecraft-restic-debug -- restic check --read-data-subset=1/20
kubectl -n minecraft delete pod minecraft-restic-debug
```

## Manual PVC safety backup

For high-risk changes, keep a cluster-local PVC copy in addition to restic.
Stop Minecraft before copying the live PVC.

```bash
kubectl -n minecraft scale deploy/minecraft-server --replicas=0
kubectl -n minecraft wait --for=delete pod -l app=minecraft-server --timeout=180s
```

Create a timestamped PVC and copy data inside the cluster with both PVCs mounted
in a temporary pod. Verify file counts, byte counts, and checksums before
restarting Minecraft.

The incident-response backup retained during initial restic setup was:

- `minecraft-server-datadir-backup-20260905t161153z`

## Local archive verification

When exporting a local tarball, create the archive inside the cluster first,
serve it from a temporary HTTP pod, download with retries, and compare SHA256.
Do not trust a tarball until all of these pass:

```bash
gzip -t /path/to/minecraft-data.tar.gz
sha256sum /path/to/minecraft-data.tar.gz
tar -tzf /path/to/minecraft-data.tar.gz | head
```

`kubectl cp` and `kubectl exec ... > file` both use the Kubernetes exec stream;
large transfers can truncate and must be verified with checksums.
