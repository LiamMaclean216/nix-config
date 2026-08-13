{
  config,
  pkgs,
  lib,
  ...
}: let
  # Dismiss existing notifications before launching the logout menu.
  wlogoutWithClear = pkgs.writeShellScript "wlogout-clear-notifications" ''
    ${pkgs.mako}/bin/makoctl dismiss --all || true
    exec ${pkgs.wlogout}/bin/wlogout "$@"
  '';
in {
  wayland.windowManager.hyprland = {
    settings = {
      # keybinds
      bind = [
        # apps
        "$mainMod, RETURN, exec, alacritty"
        "$mainMod, Q, killactive"
        "$mainMod, F, exec, dolphin"
        "$mainMod, B, exec, firefox"
        "$mainMod, C, exec, firefox https://gemini.google.com/"
        "$mainMod, D, exec, /home/liam/nix-config/desktop/wofi/launch.sh"
        "$mainMod, N, exec, alacritty -e nvim +'lua vim.schedule(function() vim.cmd([[Telescope projects]]) end)'"
        # record screen selection with wf-recorder
        "$mainMod, R, exec, wf-recorder -g \"$(slurp)\" -f \"$HOME/videos/$(date +%Y-%m-%d_%H-%M-%S).webm\""
        "$mainMod SHIFT, R, exec, killall wf-recorder"
        # screenshot with flameshot
        "$mainMod, p, exec, flameshot gui"
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

        # volume/media keys — wpctl with --limit 2.0 so we can boost past pulse's 153% UI cap
        ", XF86AudioRaiseVolume, exec, wpctl set-volume --limit 2.0 @DEFAULT_AUDIO_SINK@ 10%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume --limit 2.0 @DEFAULT_AUDIO_SINK@ 10%-"
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
      ];

      # mouse bindings
      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];
    };
  };
}
