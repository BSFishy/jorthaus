{ pkgs }:
let
  buildkitConfig = pkgs.writeText "buildkitd.toml" ''
    [worker.oci]
      gc = true
      reservedSpace = "2GB"
      maxUsedSpace = "20GB"
      minFreeSpace = "10GB"
      max-parallelism = 2
  '';
  containerImage = pkgs.dockerTools.buildLayeredImage {
    name = "test-image";
    tag = "latest";
    contents = [
      pkgs.bashInteractive
      pkgs.buildkit
      pkgs.coreutils
      pkgs.curl
      pkgs.gnutar
      pkgs.pkgsStatic.busybox
      pkgs.skopeo
    ];
    fakeRootCommands = ''
      mkdir -p ./etc/containers ./home/buildkit ./tmp ./var/tmp
      printf '%s' '{"default":[{"type":"insecureAcceptAnything"}]}' > ./etc/containers/policy.json
      printf '%s\n' 'unqualified-search-registries = ["docker.io"]' '[[registry]]' 'location = "localhost:3000"' 'insecure = true' > ./etc/containers/registries.conf
      printf '%s\n' 'buildkit:x:1000:1999:BuildKit:/home/buildkit:/bin/sh' >> ./etc/passwd
      printf '%s\n' 'buildkit:x:1999:' >> ./etc/group
      chmod 1777 ./tmp ./var/tmp
      chown -R 1000:1999 ./home/buildkit
    '';
    config = {
      Env = [
        "PATH=${
          pkgs.lib.makeBinPath [
            pkgs.bashInteractive
            pkgs.buildkit
            pkgs.coreutils
            pkgs.curl
            pkgs.gnutar
            pkgs.pkgsStatic.busybox
            pkgs.skopeo
          ]
        }:/bin:/usr/bin:/sbin:/usr/sbin"
        "HOME=/home/buildkit"
      ];
      User = "1000:1999";
    };
  };
  workflow = pkgs.writeText "forgejo-runner-buildkit-workflow.yaml" ''
    name: rootless BuildKit job test
    on: [push]
    jobs:
      build:
        runs-on: linux-x86_64
        container:
          image: test-image:latest
        steps:
          - name: Check the rootless BuildKit endpoint
            run: buildctl --addr unix:///var/lib/buildkit/buildkitd.sock debug workers
          - name: Build and push an OCI image to Forgejo
            run: |
              mkdir -p build-context
              cp "$(command -v busybox)" build-context/busybox
              printf '%s\n' 'FROM scratch' 'COPY busybox /busybox' 'RUN ["/busybox", "sh", "-c", "echo built-by-rootless-buildkit > /marker"]' > build-context/Dockerfile
              buildctl --addr unix:///var/lib/buildkit/buildkitd.sock build \
                --frontend dockerfile.v0 \
                --local context=build-context --local dockerfile=build-context \
                --output type=oci,dest=rootless-buildkit-image.tar
              skopeo copy --dest-creds test:hunter2 --dest-tls-verify=false \
                oci-archive:rootless-buildkit-image.tar \
                docker://localhost:3000/test/repo:rootless-buildkit-test
              curl --fail --silent --show-error --user test:hunter2 \
                -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
                http://localhost:3000/v2/test/repo/manifests/rootless-buildkit-test \
                -o pushed-manifest.json
              grep -q 'schemaVersion' pushed-manifest.json
              sleep 30
  '';
