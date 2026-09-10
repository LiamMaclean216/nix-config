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
    # Lua configs require a Lua dispatcher expression, including through hyprctl.
    ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.workspace.toggle_special("spotify")'
  '';
in {
  xdg.configFile."hypr/hyprland.lua".text = ''
    hl.on("hyprland.start", function()
      hl.exec_cmd("spotify")
      hl.exec_cmd("alacritty --class notes-scratchpad -e nvim ~/notes.txt")
    end)
    hl.bind("SUPER + S", hl.dsp.exec_cmd("${toggleSpotify}"))
    hl.window_rule({
      name = "spotify-scratchpad", match = { class = "^(Spotify)$" },
      float = true, size = "(monitor_w*0.35) (monitor_h*0.70)",
      move = "(monitor_w*0.55) (monitor_h*0.15)",
      workspace = "special:spotify silent",
    })
    hl.window_rule({
      name = "notes-scratchpad", match = { class = "^(notes-scratchpad)$" },
      float = true, size = "(monitor_w*0.35) (monitor_h*0.70)",
      move = "(monitor_w*0.10) (monitor_h*0.15)",
      workspace = "special:spotify silent",
    })
  '';
}
