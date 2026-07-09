{ config, lib, pkgs, inputs, ... }:

let
  claude-code = inputs.nix-claude-code.packages.${pkgs.system}.default;

  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };

  # Wrapper script that activates venv before running claude
  claudeWrapper = pkgs.writeShellScriptBin "claudevenv" ''
    source ~/.venv/bin/activate
    exec "${claude-code}/bin/claude" "$@"
  '';

  # Wrapper script that activates venv before running cursor-agent
  cursorWrapper = pkgs.writeShellScriptBin "cursorvenv" ''
    source ~/.venv/bin/activate
    exec "${pkgs-unstable.cursor-cli}/bin/cursor-agent" "$@"
  '';
in {
  # Add the wrappers to PATH
  home.packages = [ claudeWrapper cursorWrapper ];
}
