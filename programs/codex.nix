{ pkgs, inputs, ... }:

let
  codex = inputs.codex-nix.packages.${pkgs.system}.default;

  codexWrapper = pkgs.writeShellScriptBin "codexvenv" ''
    source ~/.venv/bin/activate
    exec "${codex}/bin/codex" "$@"
  '';
in {
  home.packages = [ codexWrapper ];
}