in
pkgs.testers.runNixOSTest {
  name = "jorthaus-forgejo-runner-rootless-buildkit";

  nodes.machine =
    { config, ... }:
    {
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 12288;

      users.groups.buildkit.gid = 1999;
      users.users.buildkit = {
        uid = 1999;
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

      services.forgejo = {
        enable = true;
        database.type = "sqlite3";
        settings = {
          server.HTTP_ADDR = "0.0.0.0";
          server.ROOT_URL = "http://localhost:3000/";
          actions.ENABLED = true;
          service.DISABLE_REGISTRATION = true;
        };
      };

      services.forgejo-runner = {
        package = pkgs.forgejo-runner;
        instances.standard = {
          enable = true;
          settings = {
            log = {
              level = "debug";
              job_level = "debug";
            };
            runner.labels = [ "linux-x86_64:docker://test-image:latest" ];
            runner.capacity = 1;
            server.connections.default = {
              url = "http://localhost:3000";
              uuid = "@UUID@";
            };
            container = {
              docker_host = "-";
              network = "host";
              privileged = false;
              valid_volumes = [ "/var/lib/buildkit/buildkitd.sock" ];
              options = "--cpus=1 --memory=6g --memory-swap=6g --pids-limit=2048 --group-add=1999 --volume=/var/lib/buildkit/buildkitd.sock:/var/lib/buildkit/buildkitd.sock";
            };
          };
          secrets.server.connections.default.token_url = "/var/lib/forgejo/runner_token";
        };
      };

      virtualisation.podman.enable = true;
      systemd.services.forgejo-runner-standard = {
        requires = [ "buildkitd.service" ];
        after = [ "buildkitd.service" ];
        wantedBy = pkgs.lib.mkForce [ ];
        preStart = ''
          cp ${config.services.forgejo-runner.instances.standard.configFile} ./config.yaml
          chmod u+w ./config.yaml
          ${pkgs.lib.getExe pkgs.replace-secret} "@UUID@" "$CREDENTIALS_DIRECTORY/UUID" ./config.yaml
          chmod u-w ./config.yaml
        '';
        serviceConfig = {
          SupplementaryGroups = [ "buildkit" ];
          ExecStart = pkgs.lib.mkForce "${pkgs.lib.getExe config.services.forgejo-runner.package} daemon --config ./config.yaml";
          LoadCredential = [ "UUID:/var/lib/forgejo/runner_uuid" ];
        };
      };
      systemd.services.buildkitd = {
        description = "Rootless BuildKit daemon for runner VM test";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [
          pkgs.buildkit
          pkgs.iproute2
          pkgs.rootlesskit
          pkgs.runc
          pkgs.shadow
          pkgs.slirp4netns
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "simple";
          User = "buildkit";
          Group = "buildkit";
          Environment = [
            "HOME=/var/lib/buildkit"
            "PATH=/run/wrappers/bin:${
              pkgs.lib.makeBinPath [
                pkgs.buildkit
                pkgs.iproute2
                pkgs.rootlesskit
                pkgs.runc
                pkgs.shadow
                pkgs.slirp4netns
                pkgs.util-linux
              ]
            }"
          ];
          WorkingDirectory = "/var/lib/buildkit";
          StateDirectory = "buildkit";
          StateDirectoryMode = "0700";
          UMask = "0007";
          ExecStart = "${pkgs.rootlesskit}/bin/rootlesskit --net=slirp4netns --disable-host-loopback --copy-up=/etc --copy-up=/run --state-dir=/var/lib/buildkit/rootlesskit ${pkgs.buildkit}/bin/buildkitd --config ${buildkitConfig} --addr unix:///var/lib/buildkit/buildkitd.sock --oci-worker-snapshotter=native --oci-worker-binary=${pkgs.runc}/bin/runc";
          CPUQuota = "100%";
          MemoryMax = "2G";
          TasksMax = 512;
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
      environment.systemPackages = [
        pkgs.buildkit
        pkgs.forgejo
        pkgs.forgejo-runner
        pkgs.gitMinimal
        pkgs.jq
        pkgs.podman
        pkgs.rootlesskit
        pkgs.runc
        pkgs.sqlite
        pkgs.tea
        pkgs.zstd
      ];
    };

  testScript = ''
    import json

    def tea_json(args):
        output = machine.succeed("tea " + args + " --login test -o json").strip()
        if not output.startswith(("[", "{")):
            return []
        return json.loads(output)

    def latest_task_log():
        return machine.succeed(
            "log_file=$(sqlite3 /var/lib/forgejo/data/forgejo.db "
            "'SELECT log_filename FROM action_task ORDER BY id DESC LIMIT 1'); "
            "if [ -n \"$log_file\" ]; then "
            "zstd -dc \"/var/lib/forgejo/data/actions_log/$log_file\" 2>&1 || true; "
            "else echo 'No task log recorded'; fi"
        )

    start_all()
    machine.wait_for_unit("forgejo.service")
    machine.wait_for_open_port(3000)
    machine.succeed("curl --fail http://localhost:3000/")
    machine.succeed(
        "su -l forgejo -c 'GITEA_WORK_DIR=/var/lib/forgejo forgejo admin user create "
        "--admin --username test --password hunter2 --email test@localhost "
        "--must-change-password=false'"
    )
    machine.succeed(
        "tea login add --url http://localhost:3000 --user test --password hunter2 -n test"
    )

    with subtest("Start Podman and the rootless BuildKit daemon"):
        machine.wait_for_unit("podman.socket")
        machine.wait_for_unit("buildkitd.service")
        machine.wait_until_succeeds(
            "test -S /var/lib/buildkit/buildkitd.sock && "
            "buildctl --addr unix:///var/lib/buildkit/buildkitd.sock debug workers",
            timeout=60,
        )
        socket_stat = machine.succeed("stat -c '%U %G %a' /var/lib/buildkit/buildkitd.sock").strip()
        assert socket_stat == "buildkit buildkit 660", socket_stat
        buildkit_limits = machine.succeed(
            "systemctl show buildkitd.service -p CPUQuotaPerSecUSec -p MemoryMax -p TasksMax"
        )
        assert "MemoryMax=2147483648" in buildkit_limits, buildkit_limits
        assert "TasksMax=512" in buildkit_limits, buildkit_limits

    with subtest("Load the test image and register the runner"):
        machine.succeed("podman load -i ${containerImage}")
        tea_json("repos create --name repo --init")
        machine.succeed(
            "umask 077 && curl --fail --silent --show-error --user test:hunter2 "
            "--header 'Content-Type: application/json' "
            "--data-binary '{\"name\":\"ci-standard\",\"description\":\"VM test runner\",\"ephemeral\":false}' "
            "http://localhost:3000/api/v1/admin/actions/runners "
            "> /var/lib/forgejo/runner.json && "
            "jq -er .uuid /var/lib/forgejo/runner.json > /var/lib/forgejo/runner_uuid && "
            "jq -er .token /var/lib/forgejo/runner.json > /var/lib/forgejo/runner_token && "
            "chmod 0600 /var/lib/forgejo/runner_uuid /var/lib/forgejo/runner_token /var/lib/forgejo/runner.json"
        )
        machine.systemctl("start forgejo-runner-standard.service")
        machine.wait_for_unit("forgejo-runner-standard.service")
        machine.wait_until_succeeds(
            "journalctl -u forgejo-runner-standard.service --grep 'declared successfully'"
        )

    with subtest("Create a BuildKit workflow"):
        machine.succeed("tea api -X PATCH /repos/test/repo --login test -f has_actions=true")
        machine.succeed(
            "tea api -X POST /repos/test/repo/contents/.forgejo%2Fworkflows%2Ftest.yaml "
            "--login test -f branch=main -f content=\"$(base64 -w0 ${workflow})\" "
            "-f message='Add workflow'"
        )

    with subtest("Assert job-container isolation and resource constraints"):
        for _ in range(120):
            found = machine.succeed(
                "podman ps --format '{{.ID}} {{.Image}}' | "
                "grep 'test-image:latest' || true"
            ).strip()
            if found:
                break
            machine.sleep(1)
        else:
            diagnostics = machine.succeed(
                "echo '=== runner journal ==='; "
                "journalctl -u forgejo-runner-standard.service -n 250 --no-pager || true; "
                "echo '=== BuildKit service ==='; "
                "systemctl status buildkitd.service --no-pager || true; "
                "journalctl -u buildkitd.service -n 200 --no-pager || true; "
                "echo '=== Podman containers ==='; podman ps -a --no-trunc || true; "
                "echo '=== latest Forgejo task log ==='; "
                "log_file=$(sqlite3 /var/lib/forgejo/data/forgejo.db "
                "'SELECT log_filename FROM action_task ORDER BY id DESC LIMIT 1'); "
                "if [ -n \"$log_file\" ]; then "
                "zstd -dc \"/var/lib/forgejo/data/actions_log/$log_file\" 2>&1 || true; "
                "else echo 'No task log recorded'; fi"
            )
            raise AssertionError("Runner did not create a job container:\\n" + diagnostics)
        rows = machine.succeed("podman ps --format '{{.ID}} {{.Image}}'").splitlines()
        matches = [row.split(maxsplit=1)[0] for row in rows if "test-image:latest" in row]
        assert len(matches) == 1, rows
        info = json.loads(machine.succeed("podman inspect " + matches[0]))[0]
        host = info["HostConfig"]
        assert host["Privileged"] is False, host
        assert "1999" in host["GroupAdd"], host
        assert (
            host["CpuQuota"],
            host["Memory"],
            host["MemorySwap"],
            host["PidsLimit"],
        ) == (100000, 6442450944, 6442450944, 2048), host
        mounted_paths = [
            mount.get(field, "")
            for mount in info.get("Mounts", [])
            for field in ("Source", "Destination")
        ]
        assert not any(
            "docker.sock" in path or "podman.sock" in path for path in mounted_paths
        ), mounted_paths
        assert any("buildkitd.sock" in path for path in mounted_paths), mounted_paths

    with subtest("Wait for BuildKit build and registry push"):
        runs = []
        for _ in range(60):
            runs = tea_json("actions runs list --repo test/repo")
            if any(run.get("status") in ("success", "failure", "cancelled") for run in runs):
                break
            machine.sleep(5)
        else:
            raise AssertionError(
                f"Workflow did not finish; latest runs: {runs}\\n{latest_task_log()}"
            )
        if len(runs) != 1 or runs[0].get("status") != "success":
            raise AssertionError(f"Workflow failed: {runs}\\n{latest_task_log()}")
        manifest = machine.succeed(
            "curl --fail --silent --show-error --user test:hunter2 "
            "-H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "
            "http://localhost:3000/v2/test/repo/manifests/rootless-buildkit-test"
        )
        assert '"schemaVersion"' in manifest, manifest
  '';
}
