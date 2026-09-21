{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jorthaus.xfsQuota;
  projects = lib.mapAttrsToList (name: project: project // { inherit name; }) cfg.projects;
  projectsByFileSystem = lib.groupBy (project: project.fileSystem) projects;
  quotaServiceName = name: "xfs_quota-${name}";
  mountUnitName =
    fileSystem: "${lib.removePrefix "-" (lib.replaceStrings [ "/" ] [ "-" ] fileSystem)}.mount";
  capacityServiceName =
    fileSystem:
    "jorthaus-xfs-quota-capacity-${
      lib.removePrefix "-" (lib.replaceStrings [ "/" ] [ "-" ] fileSystem)
    }";
  validQuota = quota: builtins.match "^[1-9][0-9]*g$" quota != null;
  quotaToBytes = quota: "$(quota_bytes ${lib.escapeShellArg quota})";
in
{
  options.jorthaus.xfsQuota = {
    projects = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.ints.positive;
              description = "XFS project ID.";
            };
            fileSystem = lib.mkOption {
              type = lib.types.str;
              description = "Mount point of the XFS filesystem containing the project.";
            };
            path = lib.mkOption {
              type = lib.types.str;
              description = "Directory assigned to the XFS project.";
            };
            quota = lib.mkOption {
              type = lib.types.str;
              description = "Hard quota as a whole GiB value with a lowercase g suffix.";
            };
          };
        }
      );
      default = { };
      description = "XFS project quota claims supplied by storage-owning slivers.";
    };

    minimumHeadroom = lib.mkOption {
      type = lib.types.str;
      default = "100g";
      description = "Unallocated capacity required on each filesystem with XFS project quotas.";
    };
  };

  config = lib.mkIf (cfg.projects != { }) {
    assertions = [
      {
        assertion = validQuota cfg.minimumHeadroom;
        message = "The XFS project quota minimum headroom must be a positive whole GiB value with a lowercase g suffix.";
      }
      {
        assertion = lib.all (project: validQuota project.quota) projects;
        message = "XFS project quota limits must be positive whole GiB values with a lowercase g suffix.";
      }
    ];

    programs.xfs_quota.projects = lib.mapAttrs (_: project: {
      inherit (project) id path;
      fileSystem = project.fileSystem;
      sizeHardLimit = project.quota;
    }) cfg.projects;

    systemd.services =
      lib.mapAttrs' (
        fileSystem: fileSystemProjects:
        let
          capacityService = capacityServiceName fileSystem;
          quotaUnits = map (project: "${quotaServiceName project.name}.service") fileSystemProjects;
        in
        lib.nameValuePair capacityService {
          description = "Validate ${fileSystem} capacity for XFS project quotas";
          requiredBy = quotaUnits;
          before = quotaUnits;
          requires = [ (mountUnitName fileSystem) ];
          after = [
            (mountUnitName fileSystem)
            "systemd-tmpfiles-setup.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            quota_bytes() {
              quota="$1"
              ${pkgs.coreutils}/bin/numfmt --from=iec "''${quota%g}G"
            }

            read -r block_size blocks < <(${pkgs.coreutils}/bin/stat -f --format='%S %b' ${fileSystem})
            total_bytes=$((block_size * blocks))
            required_bytes=$(quota_bytes ${lib.escapeShellArg cfg.minimumHeadroom})
            ${lib.concatMapStringsSep "\n" (
              project: "required_bytes=$((required_bytes + ${quotaToBytes project.quota}))"
            ) fileSystemProjects}

            if (( required_bytes > total_bytes )); then
              echo "XFS project quotas plus required headroom exceed ${fileSystem}" >&2
              exit 1
            fi
          '';
        }
      ) projectsByFileSystem
      // lib.mapAttrs' (
        name: project:
        lib.nameValuePair (quotaServiceName name) {
          requires = [ "${capacityServiceName project.fileSystem}.service" ];
          after = [
            "${capacityServiceName project.fileSystem}.service"
            "systemd-tmpfiles-setup.service"
          ];
        }
      ) cfg.projects;
  };
}
