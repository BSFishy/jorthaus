{
  lib,
  buildGo127Module,
  fetchFromGitHub,
}:
buildGo127Module rec {
  pname = "openbao-plugin-secrets-nats";
  version = "1.11.0";

  src = fetchFromGitHub {
    owner = "NatzkaLabsOpenSource";
    repo = "openbao-plugin-secrets-nats";
    rev = "d2ce83e18829bea868c97abf1f4f6968f4ccc8db";
    hash = "sha256-D4N03pab+1KeOXQrSv3zII+ZNQKsHIQaPyAZO6nZX7M=";
  };

  vendorHash = "sha256-39SOrXzG3h9OothQyss5kZfbEhnMiFDxoIa9kCug5Es=";
  patches = [ ./patches/openbao-plugin-secrets-nats-resolver-errors.patch ];

  subPackages = [ "cmd/openbao-plugin-secrets-nats" ];
  env.CGO_ENABLED = 0;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    go test ./...
    go vet ./...
    runHook postCheck
  '';

  passthru = {
    pluginType = "secret";
    pluginName = pname;
  };

  meta = {
    description = "NATS secrets engine plugin for OpenBao";
    homepage = "https://github.com/NatzkaLabsOpenSource/openbao-plugin-secrets-nats";
    license = lib.licenses.mpl20;
    mainProgram = pname;
  };
}
