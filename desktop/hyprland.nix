{ config, pkgs, lib, inputs, ... }:

{
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
      ];

      # startup
      "exec-once" = [
        "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE"
        "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE"
        "hyprpaper"
        "hyprctl setcursor Adwaita 24"
        "waybar"
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
          "workspaces, 1, 3, fluent_decel, slidefadevert 30%"
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
