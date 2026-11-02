{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.gracefulReboot;
  enabled = host.slivers.k3s.enable;
  k3sHosts = lib.filter (peer: peer.slivers.k3s.enable) (builtins.attrValues hostInventory);
  hooks = lib.sort (
    a: b: if a.order == b.order then a.name < b.name else a.order < b.order
  ) cfg.hooks;
  coordinator = pkgs.writeShellScriptBin "jorthaus-graceful-reboot-coordinator" ''
    set -Eeuo pipefail

    log() {
      printf '%s\n' "$*"
      ${pkgs.util-linux}/bin/logger --tag jorthaus-graceful-reboot -- "$*" || true
    }

    failure() {
      status=$?
      log "Graceful reboot aborted (status $status); inspect this failed unit before retrying."
      exit "$status"
    }
    trap failure ERR

    if [ "$#" -ne 0 ]; then
      log "The reboot coordinator does not accept arguments."
      exit 2
    fi

    ${lib.concatMapStringsSep "\n" (hook: ''
      log "Running reboot hook '${hook.name}'."
      ${pkgs.coreutils}/bin/timeout --foreground --kill-after=10s ${toString hook.timeoutSeconds}s ${lib.getExe hook.command}
      log "Reboot hook '${hook.name}' succeeded."
    '') hooks}

    log "All reboot hooks succeeded; requesting system reboot."
    ${pkgs.coreutils}/bin/timeout --foreground 30s ${pkgs.systemd}/bin/systemctl reboot
  '';
  kuredCommand = pkgs.writeShellScriptBin "jorthaus-kured-reboot" ''
    exec ${pkgs.systemd}/bin/systemctl start --wait jorthaus-graceful-reboot.service
  '';
  systemdServices = lib.optional (k3sHosts != [ ]) {
    unit = "jorthaus-graceful-reboot.service";
    sliver = "gracefulReboot";
    severity = "critical";
    alertWhenInactive = false;
  };
in
{
  options.jorthaus.gracefulReboot.hooks = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Unique name used to identify this reboot hook in logs.";
          };
          order = lib.mkOption {
            type = lib.types.int;
            description = "Execution order; hooks with equal order run by name.";
          };
          timeoutSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Maximum runtime for this hook before the reboot is aborted.";
          };
          command = lib.mkOption {
            type = lib.types.package;
            description = "Executable package for the hook.";
          };
        };
      }
    );
    default = [ ];
    description = "Ordered, bounded hooks that must succeed before a Kured reboot.";
  };

  config = lib.mkMerge [
    { jorthaus.prometheus.systemdServices = systemdServices; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion =
            lib.length (map (hook: hook.name) cfg.hooks)
            == lib.length (lib.unique (map (hook: hook.name) cfg.hooks));
          message = "Graceful reboot hook names must be unique.";
        }
      ];

      jorthaus.prometheus.localSystemdServices = [ "jorthaus-graceful-reboot.service" ];

      environment.systemPackages = [
        coordinator
        kuredCommand
      ];

      systemd.services.jorthaus-graceful-reboot = {
        description = "Run declared hooks before a Kured-managed reboot";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe coordinator;
          TimeoutStartSec = "15min";
          StandardOutput = "journal";
          StandardError = "journal";
        };
      };
    })
  ];
}
