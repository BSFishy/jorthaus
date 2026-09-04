# postgres restore runbook

This runbook covers WAL-G restore inspection, scratch restore, and point-in-time
recovery preparation.

It does not automate destructive cluster replacement. Treat routine backup
creation, disaster recovery, and Patroni replica management as separate
operator workflows.

## Preconditions

Before restoring, verify that:

- the backup repository is reachable
- the target restore path is not the live Patroni data directory
- the live cluster remains untouched during the test
- the target node has the OpenBao-rendered WAL-G env available

Useful checks:

```bash
ssh matt@gaia-01.node.jort.haus 'sudo systemctl status vault-agent-postgres-wal-g --no-pager'
ssh matt@gaia-01.node.jort.haus 'sudo ls -l /run/postgres-wal-g/wal-g.env'
sudo -u patroni /run/current-system/sw/bin/jorthaus-wal-g backup-list --detail --json
```

## Inspect available backups

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni /run/current-system/sw/bin/jorthaus-wal-g backup-list --detail --json
```

To inspect WAL continuity, use a recent `postgres-backup` Job log or launch a
manual backup Job from Kubernetes before the restore drill.

Record the backup name you intend to test.

## Scratch restore preparation

Choose a scratch path on a node with enough free space. The example below uses:

- `/srv/postgres-restore-test/18`

Prepare the directory:

```bash
ssh matt@gaia-01.node.jort.haus
sudo systemctl stop patroni
sudo install -d -m 0700 -o patroni -g patroni /srv/postgres-restore-test
sudo rm -rf /srv/postgres-restore-test/18
sudo install -d -m 0700 -o patroni -g patroni /srv/postgres-restore-test/18
sudo systemctl start patroni
```

This keeps the scratch path separate from the live data directory.

## Restore a backup into the scratch path

Restore the latest backup:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni /run/current-system/sw/bin/jorthaus-wal-g \
  backup-fetch /srv/postgres-restore-test/18 LATEST
```

Restore a specific backup:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni /run/current-system/sw/bin/jorthaus-wal-g \
  backup-fetch /srv/postgres-restore-test/18 <backup-name>
```

## Prepare WAL replay

WAL replay uses the helper wrapper:

- `/run/current-system/sw/bin/jorthaus-wal-g-wal-fetch`

Create recovery settings for replay to the latest available WAL:

```bash
ssh matt@gaia-01.node.jort.haus
sudo tee /srv/postgres-restore-test/18/postgresql.auto.conf >/dev/null <<'EOF'
restore_command = '/run/current-system/sw/bin/jorthaus-wal-g-wal-fetch "%f" "%p"'
recovery_target_timeline = 'latest'
recovery_target_action = 'promote'
EOF
sudo touch /srv/postgres-restore-test/18/recovery.signal
sudo chown patroni:patroni /srv/postgres-restore-test/18/postgresql.auto.conf /srv/postgres-restore-test/18/recovery.signal
sudo chmod 0600 /srv/postgres-restore-test/18/postgresql.auto.conf
```

## Optional point-in-time recovery

Add a target to `postgresql.auto.conf` before starting the restored instance.
For example:

```bash
ssh matt@gaia-01.node.jort.haus
sudo tee -a /srv/postgres-restore-test/18/postgresql.auto.conf >/dev/null <<'EOF'
recovery_target_time = '2026-08-25 00:26:00+00'
EOF
```

Choose a target time that falls inside the retained WAL range.

## Validate the restored files

Basic checks:

```bash
ssh matt@gaia-01.node.jort.haus
sudo find /srv/postgres-restore-test/18 -maxdepth 2 | head
sudo ls -l /srv/postgres-restore-test/18/PG_VERSION
```

If you want deeper validation, start a temporary PostgreSQL instance on an
alternate port with a config outside the live Patroni-managed cluster.

## Patroni interaction

Routine Patroni operations keep using Patroni's own failover and replica
creation paths. WAL-G is the disaster-recovery archive and base-backup source.

That means:

1. Patroni failover does not require WAL-G restore steps.
2. Replica rejoin still follows Patroni's normal replication workflow.
3. WAL-G restore is an operator-driven recovery path for scratch restores,
   point-in-time recovery, or full cluster rebuild.

## Completely lost cluster

A complete cluster rebuild remains a manual recovery procedure.

The recovery shape is:

1. stop Patroni on all PostgreSQL nodes
2. preserve or move aside any surviving data directories
3. choose the node that will become the replacement primary
4. fetch the chosen base backup into that node's PostgreSQL data directory
5. write `restore_command` and any PITR target settings
6. allow PostgreSQL to replay WAL to the desired recovery target and promote
7. re-establish Patroni control around the restored primary
8. re-seed the remaining nodes from the restored primary

Keep the DCS, Patroni bootstrap state, and restored PostgreSQL data under one
operator-controlled change window. Do not point a restored data directory at the
existing live cluster without first isolating the old primary state.

## Cleanup

Remove the scratch restore when finished:

```bash
ssh matt@gaia-01.node.jort.haus
sudo rm -rf /srv/postgres-restore-test
```

## Notes

- `wal-g backup-list` proves that the repository is visible.
- `wal-g wal-verify` checks WAL continuity, not restore correctness.
- A destructive cluster replacement deserves an isolated rehearsal before it is
  used in production.
