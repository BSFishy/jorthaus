# postgres backups

This repository uses WAL-G for PostgreSQL physical backups and WAL archiving.

## Topology

The backup path has two parts:

- PostgreSQL nodes archive WAL locally through `archive_command`
- Kubernetes schedules remote physical base backups through the PostgreSQL `BASE_BACKUP` protocol

The current deployment shape is:

- WAL archiving runs from the active primary through `archive_command`
- Kubernetes runs one remote physical base backup per day
- Kubernetes prunes old base backups after the backup window
- WAL and base backups live in Backblaze B2 through its S3-compatible API
- the WAL-G storage prefix lives at `backup/data/postgres` in OpenBao
- the Kubernetes backup workload reads PostgreSQL credentials from `postgres/static-creds/postgres-backup`

The running PostgreSQL cluster remains on the metal nodes under Patroni.
Kubernetes does not mount `/srv/postgres/...`.

## Node-local archiving

All PostgreSQL nodes install `jorthaus-wal-g` and archive with:

- `archive_mode = on`
- `archive_timeout = 60s`
- `archive_command = jorthaus-wal-g wal-push %p`

`jorthaus-wal-g` reads its B2 settings from the OpenBao-rendered env file:

- `/run/postgres-wal-g/wal-g.env`

The PostgreSQL nodes authenticate to OpenBao with the AppRole bootstrap files:

- `secrets/postgres-wal-g-approle-role-id.age`
- `secrets/postgres-wal-g-approle-secret-id.age`

The rendered env contains the storage settings WAL-G needs:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_ENDPOINT`
- `AWS_REGION`
- `WALG_S3_PREFIX`
- `AWS_S3_FORCE_PATH_STYLE=true`
- `WALG_PREVENT_WAL_OVERWRITE=true`

## Kubernetes base backups

The Kubernetes backup subject lives under:

- `kubernetes/postgres-backup/`

It defines:

- `CronJob/postgres-backup`
- `CronJob/postgres-backup-prune`
- `ServiceAccount/postgres-backup`
- `SecretProviderClass/postgres-backup-openbao`

The backup job:

- authenticates to OpenBao through Secrets Store CSI
- reads B2 settings from `backup/data/postgres`
- reads PostgreSQL credentials from `postgres/static-creds/postgres-backup`
- connects to `postgres.service.jort.haus:5432` with TLS verification
- runs `wal-g backup-push --verify`
- verifies repository visibility with `wal-g backup-list --detail --json`
- verifies WAL continuity with `wal-g wal-verify integrity timeline --json`

The backup job uses the existing Postgres read/write service endpoint. That
keeps the selection logic simple and directs the `BASE_BACKUP` session at the
current primary.

## Schedule and retention

The default schedule is:

- base backup: `15 03 * * *` UTC
- prune: `15 05 * * *` UTC

The prune job keeps:

- `14` full base backups

It enforces retention with:

- `wal-g delete retain FULL 14 --use-sentinel-time --confirm`

`concurrencyPolicy: Forbid` prevents overlapping jobs.

## PostgreSQL backup identity

The physical backup workflow uses the dedicated PostgreSQL role:

- `postgres_backup`

That role is created by the node-local bootstrap unit:

- `jorthaus-postgres-backup-bootstrap.service`

The role keeps:

- `LOGIN`
- `REPLICATION`
- `pg_monitor`
- `CONNECT` on the `postgres` database

OpenBao rotates its password through the static role path:

- `postgres/static-creds/postgres-backup`

## Legacy pgBackRest data

The previous pgBackRest repository remains a legacy recovery source in B2.
This migration does not rewrite or delete the old pgBackRest objects.

Use the WAL-G path for current operations. Treat the pgBackRest repository as a
separate legacy recovery source until you intentionally retire it.
