set dotenv-load
set default-list := true

import 'terraform/justfile'

# ssh into a nixos node
[group('nix')]
ssh host:
  ssh matt@{{host}}.node.jort.haus

# build and switch a nixos node
[group('nix')]
switch host:
  nh os switch --elevation-strategy passwordless --target-host {{host}}.node.jort.haus .#{{host}}

# install a nixos node from a live environment over ssh
[group('nix')]
install-node target host:
  nix run nixpkgs#nixos-anywhere -- --flake .#{{host}} {{target}}

# create or edit an agenix-managed secret file
[group('secret')]
secret-edit name:
  agenix -e secrets/{{name}} -i "$HOME/.ssh/id_ed25519"

# re-encrypts all secrets with specified recipients
[group('secret')]
secret-rekey:
  agenix -r -i "$HOME/.ssh/id_ed25519"

# generate and encrypt a new random hex secret
[script]
[group('secret')]
secret-random name bytes='32':
  tmp=$(printf %s "$(nix-shell -p openssl --run 'openssl rand -hex {{bytes}}')")
  printf %s "$tmp" | agenix -e secrets/{{name}}

# generate & encrypt new openbao unsealing key
[group('secret')]
openbao-key name:
  just secret-random {{name}} 32
