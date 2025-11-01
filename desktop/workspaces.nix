{ config, pkgs, lib, ... }:

let
  # Toggle Spotify scratchpad, launching it if not running
  toggleSpotify = pkgs.writeShellScript "toggle-spotify" ''
    if ! pgrep -x spotify > /dev/null; then
      spotify &
    fi
    hyprctl dispatch togglespecialworkspace spotify
  '';
in
{
  wayland.windowManager.hyprland = {
    settings = {
      # Startup
      "exec-once" = [
        "spotify"
      ];

      # Keybinds
      bind = [
        # Spotify scratchpad toggle
        "$mainMod, S, exec, ${toggleSpotify}"
      ];

      # Window rules for Spotify scratchpad
      windowrulev2 = [
        "float, class:^(Spotify)$"
        "size 70% 70%, class:^(Spotify)$"
        "center, class:^(Spotify)$"
        "workspace special:spotify silent, class:^(Spotify)$"
      ];
    };
  };
}
