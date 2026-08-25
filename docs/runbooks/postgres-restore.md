# postgres restore runbook

This runbook covers pgBackRest restore inspection and a scratch restore workflow.

It does not rejoin a restored data directory to the live Patroni cluster. Treat
restore validation as a separate operation from cluster recovery.

## Preconditions

Before restoring, verify that:

- the pgBackRest stanza is healthy
- the backup repository is reachable
- the target restore path is not the live Patroni data directory
- the live cluster remains untouched during the test

Useful checks:

```bash
ssh matt@gaia-01.node.jort.haus
sudo systemctl start jorthaus-pgbackrest-check
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  export PGPASSWORD=$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)
  /run/current-system/sw/bin/jorthaus-pgbackrest --stanza=jorthaus-postgres info
'
```

## Inspect available backups

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  export PGPASSWORD=$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)
  /run/current-system/sw/bin/jorthaus-pgbackrest --stanza=jorthaus-postgres info
'
```

Record the backup label you intend to test.

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

Run the restore as `patroni` and point pgBackRest at the scratch directory:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  /run/current-system/sw/bin/jorthaus-pgbackrest \
    --stanza=jorthaus-postgres \
    --pg1-path=/srv/postgres-restore-test/18 \
    restore
'
```

To restore a specific backup label:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  /run/current-system/sw/bin/jorthaus-pgbackrest \
    --stanza=jorthaus-postgres \
    --set=<backup-label> \
    --pg1-path=/srv/postgres-restore-test/18 \
    restore
'
```

## Optional PITR restore

A point-in-time recovery test uses a restore target.

Example:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  /run/current-system/sw/bin/jorthaus-pgbackrest \
    --stanza=jorthaus-postgres \
    --type=time \
    --target="2026-08-25 00:26:00+00" \
    --pg1-path=/srv/postgres-restore-test/18 \
    restore
'
```

Choose a target time that falls inside the archived WAL range shown by
`pgbackrest info`.

## Validate the restored files

Basic checks:

```bash
ssh matt@gaia-01.node.jort.haus
sudo find /srv/postgres-restore-test/18 -maxdepth 2 | head
sudo ls -l /srv/postgres-restore-test/18/PG_VERSION
```

If you want a deeper validation, start a temporary PostgreSQL instance on an
alternate port with a temporary config outside the live Patroni-managed
cluster.

## Cleanup

Remove the scratch restore when finished:

```bash
ssh matt@gaia-01.node.jort.haus
sudo rm -rf /srv/postgres-restore-test
```

## Notes

- Keep restore testing separate from the live Patroni data directory.
- Do not run `restore` against `/srv/postgres/18` on a live cluster node unless
  you are intentionally performing a recovery operation.
- Cluster replacement, PITR cutover, and node rejoin deserve a separate
  recovery-specific runbook once you decide on the exact operational model.
