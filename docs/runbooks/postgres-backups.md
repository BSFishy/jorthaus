# postgres backup runbook

This runbook covers routine pgBackRest operations for the Patroni/Postgres
cluster.

## Preconditions

Before running backup commands, verify that:

- Patroni is healthy
- PostgreSQL archiving is enabled on the current leader
- the B2 secret is present on the node
- `gaia-01` can reach the B2 endpoint

Useful checks:

```bash
curl -k https://gaia-01.node.jort.haus:8008/cluster
systemctl list-timers --all | grep jorthaus-pgbackrest
ls -l /run/agenix/pgbackrest-b2-env
```

## Run a stanza check

A stanza check validates repository access and confirms that WAL archiving is
working.

```bash
ssh matt@gaia-01.node.jort.haus
sudo systemctl start jorthaus-pgbackrest-check
journalctl -u jorthaus-pgbackrest-check --no-pager -n 100
```

A successful run ends with log lines showing:

- `stanza-create command end: completed successfully`
- `check command end: completed successfully`
- a WAL segment archived to repo1

## Run a full backup

```bash
ssh matt@gaia-01.node.jort.haus
sudo systemctl start jorthaus-pgbackrest-backup-full
journalctl -u jorthaus-pgbackrest-backup-full --no-pager -n 200
```

## Run a differential backup

```bash
ssh matt@gaia-01.node.jort.haus
sudo systemctl start jorthaus-pgbackrest-backup-diff
journalctl -u jorthaus-pgbackrest-backup-diff --no-pager -n 200
```

## Inspect repository state

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

This output shows:

- stanza status
- archived WAL range
- backup sets
- backup sizes
- start and stop WAL for each backup

## Verify archiving from PostgreSQL

On the current leader:

```bash
sudo -u patroni sh -c '
  PGPASSWORD=$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)
  psql "host=/run/postgresql dbname=postgres user=postgres" -Atc "
    show archive_mode;
    show archive_command;
    show archive_timeout;
    select archived_count, last_archived_wal, last_archived_time,
           failed_count, last_failed_wal, last_failed_time
    from pg_stat_archiver;
  "
'
```

A healthy archiver shows:

- `archive_mode` enabled
- the pgBackRest `archive-push` command
- increasing `archived_count`

## Timers

Scheduled backups run only on `gaia-01`.

```bash
systemctl list-timers --all | grep jorthaus-pgbackrest
```

Expected timers:

- daily diff backup at `03:15 UTC`
- weekly full backup at `03:15 UTC` on Sunday

## Notes

- WAL archiving runs from whichever node is currently primary.
- Scheduled base backups currently run on `gaia-01`.
- Restore and PITR rehearsal should be treated as a separate operator workflow.
