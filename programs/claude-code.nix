{ config, lib, pkgs, ... }:

let
  npmInstall = lib.hm.dag.entryAfter ["installPackages"] ''
    export PATH=${pkgs.nodejs}/bin:$PATH
    mkdir -p "$HOME/node_modules"
    if [ ! -x "$HOME/node_modules/bin/claude-code" ]; then
      npm install -g @anthropic-ai/claude-code --prefix "$HOME/node_modules" --ignore-scripts
    fi
  '';
in {
  home.activation.npmInstallClaudeCode = npmInstall;

  home.file.".claude/settings.json".text = ''
    {
      "apiKeyHelper": "${config.home.homeDirectory}/.claude/anthropic_key.sh"
    }
  '';

  home.file.".claude/anthropic_key.sh" = {
    text = ''
      #!/usr/bin/env bash
      echo "sk-your-anthropic-key"
    '';
    executable = true;
  };
}
