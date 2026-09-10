{ config, pkgs, lib, inputs, ... }:

let
  theme = import ./theme.nix;
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

  # Home Manager 25.05 manages packages; native Lua owns configuration/startup.
  wayland.windowManager.hyprland = {
    enable = true;
    package = pkgs.hyprland;
    portalPackage = pkgs.xdg-desktop-portal-hyprland;
    systemd.enable = false;
  };

  # Preserve the standard session target for dictation and other user services,
  # without the older module's Hyprlang-only startup and config generation.
  systemd.user.targets.hyprland-session.Unit = {
    Description = "Hyprland compositor session";
    Documentation = [ "man:systemd.special(7)" ];
    BindsTo = [ "graphical-session.target" ];
    Wants = [ "graphical-session-pre.target" ];
    After = [ "graphical-session-pre.target" ];
  };

  xdg.configFile."hypr/hyprland.lua".text = lib.mkBefore (builtins.replaceStrings
    [ "@GLASS@" "@BACKGROUND@" "@RADIUS@" "@WAYBAR_HIDE@" "@SESSION_START@" ]
    [ "${pkgs.hyprglass}/lib/libhyprglass.so" theme.colors.background (toString theme.radius)
      "${waybarHideScript}"
      "${pkgs.dbus}/bin/dbus-update-activation-environment --systemd --all && systemctl --user stop hyprland-session.target && systemctl --user start hyprland-session.target"
    ]
    (builtins.readFile ./hyprland.lua));
}
