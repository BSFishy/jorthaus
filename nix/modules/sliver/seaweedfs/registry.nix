{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  registry = config.jorthaus.s3;
  logicalIdValid =
    value:
    builtins.stringLength value <= 64 && builtins.match "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" value != null;
  bucketNameValid =
    value:
    builtins.stringLength value >= 3
    && builtins.stringLength value <= 63
    && builtins.match "^[a-z0-9][a-z0-9.-]*[a-z0-9]$" value != null
    && !(lib.hasInfix ".." value)
    && !(lib.hasInfix ".-" value)
    && !(lib.hasInfix "-." value)
    && value != "filemeta"
    && !(lib.hasPrefix "xn--" value)
    && !(lib.hasSuffix "-s3alias" value)
    && builtins.match "^[0-9]+(\\.[0-9]+){3}$" value == null;
  openbaoPathValid =
    value:
    builtins.match "^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$" value != null
    && !(builtins.any (
      segment:
      builtins.elem segment [
        "."
        ".."
      ]
    ) (lib.splitString "/" value));
  endpointMatch = builtins.match "^https://([A-Za-z0-9][A-Za-z0-9.-]*)(:([0-9]+))?(/[^[:space:]]*)?$" registry.endpoint;
  endpointHost = if endpointMatch == null then "" else builtins.elemAt endpointMatch 0;
  endpointPort = if endpointMatch == null then "" else builtins.elemAt endpointMatch 2;
  endpointValid =
    endpointMatch != null
    && builtins.stringLength endpointHost <= 253
    && !(lib.hasInfix ".." endpointHost)
    && !(lib.hasInfix ".-" endpointHost)
    && !(lib.hasInfix "-." endpointHost)
    && lib.all (
      label:
      builtins.stringLength label <= 63
      && builtins.match "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$" label != null
    ) (lib.splitString "." endpointHost)
    && (
      endpointPort == ""
      || (
        builtins.stringLength endpointPort <= 5
        && builtins.fromJSON endpointPort >= 1
        && builtins.fromJSON endpointPort <= 65535
      )
    );

  bucketType = types.submodule (
    { name, ... }:
    {
      options.name = mkOption {
        type = types.str;
        default = name;
        description = "SeaweedFS S3 bucket name; defaults to this registry key.";
      };
    }
  );
  grantType = types.submodule (
    { name, ... }:
    {
      options = {
        bucket = mkOption {
          type = types.str;
          description = "Logical ID of the granted bucket.";
        };

        permissions = mkOption {
          type = types.listOf (
            types.enum [
              "list"
              "read"
              "write"
              "delete"
            ]
          );
          description = "S3 capabilities granted by this bucket-scoped identity.";
        };

        openbao.path = mkOption {
          type = types.str;
          default = "seaweedfs/data/s3/bindings/${name}";
          description = "OpenBao KVv2 API path for this grant's canonical credential and consumer bundle.";
        };
      };
    }
  );

  ids = builtins.attrNames registry.buckets ++ builtins.attrNames registry.grants;
  grantIds = builtins.attrNames registry.grants;
  bucketNames = map (bucket: bucket.name) (builtins.attrValues registry.buckets);
  openbaoPaths = map (grant: grant.openbao.path) (builtins.attrValues registry.grants);
  grants = builtins.attrValues registry.grants;
  provisioningInput = {
    schema_version = 1;
    endpoint = registry.endpoint;
    region = registry.region;
    buckets = lib.mapAttrs (_: bucket: { name = bucket.name; }) registry.buckets;
    grants = lib.mapAttrs (id: grant: {
      identity_name = id;
      bucket_id = grant.bucket;
      bucket_name =
        if builtins.hasAttr grant.bucket registry.buckets then
          registry.buckets.${grant.bucket}.name
        else
          null;
      permissions = grant.permissions;
      openbao_path = grant.openbao.path;
    }) registry.grants;
  };
  grantsHaveValidPermissions = lib.all (
    grant:
    grant.permissions != [ ]
    && builtins.length grant.permissions == builtins.length (lib.unique grant.permissions)
  ) grants;
in
{
  # App modules contributing S3 resources must be imported by every
  # SeaweedFS control-plane evaluation so the leader reconciles the full set.
  options.jorthaus.s3 = {
    endpoint = mkOption {
      type = types.str;
      default = "https://s3.service.jort.haus:8443";
      description = "HTTPS endpoint shared by registry-managed S3 consumers.";
    };

    region = mkOption {
      type = types.str;
      default = "us-east-1";
      description = "AWS signing region shared by registry-managed S3 consumers.";
    };

    buckets = mkOption {
      type = types.attrsOf bucketType;
      default = { };
      description = "S3 buckets declared alongside the applications that use them.";
    };

    grants = mkOption {
      type = types.attrsOf grantType;
      default = { };
      description = "Stable bucket-scoped identities and credentials declared alongside their consumers.";
    };
  };

  config.environment.etc."seaweedfs/s3-registry.json" =
    lib.mkIf config.jorthaus.seaweedfs.controlplaneEnabled
      {
        text = builtins.toJSON provisioningInput;
      };

  config.assertions = [
    {
      assertion = endpointValid;
      message = "jorthaus.s3.endpoint must be an HTTPS URL with a valid DNS-style host and optional port.";
    }
    {
      assertion = builtins.match "^[a-z0-9]+(-[a-z0-9]+)*$" registry.region != null;
      message = "jorthaus.s3.region must be a lowercase AWS-style region name with non-empty hyphen-separated segments.";
    }
    {
      assertion = lib.all logicalIdValid ids;
      message = "SeaweedFS S3 registry IDs must be lowercase alphanumeric/hyphen names of at most 64 characters.";
    }
    {
      assertion = !(builtins.elem "admin" grantIds);
      message = "SeaweedFS S3 grant ID 'admin' is reserved for the existing static IAM identity.";
    }
    {
      assertion = lib.all bucketNameValid bucketNames;
      message = "SeaweedFS S3 bucket names must satisfy the pinned SeaweedFS bucket-name rules.";
    }
    {
      assertion = builtins.length bucketNames == builtins.length (lib.unique bucketNames);
      message = "SeaweedFS S3 bucket names must be unique.";
    }
    {
      assertion = lib.all openbaoPathValid openbaoPaths;
      message = "SeaweedFS S3 OpenBao paths must be relative KVv2 API paths without dot or parent-directory components.";
    }
    {
      assertion = lib.all (path: lib.hasPrefix "seaweedfs/data/s3/bindings/" path) openbaoPaths;
      message = "SeaweedFS S3 grant OpenBao paths must be under seaweedfs/data/s3/bindings/.";
    }
    {
      assertion = builtins.length openbaoPaths == builtins.length (lib.unique openbaoPaths);
      message = "SeaweedFS S3 grant OpenBao paths must be unique.";
    }
    {
      assertion = lib.all (grant: builtins.hasAttr grant.bucket registry.buckets) grants;
      message = "Every SeaweedFS S3 grant must reference a declared bucket ID.";
    }
    {
      assertion = grantsHaveValidPermissions;
      message = "Every SeaweedFS S3 grant must declare a non-empty, duplicate-free permission list.";
    }
  ];
}
