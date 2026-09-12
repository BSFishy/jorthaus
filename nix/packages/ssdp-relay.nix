{ pkgs }:
let
  relay = pkgs.stdenv.mkDerivation {
    pname = "udp-broadcast-relay-redux";
    version = "5a5cd384bc944f40ebda3658b08ce0c1c9f00182";
    src = pkgs.fetchzip {
      url = "https://github.com/udp-redux/udp-broadcast-relay-redux/archive/5a5cd384bc944f40ebda3658b08ce0c1c9f00182.tar.gz";
      hash = "sha256-1T3zBqfseECr+jRD5BHWgcDOfSohDVaTNfAmfUvk+hY=";
    };
    installPhase = ''
      install -Dm755 udp-broadcast-relay-redux $out/bin/udp-broadcast-relay-redux
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "jorthaus-ssdp-relay";
  tag = relay.version;
  contents = [ relay ];
  config.Entrypoint = [ "${relay}/bin/udp-broadcast-relay-redux" ];
}
