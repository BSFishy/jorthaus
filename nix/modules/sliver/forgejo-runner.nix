{
  config,
  host,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  runnerHosts = lib.filter (peer: peer.slivers.forgejoRunner.enable) (
    builtins.attrValues hostInventory
  );
  enabled = host.slivers.forgejoRunner.enable;
  tokenFile = config.jorthaus.openbao.secrets.forgejoRunnerToken.filePath;
  uuidFile = config.jorthaus.openbao.secrets.forgejoRunnerUUID.filePath;
  runnerService = "forgejo-runner-forgejo";
  runnerUnit = "${runnerService}.service";
  buildkitUnit = "buildkitd.service";
  buildkitUid = 1999;
  buildkitGid = 1999;
  buildkitSocket = "/var/lib/buildkit/buildkitd.sock";
  buildkitConfig = pkgs.writeText "buildkitd.toml" ''
    [worker.oci]
      gc = true
      reservedSpace = "2GB"
      maxUsedSpace = "20GB"
      minFreeSpace = "10GB"
      max-parallelism = 2
  '';
  runnerLabels = lib.optional enabled "linux-x86_64:docker://node:22.16.0-bookworm-slim";
  systemdServices = lib.optionals (runnerHosts != [ ]) [
    {
      unit = runnerUnit;
      sliver = "forgejoRunner";
      severity = "warning";
    }
    {
      unit = buildkitUnit;
      sliver = "forgejoRunner";
      severity = "warning";
    }
  ];
in
{
  config = lib.mkMerge [
    { jorthaus.prometheus.systemdServices = systemdServices; }
    (lib.mkIf enabled {
      assertions = [
        {
          assertion = runnerLabels != [ ];
          message = "The Forgejo runner on ${host.hostname} requires at least one enabled runner label.";
        }
      ];

      jorthaus.prometheus.localSystemdServices = [
        runnerUnit
        buildkitUnit
      ];

      jorthaus.openbao.secrets.forgejoRunnerToken = {
        path = "metal/forgejo/runners/${host.hostname}";
        key = "token";
        owner = "root";
        group = "root";
        mode = "0400";
        consumers = [
          {
            unit = runnerUnit;
            onChange = "restart";
          }
        ];
      };
      jorthaus.openbao.secrets.forgejoRunnerUUID = {
        path = "metal/forgejo/runners/${host.hostname}";
        key = "uuid";
        owner = "root";
        group = "root";
        mode = "0400";
        consumers = [
          {
            unit = runnerUnit;
            onChange = "restart";
          }
        ];
      };

      users.groups.buildkit.gid = buildkitGid;
      users.users.buildkit = {
        uid = buildkitUid;
        isNormalUser = true;
        group = "buildkit";
        home = "/var/lib/buildkit";
        createHome = false;
        subUidRanges = [
          {
            startUid = 100000;
            count = 65536;
          }
        ];
        subGidRanges = [
          {
            startGid = 100000;
            count = 65536;
          }
        ];
      };

      services.forgejo-runner = {
        package = pkgs.forgejo-runner;
        instances.forgejo = {
          enable = true;
          settings = {
            runner = {
              labels = runnerLabels;
              capacity = 1;
              timeout = "2h";
              shutdown_timeout = "15m";
            };
            server.connections.default = {
              url = "https://git.jort.haus";
              uuid = "@FORGEJO_RUNNER_UUID@";
            };
            container = {
              docker_host = "-";
              privileged = false;
              valid_volumes = [ buildkitSocket ];
              options = "--cpus=2 --memory=6g --memory-swap=6g --pids-limit=2048 --group-add=${toString buildkitGid} --volume=${buildkitSocket}:${buildkitSocket}";
            };
            cache.enabled = false;
          };
          secrets.server.connections.default.token_url = tokenFile;
        };
      };

      systemd.services.${runnerService} = {
        requires = [ buildkitUnit ];
        after = [ buildkitUnit ];
        preStart = ''
          cp ${config.services.forgejo-runner.instances.forgejo.configFile} ./config.yaml
          chmod u+w ./config.yaml
          ${lib.getExe pkgs.replace-secret} "@FORGEJO_RUNNER_UUID@" "$CREDENTIALS_DIRECTORY/UUID" ./config.yaml
          chmod u-w ./config.yaml
        '';
        path = with pkgs; [
          bash
          coreutils
          findutils
          gawk
          gnugrep
          gnused
          util-linux
        ];
        serviceConfig = {
          ExecStart = lib.mkForce "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config ./config.yaml";
          LoadCredential = [ "UUID:${uuidFile}" ];
          SupplementaryGroups = [ "buildkit" ];
          CPUQuota = "100%";
          MemoryMax = "2G";
          TasksMax = 512;
          TimeoutStopSec = "16min";
        };
      };

      systemd.services.buildkitd = {
        description = "Rootless BuildKit daemon for Forgejo Actions jobs";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [
          "/run/wrappers"
        ]
        ++ (with pkgs; [
          bash
          buildkit
          coreutils
          iproute2
          rootlesskit
          runc
          shadow
          slirp4netns
          util-linux
        ]);
        serviceConfig = {
          Type = "simple";
          User = "buildkit";
          Group = "buildkit";
          Environment = [ "HOME=/var/lib/buildkit" ];
          WorkingDirectory = "/var/lib/buildkit";
          StateDirectory = "buildkit";
          StateDirectoryMode = "0700";
          UMask = "0007";
          ExecStart = "${pkgs.rootlesskit}/bin/rootlesskit --net=slirp4netns --disable-host-loopback --copy-up=/etc --copy-up=/run --state-dir=/var/lib/buildkit/rootlesskit ${pkgs.buildkit}/bin/buildkitd --config ${buildkitConfig} --addr unix://${buildkitSocket} --oci-worker-snapshotter=auto --oci-worker-binary=${pkgs.runc}/bin/runc";
          CPUQuota = "200%";
          MemoryMax = "4G";
          TasksMax = 512;
          Restart = "on-failure";
          RestartSec = 2;
        };
      };

      virtualisation.podman.enable = true;
    })
  ];
}
