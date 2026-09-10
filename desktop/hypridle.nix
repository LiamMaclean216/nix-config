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
      after_sleep_cmd = hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
      lock_cmd = pidof hyprlock || hyprlock
    }

    listener {
      timeout = 180
      on-timeout = hyprctl dispatch 'hl.dsp.dpms({ action = "off" })'
      on-resume = hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
    }

    listener {
      timeout = 10800
      on-timeout = loginctl lock-session
    }

  '';

    # listener {
    #   timeout = 3600
    #   on-timeout = systemctl suspend
    #   on-resume = hyprctl dispatch 'hl.dsp.dpms({ action = "on" })'
    # }
}
