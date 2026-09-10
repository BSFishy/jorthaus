---
description: Centralized Patroni/Postgres role and database ensure configuration
---

# Postgres ensure configuration

`jorthaus.postgres.ensure` is the declarative source for cluster-scoped
PostgreSQL roles, databases, ownership, and grants that must exist before
services use OpenBao-managed credentials.

The module lives in:

```text
nix/modules/sliver/postgres/ensure.nix
```

The Postgres sliver is organized as:

```text
nix/modules/sliver/postgres/default.nix
nix/modules/sliver/postgres/patroni.nix
nix/modules/sliver/postgres/ensure.nix
```

## Runtime unit

The generated unit is:

```text
jorthaus-postgres-ensure.service
```

It is enabled only on the first enabled Postgres host by sorted inventory order.
It waits for a writable primary through `postgres.service.jort.haus`, then
applies the desired state.

Current expected placement:

```text
gaia-01: jorthaus-postgres-ensure.service enabled
gaia-02: no ensure unit
gaia-03: no ensure unit
```

## Safety model

The ensure module is intentionally non-destructive:

- creates roles only when absent
- creates databases only when absent
- applies configured role attributes with `ALTER ROLE`
- applies configured database/schema ownership and grants
- does not drop roles
- does not drop databases
- does not revoke unmanaged grants

Role and database names are quoted as SQL identifiers by the Nix generator.
Database grants are constrained to a small enum:

- `CONNECT`
- `CREATE`
- `TEMP`
- `TEMPORARY`

## Current desired state

### k3s

Defined in:

```text
nix/modules/sliver/k3s.nix
```

Ensures:

- role `k3s` with `LOGIN`
- database `k3s` owned by `k3s`
- schema `public` owned by `k3s`
- existing table/sequence privileges for `k3s`
- future table/sequence default privileges for `k3s`

### SeaweedFS

Defined in:

```text
nix/modules/sliver/seaweedfs/controlplane.nix
```

Ensures:

- role `seaweedfs` with `LOGIN`
- database `seaweedfs` owned by `seaweedfs`
- schema `public` owned by `seaweedfs`
- existing table/sequence privileges for `seaweedfs`
- future table/sequence default privileges for `seaweedfs`

### Authentik

Defined in:

```text
nix/modules/sliver/postgres/patroni.nix
```

Ensures:

- role `authentik` with `NOLOGIN` as database owner
- role `authentik_app` with `LOGIN` and membership in `authentik`
- database `authentik` owned by `authentik`
- schema `public` owned by `authentik`
- existing table/sequence privileges for `authentik`
- future table/sequence default privileges for `authentik`

OpenBao manages the `authentik_app` password through the static role:

```text
postgres/static-creds/authentik-static
```

The password rotates every 180 days. Follow
[`docs/runbooks/authentik.md`](runbooks/authentik.md) for the required
maintenance rollout.

### PostgreSQL backup

Defined in:

```text
nix/modules/sliver/postgres/patroni.nix
```

Ensures:

- role `postgres_backup` with `LOGIN`
- `REPLICATION`
- `CONNECTION LIMIT 5`
- membership in `pg_monitor`
- `CONNECT` on database `postgres`

OpenBao rotates the password for this role at:

```text
postgres/static-creds/postgres-backup
```

## Adding a service database

For a service with a stable login role and application database:

```nix
jorthaus.postgres.ensure = {
  users.example.login = true;

  databases.example = {
    owner = "example";
    schemas.public = {
      owner = "example";
      grantAllTo = [ "example" ];
      defaultPrivilegesFor = [ "example" ];
    };
  };
};
```

For a service that uses OpenBao dynamic login credentials, prefer a stable
NOLOGIN owner/grant role and let OpenBao create short-lived login roles:

```nix
jorthaus.postgres.ensure = {
  users.authentik.login = false;

  databases.authentik = {
    owner = "authentik";
    schemas.public = {
      owner = "authentik";
      grantAllTo = [ "authentik" ];
      defaultPrivilegesFor = [ "authentik" ];
    };
  };
};
```

The corresponding OpenBao dynamic role should grant membership in the stable
role.

## Validate after deploy

Check unit placement and result:

```bash
for host in gaia-01 gaia-02 gaia-03; do
  echo "===$host==="
  ssh matt@$host.node.jort.haus '
    systemctl is-enabled jorthaus-postgres-ensure 2>/dev/null || true
    systemctl status jorthaus-postgres-ensure --no-pager -l 2>/dev/null | sed -n "1,40p" || true
  '
done
```

Check the Patroni cluster:

```bash
curl -ksS https://gaia-01.node.jort.haus:8008/cluster | jq
```

Check roles and databases on the current primary:

```bash
ssh matt@gaia-02.node.jort.haus 'sudo bash -s' <<'EOF'
set -euo pipefail
export PGPASSWORD="$(tr -d "\n" < /run/agenix/patroni-postgres-superuser-password)"
psql "host=/run/postgresql dbname=postgres user=postgres" -F $'\t' -Atc "
select rolname, rolcanlogin, rolreplication, rolconnlimit
from pg_roles
where rolname in ('k3s','seaweedfs','postgres_backup')
order by rolname;
"
psql "host=/run/postgresql dbname=postgres user=postgres" -F $'\t' -Atc "
select d.datname, pg_catalog.pg_get_userbyid(d.datdba) as owner
from pg_database d
where d.datname in ('postgres','k3s','seaweedfs','authentik')
order by d.datname;
"
EOF
```

Check OpenBao-issued static credentials without printing passwords:

```bash
for path in postgres/static-creds/k3s postgres/static-creds/seaweedfs postgres/static-creds/postgres-backup; do
  echo "--- $path"
  bao read -format=json "$path" \
    | jq -r '.data | {username, password_present:(.password != null and (.password|length > 0)), ttl}'
done
```

Application credential checks should connect with the issued username/password
without logging secret values.
