{ pkgs, ... }:

let
  fastfetchLauncher = pkgs.writeShellScriptBin "alacritty-fastfetch" ''
    if command -v fastfetch >/dev/null 2>&1; then
      fastfetch
      printf '\n'
    fi

    target_shell="''${SHELL:-${pkgs.bashInteractive}/bin/bash}"
    exec "$target_shell" "$@"
  '';
in {
  home.file.".config/fastfetch/config.jsonc".text = ''
    {
      "$schema": "https://raw.githubusercontent.com/fastfetch-cli/fastfetch/master/doc/json_schema.json",
      "logo": {
        "type": "preset",
        "preset": "nixos_small",
        "padding": {
          "left": 1
        }
      },
      "modules": [
        {
          "type": "title",
          "separator": " ❄ ",
          "userColor": "#7ebae4",
          "hostColor": "#84b7f4"
        },
        {
          "type": "separator"
        },
        {
          "type": "os",
          "key": "OS",
          "keyColor": "#7ebae4"
        },
        {
          "type": "kernel",
          "key": "Kernel",
          "keyColor": "#7ebae4"
        },
        {
          "type": "host",
          "key": "Host",
          "keyColor": "#7ebae4"
        },
        {
          "type": "wm",
          "key": "WM",
          "keyColor": "#7ebae4"
        },
        {
          "type": "shell",
          "key": "Shell",
          "keyColor": "#7ebae4"
        },
        {
          "type": "packages",
          "key": "Packages",
          "keyColor": "#7ebae4"
        },
        {
          "type": "memory",
          "key": "Memory",
          "keyColor": "#7ebae4"
        },
        {
          "type": "uptime",
          "key": "Uptime",
          "keyColor": "#7ebae4"
        }
      ]
    }
  '';

  programs.alacritty = {
    enable = true;
    settings = {
      shell.program = "${fastfetchLauncher}/bin/alacritty-fastfetch";
    };
  };
}
