{ config, lib, pkgs, ... }:

let
  npmInstall = lib.hm.dag.entryAfter ["installPackages"] ''
    export PATH=${pkgs.nodejs}/bin:$PATH
    mkdir -p "$HOME/node_modules"
    if [ ! -x "$HOME/node_modules/bin/opencode" ]; then
      npm install -g opencode-ai --prefix "$HOME/node_modules" --ignore-scripts
    fi
  '';

  # Wrapper script that activates venv before running opencode
  opencodeWrapper = pkgs.writeShellScriptBin "opencodevenv" ''
    source ~/.venv/bin/activate
    exec "$HOME/node_modules/bin/opencode" "$@"
  '';
in {
  home.activation.npmInstallOpenCode = npmInstall;

  # Add the wrapper to PATH (takes precedence over the npm-installed one)
  home.packages = [ opencodeWrapper ];

  # Create config directory for opencode
  home.file.".config/opencode/.keep".text = ''
    # OpenCode configuration directory
  '';

}
