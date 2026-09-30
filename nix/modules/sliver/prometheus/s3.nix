{ ... }:
{
  jorthaus.s3.buckets.thanos = { };

  jorthaus.s3.grants.thanos = {
    bucket = "thanos";
    permissions = [
      "delete"
      "list"
      "read"
      "write"
    ];
  };
}
