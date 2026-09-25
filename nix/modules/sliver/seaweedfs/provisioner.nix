{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.seaweedfs;
  registry = config.jorthaus.s3;
  provisionerHost = if cfg.controlplaneHosts == [ ] then null else lib.head cfg.controlplaneHosts;
  isProvisionerHost = provisionerHost != null && host.hostname == provisionerHost.hostname;
  hasRegistry = registry.buckets != { } || registry.grants != { };
  runtimeDir = "/run/seaweedfs-s3-provisioner";
  filerRuntimeDir = "/run/seaweedfs-filer";
  provisionerAgentName = "seaweedfs-s3-provisioner";
  provisionerAgentDir = "/run/seaweedfs-agent-s3-provisioner";
  provisionerTokenFile = "${provisionerAgentDir}/openbao.token";
  provisionerRoleIdSecretName = "seaweedfs-s3-provisioner-approle-role-id";
  provisionerSecretIdSecretName = "seaweedfs-s3-provisioner-approle-secret-id";
  provisionerRoleIdFile = config.age.secrets.${provisionerRoleIdSecretName}.path;
  provisionerSecretIdFile = config.age.secrets.${provisionerSecretIdSecretName}.path;

  renderBucket = bucket: ''
    bucket_id=${lib.escapeShellArg bucket.id}
    bucket_name=${lib.escapeShellArg bucket.name}
    if bucket_exists "$bucket_name"; then
      log "bucket $bucket_id ($bucket_name): already exists; create skipped to preserve metadata"
    else
      log "bucket $bucket_id ($bucket_name): absent; creating with static admin ownership"
      if run_weed "create bucket $bucket_name" "s3.bucket.create -name $bucket_name -owner admin" 1; then
        bucket_exists "$bucket_name" || die "bucket $bucket_name was not visible after creation"
        log "bucket $bucket_id ($bucket_name): created"
      elif bucket_exists "$bucket_name"; then
        log "bucket $bucket_id ($bucket_name): present after ambiguous create result; left untouched"
      else
        die "bucket creation failed for $bucket_name; it remains absent"
      fi
    fi
  '';
  renderGrant =
    id: grant:
    let
      pathParts = lib.splitString "/" grant.openbao.path;
      permissions = builtins.toJSON (lib.sort builtins.lessThan grant.permissions);
      bucketName =
        if builtins.hasAttr grant.bucket registry.buckets then
          registry.buckets.${grant.bucket}.name
        else
          "";
      mount = builtins.elemAt pathParts 0;
      path = lib.concatStringsSep "/" (lib.drop 2 pathParts);
      policyName = "jorthaus-s3-${id}";
    in
    ''
      grant_id=${lib.escapeShellArg id}
      bucket_id=${lib.escapeShellArg grant.bucket}
      bucket_name=${lib.escapeShellArg bucketName}
      permissions=${lib.escapeShellArg permissions}
      openbao_path=${lib.escapeShellArg grant.openbao.path}
      mount=${lib.escapeShellArg mount}
      path=${lib.escapeShellArg path}
      policy_name=${lib.escapeShellArg policyName}
      POLICY_ACTION=
      IDENTITY_ACTION=

      log "grant $grant_id: reconciling bucket $bucket_name with permissions $permissions"
      identity_exists=false
      binding_exists=false
      if get_user "$grant_id"; then
        identity_exists=true
      fi
      if get_binding "$grant_id" "$mount" "$path"; then
        binding_exists=true
        ACCESS_KEY=$(<"$ACCESS_FILE")
        SECRET_KEY=$(<"$SECRET_FILE")
        if [[ "$identity_exists" == true ]]; then
          verify_user_key "$grant_id" "$ACCESS_KEY"
        fi
      else
        status=$?
        (( status == 2 )) || die "failed to inspect binding for $grant_id"
        if [[ "$identity_exists" == true ]]; then
          die "IAM identity $grant_id exists without an OpenBao binding; refusing to create or replace credentials"
        fi
        random_key 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' 21 "$ACCESS_FILE"
        random_key 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789' 42 "$SECRET_FILE"
        ACCESS_KEY=$(<"$ACCESS_FILE")
        SECRET_KEY=$(<"$SECRET_FILE")
        printf '{}\n' >"$CURRENT_DATA"
        log "grant $grant_id: generated a new credential pair in restricted runtime files"
      fi

      build_bundle "$bucket_name"
      if [[ "$binding_exists" == true ]]; then
        write_binding "$grant_id" "$mount" "$path" true
      else
        BINDING_VERSION=0
        write_binding "$grant_id" "$mount" "$path" false
      fi
      make_policy "$bucket_name" "$permissions"
      policy_existed=false
      if get_policy "$policy_name"; then
        policy_existed=true
        if policy_matches; then
          log "grant $grant_id: policy $policy_name already matches desired permissions"
          POLICY_ACTION=unchanged
        fi
      else
        status=$?
        (( status == 2 )) || die "failed to inspect policy $policy_name"
      fi
      if [[ "$policy_existed" == false || "$POLICY_ACTION" != unchanged ]]; then
        if run_weed "upsert policy $policy_name" "s3.policy -put -name $policy_name -file $EXPECTED_POLICY" 3; then
          :
        elif get_policy "$policy_name" && policy_matches; then
          log "grant $grant_id: policy write result was ambiguous; desired policy is present"
          POLICY_ACTION=verified_after_ambiguous_write
        else
          die "failed to upsert SeaweedFS policy $policy_name"
        fi
        if [[ "$POLICY_ACTION" != verified_after_ambiguous_write ]]; then
          get_policy "$policy_name" || die "SeaweedFS policy $policy_name was not readable after upsert"
          policy_matches || die "SeaweedFS policy read-back mismatch for $policy_name"
          if [[ "$policy_existed" == true ]]; then POLICY_ACTION=updated; else POLICY_ACTION=created; fi
          log "grant $grant_id: policy $policy_name $POLICY_ACTION"
        fi
      fi

      if get_user "$grant_id"; then
        verify_user_key "$grant_id" "$ACCESS_KEY"
        IDENTITY_ACTION=verified
        log "grant $grant_id: existing IAM identity and canonical key verified"
      else
        command="s3.user.create -name $grant_id -access_key $ACCESS_KEY -secret_key $SECRET_KEY"
        log "grant $grant_id: creating IAM identity from its OpenBao-stored credential pair"
        if run_weed "create IAM identity $grant_id" "$command" 1 true; then
          :
        elif get_user "$grant_id" && verify_user_key "$grant_id" "$ACCESS_KEY"; then
          IDENTITY_ACTION=created_after_ambiguous_result
          log "grant $grant_id: identity exists with canonical key after ambiguous create result"
        else
          die "IAM identity creation failed for $grant_id; credential values suppressed"
        fi
        if [[ "$IDENTITY_ACTION" != created_after_ambiguous_result ]]; then
          get_user "$grant_id" || die "SeaweedFS did not return the created IAM identity $grant_id"
          verify_user_key "$grant_id" "$ACCESS_KEY"
          IDENTITY_ACTION=created
          log "grant $grant_id: IAM identity created and canonical key verified"
        fi
      fi
      run_weed "attach policy $policy_name to $grant_id" \
        "s3.policy.attach -policy $policy_name -user $grant_id" 3 \
        || {
          if get_user "$grant_id" \
            && "$JQ" -e --arg id "$grant_id" --arg policy "$policy_name" \
              'any(.[]; .name == $id and (.policies | index($policy) != null))' "$OUT" >/dev/null; then
            log "grant $grant_id: policy attach result was ambiguous; attachment is present"
          else
            die "failed to attach policy $policy_name to $grant_id"
          fi
        }
      get_user "$grant_id" || die "IAM identity $grant_id disappeared after policy attachment"
      "$JQ" -e --arg id "$grant_id" --arg policy "$policy_name" \
        'any(.[]; .name == $id and (.policies | index($policy) != null))' "$OUT" >/dev/null \
        || die "policy $policy_name is not attached to IAM identity $grant_id"
      log "grant $grant_id: complete; bucket=$bucket_name permissions=$permissions "\
        "binding-version=$BINDING_VERSION policy=$POLICY_ACTION identity=$IDENTITY_ACTION attached=yes"
    '';

  provisioner = pkgs.writeScriptBin "jorthaus-seaweedfs-s3-provisioner" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    umask 0077
    export LC_ALL=C

    WEED=${lib.escapeShellArg (lib.getExe' pkgs.seaweedfs "weed")}
    BAO=${lib.escapeShellArg (lib.getExe pkgs.openbao)}
    JQ=${lib.escapeShellArg (lib.getExe pkgs.jq)}
    OPENSSL=${lib.escapeShellArg (lib.getExe pkgs.openssl)}
    COREUTILS=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "timeout")}
    TR=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "tr")}
    HEAD=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "head")}
    WC=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "wc")}
    AWK=${lib.escapeShellArg (lib.getExe' pkgs.gawk "awk")}
    GREP=${lib.escapeShellArg (lib.getExe' pkgs.gnugrep "grep")}
    MKFIFO=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "mkfifo")}
    MKTEMP=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "mktemp")}
    CMP=${lib.escapeShellArg (lib.getExe' pkgs.diffutils "cmp")}

    MASTER=${lib.escapeShellArg cfg.master.peers}
    FILER=${lib.escapeShellArg "127.0.0.1:${toString cfg.filer.port}"}
    BAO_ADDR="https://openbao.service.jort.haus:8200"
    BAO_CACERT=${lib.escapeShellArg "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"}
    TOKEN_FILE=${lib.escapeShellArg provisionerTokenFile}
    RUNTIME_DIR=${lib.escapeShellArg runtimeDir}
    LOCK_PID=
    LOCK_ACQUIRED=false
    ACCESS_KEY=
    SECRET_KEY=

    log() {
      printf 'SeaweedFS S3 provisioner: %s\n' "$*"
    }

    die() {
      log "ERROR: $*" >&2
      exit 1
    }

    TMP_DIR=$("$MKTEMP" -d "$RUNTIME_DIR/work.XXXXXX") || die "cannot create a restricted runtime directory"
    chmod 0700 "$TMP_DIR"
    OUT="$TMP_DIR/command.out"
    ERR="$TMP_DIR/command.err"
    LOCK_IN="$TMP_DIR/lock.in"
    LOCK_OUT="$TMP_DIR/lock.out"
    LOCK_ERR="$TMP_DIR/lock.err"
    KV_FILE="$TMP_DIR/openbao-kv.json"
    CURRENT_DATA="$TMP_DIR/current-data.json"
    BUNDLE_FILE="$TMP_DIR/bundle.json"
    ACCESS_FILE="$TMP_DIR/access-key"
    SECRET_FILE="$TMP_DIR/secret-key"
    POLICY_FILE="$TMP_DIR/policy.json"
    CURRENT_POLICY="$TMP_DIR/current-policy.json"
    EXPECTED_POLICY="$TMP_DIR/expected-policy.json"

    cleanup() {
      set +e
      if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        if [[ "$LOCK_ACQUIRED" == true ]]; then
          printf 'unlock\nexit\n' >&3 2>/dev/null
        else
          kill "$LOCK_PID" 2>/dev/null
        fi
        exec 3>&- 2>/dev/null
        exec 4<&- 2>/dev/null
        if wait "$LOCK_PID" 2>/dev/null; then
          [[ "$LOCK_ACQUIRED" == true ]] && log "cluster administrative lock released"
        elif [[ "$LOCK_ACQUIRED" == true ]]; then
          log "warning: cluster lock session did not exit cleanly"
        fi
      elif [[ "$LOCK_ACQUIRED" == true ]]; then
        log "warning: cluster lock session exited before cleanup"
      fi
      rm -rf "$TMP_DIR"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    check_lock() {
      [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null \
        || die "SeaweedFS cluster lock session exited unexpectedly"
      if "$GREP" -qF 'Failed to renew lock' "$LOCK_ERR" 2>/dev/null; then
        die "SeaweedFS cluster lock renewal failed"
      fi
    }

    acquire_lock() {
      "$MKFIFO" "$LOCK_IN" "$LOCK_OUT" || die "cannot create lock-session pipes"
      exec 3<>"$LOCK_IN"
      "$WEED" shell -master="$MASTER" -filer="$FILER" \
        <"$LOCK_IN" >"$LOCK_OUT" 2>"$LOCK_ERR" &
      LOCK_PID=$!
      exec 4<"$LOCK_OUT"
      printf 'lock\nfs.pwd\n' >&3
      log "waiting for SeaweedFS cluster administrative lock"

      for _ in {1..300}; do
        if IFS= read -r -t 1 marker <&4; then
          if [[ "$marker" == "/" ]]; then
            LOCK_ACQUIRED=true
            log "cluster administrative lock acquired"
            return
          fi
          [[ -z "$marker" ]] || log "lock session: $marker"
        elif ! kill -0 "$LOCK_PID" 2>/dev/null; then
          die "SeaweedFS shell exited before acquiring the cluster lock"
        fi
      done
      die "timed out after 300 seconds waiting for the SeaweedFS cluster lock"
    }

    run_weed() {
      local label="$1"
      local command="$2"
      local retries="$3"
      local sensitive="''${4:-false}"
      local quiet_missing="''${5:-}"
      local attempt status detail

      for (( attempt = 1; attempt <= retries; attempt++ )); do
        check_lock
        if printf '%s\nexit\n' "$command" \
          | "$COREUTILS" 60 "$WEED" shell -master="$MASTER" -filer="$FILER" \
              >"$OUT" 2>"$ERR"; then
          return 0
        else
          status=$?
        fi

        if [[ -n "$quiet_missing" ]] && "$GREP" -qiE "$quiet_missing" "$ERR"; then
          return 2
        fi
        if [[ "$sensitive" == true ]]; then
          detail="details suppressed for a secret-bearing command"
        else
          detail=$(<"$ERR")
          [[ -n "$detail" ]] || detail="weed shell exited with status $status"
        fi
        if (( attempt < retries )); then
          log "$label attempt $attempt/$retries failed (status $status): $detail; retrying"
          sleep $((attempt * 2))
        else
          log "$label failed after $retries attempt(s) (status $status): $detail" >&2
          return "$status"
        fi
      done
      return 1
    }

    run_bao_get() {
      local label="$1"
      local mount="$2"
      local path="$3"
      local attempt status detail

      for (( attempt = 1; attempt <= 3; attempt++ )); do
        if BAO_ADDR="$BAO_ADDR" BAO_CACERT="$BAO_CACERT" BAO_TOKEN="$BAO_TOKEN" \
          "$COREUTILS" 45 "$BAO" kv get -format=json "-mount=$mount" "$path" >"$OUT" 2>"$ERR"; then
          cp "$OUT" "$KV_FILE"
          return 0
        else
          status=$?
        fi
        if "$GREP" -qi 'no value found' "$ERR"; then
          return 2
        fi
        detail=$(<"$ERR")
        [[ -n "$detail" ]] || detail="bao exited with status $status"
        if (( attempt < 3 )); then
          log "$label attempt $attempt/3 failed (status $status): $detail; retrying"
          sleep $((attempt * 2))
        else
          die "$label failed after 3 attempts (status $status): $detail"
        fi
      done
    }

    write_binding() {
      local grant_id="$1"
      local mount="$2"
      local path="$3"
      local existed="$4"
      local detail status

      if [[ "$existed" == true ]]; then
        "$JQ" -S . "$CURRENT_DATA" >"$TMP_DIR/current.sorted"
      else
        printf '{}\n' >"$TMP_DIR/current.sorted"
      fi
      "$JQ" -S . "$BUNDLE_FILE" >"$TMP_DIR/bundle.sorted"
      if "$CMP" -s "$TMP_DIR/current.sorted" "$TMP_DIR/bundle.sorted"; then
        log "grant $grant_id: OpenBao binding unchanged; KVv2 version $BINDING_VERSION"
        return
      fi

      if BAO_ADDR="$BAO_ADDR" BAO_CACERT="$BAO_CACERT" BAO_TOKEN="$BAO_TOKEN" \
        "$COREUTILS" 45 "$BAO" kv put "-mount=$mount" "$path" "@$BUNDLE_FILE" >"$OUT" 2>"$ERR"; then
        :
      else
        status=$?
        detail=$(<"$ERR")
        log "grant $grant_id: OpenBao write returned status $status; checking whether it committed"
        if run_bao_get "verify ambiguous OpenBao write for $grant_id" "$mount" "$path"; then
          if "$JQ" -e --slurpfile expected "$BUNDLE_FILE" '.data.data == $expected[0]' "$KV_FILE" >/dev/null; then
            BINDING_VERSION=$("$JQ" -er '.data.metadata.version' "$KV_FILE")
            log "grant $grant_id: OpenBao write was committed; KVv2 version $BINDING_VERSION"
            return
          fi
        fi
        die "OpenBao binding write failed for $grant_id: $detail"
      fi

      if ! run_bao_get "read back OpenBao binding for $grant_id" "$mount" "$path"; then
        die "OpenBao binding for $grant_id was not readable after write"
      fi
      "$JQ" -e --slurpfile expected "$BUNDLE_FILE" '.data.data == $expected[0]' "$KV_FILE" >/dev/null \
        || die "OpenBao binding read-back mismatch for $grant_id"
      BINDING_VERSION=$("$JQ" -er '.data.metadata.version' "$KV_FILE")
      if [[ "$existed" == true ]]; then
        log "grant $grant_id: canonical OpenBao binding updated; KVv2 version $BINDING_VERSION"
      else
        log "grant $grant_id: canonical OpenBao binding created; KVv2 version $BINDING_VERSION"
      fi
    }

    random_key() {
      local alphabet="$1"
      local length="$2"
      local destination="$3"
      local attempt count

      for attempt in {1..3}; do
        set +o pipefail
        "$OPENSSL" rand -base64 256 \
          | "$TR" -dc "$alphabet" \
          | "$HEAD" -c "$length" >"$destination"
        set -o pipefail
        count=$("$WC" -c <"$destination")
        if (( count == length )); then
          chmod 0600 "$destination"
          return 0
        fi
      done
      die "cryptographic credential generation returned an unexpected length"
    }

    list_buckets() {
      run_weed "list buckets" "s3.bucket.list" 3 \
        || die "could not list SeaweedFS buckets"
    }

    bucket_exists() {
      local name="$1"
      list_buckets
      "$AWK" -v name="$name" '$1 == name { found = 1 } END { exit !found }' "$OUT"
    }

    get_user() {
      local grant_id="$1"
      run_weed "list IAM identities" "s3.user.list" 3 \
        || die "could not list SeaweedFS IAM identities"
      local count
      count=$("$JQ" --arg name "$grant_id" '[.[] | select(.name == $name)] | length' "$OUT")
      if (( count > 1 )); then
        die "SeaweedFS returned duplicate IAM identities named $grant_id"
      fi
      if (( count == 0 )); then
        return 1
      fi
      "$JQ" -e --arg name "$grant_id" \
        'any(.[]; .name == $name and .status == "enabled")' "$OUT" >/dev/null \
        || die "IAM identity $grant_id exists but is disabled; refusing to change it"
      return 0
    }

    verify_user_key() {
      local grant_id="$1"
      local expected="$2"
      local found=false
      local active=false
      local key status extra_count=0

      run_weed "list access keys for $grant_id" "s3.accesskey.list -user $grant_id" 3 \
        || die "could not list access keys for IAM identity $grant_id"
      while read -r key status; do
        [[ "$key" == "ACCESS" || "$key" == "No" || -z "$key" ]] && continue
        if [[ "$key" == "$expected" ]]; then
          found=true
          [[ "$status" == "Active" || "$status" == "active" ]] && active=true
        else
          extra_count=$((extra_count + 1))
        fi
      done <"$OUT"

      [[ "$found" == true ]] \
        || die "IAM identity $grant_id exists without its canonical OpenBao key; refusing implicit rotation"
      [[ "$active" == true ]] \
        || die "canonical access key for IAM identity $grant_id is not active"
      if (( extra_count > 0 )); then
        log "IAM identity $grant_id: canonical key verified; preserving $extra_count additional key(s)"
      fi
    }

    get_binding() {
      local grant_id="$1"
      local mount="$2"
      local path="$3"
      local status

      if run_bao_get "read OpenBao binding for $grant_id" "$mount" "$path"; then
        if ! "$JQ" -e --arg id "$grant_id" '
          .data.data as $data
          | (if ($data | has("schema_version")) then
               $data.schema_version == 1 and $data.grant_id == $id
             else true end)
            and ($data.access_key_id | (type == "string" and test("^[A-Z0-9]{21}$")))
            and ($data.secret_access_key | (type == "string" and test("^[A-Za-z0-9]{42}$")))
            and ($data.bucket | (type == "string" and length > 0))
            and ($data.endpoint | (type == "string" and startswith("https://")))
            and ($data.region | (type == "string" and test("^[a-z0-9][a-z0-9-]*$")))
        ' "$KV_FILE" >/dev/null; then
          die "OpenBao binding for $grant_id has invalid consumer metadata or credential fields"
        fi
        "$JQ" -r '.data.data.access_key_id' "$KV_FILE" >"$ACCESS_FILE"
        "$JQ" -r '.data.data.secret_access_key' "$KV_FILE" >"$SECRET_FILE"
        "$JQ" -c '.data.data' "$KV_FILE" >"$CURRENT_DATA"
        BINDING_VERSION=$("$JQ" -er '.data.metadata.version' "$KV_FILE")
        return 0
      else
        status=$?
      fi
      (( status == 2 )) && return 2
      die "could not read OpenBao binding for $grant_id"
    }

    build_bundle() {
      local bucket_name="$1"

      "$JQ" -n \
        --arg bucket "$bucket_name" \
        --arg endpoint ${lib.escapeShellArg registry.endpoint} \
        --arg region ${lib.escapeShellArg registry.region} \
        --rawfile access_key_id "$ACCESS_FILE" \
        --rawfile secret_access_key "$SECRET_FILE" \
        '{
          access_key_id: ($access_key_id | rtrimstr("\n")),
          bucket: $bucket,
          endpoint: $endpoint,
          region: $region,
          secret_access_key: ($secret_access_key | rtrimstr("\n"))
        }' >"$BUNDLE_FILE"
      chmod 0600 "$BUNDLE_FILE"
    }

    make_policy() {
      local bucket_name="$1"
      local permissions="$2"
      "$JQ" -n --arg bucket "$bucket_name" --argjson permissions "$permissions" '
        {
          Version: "2012-10-17",
          Statement: [
            (if ($permissions | index("list")) != null then {
              Effect: "Allow",
              Action: ["s3:ListBucket"],
              Resource: ["arn:aws:s3:::" + $bucket]
            } else empty end),
            (if ($permissions | index("read")) != null then {
              Effect: "Allow",
              Action: ["s3:GetObject"],
              Resource: ["arn:aws:s3:::" + $bucket + "/*"]
            } else empty end),
            (if ($permissions | index("write")) != null then {
              Effect: "Allow",
              Action: ["s3:PutObject"],
              Resource: ["arn:aws:s3:::" + $bucket + "/*"]
            } else empty end),
            (if ($permissions | index("delete")) != null then {
              Effect: "Allow",
              Action: ["s3:DeleteObject"],
              Resource: ["arn:aws:s3:::" + $bucket + "/*"]
            } else empty end)
          ]
        }
      ' >"$EXPECTED_POLICY"
    }

    policy_matches() {
      local normalization='
        .Statement |= map(
          if (.Action | type) == "string" then .Action = [.Action] else . end
          | if (.Resource | type) == "string" then .Resource = [.Resource] else . end
        )
      '
      "$JQ" -S "$normalization" "$CURRENT_POLICY" >"$TMP_DIR/current-policy.canonical"
      "$JQ" -S "$normalization" "$EXPECTED_POLICY" >"$TMP_DIR/expected-policy.canonical"
      "$CMP" -s "$TMP_DIR/current-policy.canonical" "$TMP_DIR/expected-policy.canonical"
    }

    get_policy() {
      local policy_name="$1"
      if run_weed "read policy $policy_name" "s3.policy -get -name $policy_name" 1 false 'policy not found|notfound'; then
        "$JQ" -S . "$OUT" >"$CURRENT_POLICY" \
          || die "SeaweedFS policy $policy_name is not valid JSON"
        return 0
      else
        if "$GREP" -qiE 'policy not found|notfound' "$ERR"; then
          return 2
        fi
        die "could not read SeaweedFS policy $policy_name"
      fi
    }

    main() {
      [[ -r "$TOKEN_FILE" ]] || die "OpenBao token file is unavailable"
      BAO_TOKEN=$(<"$TOKEN_FILE")
      [[ -n "$BAO_TOKEN" ]] || die "OpenBao token file is empty"
      log "starting compiled registry reconciliation"
      acquire_lock
      log "reconciling declared buckets and grants"
      ${lib.concatMapStrings renderBucket (
        lib.mapAttrsToList (id: bucket: bucket // { inherit id; }) registry.buckets
      )}
      ${lib.concatStrings (lib.mapAttrsToList (id: grant: renderGrant id grant) registry.grants)}
      log "reconciliation succeeded"
    }

    main
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.controlplaneEnabled && isProvisionerHost && hasRegistry) {
    age.secrets.${provisionerRoleIdSecretName} = {
      file = ../../../../secrets/seaweedfs-s3-provisioner-approle-role-id.age;
      owner = "seaweedfs-filer";
      group = "seaweedfs";
      mode = "0400";
    };
    age.secrets.${provisionerSecretIdSecretName} = {
      file = ../../../../secrets/seaweedfs-s3-provisioner-approle-secret-id.age;
      owner = "seaweedfs-filer";
      group = "seaweedfs";
      mode = "0400";
    };

    services.vault-agent.instances.${provisionerAgentName} = {
      package = pkgs.openbao;
      user = "seaweedfs-filer";
      group = "seaweedfs";
      settings = {
        pid_file = "${provisionerAgentDir}/vault-agent.pid";
        vault = {
          address = "https://openbao.service.jort.haus:8200";
          tls_server_name = "openbao.service.jort.haus";
          ca_cert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
        auto_auth = [
          {
            method = [
              {
                type = "approle";
                mount_path = "auth/approle";
                config = {
                  role_id_file_path = provisionerRoleIdFile;
                  secret_id_file_path = provisionerSecretIdFile;
                  remove_secret_id_file_after_reading = false;
                };
              }
            ];
            sink = [
              {
                type = "file";
                config = {
                  path = provisionerTokenFile;
                  mode = 256;
                };
              }
            ];
          }
        ];
      };
    };

    systemd.services."vault-agent-${provisionerAgentName}" = {
      after = [
        "network-online.target"
        "agenix.service"
      ]
      ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      wants = [
        "network-online.target"
        "agenix.service"
      ]
      ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "seaweedfs-agent-s3-provisioner";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    environment.systemPackages = [ provisioner ];

    systemd.services.jorthaus-seaweedfs-s3-provisioner = {
      description = "Reconcile registry-managed SeaweedFS S3 buckets and grants";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "seaweedfs-filer.service"
        "vault-agent-${provisionerAgentName}.service"
      ];
      wants = [
        "network-online.target"
        "seaweedfs-filer.service"
        "vault-agent-${provisionerAgentName}.service"
      ];
      unitConfig.ConditionPathExists = [ "${filerRuntimeDir}/.seaweedfs/security.toml" ];
      preStart = ''
        for _ in $(seq 1 60); do
          if test -s ${lib.escapeShellArg provisionerTokenFile}; then
            exit 0
          fi
          sleep 1
        done
        echo "timed out waiting for the SeaweedFS S3 provisioner AppRole token" >&2
        exit 1
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "seaweedfs-filer";
        Group = "seaweedfs";
        Environment = [ "HOME=${filerRuntimeDir}" ];
        EnvironmentFile = "${cfg.tls.dir}/jwt.env";
        WorkingDirectory = filerRuntimeDir;
        RuntimeDirectory = "seaweedfs-s3-provisioner";
        RuntimeDirectoryMode = "0750";
        UMask = "0077";
        ExecStart = lib.getExe provisioner;
        TimeoutStartSec = "20min";
        TimeoutStopSec = "30s";
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
