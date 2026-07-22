{ pkgs, inputs, ... }:

let
  codex = inputs.codex-nix.packages.${pkgs.system}.default;

  # `codex remote-control start` intentionally launches app-server from the
  # fixed standalone-installer path rather than resolving `codex` from PATH.
  # Mirror that layout while keeping the binary managed by Nix.
  codexStandalone = pkgs.runCommand "codex-standalone" { } ''
    mkdir -p "$out"
    ln -s "${codex}/bin/codex" "$out/codex"
  '';

  codexWrapper = pkgs.writeShellScriptBin "codexvenv" ''
    source ~/.venv/bin/activate
    exec "${codex}/bin/codex" "$@"
  '';
in {
  home.packages = [ codexWrapper ];

  home.file.".codex/packages/standalone/current".source = codexStandalone;
}
