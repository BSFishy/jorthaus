# OpenBao backup runbook

This runbook covers routine Raft snapshot backups from Gaia-01/02/03 and the
recovery procedure for isolated restore drills.

## Backup design

- Each node has a host-native daily systemd timer at 11:30 UTC. Missed runs do
  not catch up. The service refuses to run during 01:00–05:00
  `America/Chicago`.
- All three nodes check `/v1/sys/leader`; only the current leader takes and
  uploads a snapshot. A follower exits successfully after logging a skip. A
  missing or invalid leader response fails closed.
- The service saves the compressed Raft snapshot under a private runtime
  directory, uploads it directly to Restic, then removes the temporary files.
- The Restic repository is at
  `s3:https://s3.us-east-005.backblazeb2.com/jorthaus-openbao-backups/restic/openbao`.
  Restic client-side encryption protects repository contents; the B2 bucket
  also uses SSE-B2. The application key is restricted to this repository
  prefix and has delete permission for Restic locks and pruning, so treat it as
  destructive.
- Restic keeps one latest snapshot, daily points within 7 days, weekly points
  within 14 days, monthly points within 3 months, and yearly points within one
  year. Weekly pruning runs on Sundays after the scheduled backup.
- The Vault Agent and backup units run as the dedicated `openbao-backup`
  system user. Decrypted runtime credentials are mode `0400` and owned by that
  user; OpenBao's service UID cannot read them. Their encrypted source is
  `secrets/openbao-backup-credentials.age`. The snapshot AppRole role ID and
  SecretID are in separate agenix files. The OpenBao seal key is not in the
  backup; recovery requires the matching key from the separately managed
  recovery path.

## Routine checks

Confirm the cluster is healthy and inspect the scheduled timers:

```bash
kubectl get nodes
for host in gaia-01 gaia-02 gaia-03; do
  ssh "matt@$host.node.jort.haus" \
    'sudo systemctl show -p ActiveState,NextElapseUSecRealtime openbao-raft-backup.timer'
done
```

Run the non-destructive repository check and retention preview on any deployed
node:

```bash
just openbao-backup-verify gaia-01
```

This runs `restic check --read-data`, previews `forget` with `--dry-run`,
updates the local success timestamp from the latest snapshot, and refreshes the
node-exporter textfile metric. Review its output in the unit journal:

```bash
ssh matt@gaia-01.node.jort.haus \
  'sudo journalctl -u openbao-raft-backup-verify.service --since today --no-pager'
```

A successful check reports no repository errors. Review the `forget` preview
for unexpected removals before any scheduled weekly prune. The latest
production dry run kept the oldest daily snapshot and the newest snapshot; it
marked the intermediate same-day manual run for removal. The preview used
`--dry-run`, so no production snapshot has been pruned.

The last-success metric is
`openbao_raft_backup_last_success_timestamp_seconds`. The host-native
`OpenBaoBackupStale` alert fires when the newest recorded backup is older than
36 hours. Backup service failures and inactive timers have separate systemd
alerts. Alertmanager is intentionally routed to `blackhole` until notification
paging is configured.

To request a manual backup, run the host-native service on a Gaia node:

```bash
just openbao-backup-run gaia-02
```

The same leader and Kured-window checks apply. Confirm the selected node is
currently the leader before the manual run; a follower will log a skip. A
successful leader run creates a new Restic snapshot and updates its local
success timestamp.

`just openbao-backup-init <host>` is a one-time repository initialization
operation. Do not rerun it against an existing repository or recreate a
repository to resolve an access error.

## Restore drill

The production repository has passed a full Restic data check and an isolated
restore drill. Treat snapshot files and restored state as sensitive even though
the repository is encrypted. Prefer a B2 key limited to read/list operations
for restore drills; the backup key configured in
`terraform/system/openbao-backup.tf` also grants `writeFiles` and `deleteFiles`
for Restic backup and pruning.

1. Prepare a fresh, isolated recovery environment that cannot write to the
   production OpenBao cluster. Obtain the matching seal key through the
   separately maintained human recovery procedure.
2. Provide a dedicated read-only B2 application key and the Restic password to
   that environment through protected secret files or an equivalent secure
   mechanism. Do not place values in command arguments, shell history, logs, or
   this repository. The configured backup key is destructive; use it for a
   restore drill only after explicit approval, and only with read-only Restic
   commands.
3. Select a snapshot tagged `openbao-raft` for host `jorthaus-openbao`, and
   restore it with Restic into a private temporary directory without acquiring
   a repository lock:

   ```bash
   restic --no-cache --no-lock restore "$snapshot_id" \
     --host=jorthaus-openbao \
     --tag=openbao-raft \
     --target="$restore_dir" \
     --verify
   ```
4. Start a disposable OpenBao Raft cluster with a fresh Raft directory, loopback
   listeners, and network isolation, using the matching seal key. Restore the
   snapshot there without `-force`; never perform the drill against production
   storage or a production-connected network.
5. Verify that the isolated cluster is initialized, unsealed, and active, then
   read a user-selected rotatable canary without printing or exporting its
   value.
6. Record the snapshot ID, restore duration, and verification result without
   recording secret data. Remove temporary credentials and restored artifacts
   using the recovery environment's approved cleanup procedure.

### Latest drill record (2026-10-08 UTC)

- Snapshot `f0b4e29652ec16ae6d5feef725a94e67ae48903468423c00bb5a0c8af7c2630c`
  from `2026-10-07T23:09:01Z` was restored with Restic 0.19.1 and `--verify`.
- OpenBao 2.6.2 restored it into a fresh single-node Raft directory on
  `/run/user/1000` tmpfs, using the matching static seal key. A transient
  user-systemd unit had `PrivateNetwork=yes`; an in-unit check confirmed only
  loopback was available. OpenBao reported initialized, unsealed, and active.
- The `backup/hister-volsync` `aws_secret_access_key` canary was read from the
  isolated clone. Its raw CLI output went through a non-disclosing line check
  and produced a count of one; the value was not displayed or logged.
- Restore duration was not captured. Decrypted credentials, the seal key,
  snapshot file, restored Raft data, and temporary tokens were removed from
  tmpfs; the transient units were collected.
- The B2 key used for listing and restore was the configured backup key, whose
  Terraform capabilities include `writeFiles` and `deleteFiles`; it was not a
  read-only key. Restic was invoked only for `snapshots` and `restore --verify`,
  both with `--no-lock`; no backup, lock, forget, or prune operation was run.
  Future drills should use a dedicated read-only key unless use of the
  destructive backup key is explicitly approved.

Repeat the restore drill periodically and after material changes to OpenBao,
Restic, or the B2 repository configuration.
