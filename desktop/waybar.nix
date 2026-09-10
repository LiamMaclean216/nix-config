{ pkgs, lib, ... }:

let
  theme = import ./theme.nix;
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
      passthrough = true;
      height = 32;
      spacing = 6;
      margin = "0 5 5 0";
      modules-left = [ ];
      modules-center = [ ];
      modules-right = [  "clock" ];

      clock = {
        format = "{:%a %d %b  %H:%M}";
        tooltip = false;
      };
    };

    style = theme.gtkColors + ''
      * {
        border: none;
        border-radius: 0;
        font-family: "${theme.font}", "Noto Sans", sans-serif;
        font-size: 12pt;
        font-weight: 500;
        min-height: 0;
      }

      window#waybar {
        background: transparent;
        color: @foreground;
        padding: 0;
        margin: 0;
      }

      #clock {
        background: @background;
        border-radius: ${toString theme.radius}px;
        padding: 11px 20px 9px 20px;
        letter-spacing: 0.3px;
        color: @foreground;
        border: none;
        font-family: "${theme.font}", "Noto Sans", sans-serif;
        font-weight: 400;
      }

    '';
  };
}
