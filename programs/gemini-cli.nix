{ config, lib, pkgs, ... }:

let
  npmInstall = lib.hm.dag.entryAfter ["installPackages"] ''
    export PATH=${pkgs.nodejs}/bin:$PATH
    mkdir -p "$HOME/node_modules"
    if [ ! -x "$HOME/node_modules/bin/gemini" ]; then
      npm install -g @google/gemini-cli@latest --prefix "$HOME/node_modules" --ignore-scripts
    fi
  '';
in {
  home.activation.npmInstallGeminiCli = npmInstall;
}
