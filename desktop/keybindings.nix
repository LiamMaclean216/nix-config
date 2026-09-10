{
  config,
  pkgs,
  lib,
  ...
}: let
  # Focus the running Vesktop window (switching to its workspace), or launch it.
  focusOrLaunchVesktop = pkgs.writeShellScript "focus-or-launch-vesktop" ''
    vesktop_address="$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r 'first(.[] | select(
          (((.class // "") | ascii_downcase) == "vesktop") or
          (((.initialClass // "") | ascii_downcase) == "vesktop")
        ) | .address) // empty')"

    if [ -n "$vesktop_address" ]; then
      exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.focus({ window = 'address:$vesktop_address' })"
    fi

    exec vesktop
  '';
in {
  xdg.configFile."hypr/hyprland.lua".text = ''
    hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("alacritty"))
    hl.bind("SUPER + TAB", hl.dsp.window.close())
    hl.bind("SUPER + V", hl.dsp.exec_cmd("${focusOrLaunchVesktop}"))
    hl.bind("SUPER + F", hl.dsp.exec_cmd("dolphin"))
    hl.bind("SUPER + B", hl.dsp.exec_cmd("firefox"))
    hl.bind("SUPER + C", hl.dsp.exec_cmd("firefox https://gemini.google.com/"))
    hl.bind("SUPER + D", hl.dsp.exec_cmd("wofi-glass"))
    hl.bind("SUPER + N", hl.dsp.exec_cmd("alacritty -e nvim +'lua vim.schedule(function() vim.cmd([[Telescope projects]]) end)'"))
    hl.bind("SUPER + p", hl.dsp.exec_cmd("flameshot gui"))
    hl.bind("SUPER + ESCAPE", hl.dsp.exec_cmd("wlogout-glass"))
    hl.bind("SUPER + h", hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + j", hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + k", hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + l", hl.dsp.focus({ direction = "right" }))
    hl.bind("SUPER + SHIFT + h", hl.dsp.window.move({ direction = "left" }))
    hl.bind("SUPER + SHIFT + j", hl.dsp.window.move({ workspace = "r+1", follow = false }))
    hl.bind("SUPER + SHIFT + k", hl.dsp.window.move({ workspace = "r-1", follow = false }))
    hl.bind("SUPER + SHIFT + l", hl.dsp.window.move({ direction = "right" }))
    hl.bind("SUPER + Q", hl.dsp.focus({ workspace = "1" }))
    hl.bind("SUPER + W", hl.dsp.focus({ workspace = "2" }))
    hl.bind("SUPER + E", hl.dsp.focus({ workspace = "3" }))
    hl.bind("SUPER + R", hl.dsp.focus({ workspace = "4" }))
    hl.bind("SUPER + T", hl.dsp.focus({ workspace = "5" }))
    hl.bind("SUPER + SHIFT + Q", hl.dsp.window.move({ workspace = "1", follow = true }))
    hl.bind("SUPER + SHIFT + W", hl.dsp.window.move({ workspace = "2", follow = true }))
    hl.bind("SUPER + SHIFT + E", hl.dsp.window.move({ workspace = "3", follow = true }))
    hl.bind("SUPER + SHIFT + R", hl.dsp.window.move({ workspace = "4", follow = true }))
    hl.bind("SUPER + SHIFT + T", hl.dsp.window.move({ workspace = "5", follow = true }))
    hl.bind("SUPER + CTRL + Q", hl.dsp.window.move({ workspace = "1", follow = false }))
    hl.bind("SUPER + CTRL + W", hl.dsp.window.move({ workspace = "2", follow = false }))
    hl.bind("SUPER + CTRL + E", hl.dsp.window.move({ workspace = "3", follow = false }))
    hl.bind("SUPER + CTRL + R", hl.dsp.window.move({ workspace = "4", follow = false }))
    hl.bind("SUPER + CTRL + T", hl.dsp.window.move({ workspace = "5", follow = false }))
    hl.bind("SUPER + g", hl.dsp.window.float({ action = "toggle" }))
    hl.bind("SUPER + m", hl.dsp.window.fullscreen())
    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume --limit 2.0 @DEFAULT_AUDIO_SINK@ 10%+"))
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume --limit 2.0 @DEFAULT_AUDIO_SINK@ 10%-"))
    hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
    hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"))
    hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
    hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
  '';
}
