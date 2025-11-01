{ config, pkgs, lib, ... }:

let
  # Dismiss existing notifications before launching the logout menu.
  wlogoutWithClear = pkgs.writeShellScript "wlogout-clear-notifications" ''
    ${pkgs.mako}/bin/makoctl dismiss --all || true
    exec ${pkgs.wlogout}/bin/wlogout "$@"
  '';
in
{
  wayland.windowManager.hyprland = {
    settings = {
      # keybinds
      bind = [
        # apps
        "$mainMod, RETURN, exec, alacritty"
        "$mainMod, Q, killactive"
        "$mainMod, F, exec, cosmic-files"
        "$mainMod, B, exec, firefox"
        "$mainMod, C, exec, firefox https://t3.chat"
        "$mainMod, D, exec, /home/liam/nix-config/desktop/wofi/launch.sh"
        # screenshot region to clipboard
        "$mainMod, p, exec, hyprshot -m region --clipboard-only --freeze"
        "$mainMod, ESCAPE, exec, wlogout -b 2"

        # focus (vim-style)
        "$mainMod, h, movefocus, l"
        "$mainMod, j, movefocus, d"
        "$mainMod, k, movefocus, u"
        "$mainMod, l, movefocus, r"

        # move window (vim-style + shift)
        "$mainMod SHIFT, h, movewindow, l"
        "$mainMod SHIFT, j, movetoworkspacesilent, r+1"
        "$mainMod SHIFT, k, movetoworkspacesilent, r-1"
        "$mainMod SHIFT, l, movewindow, r"

        # workspaces relative
        "$mainMod, e, workspace, r-1"
        "$mainMod, w, workspace, r+1"
        "$mainMod SHIFT, e, movetoworkspace, r-1"
        "$mainMod SHIFT, w, movetoworkspace, r+1"

        # toggle floating on the focused window
        "$mainMod, g, togglefloating"

        # fullscreen
        "$mainMod, m, fullscreen"

        # volume/media keys
        ", XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +10%"
        ", XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -10%"
        ", XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle"
        ", XF86AudioMicMute, exec, pactl set-source-mute @DEFAULT_SOURCE@ toggle"
      ];

      # mouse bindings
      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];
    };
  };
}
