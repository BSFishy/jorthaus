# PostgreSQL collation refresh

This runbook updates database default-collation metadata after rebuilding
indexes that depend on the database's recorded collation version. The host-side
`jorthaus-postgres-collation-maintenance` command operates only on databases
whose recorded version differs from the current provider version.

## Scope and impact

The plan checks both `pg_database.datcollversion` and each database's
`pg_collation.collversion` against the current provider versions. For a selected
database, execution runs `REINDEX DATABASE`, refreshes each outdated collation
object with `ALTER COLLATION ... REFRESH VERSION`, and refreshes the database
default with `ALTER DATABASE ... REFRESH COLLATION VERSION` when needed.
`REINDEX DATABASE` rebuilds every index in that database, not only indexes
known to use the outdated collations.

`REINDEX DATABASE` can take significant time and acquire locks. Schedule a
maintenance window and quiesce application writers to every affected database.
Do not stop Patroni. The plan reports client activity, and execution aborts if
it sees a non-idle client or an open transaction in an affected database. Idle
monitoring and Patroni connections may remain. This is a point-in-time check;
keep writers stopped for the entire operation.

## Preconditions

1. Check Patroni and PostgreSQL health and identify the writable primary.
2. Take a fresh WAL-G base backup and verify repository visibility and WAL
   continuity by following [the PostgreSQL backup runbook](postgres-backups.md).
   Record the verified backup name; the maintenance command records this
   operator-supplied reference but does not validate it itself.
3. Stop application writers and wait for active work and open transactions to
   finish. Ensure no backup or other maintenance job is using an affected
   database; idle Patroni and monitoring connections may remain.
4. Leave Patroni and the PostgreSQL cluster running. The command routes through
   `postgres.service.jort.haus`, checks that it reaches a writable primary,
   and stops if it detects a failover or client sessions in the affected
   databases.

## Review the plan

From the repository root, run:

```bash
just postgres-collation-plan
```

The read-only plan records the primary and a JSON inventory of database sizes,
index counts/sizes, default-collation versions, outdated collation objects,
connection eligibility, and active client work in
`/var/log/jorthaus/postgres-collation-maintenance.log` on `gaia-01`.
Review the complete inventory before proceeding. Do not proceed if an affected
database does not allow connections or if the primary is not writable.

## Reindex and refresh

With the verified backup name and writer quiescence confirmed, run once for
each selected database:

```bash
just postgres-collation-refresh <database> <WAL-G-backup-name> REINDEX-AND-REFRESH-POSTGRES-COLLATIONS
```

Execution rechecks the primary and active work for that database, reindexes it,
refreshes its outdated collation objects and default version, then verifies
that its mismatches are gone. An explicit database, backup reference, writer
quiescence attestation, and confirmation phrase are required.

The operation is resumable rather than transactional. If it fails, keep writers
stopped, review the audit log, rerun the read-only plan, and repeat the command
for that database. A completed database no longer appears as mismatched.

The `k3s` database is the Kubernetes control-plane datastore. Reindex it only
in a separately planned control-plane maintenance window; do not treat it as
an ordinary application database.

## After the operation

- Confirm the plan reports no database default-collation mismatches.
- Confirm PostgreSQL and Patroni remain healthy and resume writers only after
  verification succeeds.
- Keep the backup reference and the host audit log with the maintenance
  record.
