#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly pg_host=${JORT_POSTGRES_HOST:-postgres.service.jort.haus}
readonly pg_port=${JORT_POSTGRES_PORT:-5432}
readonly pg_user=${JORT_POSTGRES_USER:-postgres}
readonly psql_bin=${PSQL_BIN:-psql}
readonly audit_file=${JORT_POSTGRES_COLLATION_AUDIT_FILE:-/var/log/jorthaus/postgres-collation-maintenance.log}
readonly lock_file=${JORT_POSTGRES_COLLATION_LOCK_FILE:-/run/lock/jorthaus-postgres-collation-maintenance.lock}
readonly confirmation_phrase='REINDEX-AND-REFRESH-POSTGRES-COLLATIONS'

mode=${1:-plan}
shift || true
target_database=
backup_ref=
writers_quiesced=false
confirmed=false

usage() {
  cat >&2 <<'EOF'
Usage:
  jorthaus-postgres-collation-maintenance plan
  jorthaus-postgres-collation-maintenance execute \
    --database DATABASE \
    --backup-ref WAL_G_BACKUP_NAME \
    --writers-quiesced \
    --confirm REINDEX-AND-REFRESH-POSTGRES-COLLATIONS

Plan is read-only. Execute operates on one selected database: it reindexes the
whole database, refreshes each outdated collation object, and refreshes the
database's default-collation version when needed.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "$mode" in
  plan)
    [[ $# -eq 0 ]] || { usage; exit 2; }
    ;;
  execute)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --database)
          [[ $# -ge 2 ]] || { usage; exit 2; }
          target_database=$2
          shift 2
          ;;
        --backup-ref)
          [[ $# -ge 2 ]] || { usage; exit 2; }
          backup_ref=$2
          shift 2
          ;;
        --writers-quiesced)
          writers_quiesced=true
          shift
          ;;
        --confirm)
          [[ $# -ge 2 ]] || { usage; exit 2; }
          [[ $2 == "$confirmation_phrase" ]] || fail 'confirmation phrase did not match'
          confirmed=true
          shift 2
          ;;
        *)
          usage
          exit 2
          ;;
      esac
    done
    [[ -n $target_database ]] || fail 'execute requires exactly one --database target'
    [[ $backup_ref =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail 'provide a valid WAL-G backup reference'
    [[ $writers_quiesced == true ]] || fail 'execute requires --writers-quiesced after application writers are stopped'
    [[ $confirmed == true ]] || fail "execute requires --confirm $confirmation_phrase"
    ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -n ${PGPASSWORD:-} ]] || fail 'PGPASSWORD must be supplied by the host-side secret wrapper'

install -d -m 0700 "$(dirname "$audit_file")"
touch "$audit_file"
chmod 0600 "$audit_file"
exec > >(tee -a "$audit_file") 2>&1

exec 9>"$lock_file"
flock -n 9 || fail 'another PostgreSQL collation maintenance run is active'

export PGHOST="$pg_host"
export PGPORT="$pg_port"
export PGUSER="$pg_user"
export PGSSLMODE=verify-full
export PGSSLROOTCERT=system
export PGCONNECT_TIMEOUT=10
export PGAPPNAME=jorthaus-postgres-collation-maintenance

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

trap 'status=$?; if (( status != 0 )); then log "run failed exit_status=$status"; fi' EXIT

psql_run() {
  local database=$1
  local sql=$2
  shift 2
  "$psql_bin" -X --set=ON_ERROR_STOP=1 --dbname="$database" "$@" --command="$sql"
}

query() {
  psql_run "$1" "$2" --quiet --tuples-only --no-align
}

quote_identifier() {
  local value=${1//\"/\"\"}
  printf '"%s"' "$value"
}

primary_description() {
  local is_primary
  is_primary=$(query postgres 'SELECT NOT pg_is_in_recovery()' | tr -d '[:space:]')
  [[ $is_primary == t ]] || fail 'postgres.service.jort.haus is not connected to the writable primary'
  query postgres "SELECT inet_server_addr()::text || ':' || inet_server_port()::text || ' started=' || pg_postmaster_start_time()::text || ' PostgreSQL ' || current_setting('server_version')" \
    | tr -d '\r'
}

assert_primary_stable() {
  [[ $1 == "$primary_identity" ]] || fail "writable primary changed during maintenance: initial=$primary_identity current=$1"
}

database_list_query=$(cat <<'SQL'
SELECT COALESCE(json_agg(datname ORDER BY datname), '[]'::json)::text
FROM pg_database
WHERE datallowconn;
SQL
)

blocked_database_query=$(cat <<'SQL'
SELECT COALESCE(
  json_agg(
    json_build_object(
      'database', datname,
      'recorded_version', datcollversion,
      'actual_version', pg_database_collation_actual_version(oid),
      'allow_connections', datallowconn
    ) ORDER BY datname
  ),
  '[]'::json
)::text
FROM pg_database
WHERE NOT datallowconn
  AND datcollversion IS NOT NULL
  AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid);
SQL
)

database_inventory_query=$(cat <<'SQL'
SELECT json_build_object(
  'database', d.datname,
  'allow_connections', d.datallowconn,
  'recorded_version', d.datcollversion,
  'actual_version', pg_database_collation_actual_version(d.oid),
  'default_mismatch', d.datcollversion IS NOT NULL
    AND d.datcollversion IS DISTINCT FROM pg_database_collation_actual_version(d.oid),
  'database_size_bytes', pg_database_size(d.oid),
  'index_count', (SELECT count(*) FROM pg_class WHERE relkind = 'i'),
  'index_size_bytes', COALESCE((SELECT sum(pg_relation_size(oid)) FROM pg_class WHERE relkind = 'i'), 0),
  'collations', COALESCE((
    SELECT json_agg(
      json_build_object(
        'identifier', format('%I.%I', n.nspname, c.collname),
        'schema', n.nspname,
        'name', c.collname,
        'provider', c.collprovider,
        'recorded_version', c.collversion,
        'actual_version', pg_collation_actual_version(c.oid)
      ) ORDER BY n.nspname, c.collname
    )
    FROM pg_collation c
    JOIN pg_namespace n ON n.oid = c.collnamespace
    WHERE c.collversion IS NOT NULL
      AND c.collversion IS DISTINCT FROM pg_collation_actual_version(c.oid)
  ), '[]'::json)
)::text
FROM pg_database d
WHERE d.datname = current_database();
SQL
)

active_work_query=$(cat <<'SQL'
SELECT COALESCE(
  json_agg(
    json_build_object(
      'database', datname,
      'role', usename,
      'application', application_name,
      'state', state,
      'transaction_started', xact_start
    ) ORDER BY usename, application_name
  ),
  '[]'::json
)::text
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid()
  AND datname = current_database()
  AND (state IS DISTINCT FROM 'idle' OR xact_start IS NOT NULL);
SQL
)

collect_inventory() {
  local databases blocked result database record
  local -a names=()
  local -a records=()

  databases=$(query postgres "$database_list_query")
  jq -e 'type == "array"' >/dev/null <<<"$databases" || fail 'PostgreSQL returned an invalid database list'
  mapfile -d '' -t names < <(jq -j '.[] | ., "\u0000"' <<<"$databases")

  for database in "${names[@]}"; do
    record=$(query "$database" "$database_inventory_query")
    jq -e 'type == "object" and (.collations | type == "array")' >/dev/null <<<"$record" \
      || fail "PostgreSQL returned invalid inventory for database $database"
    records+=("$record")
  done

  result=$(printf '%s\n' "${records[@]}" | jq -s 'sort_by(.database)')
  jq -e 'type == "array"' >/dev/null <<<"$result" || fail 'failed to assemble database inventory'

  blocked=$(query postgres "$blocked_database_query")
  jq -e 'type == "array"' >/dev/null <<<"$blocked" || fail 'PostgreSQL returned invalid blocked-database inventory'
  if ! jq -e 'length == 0' >/dev/null <<<"$blocked"; then
    result=$(jq --argjson blocked "$blocked" '. + $blocked' <<<"$result")
  fi

  printf '%s' "$result"
}

get_active_work() {
  local database=$1 result
  result=$(psql_run "$database" "$active_work_query" --quiet --tuples-only --no-align) \
    || fail "failed to query active work for database $database"
  jq -e 'type == "array"' >/dev/null <<<"$result" || fail 'PostgreSQL returned an invalid activity inventory'
  printf '%s' "$result"
}

add_activity_to_mismatches() {
  local inventory=$1 database sessions
  while IFS= read -r -d '' database; do
    sessions=$(get_active_work "$database") || fail "failed to inventory active work for database $database"
    inventory=$(jq --arg database "$database" --argjson sessions "$sessions" \
      'map(if .database == $database then . + {active_work: $sessions} else . end)' <<<"$inventory") \
      || fail "failed to assemble active-work inventory for database $database"
  done < <(jq -j '.[] | select(.allow_connections == true and (.default_mismatch or (.collations | length > 0))) | .database, "\u0000"' <<<"$inventory")
  printf '%s' "$inventory"
}

assert_no_active_work() {
  local database=$1 work
  work=$(get_active_work "$database")
  if ! jq -e 'length == 0' >/dev/null <<<"$work"; then
    log "Refusing reindex while active client work or open transactions remain database=$database:"
    jq . <<<"$work"
    fail 'stop application writers and wait for active work and open transactions to finish, then rerun the plan'
  fi
}

log "mode=$mode operator=${SUDO_USER:-$(id -un)}"
primary_identity=$(primary_description)
log "verified writable primary: $primary_identity"

inventory=$(collect_inventory)
mismatches=$(jq '[.[] | select(.default_mismatch or (.collations | length > 0))]' <<<"$inventory")
mismatches=$(add_activity_to_mismatches "$mismatches")
log 'collation mismatch inventory:'
jq . <<<"$mismatches"

if jq -e 'length == 0' >/dev/null <<<"$mismatches"; then
  log 'No database default-collation or collation-object version mismatches were found.'
  exit 0
fi

if [[ $mode == plan ]]; then
  log 'Plan only; no database was modified.'
  exit 0
fi

target=$(jq -c --arg database "$target_database" '[.[] | select(.database == $database)] | .[0] // empty' <<<"$mismatches")
[[ -n $target ]] || fail "database $target_database is not present in the current mismatch inventory"
if ! jq -e '.allow_connections == true' >/dev/null <<<"$target"; then
  fail "database $target_database does not allow connections"
fi

log "operator attested writers are quiesced; database=$target_database backup_ref=$backup_ref"
assert_no_active_work "$target_database"

primary=$(primary_description)
assert_primary_stable "$primary"
quoted_database=$(quote_identifier "$target_database")
log "reindex start database=$target_database primary=$primary"
psql_run "$target_database" "REINDEX DATABASE $quoted_database;" --quiet
log "reindex complete database=$target_database"

mapfile -d '' -t collations < <(jq -j '.collations[] | .identifier, "\u0000"' <<<"$target")
for collation in "${collations[@]}"; do
  assert_no_active_work "$target_database"
  primary=$(primary_description)
  assert_primary_stable "$primary"
  log "collation refresh start database=$target_database collation=$collation"
  psql_run "$target_database" "ALTER COLLATION $collation REFRESH VERSION;" --quiet
  log "collation refresh complete database=$target_database collation=$collation"
done

if jq -e '.default_mismatch == true' >/dev/null <<<"$target"; then
  assert_no_active_work "$target_database"
  primary=$(primary_description)
  assert_primary_stable "$primary"
  psql_run postgres "ALTER DATABASE $quoted_database REFRESH COLLATION VERSION;" --quiet
  log "database default-collation version refreshed database=$target_database primary=$primary"
fi

verified_inventory=$(collect_inventory)
verified_target=$(jq -c --arg database "$target_database" '[.[] | select(.database == $database)] | .[0] // empty' <<<"$verified_inventory")
if [[ -z $verified_target ]] || jq -e '.default_mismatch or (.collations | length > 0)' >/dev/null <<<"$verified_target"; then
  log "collation mismatch remains database=$target_database"
  jq . <<<"$verified_target"
  fail "verification failed for database $target_database"
fi

primary=$(primary_description)
assert_primary_stable "$primary"
log "Database collation maintenance completed successfully database=$target_database."
