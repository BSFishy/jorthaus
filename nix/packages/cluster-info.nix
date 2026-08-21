{ pkgs, system, hostNames }:
pkgs.writeShellApplication {
  name = "cluster-info";
  text = ''
    echo "system: ${system}"
    echo "hosts: ${builtins.concatStringsSep ", " hostNames}"
  '';
}
