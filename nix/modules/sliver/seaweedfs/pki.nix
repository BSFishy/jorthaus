{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.seaweedfs;
  roleIdSecretName = "seaweedfs-approle-role-id";
  secretIdSecretName = "seaweedfs-approle-secret-id";
  roleIdFile = config.age.secrets.${roleIdSecretName}.path;
  secretIdFile = config.age.secrets.${secretIdSecretName}.path;
  pkiAgentDir = "/run/seaweedfs-agent-pki";
  tokenFile = "${pkiAgentDir}/openbao.token";
  internalTlsDir = cfg.tls.dir;
  jwtEnvFile = "${internalTlsDir}/jwt.env";
  altNames = lib.concatStringsSep "," cfg.tls.altNames;
  restartHelper = pkgs.writeShellScript "jorthaus-seaweedfs-security-refresh" ''
    set -eu

    for unit in seaweedfs-master.service seaweedfs-filer.service seaweedfs-volume.service; do
      if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        systemctl restart "$unit"
      fi
    done
  '';
  # TODO: Tighten the public-facing SeaweedFS security posture once the client
  # set is stable. The current config allows broad CORS and does not require a
  # client certificate for filer HTTPS.
  sharedSecurityToml = ''
    [cors.allowed_origins]
    values = "*"

    [grpc]
    ca = "${cfg.tls.caFile}"
    allowed_wildcard_domain = ".node.jort.haus"

    [grpc.master]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"

    [grpc.filer]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"

    [grpc.volume]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"

    [grpc.client]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"

    [https.client]
    enabled = true
    ca = "${cfg.tls.caFile}"

    [https.master]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"

    [https.filer]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"
    disable_tls_verify_client_cert = true

    [https.volume]
    cert = "${cfg.tls.certFile}"
    key = "${cfg.tls.keyFile}"
  '';
  issueInternalCert = pkgs.writeShellScript "jorthaus-seaweedfs-issue-internal-cert" ''
    set -euo pipefail

    if [ -s ${cfg.tls.certFile} ] && [ -s ${cfg.tls.keyFile} ] && [ -s ${cfg.tls.caFile} ] \
      && ${lib.getExe pkgs.openssl} x509 -checkend $((7 * 24 * 60 * 60)) -noout -in ${cfg.tls.certFile}
    then
      exit 0
    fi

    for _ in $(seq 1 60); do
      if [ -s ${tokenFile} ]; then
        break
      fi
      sleep 1
    done

    [ -s ${tokenFile} ]

    export BAO_ADDR=https://openbao.service.jort.haus:8200
    export BAO_TOKEN="$(tr -d '\n' < ${tokenFile})"

    issue_args=(
      ${lib.getExe pkgs.openbao}
      write
      -format=json
      seaweedfs-pki/issue/seaweedfs-node
      common_name=${cfg.tls.commonName}
      ttl=720h
    )

    if [ -n '${altNames}' ]; then
      issue_args+=("alt_names=${altNames}")
    fi

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    "''${issue_args[@]}" > "$tmpdir/issue.json"

    ${lib.getExe pkgs.python3} - "$tmpdir/issue.json" ${cfg.tls.certFile} ${cfg.tls.keyFile} ${cfg.tls.caFile} <<'PY'
import json
import os
import sys

issue_path, cert_path, key_path, ca_path = sys.argv[1:5]
with open(issue_path, "r", encoding="utf-8") as f:
    data = json.load(f)["data"]

ca_chain = data.get("ca_chain") or []
ca_pem = "\n".join(ca_chain).strip()
if not ca_pem:
    ca_pem = (data.get("issuing_ca") or "").strip()

for path, value in (
    (cert_path, (data["certificate"] + "\n").strip() + "\n"),
    (key_path, (data["private_key"] + "\n").strip() + "\n"),
    (ca_path, ca_pem + ("\n" if ca_pem else "")),
):
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)
PY

    chown root:seaweedfs ${cfg.tls.certFile} ${cfg.tls.keyFile} ${cfg.tls.caFile}
    chmod 0640 ${cfg.tls.certFile} ${cfg.tls.caFile}
    chmod 0640 ${cfg.tls.keyFile}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # TODO: Reduce the remaining SeaweedFS agenix bootstrap material once node
    # authentication can be modeled in a more OpenBao-native way.
    age.secrets.${roleIdSecretName} = {
      file = ../../../../secrets/seaweedfs-approle-role-id.age;
      owner = "root";
      group = "seaweedfs";
      mode = "0440";
    };

    age.secrets.${secretIdSecretName} = {
      file = ../../../../secrets/seaweedfs-approle-secret-id.age;
      owner = "root";
      group = "seaweedfs";
      mode = "0440";
    };

    environment.etc."seaweedfs/security.toml".text = sharedSecurityToml;

    systemd.tmpfiles.rules = [
      "d ${internalTlsDir} 0750 root seaweedfs -"
    ];

    services.vault-agent.instances.seaweedfs-pki = {
      package = pkgs.openbao;
      user = "root";
      group = "seaweedfs";
      settings = {
        pid_file = "${pkiAgentDir}/vault-agent.pid";

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
                  role_id_file_path = roleIdFile;
                  secret_id_file_path = secretIdFile;
                  remove_secret_id_file_after_reading = false;
                };
              }
            ];

            sink = [
              {
                type = "file";
                config = {
                  path = tokenFile;
                  mode = 256;
                };
              }
            ];
          }
        ];

        template_config.static_secret_render_interval = "5m";

        template = [
          {
            destination = jwtEnvFile;
            perms = 288;
            contents = ''
              {{- with secret "seaweedfs/data/security" }}
              WEED_JWT_SIGNING_KEY={{ .Data.data.jwt_signing_key }}
              WEED_JWT_SIGNING_READ_KEY={{ .Data.data.jwt_signing_read_key }}
              WEED_JWT_FILER_SIGNING_KEY={{ .Data.data.jwt_filer_signing_key }}
              WEED_JWT_FILER_SIGNING_READ_KEY={{ .Data.data.jwt_filer_signing_read_key }}
              {{- end }}
            '';
          }
        ];
      };
    };

    systemd.services.vault-agent-seaweedfs-pki = {
      after = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      wants = [
        "network-online.target"
        "agenix.service"
      ] ++ lib.optionals host.slivers.openbao.enable [ "openbao.service" ];
      serviceConfig = {
        RuntimeDirectory = lib.mkForce "seaweedfs-agent-pki";
        RuntimeDirectoryMode = lib.mkForce "0750";
      };
    };

    systemd.services.jorthaus-seaweedfs-pki-renew = {
      description = "Issue or renew SeaweedFS internal TLS materials";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "vault-agent-seaweedfs-pki.service"
      ];
      wants = [
        "network-online.target"
        "vault-agent-seaweedfs-pki.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "seaweedfs";
        ExecStart = issueInternalCert;
      };
    };

    systemd.services.jorthaus-seaweedfs-security-refresh = {
      description = "Gracefully restart SeaweedFS services after security secret changes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = restartHelper;
      };
    };

    systemd.paths.jorthaus-seaweedfs-security-refresh = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = jwtEnvFile;
        Unit = "jorthaus-seaweedfs-security-refresh.service";
      };
    };

    systemd.timers.jorthaus-seaweedfs-pki-renew = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15m";
        OnUnitActiveSec = "24h";
        RandomizedDelaySec = "30m";
        Unit = "jorthaus-seaweedfs-pki-renew.service";
      };
    };
  };
}
