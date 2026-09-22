# VictoriaLogs curl query cookbook

Use one direct replica for exploratory queries. Query every replica only when
checking delivery or replica consistency. Direct endpoints are private:

```bash
endpoint=http://10.1.10.1:9428
```

Always include a narrow LogsQL predicate, a response limit, and a short query
timeout. `curl --data-urlencode` preserves quoting and special characters in a
LogsQL expression.

```bash
query='host:in("gaia-01") kubernetes_namespace:in("kube-system")'
curl --fail --silent "$endpoint/select/logsql/query" \
  --data-urlencode "query=$query" \
  --data-urlencode 'limit=50' \
  --data-urlencode 'timeout=5s'
```

`limit` returns the most recent matching records. Add `_time:<duration>` to
bound the searched time range as well as the response:

```bash
query='_time:15m host:in("gaia-01") kubernetes_container:in("seaweedfs-mount")'
```

## Inspect selected fields with jq

VictoriaLogs returns one JSON object per line. Use `jq -c` to retain one compact
object per record and select only the fields relevant to the question:

```bash
curl --fail --silent "$endpoint/select/logsql/query" \
  --data-urlencode 'query=_time:15m source:in("kubernetes")' \
  --data-urlencode 'limit=50' \
  --data-urlencode 'timeout=5s' \
  | jq -c '{time: ._time, host, namespace: .kubernetes_namespace,
            pod: .kubernetes_pod, container: .kubernetes_container,
            stream, message: ._msg}'
```

If `jq` is not installed, use it temporarily without changing host or project
configuration:

```bash
export endpoint query
nix-shell -p jq --run 'curl --fail --silent "$endpoint/select/logsql/query" \
  --data-urlencode "query=$query" \
  --data-urlencode "limit=50" \
  --data-urlencode "timeout=5s" \
  | jq -c "{time: ._time, host, message: ._msg}"'
```

Use single quotes around the shell program passed to `nix-shell`, and export
`endpoint` and `query` first when their values are needed inside it.

Do not print whole records when they may contain credentials, authorization
headers, cookies, tokens, private keys, or secret values. Select an allowlist
of metadata and message fields, redact known sensitive values before output,
and avoid saving raw responses to tracked files.

## Common filters

```bash
# Kubernetes logs from one host, namespace, pod, or container.
'host:in("gaia-01") source:in("kubernetes")'
'kubernetes_namespace:in("hister") kubernetes_pod:in("hister-6f7dfd4ff-2vt8k")'
'kubernetes_container:in("seaweedfs-mount") stream:in("stderr")'

# Journald records from a unit or program name.
'source:in("journald") journal_unit:in("seaweedfs-volume.service")'
'source:in("journald") journal_identifier:in("sshd") journal_priority:in("3")'

# Exact marker or words in a message.
'fluent-bit-check-20260922T000000Z'
'"wrong jwt"'
```

Combine filters with spaces for logical AND. Use `_time:5m` during incident
investigation unless a longer window is required and justified.

## Count errors and calculate a rate

Use the `stats` pipe instead of downloading a large event set:

```bash
query='_time:5m host:in("gaia-01") kubernetes_container:in("seaweedfs-mount") "wrong jwt" | stats count() errors'
curl --fail --silent "$endpoint/select/logsql/query" \
  --data-urlencode "query=$query" \
  --data-urlencode 'timeout=5s'
```

The result is JSON such as `{"errors":"29225"}`. Divide by the explicit
window duration for an approximate per-second rate.

For time-bucketed counts, query the hits endpoint with explicit start, end, and
step values:

```bash
query='host:in("gaia-01") kubernetes_container:in("seaweedfs-mount") "wrong jwt"'
start=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl --fail --silent "$endpoint/select/logsql/hits" \
  --data-urlencode "query=$query" \
  --data-urlencode "start=$start" \
  --data-urlencode "end=$end" \
  --data-urlencode 'step=5m' \
  --data-urlencode 'timeout=5s' | jq .
```

## Find first and latest events

A request limit returns recent events. To inspect the oldest event within an
explicit window, sort ascending and then limit:

```bash
base='host:in("gaia-01") kubernetes_container:in("seaweedfs-mount") "wrong jwt"'
curl --fail --silent "$endpoint/select/logsql/query" \
  --data-urlencode "query=_time:6h $base | sort by (_time) | limit 1" \
  --data-urlencode 'timeout=5s' \
  | jq -c '{time: ._time, message: ._msg, pod: .kubernetes_pod}'
```

## Query all replicas for delivery verification

Use a known non-sensitive marker. Require every replica to return it:

```bash
marker='replace-with-a-specific-marker'
for host in 10.1.10.1 10.1.10.2 10.1.10.3; do
  result=$(curl --fail --silent "http://$host:9428/select/logsql/query" \
    --data-urlencode "query=$marker" \
    --data-urlencode 'limit=1' \
    --data-urlencode 'timeout=5s')
  printf '%s: %s\n' "$host" "$(printf '%s' "$result" | jq -r '._time // "missing"')"
done
```

A direct-query match proves that replica stored the event. When the goal is a
user-visible search or sidebar filter, ask the user to confirm it in
`https://logs.jort.haus` after direct verification.
