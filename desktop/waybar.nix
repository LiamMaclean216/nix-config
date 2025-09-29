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
      height = 32;
      spacing = 6;
      margin = "0 24 24 0";
      modules-left = [ ];
      modules-center = [ ];
      modules-right = [ "custom/discord" "clock" ];

      "custom/discord" = {
        exec = "${discordStatusScript}";
        interval = 5;
        format = "{}";
        return-type = "json";
        tooltip = true;
        on-click = "discord";
      };

      clock = {
        format = "{:%a %d %b  %H:%M}";
        tooltip-format = "{:%A, %d %B %Y}\n%H:%M";
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
        color: #e5e9f0;
        padding: 0;
        margin: 0;
      }

      #modules-right {
        background: rgba(20, 22, 36, 0.28);
        border-radius: 999px;
        padding: 8px 18px;
        border: 1px solid rgba(180, 195, 255, 0.22);
        backdrop-filter: blur(18px) saturate(130%);
        box-shadow: 0 12px 32px rgba(5, 6, 11, 0.55);
        gap: 18px;
        align-items: center;
      }

      #modules-right > * {
        margin: 0;
      }

      #clock {
        letter-spacing: 0.5px;
      }

      #custom-discord {
        font-size: 16pt;
        color: #a5b4fc;
      }

      #custom-discord.unread {
        color: #f38ba8;
        text-shadow: 0 0 12px rgba(243, 139, 168, 0.85);
      }
    '';
  };
}
