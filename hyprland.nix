{ config, pkgs, lib, inputs, ... }:
{
  wayland.windowManager.hyprland = {
    enable = true;

    plugins = [
      inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.borders-plus-plus
    ];

    # Export user environment to systemd (fixes PATH in services)
    systemd.variables = [ "--all" ];

    # Declarative Hyprland config translated from hyprland.conf
    settings = {
      "$mainMod" = "SUPER";

      "plugin:borders-plus-plus" = {
        add_borders = 1;
        top_border_color = "rgba(173, 216, 230, 1)";
        top_border_width = 3;
      };

      # startup
      "exec-once" = [
        "waybar"
        "hyprpaper"
      ];

      xwayland = {
        force_zero_scaling = true;
      };

      general = {
        gaps_in = 5;
        gaps_out = 10;
      };

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
          "workspaces, 1, 3, fluent_decel, slidefadevert 30%"
          "specialWorkspace, 1, 2, fluent_decel, slidefade 10%"
        ];
      };

      # keybinds
      bind = [
        # apps
        "$mainMod, RETURN, exec, alacritty"
        "$mainMod, Q, killactive"
        "$mainMod, D, exec, rofi -show drun"
        "$mainMod, F, exec, dolphin"
        "$mainMod, B, exec, firefox"

        # focus (vim-style)
        "$mainMod, h, movefocus, l"
        "$mainMod, j, movefocus, d"
        "$mainMod, k, movefocus, u"
        "$mainMod, l, movefocus, r"

        # move window (vim-style + shift)
        "$mainMod SHIFT, h, movewindow, l"
        "$mainMod SHIFT, j, movewindow, d"
        "$mainMod SHIFT, k, movewindow, u"
        "$mainMod SHIFT, l, movewindow, r"

        # workspaces relative
        "$mainMod, e, workspace, r-1"
        "$mainMod, w, workspace, r+1"

        # fullscreen
        "$mainMod, m, fullscreen"

        # volume/media keys
        ", XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +10%"
        ", XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -10%"
        ", XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle"
        ", XF86AudioMicMute, exec, pactl set-source-mute @DEFAULT_SOURCE@ toggle"
      ];

    };
  };
}

