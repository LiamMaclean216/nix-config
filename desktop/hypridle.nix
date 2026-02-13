{
  config,
  pkgs,
  ...
}: {
  home.packages = [
    pkgs.hypridle
  ];

  xdg.configFile."hypr/hypridle.conf".text = ''
    general {
      after_sleep_cmd = hyprctl dispatch dpms on
      lock_cmd = pidof hyprlock || hyprlock
    }

    listener {
      timeout = 180
      on-timeout = hyprctl dispatch dpms off
      on-resume = hyprctl dispatch dpms on
    }

    listener {
      timeout = 10800
      on-timeout = loginctl lock-session
    }

  '';

    # listener {
    #   timeout = 3600
    #   on-timeout = systemctl suspend
    #   on-resume = hyprctl dispatch dpms on
    # }
}
