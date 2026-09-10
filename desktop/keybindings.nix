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

  # Focus the running Vesktop window (switching to its workspace), or launch it.
  focusOrLaunchVesktop = pkgs.writeShellScript "focus-or-launch-vesktop" ''
    vesktop_address="$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r 'first(.[] | select(
          (((.class // "") | ascii_downcase) == "vesktop") or
          (((.initialClass // "") | ascii_downcase) == "vesktop")
        ) | .address) // empty')"

    if [ -n "$vesktop_address" ]; then
      exec ${pkgs.hyprland}/bin/hyprctl dispatch focuswindow "address:$vesktop_address"
    fi

    exec vesktop
  '';
in {
  wayland.windowManager.hyprland = {
    settings = {
      # keybinds
      bind = [
        # apps
        "$mainMod, RETURN, exec, alacritty"
        "$mainMod, TAB, killactive"
        "$mainMod, V, exec, ${focusOrLaunchVesktop}"
        "$mainMod, F, exec, dolphin"
        "$mainMod, B, exec, firefox"
        "$mainMod, C, exec, firefox https://gemini.google.com/"
        "$mainMod, D, exec, /home/liam/nix-config/desktop/wofi/launch.sh"
        "$mainMod, N, exec, alacritty -e nvim +'lua vim.schedule(function() vim.cmd([[Telescope projects]]) end)'"
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

        # workspaces
        "$mainMod, Q, workspace, 1"
        "$mainMod, W, workspace, 2"
        "$mainMod, E, workspace, 3"
        "$mainMod, R, workspace, 4"
        "$mainMod, T, workspace, 5"
        "$mainMod SHIFT, Q, movetoworkspace, 1"
        "$mainMod SHIFT, W, movetoworkspace, 2"
        "$mainMod SHIFT, E, movetoworkspace, 3"
        "$mainMod SHIFT, R, movetoworkspace, 4"
        "$mainMod SHIFT, T, movetoworkspace, 5"
        "$mainMod CTRL, Q, movetoworkspacesilent, 1"
        "$mainMod CTRL, W, movetoworkspacesilent, 2"
        "$mainMod CTRL, E, movetoworkspacesilent, 3"
        "$mainMod CTRL, R, movetoworkspacesilent, 4"
        "$mainMod CTRL, T, movetoworkspacesilent, 5"

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
