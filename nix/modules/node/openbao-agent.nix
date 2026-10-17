{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.openbao;
  enabled = cfg.secrets != { };
  types = lib.types;
  runtimeDirectory = cfg.agent.runtimeDirectory;
  runtimePath = "/run/${runtimeDirectory}";
  agentUnit = "vault-agent-metal.service";
  appRoleSecretIdName = "openbao-metal-secret-id";

  validLogicalPath =
    path:
    let
      components = lib.splitString "/" path;
    in
    lib.hasPrefix "metal/" path
    && builtins.match "metal(/[A-Za-z0-9._-]+)+" path != null
    && lib.all (component: component != "" && component != "." && component != "..") components
    && !(lib.elemAt components 1 == "data" || lib.elemAt components 1 == "metadata");

  validSecretName = name: builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
  validField = field: builtins.match "[A-Za-z_][A-Za-z0-9_]*" field != null;
  validMode = mode: builtins.match "0[0-7][0-7]0" mode != null;

  secretFilePath = name: "${runtimePath}/secrets/${name}";
  readinessMarkerPath = name: "${runtimePath}/ready/${name}";
  apiPath = path: "metal/data/${lib.removePrefix "metal/" path}";

  consumerOptions = {
    options = {
      unit = lib.mkOption {
        type = types.str;
        description = "Systemd service unit that requires this rendered secret.";
      };

      onChange = lib.mkOption {
        type = types.enum [
          "none"
          "reload"
          "restart"
        ];
        default = "none";
        description = "Action to request for the consumer when the rendered file changes.";
      };
    };
  };

  secretOptions =
    { name, ... }:
    {
      options = {
        path = lib.mkOption {
          type = types.str;
          description = "Logical KV v2 path below the metal/ mount.";
        };

        key = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "KV field rendered as the file contents; defaults to the value field.";
        };

        template = lib.mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "Optional OpenBao Agent template body evaluated against this KV record.";
        };

        owner = lib.mkOption {
          type = types.str;
          default = "root";
          description = "User that owns the rendered file.";
        };

        group = lib.mkOption {
          type = types.str;
          default = "root";
          description = "Group that owns the rendered file.";
        };

        mode = lib.mkOption {
          type = types.str;
          default = "0400";
          description = "Octal file mode; world permissions are not allowed.";
        };

        consumers = lib.mkOption {
          type = types.listOf (types.submodule consumerOptions);
          default = [ ];
          description = "Systemd services ordered after the initial render and optionally restarted on changes.";
        };

        filePath = lib.mkOption {
          type = types.str;
          readOnly = true;
          default = secretFilePath name;
          description = "Runtime path of the rendered secret file.";
        };
      };
    };

  postRenderScript =
    name: secret:
    let
      filePath = secret.filePath;
      ownerGroup = "${secret.owner}:${secret.group}";
      consumerCommands = lib.concatMapStringsSep "\n" (
        consumer:
        if consumer.onChange == "restart" then
          "${pkgs.systemd}/bin/systemctl --no-block try-restart ${lib.escapeShellArg consumer.unit}"
        else if consumer.onChange == "reload" then
          "${pkgs.systemd}/bin/systemctl --no-block try-reload-or-restart ${lib.escapeShellArg consumer.unit}"
        else
          "true"
      ) secret.consumers;
    in
    pkgs.writeShellScript "openbao-metal-${name}-post-render" ''
      set -eu
      ${pkgs.coreutils}/bin/chown -- ${lib.escapeShellArg ownerGroup} ${lib.escapeShellArg filePath}
      ${pkgs.coreutils}/bin/chmod ${lib.escapeShellArg secret.mode} ${lib.escapeShellArg filePath}
      ${consumerCommands}
      ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${lib.escapeShellArg (readinessMarkerPath name)}
    '';

  secretTemplate =
    name: secret:
    let
      field = if secret.key == null then "value" else secret.key;
      readExpression = ".Data.data.${field}";
      contents = if secret.template == null then "{{- ${readExpression} -}}" else secret.template;
    in
    {
      destination = secret.filePath;
      create_dest_dirs = false;
      perms = secret.mode;
      backup = false;
      error_on_missing_key = true;
      contents = ''
        {{- with secret "${apiPath secret.path}" -}}
        ${contents}
        {{- end -}}
      '';
      exec = {
        command = [ (toString (postRenderScript name secret)) ];
        timeout = "30s";
      };
    };

  secretAssertions = lib.concatLists (
    lib.mapAttrsToList (
      name: secret:
      [
        {
          assertion = validSecretName name;
          message = "jorthaus.openbao.secrets.${name} must use a simple identifier for its runtime file name.";
        }
        {
          assertion = validLogicalPath secret.path;
          message = "jorthaus.openbao.secrets.${name}.path must be a logical KV path below metal/ and must not contain traversal or API path components.";
        }
        {
          assertion = secret.key == null || validField secret.key;
          message = "jorthaus.openbao.secrets.${name}.key must be a simple field identifier.";
        }
        {
          assertion = secret.template == null || secret.key == null;
          message = "jorthaus.openbao.secrets.${name} must choose either key or template, not both.";
        }
        {
          assertion = validMode secret.mode;
          message = "jorthaus.openbao.secrets.${name}.mode must be a four-digit octal mode with no world permissions.";
        }
        {
          assertion = secret.owner == "root" || builtins.hasAttr secret.owner config.users.users;
          message = "jorthaus.openbao.secrets.${name}.owner must name a configured system user.";
        }
        {
          assertion = secret.group == "root" || builtins.hasAttr secret.group config.users.groups;
          message = "jorthaus.openbao.secrets.${name}.group must name a configured system group.";
        }
      ]
      ++ map (consumer: {
        assertion =
          lib.hasSuffix ".service" consumer.unit
          && builtins.match "[A-Za-z0-9_.@:-]+" (lib.removeSuffix ".service" consumer.unit) != null;
        message = "jorthaus.openbao.secrets.${name}.consumers units must be simple systemd service unit names ending in .service.";
      }) secret.consumers
    ) cfg.secrets
  );

  consumerServices = lib.concatMap (
    secret:
    map (consumer: {
      "${lib.removeSuffix ".service" consumer.unit}" = {
        requires = [ agentUnit ];
        after = [ agentUnit ];
      };
    }) secret.consumers
  ) (builtins.attrValues cfg.secrets);

  requiredMarkers = mapAttrsToList (name: _: readinessMarkerPath name) cfg.secrets;
  mapAttrsToList = lib.mapAttrsToList;
  renderedFilesCondition =
    if requiredMarkers == [ ] then
      "false"
    else
      lib.concatStringsSep " && " (map (marker: "[ -e ${lib.escapeShellArg marker} ]") requiredMarkers);

  initializeRuntimeFiles = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: secret: ''
      if [ -f ${lib.escapeShellArg secret.filePath} ]; then
        ${pkgs.coreutils}/bin/chown -- ${lib.escapeShellArg "${secret.owner}:${secret.group}"} ${lib.escapeShellArg secret.filePath}
        ${pkgs.coreutils}/bin/chmod ${lib.escapeShellArg secret.mode} ${lib.escapeShellArg secret.filePath}
        ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${lib.escapeShellArg (readinessMarkerPath name)}
      else
        ${pkgs.coreutils}/bin/rm -f -- ${lib.escapeShellArg (readinessMarkerPath name)}
      fi
    '') cfg.secrets
  );

  roleIdFile =
    if cfg.agent.appRole.roleIdFile != null then
      cfg.agent.appRole.roleIdFile
    else
      config.age.secrets.openbao-metal-role-id.path;
  secretIdFile =
    if cfg.agent.appRole.secretIdFile != null then
      cfg.agent.appRole.secretIdFile
    else
      config.age.secrets.${appRoleSecretIdName}.path;

  agentInstance = {
    package = cfg.agent.package;
    user = "root";
    group = "root";
    settings = {
      pid_file = cfg.agent.pidFile;
      vault = {
        address = cfg.agent.address;
        tls_server_name = cfg.agent.tlsServerName;
        ca_cert = cfg.agent.caCert;
      };
      auto_auth = [
        {
          method = [
            {
              type = "approle";
              mount_path = cfg.agent.appRole.mountPath;
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
                path = cfg.agent.tokenFile;
                mode = 256;
              };
            }
          ];
        }
      ];
      template_config.static_secret_render_interval = cfg.agent.staticSecretRenderInterval;
      template = lib.mapAttrsToList secretTemplate cfg.secrets;
    };
  };

  agentService = {
    after = cfg.agent.systemd.after;
    wants = cfg.agent.systemd.wants;
    startLimitIntervalSec = lib.mkForce 0;
    preStart = ''
      set -eu
      ${pkgs.coreutils}/bin/install -d -m 0711 ${lib.escapeShellArg "${runtimePath}/secrets"} ${lib.escapeShellArg "${runtimePath}/ready"}
      ${initializeRuntimeFiles}
    '';
    postStart = ''
      for _ in $(seq 1 ${toString cfg.agent.startTimeoutSeconds}); do
        if ${renderedFilesCondition}; then
          exit 0
        fi
        sleep 1
      done
      echo "OpenBao metal secrets were not rendered before the startup timeout." >&2
      exit 1
    '';
    serviceConfig = {
      RestartSec = cfg.agent.systemd.restartSec;
      TimeoutStartSec = "${toString (cfg.agent.startTimeoutSeconds + 30)}s";
      RuntimeDirectory = lib.mkForce runtimeDirectory;
      RuntimeDirectoryMode = lib.mkForce "0711";
    };
  };

  ageSecretDefaults = lib.mkMerge [
    (lib.mkIf (cfg.agent.appRole.roleIdFile == null) {
      openbao-metal-role-id = {
        file = ../../../secrets/openbao-metal-role-id.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    })
    (lib.mkIf (cfg.agent.appRole.secretIdFile == null) {
      "${appRoleSecretIdName}" = {
        file = ../../../secrets/openbao-metal-secret-id.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    })
  ];
in
{
  options.jorthaus.openbao = {
    agent = {
      package = lib.mkOption {
        type = types.package;
        default = pkgs.openbao;
        description = "OpenBao package used by the host-local Agent.";
      };

      address = lib.mkOption {
        type = types.str;
        default = "https://openbao.service.jort.haus:8200";
        description = "OpenBao API address used by the host-local Agent.";
      };

      tlsServerName = lib.mkOption {
        type = types.str;
        default = "openbao.service.jort.haus";
        description = "TLS server name expected from the OpenBao API endpoint.";
      };

      caCert = lib.mkOption {
        type = types.str;
        default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        description = "CA bundle used to verify the OpenBao API certificate.";
      };

      appRole = {
        mountPath = lib.mkOption {
          type = types.str;
          default = "auth/approle";
          description = "OpenBao AppRole authentication mount path.";
        };

        roleIdFile = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional path to a bootstrap RoleID file; defaults to the shared agenix-delivered file.";
        };

        secretIdFile = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Optional path to a bootstrap SecretID file; defaults to the shared agenix-delivered file.";
        };
      };

      staticSecretRenderInterval = lib.mkOption {
        type = types.str;
        default = "5m";
        description = "Interval at which the Agent refreshes static KV secrets.";
      };

      runtimeDirectory = lib.mkOption {
        type = types.str;
        default = "openbao-metal-agent";
        description = "Systemd runtime directory used for the Agent and rendered files.";
      };

      tokenFile = lib.mkOption {
        type = types.str;
        readOnly = true;
        default = "${runtimePath}/openbao.token";
        description = "Private AppRole token sink path; consumers should use rendered files instead.";
      };

      pidFile = lib.mkOption {
        type = types.str;
        readOnly = true;
        default = "${runtimePath}/vault-agent.pid";
        description = "Runtime PID file path used by the Agent.";
      };

      systemd = {
        after = lib.mkOption {
          type = types.listOf types.str;
          default = [
            "network-online.target"
            "agenix.service"
          ]
          ++ lib.optional host.slivers.openbao.enable "openbao.service";
          description = "Systemd ordering dependencies for the host-local Agent.";
        };

        wants = lib.mkOption {
          type = types.listOf types.str;
          default = [
            "network-online.target"
            "agenix.service"
          ]
          ++ lib.optional host.slivers.openbao.enable "openbao.service";
          description = "Systemd units requested with the host-local Agent.";
        };

        restartSec = lib.mkOption {
          type = types.str;
          default = "30s";
          description = "Delay before retrying the Agent after a failed startup or render gate.";
        };
      };

      startTimeoutSeconds = lib.mkOption {
        type = types.ints.positive;
        default = 120;
        description = "Maximum time the Agent waits for all declared files on startup.";
      };
    };

    secrets = lib.mkOption {
      type = types.attrsOf (types.submodule secretOptions);
      default = { };
      description = "Static KV v2 files rendered below metal/; any declaration automatically activates the Agent.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.match "[A-Za-z0-9_-]+" cfg.agent.runtimeDirectory != null;
          message = "jorthaus.openbao.agent.runtimeDirectory must be a simple directory name.";
        }
      ]
      ++ secretAssertions;
    }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion =
            cfg.agent.appRole.roleIdFile != null || builtins.hasAttr "openbao-metal-role-id" config.age.secrets;
          message = "The OpenBao metal Agent requires a RoleID file or the default agenix RoleID secret.";
        }
        {
          assertion =
            cfg.agent.appRole.secretIdFile != null || builtins.hasAttr appRoleSecretIdName config.age.secrets;
          message = "The OpenBao metal Agent requires a SecretID file or the shared default agenix SecretID.";
        }
      ];

      age.secrets = ageSecretDefaults;
      services.vault-agent.instances.metal = agentInstance;

      systemd.services = lib.mkMerge (
        [
          { vault-agent-metal = agentService; }
        ]
        ++ consumerServices
      );
    })
  ];
}
