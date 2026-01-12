{ pkgs, ... }:

let
  discordStatusScript = pkgs.writeShellScript "waybar-discord-status" ''
    set -euo pipefail

    data="$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null || printf '[]')"

    if [ -z "$data" ]; then
      echo '{"text":"","class":"discord","tooltip":"Discord"}'
      exit 0
    fi

    urgent=$(${pkgs.jq}/bin/jq -r '
      map(select(
        ((.class // "") | ascii_downcase == "discord") or
        ((.initialClass // "") | ascii_downcase == "discord")
      ) | select(.urgent == true))
      | length > 0
    ' <<<"$data" 2>/dev/null || printf 'false')

    if [ "$urgent" = "true" ]; then
      echo '{"text":"","class":"discord unread","tooltip":"Unread Discord notifications"}'
    else
      echo '{"text":"","class":"discord","tooltip":"Discord"}'
    fi
  '';
in
{
  programs.waybar = {
    enable = true;
    package = pkgs.waybar;

    settings.mainBar = {
      layer = "overlay";
      position = "bottom";
      exclusive = false;
      passthrough = false;
      height = 32;
      spacing = 6;
      margin = "0 10 10 0";
      modules-left = [ ];
      modules-center = [ ];
      modules-right = [  "clock" ];

      clock = {
        format = "{:%a %d %b  %H:%M}";
        tooltip = false;
      };
    };

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 12pt;
        font-weight: 500;
        min-height: 0;
      }

      window#waybar {
        background: transparent;
        color: #d8deeb;
        padding: 0;
        margin: 0;
      }

      #clock {
        background: rgb(30, 30, 35);
        border-radius: 999px;
        padding: 11px 20px 9px 20px;
        letter-spacing: 0.3px;
        color: #ffffff;
        border: 1px solid rgb(0, 0, 0);
        transition: opacity 0.3s ease;
        font-family: "FiraCode Nerd Font", monospace;
        font-weight: 400;
      }

      #clock:hover {
        opacity: 0;
      }
    '';
  };
}
