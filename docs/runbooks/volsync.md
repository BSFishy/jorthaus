---
description: VolSync Restic backup, verification, and recovery for Forgejo and Hister
---

# VolSync filesystem backups

VolSync takes Restic filesystem backups of the live SeaweedFS PVCs for Forgejo
and Hister. Each workload uses an independent private Backblaze B2 bucket,
prefix-restricted application key, Restic repository password, OpenBao policy,
and Kubernetes Secret.

| Workload | Namespace | Source PVC | ReplicationSource | Repository Secret | Schedule (UTC) |
| --- | --- | --- | --- | --- | --- |
| Forgejo | `forgejo` | `forgejo-data` | `forgejo-restic` | `forgejo-volsync-restic` | daily 01:30 |
| Hister | `hister` | `hister-data` | `hister-restic` | `hister-volsync-restic` | daily 02:00 |

The sources use `copyMethod: Direct` because SeaweedFS CSI does not provide
clone or snapshot support. A backup reads the live filesystem and is therefore
not a storage-level point-in-time image.

Forgejo remains online during backups. Git objects are immutable, but a backup
can omit concurrent ref or metadata updates; run repository integrity checks on
a restored copy before accepting a recovery. Hister's relational state is in
PostgreSQL, so recovering Hister requires a PostgreSQL recovery point that is
compatible with the restored Hister filesystem.

## Credentials

Terraform manages the B2 storage and OpenBao data in `terraform/system/volsync.tf`.
The dedicated mover identities have access only to their own OpenBao path:

| Workload | OpenBao path | ServiceAccount | SecretProviderClass |
| --- | --- | --- | --- |
| Forgejo | `backup/data/forgejo-volsync` | `forgejo-volsync` | `forgejo-volsync-openbao` |
| Hister | `backup/data/hister-volsync` | `hister-volsync` | `hister-volsync-openbao` |

The long-lived `*-volsync-secret-sync` Deployment mounts the
`SecretProviderClass` and materializes the repository Secret consumed by mover
Pods. Inspect Secret names and key sets only; never print Secret values.

## Check scheduled backups

```bash
kubectl -n forgejo get replicationsource forgejo-restic
kubectl -n hister get replicationsource hister-restic
```

A healthy source reports `WaitingForSchedule`, a successful
`latestMoverStatus.result`, and a future `nextSyncTime`:

```bash
kubectl -n forgejo get replicationsource forgejo-restic \
  -o jsonpath='{.status.latestMoverStatus.result} {.status.lastSyncTime} {.status.nextSyncTime}{"\n"}'
kubectl -n hister get replicationsource hister-restic \
  -o jsonpath='{.status.latestMoverStatus.result} {.status.lastSyncTime} {.status.nextSyncTime}{"\n"}'
```

Inspect the current resource status and recent mover Pods when a run fails:

```bash
kubectl -n forgejo get replicationsource forgejo-restic -o yaml
kubectl -n forgejo get pods | grep volsync-src
kubectl -n hister get replicationsource hister-restic -o yaml
kubectl -n hister get pods | grep volsync-src
```

Mover logs can contain repository paths and filesystem names. Do not use commands
that print Kubernetes Secret data or environment variables.

## Run an on-demand backup

A manual trigger temporarily replaces the schedule. First wait until no
synchronization is in progress, choose a unique non-secret identifier, then
patch the source:

```bash
id="manual-$(date -u +%Y%m%dT%H%M%SZ)"
kubectl -n forgejo patch replicationsource forgejo-restic --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"${id}\"}}}"
```

Wait for `.status.lastManualSync` to equal the chosen identifier and for a
successful mover result. Reconcile the Helm-managed schedule immediately after
the manual run:

```bash
just k8s-apply forgejo
```

Use the equivalent commands for Hister, substituting namespace and source name.
Do not start a second trigger while `Synchronizing=True`.

## Restore drill

A restore always targets a new, empty PVC. Never restore over a production PVC.
Create a `ReplicationDestination` in the same namespace as the repository
Secret with:

- a new 20Gi `seaweedfs-storage` `ReadWriteOnce` PVC;
- `restic.repository` set to the workload's repository Secret;
- `restic.destinationPVC` set to the new PVC;
- `copyMethod: Direct`;
- the workload's dedicated mover ServiceAccount and matching mover security
  context; and
- a unique `trigger.manual` value.

Wait for `WaitingForManual`, a populated `lastSyncTime`, and
`latestMoverStatus.result: Successful`. Mount the restored PVC read-only in a
temporary validation Pod running as the workload's UID/GID.

Validate Forgejo's restored configuration and run `git fsck --no-progress` for
every restored bare repository. Validate Hister's index directories, rules,
file count, and size; then validate it with a PostgreSQL recovery point in an
isolated environment before accepting it for application recovery.

The tested one-shot restore durations are approximately 23 seconds for Forgejo
and 19 minutes 23 seconds for Hister. Account for the Hister duration when
planning an incident recovery window.

After validation, delete the temporary validation Pods, the
`ReplicationDestination`, its cache PVC, and the restored PVC. Keep the source
PVC and the Restic repository untouched.

## Credential rotation

Rotate B2 credentials and the Restic password through Terraform and OpenBao;
do not create replacement values in manifests or shell history.

1. Run `just plan-system` and apply the approved Terraform change.
2. Restart the workload's `*-volsync-secret-sync` Deployment so it remounts the
   updated OpenBao data, then wait for its rollout.
3. Verify only the key set of the synchronized repository Secret.
4. Run and verify an on-demand backup before retiring any old credential.
5. Reconcile the scheduled source with `just k8s-apply forgejo` or
   `just k8s-apply hister`.

## Monitoring

No metrics or alerting stack is currently configured for VolSync. Until one is
available, check `lastSyncTime`, `nextSyncTime`, and mover status regularly.
Future alerting covers failed runs, overdue replications, and Restic prune
failures.
