{ config, pkgs, lib, ... }:

let
  # Toggle Spotify scratchpad, launching it if not running
  toggleSpotify = pkgs.writeShellScript "toggle-spotify" ''
    if ! pgrep -x spotify > /dev/null; then
      spotify &
    fi
    if ! pgrep -f "alacritty --class notes-scratchpad" > /dev/null; then
      alacritty --class notes-scratchpad -e nvim ~/notes.txt &
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
        "alacritty --class notes-scratchpad -e nvim ~/notes.txt"
      ];

      # Keybinds
      bind = [
        # Spotify scratchpad toggle
        "$mainMod, S, exec, ${toggleSpotify}"
      ];

      # Window rules for Spotify scratchpad
      windowrulev2 = [
        "float, class:^(Spotify)$"
        "size 35% 70%, class:^(Spotify)$"
        "move 55% 15%, class:^(Spotify)$"
        "workspace special:spotify silent, class:^(Spotify)$"

        "float, class:^(notes-scratchpad)$"
        "size 35% 70%, class:^(notes-scratchpad)$"
        "move 10% 15%, class:^(notes-scratchpad)$"
        "workspace special:spotify silent, class:^(notes-scratchpad)$"
      ];
    };
  };
}
