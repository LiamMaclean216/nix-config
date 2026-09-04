{ config, pkgs, lib, inputs, ... }:

let
  # Script to hide waybar when cursor is near bottom-right
  waybarHideScript = pkgs.writeShellScript "waybar-cursor-hide" ''
    set -euo pipefail
    
    HIDE_MARGIN_X=250  # pixels from right edge
    HIDE_MARGIN_Y=50   # pixels from bottom edge
    POLL_INTERVAL=0.1
    
    # Wait for waybar to start
    sleep 2
    
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
        # SIGUSR1 = hide waybar
        pkill -SIGUSR1 waybar 2>/dev/null || true
        is_hidden=true
      elif [ "$in_region" = "false" ] && [ "$is_hidden" = "true" ]; then
        # SIGUSR2 = show waybar
        pkill -SIGUSR2 waybar 2>/dev/null || true
        is_hidden=false
      fi
      
      sleep $POLL_INTERVAL
    done
  '';
in
{
  # Chromium/Electron may request the selected source multiple times while
  # preparing a screen share. Reuse the first permission instead of showing
  # Hyprland's share picker for every request.
  xdg.configFile."hypr/xdph.conf".text = ''
    screencopy {
        allow_token_by_default = true
    }
  '';

  # Pywal template for Hyprland colors
  home.file.".config/wal/templates/colors-hyprland.conf".text = ''
    $wallpaper = {wallpaper}
    $foregroundCol = 0xff{foreground.strip}
    $backgroundCol = 0xff{background.strip}
    $color0 = 0xff{color0.strip}
    $color1 = 0xff{color1.strip}
    $color2 = 0xff{color2.strip}
    $color3 = 0xff{color3.strip}
    $color4 = 0xff{color4.strip}
    $color5 = 0xff{color5.strip}
    $color6 = 0xff{color6.strip}
    $color7 = 0xff{color7.strip}
    $color8 = 0xff{color8.strip}
    $color9 = 0xff{color9.strip}
    $color10 = 0xff{color10.strip}
    $color11 = 0xff{color11.strip}
    $color12 = 0xff{color12.strip}
    $color13 = 0xff{color13.strip}
    $color14 = 0xff{color14.strip}
    $color15 = 0xff{color15.strip}
  '';

  # Pywal template for Mako notification colors
  home.file.".config/wal/templates/colors-mako".text = ''
    background-color={color0}
    text-color={color7}
    border-color={color4}
    progress-color=over {color2}

    [urgency=high]
    border-color={color1}
  '';

  wayland.windowManager.hyprland = {
    enable = true;

    plugins = [];

    # Export user environment to systemd (fixes PATH in services)
    systemd.variables = [ "--all" ];

    # Declarative Hyprland config translated from hyprland.conf
    extraConfig = ''
      source = ~/.cache/wal/colors-hyprland.conf
    '';

    settings = {
      "$mainMod" = "SUPER";

      env = [
        "XCURSOR_THEME,Adwaita"
        "XCURSOR_SIZE,24"
        "HYPRCURSOR_THEME,rose-pine-hyprcursor"
        "HYPRCURSOR_SIZE,28"
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"
        "QT_QPA_PLATFORM,wayland"
        "USE_WAYLAND_GRIM,true"
      ];

      # startup
      "exec-once" = [
        "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE"
        "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE"
        # Keep Blueman's pairing agent available so GUI pairing works reliably.
        "systemctl --user start --no-block blueman-applet.service"
        "hyprpaper"
        "hyprctl setcursor Adwaita 24"
        # "/run/wrappers/bin/librepods"
        "waybar"
        "${waybarHideScript}"
        "systemctl --user start --no-block hyprlock-solar-times.service"
        "hypridle"
        "hyprlock || hyprctl dispatch exit"
      ];

      xwayland = {
        force_zero_scaling = true;
      };

      general = {
        gaps_in = 5;
        gaps_out = 10;
        resize_on_border = true;
        "col.active_border" = "0x88ffffff";
        border_size = 1;
      };

      decoration = {
        rounding = 8;
      };

      monitor = [
        ",3440x1440@240,auto,1"
      ];

      # input
      input = {
        accel_profile = "flat";
        sensitivity = 0.0;
      };

      # animations
      animations = {
        bezier = [
          "fluent_decel, 0, 0.2, 0.4, 1"
          "easeOutCirc, 0, 0.55, 0.45, 1"
          "easeOutCubic, 0.33, 1, 0.68, 1"
          "easeinoutsine, 0.37, 0, 0.63, 1"
        ];
        animation = [
          # windows
          "windowsIn, 1, 1.5, easeinoutsine, popin 60%"
          "windowsOut, 1, 1.5, easeOutCubic, popin 60%"
          "windowsMove, 1, 1.5, easeinoutsine, slide"

          # fading
          "fade, 1, 2.5, fluent_decel"
          "fadeLayersIn, 0"
          "border, 0"

          # layers
          "layers, 1, 1.5, easeinoutsine, popin"

          # workspaces
          "workspaces, 0"
          "specialWorkspace, 1, 2, fluent_decel, slidefade 10%"
        ];
      };

      windowrulev2 = [
        "noborder, class:^(wofi)$"
        "rounding 20, class:^(wofi)$"
      ];

      layerrule = [
        "blur, wofi"
        "ignorezero, wofi"
        "ignorealpha 0.5, wofi"
      ];

    };
  };
}
