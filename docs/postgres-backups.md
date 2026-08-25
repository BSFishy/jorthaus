# postgres backups

This repository uses pgBackRest for PostgreSQL base backups and WAL archiving.

## Topology

All PostgreSQL nodes render the same pgBackRest configuration and archive WAL to
Backblaze B2 through the S3-compatible API.

The current deployment state is:

- WAL archiving runs from the active primary through `archive_command`
- the pgBackRest stanza name is `jorthaus-postgres`
- scheduled base backups run on `gaia-01`
- the repository path inside B2 is `/jorthaus-postgres`

## Configuration

The Postgres sliver configures:

- `archive_mode = on`
- `archive_timeout = 60s`
- `archive_command = jorthaus-pgbackrest --stanza=jorthaus-postgres archive-push %p`
- pgBackRest compression with `zst`
- retention:
  - `repo1-retention-full = 2`
  - `repo1-retention-diff = 6`
  - `repo1-retention-archive = 2`
  - `repo1-retention-archive-type = full`

The generated pgBackRest config lives at:

- `/etc/pgbackrest/pgbackrest.conf`

The B2 credentials live in the agenix secret:

- `secrets/pgbackrest-b2-env.age`

The runtime secret path on each node is:

- `/run/agenix/pgbackrest-b2-env`

## Local state

pgBackRest uses:

- lock path: `/run/pgbackrest`
- spool path: `/srv/pgbackrest/spool`

The Postgres data directory remains:

- `/srv/postgres/18`

## Scheduled backups

`gaia-01` owns the scheduled backup timers:

- `jorthaus-pgbackrest-backup-diff.timer`
  - `Mon..Sat 03:15:00 UTC`
- `jorthaus-pgbackrest-backup-full.timer`
  - `Sun 03:15:00 UTC`

The corresponding services are:

- `jorthaus-pgbackrest-backup-diff.service`
- `jorthaus-pgbackrest-backup-full.service`

## Verification

A healthy node reports:

```bash
sudo -u patroni sh -c '
  PGPASSWORD=$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)
  psql "host=/run/postgresql dbname=postgres user=postgres" -Atc "
    show archive_mode;
    show archive_command;
    show archive_timeout;
  "
'
```

The cluster backup state is visible from `gaia-01` with:

```bash
sudo -u patroni sh -c '
  set -a
  . /run/agenix/pgbackrest-b2-env
  set +a
  export PGPASSWORD=$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)
  /run/current-system/sw/bin/jorthaus-pgbackrest --stanza=jorthaus-postgres info
'
```

A stanza check is available on every Postgres node:

```bash
sudo systemctl start jorthaus-pgbackrest-check
journalctl -u jorthaus-pgbackrest-check --no-pager -n 50
```

## Current backup set

The current deployment has produced an initial full backup for stanza
`jorthaus-postgres`.

Inspect the current repository state with `pgbackrest info` rather than relying
on static timestamps in this document.
