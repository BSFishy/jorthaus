{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.postgres.ensure;
  enabled = host.slivers.postgres.enable;
  postgresHosts = lib.sort (a: b: a.hostname < b.hostname) (
    lib.filter (peer: peer.slivers.postgres.enable) (builtins.attrValues hostInventory)
  );
  bootstrapHost = if postgresHosts == [ ] then null else lib.head postgresHosts;

  quoteIdent = value: ''"${lib.replaceStrings [ "\"" ] [ "\"\"" ] value}"'';
  quoteLiteral = value: "'${lib.replaceStrings [ "'" ] [ "''" ] value}'";

  roleClauses =
    user:
    lib.optional user.login "LOGIN"
    ++ lib.optional (!user.login) "NOLOGIN"
    ++ lib.optional user.replication "REPLICATION"
    ++ lib.optional (!user.replication) "NOREPLICATION"
    ++ lib.optional (user.connectionLimit != null) "CONNECTION LIMIT ${toString user.connectionLimit}";

  renderUser =
    name: user:
    let
      ident = quoteIdent name;
      clauses = roleClauses user;
    in
    ''
      psql_postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_roles WHERE rolname = ${quoteLiteral name};"} | grep -q 1 || psql_postgres -tAc ${lib.escapeShellArg "CREATE ROLE ${ident};"}
      ${lib.optionalString (clauses != [ ])
        "psql_postgres -tAc ${lib.escapeShellArg "ALTER ROLE ${ident} WITH ${lib.concatStringsSep " " clauses};"}"
      }
      ${lib.concatMapStrings (role: ''
        psql_postgres -tAc ${lib.escapeShellArg "GRANT ${quoteIdent role} TO ${ident};"}
      '') user.memberships}
      ${lib.concatStringsSep "\n" (
        lib.flatten (
          lib.mapAttrsToList (
            database: grants:
            map (
              grant:
              "psql_postgres -tAc ${lib.escapeShellArg "GRANT ${grant} ON DATABASE ${quoteIdent database} TO ${ident};"}"
            ) grants
          ) user.databaseGrants
        )
      )}
    '';

  renderSchema =
    database: schemaName: schema:
    let
      schemaIdent = quoteIdent schemaName;
      ownerSql = lib.optionalString (schema.owner != null) ''
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "ALTER SCHEMA ${schemaIdent} OWNER TO ${quoteIdent schema.owner};"}
      '';
      grantsSql = lib.concatMapStrings (grantee: ''
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "GRANT ALL ON SCHEMA ${schemaIdent} TO ${quoteIdent grantee};"}
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${schemaIdent} TO ${quoteIdent grantee};"}
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ${schemaIdent} TO ${quoteIdent grantee};"}
      '') schema.grantAllTo;
      defaultPrivilegesSql = lib.concatMapStrings (grantee: ''
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "ALTER DEFAULT PRIVILEGES IN SCHEMA ${schemaIdent} GRANT ALL ON TABLES TO ${quoteIdent grantee};"}
        psql_database ${lib.escapeShellArg database} -tAc ${lib.escapeShellArg "ALTER DEFAULT PRIVILEGES IN SCHEMA ${schemaIdent} GRANT ALL ON SEQUENCES TO ${quoteIdent grantee};"}
      '') schema.defaultPrivilegesFor;
    in
    ownerSql + grantsSql + defaultPrivilegesSql;

  renderDatabase =
    name: database:
    let
      ident = quoteIdent name;
      ownerClause = lib.optionalString (database.owner != null) " OWNER ${quoteIdent database.owner}";
      ownerSql = lib.optionalString (database.owner != null) ''
        psql_postgres -tAc ${lib.escapeShellArg "ALTER DATABASE ${ident} OWNER TO ${quoteIdent database.owner};"}
      '';
    in
    ''
      psql_postgres -tAc ${lib.escapeShellArg "SELECT 1 FROM pg_database WHERE datname = ${quoteLiteral name};"} | grep -q 1 || psql_postgres -tAc ${lib.escapeShellArg "CREATE DATABASE ${ident}${ownerClause};"}
      ${ownerSql}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (renderSchema name) database.schemas)}
    '';

  ensureScript = pkgs.writeShellScriptBin "jorthaus-postgres-ensure" ''
    set -euo pipefail

    export PGPASSWORD="$(tr -d '\n' < ${config.age.secrets.patroni-postgres-superuser-password.path})"
    psql_base=(
      ${lib.getExe' pkgs.postgresql "psql"}
      "postgresql://postgres.service.jort.haus:5432/postgres?user=postgres&sslmode=verify-full&sslrootcert=system"
    )

    psql_postgres() {
      "''${psql_base[@]}" "$@"
    }

    psql_database() {
      local database="$1"
      shift
      ${lib.getExe' pkgs.postgresql "psql"} "postgresql://postgres.service.jort.haus:5432/$database?user=postgres&sslmode=verify-full&sslrootcert=system" "$@"
    }

    wait_for_writable_primary() {
      for _ in $(seq 1 300); do
        if psql_postgres -Atc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | grep -qx t; then
          return 0
        fi
        sleep 1
      done

      echo "timed out waiting for writable PostgreSQL primary" >&2
      return 1
    }

    wait_for_writable_primary

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderUser cfg.users)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderDatabase cfg.databases)}
  '';
in
{
  options.jorthaus.postgres.ensure = {
    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            login = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether the ensured PostgreSQL role can log in.";
            };

            replication = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether the ensured PostgreSQL role has REPLICATION.";
            };

            connectionLimit = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Optional PostgreSQL CONNECTION LIMIT for the role.";
            };

            memberships = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Roles to grant to the ensured role.";
            };

            databaseGrants = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.listOf (
                  lib.types.enum [
                    "CONNECT"
                    "CREATE"
                    "TEMP"
                    "TEMPORARY"
                  ]
                )
              );
              default = { };
              description = "Database-level privileges to grant to the ensured role.";
            };
          };
        }
      );
      default = { };
      description = "PostgreSQL roles to ensure without dropping unmanaged roles.";
    };

    databases = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            owner = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional owner role for the ensured database.";
            };

            schemas = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    owner = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Optional owner role for the ensured schema.";
                    };

                    grantAllTo = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      description = "Roles granted ALL on the schema and existing tables/sequences.";
                    };

                    defaultPrivilegesFor = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      description = "Roles granted future table/sequence privileges in the schema.";
                    };
                  };
                }
              );
              default = { };
              description = "Schemas and schema-level privileges to ensure inside the database.";
            };
          };
        }
      );
      default = { };
      description = "PostgreSQL databases to ensure without dropping unmanaged databases.";
    };
  };

  config = lib.mkIf enabled {
    environment.systemPackages = [ ensureScript ];

    systemd.services.jorthaus-postgres-ensure =
      lib.mkIf (bootstrapHost != null && host.hostname == bootstrapHost.hostname)
        {
          description = "Ensure PostgreSQL cluster roles, databases, and grants";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "patroni.service"
            "haproxy.service"
          ];
          wants = [
            "network-online.target"
            "patroni.service"
            "haproxy.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            ExecStart = lib.getExe ensureScript;
          };
        };
  };
}
