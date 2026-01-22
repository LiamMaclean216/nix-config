{ pkgs, lib, ... }:

let
  # Script to hide waybar when cursor is near bottom-right
  waybarHideScript = pkgs.writeShellScript "waybar-cursor-hide" ''
    set -euo pipefail
    
    HIDE_MARGIN_X=250  # pixels from right edge
    HIDE_MARGIN_Y=50   # pixels from bottom edge
    POLL_INTERVAL=0.1
    
    is_hidden=false
    
    while true; do
      # Get cursor position
      cursor=$(${pkgs.hyprland}/bin/hyprctl cursorpos -j 2>/dev/null || echo '{"x":0,"y":0}')
      cursor_x=$(echo "$cursor" | ${pkgs.jq}/bin/jq -r '.x')
      cursor_y=$(echo "$cursor" | ${pkgs.jq}/bin/jq -r '.y')
      
      # Get active monitor dimensions
      monitor=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0]')
      mon_width=$(echo "$monitor" | ${pkgs.jq}/bin/jq -r '.width')
      mon_height=$(echo "$monitor" | ${pkgs.jq}/bin/jq -r '.height')
      
      # Check if cursor is in bottom-right region
      in_region=false
      if [ "$cursor_x" -gt "$((mon_width - HIDE_MARGIN_X))" ] && [ "$cursor_y" -gt "$((mon_height - HIDE_MARGIN_Y))" ]; then
        in_region=true
      fi
      
      if [ "$in_region" = "true" ] && [ "$is_hidden" = "false" ]; then
        pkill -SIGUSR1 waybar 2>/dev/null || true
        is_hidden=true
      elif [ "$in_region" = "false" ] && [ "$is_hidden" = "true" ]; then
        pkill -SIGUSR1 waybar 2>/dev/null || true
        is_hidden=false
      fi
      
      sleep $POLL_INTERVAL
    done
  '';

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
        font-family: "FiraCode Nerd Font", monospace;
        font-weight: 400;
      }

    '';
  };

  # Systemd service to run the cursor-hide script
  systemd.user.services.waybar-cursor-hide = {
    Unit = {
      Description = "Hide waybar when cursor near bottom-right";
      After = [ "waybar.service" ];
      PartOf = [ "waybar.service" ];
    };
    Service = {
      ExecStart = "${waybarHideScript}";
      Restart = "always";
      RestartSec = 1;
    };
    Install.WantedBy = [ "waybar.service" ];
  };
}
