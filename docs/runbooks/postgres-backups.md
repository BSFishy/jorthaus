# postgres backup runbook

This runbook covers routine WAL-G backup operations for the Patroni/Postgres
cluster.

## Preconditions

Before running backup commands, verify that:

- Patroni is healthy
- PostgreSQL archiving is enabled on the current leader
- PostgreSQL nodes can read the OpenBao-rendered WAL-G env
- the Kubernetes backup namespace can read its OpenBao-backed secrets

Useful checks:

```bash
curl -k https://gaia-01.node.jort.haus:8008/cluster
ssh matt@gaia-01.node.jort.haus 'sudo systemctl status vault-agent-postgres-wal-g --no-pager'
ssh matt@gaia-01.node.jort.haus 'sudo ls -l /run/postgres-wal-g/wal-g.env'
kubectl -n postgres-backup get cronjobs
```

## Verify archiving from PostgreSQL

On the current leader:

```bash
ssh matt@gaia-01.node.jort.haus
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
- the `jorthaus-wal-g wal-push %p` command
- increasing `archived_count`

## Launch a manual base backup

Create a one-off Job from the scheduled CronJob:

```bash
kubectl -n postgres-backup create job \
  --from=cronjob/postgres-backup \
  postgres-backup-manual-$(date +%Y%m%d%H%M%S)
```

Inspect progress:

```bash
kubectl -n postgres-backup get jobs
kubectl -n postgres-backup get pods
kubectl -n postgres-backup logs job/<job-name> --follow
```

A successful run ends with:

- a completed `backup-push`
- readable `backup-list --detail --json` output
- `wal-verify` status `OK` or a transient startup `WARNING` without lost WAL

## Launch a manual prune

```bash
kubectl -n postgres-backup create job \
  --from=cronjob/postgres-backup-prune \
  postgres-backup-prune-manual-$(date +%Y%m%d%H%M%S)
```

Inspect progress:

```bash
kubectl -n postgres-backup logs job/<job-name> --follow
```

The prune job applies:

- `wal-g delete retain FULL 14 --use-sentinel-time --confirm`

## Inspect repository state

Run the backup workflow image logic through a one-off Job or inspect a recent
backup Job log. The routine repository checks are:

- `wal-g backup-list --detail --json`
- `wal-g wal-verify integrity timeline --json`

To inspect storage directly from a PostgreSQL node:

```bash
ssh matt@gaia-01.node.jort.haus
sudo -u patroni /run/current-system/sw/bin/jorthaus-wal-g backup-list --detail --json
```

## Secrets and identities

WAL-G storage settings originate from:

- `backup/data/postgres`

The Kubernetes backup workload reads them through:

- `SecretProviderClass/postgres-backup-openbao`
- `auth/kubernetes/role/postgres-backup`

The PostgreSQL nodes read them through:

- `auth/approle/role/postgres-wal-g`
- `/run/postgres-wal-g/wal-g.env`

The Kubernetes workload reads its PostgreSQL password from:

- `postgres/static-creds/postgres-backup`

## Manual initialization

The OpenBao structure is declarative, but two inputs remain operator-supplied:

1. the `backup/postgres` KV contents
2. the AppRole bootstrap files for the PostgreSQL nodes

Populate the backup KV path with the WAL-G storage settings:

```bash
bao kv put backup/postgres \
  aws_access_key_id=<b2-key-id> \
  aws_secret_access_key=<b2-application-key> \
  aws_endpoint=<https://b2-s3-endpoint> \
  aws_region=<b2-region> \
  walg_s3_prefix=<s3://bucket/jorthaus-postgres-wal-g/v18>
```

Write the AppRole bootstrap files into agenix after Terraform creates the role:

```bash
bao read -field=role_id auth/approle/role/postgres-wal-g/role-id \
  | agenix -e secrets/postgres-wal-g-approle-role-id.age -i "$HOME/.ssh/id_ed25519"

bao write -f -field=secret_id auth/approle/role/postgres-wal-g/secret-id \
  | agenix -e secrets/postgres-wal-g-approle-secret-id.age -i "$HOME/.ssh/id_ed25519"
```

## Notes

- WAL archiving runs from whichever node is currently primary.
- Kubernetes schedules base backups but does not participate in continuous WAL
  archival.
- Patroni failover and replica creation remain separate from disaster-recovery
  restores.
