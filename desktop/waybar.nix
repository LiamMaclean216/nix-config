{ pkgs, lib, ... }:

let
  theme = import ./theme.nix;
  discordStatusScript = pkgs.writeShellScript "waybar-discord-status" ''
    set -euo pipefail

    data="$(${pkgs.hyprland}/bin/hyprctl clients -j 2>/dev/null || printf '[]')"

    if [ -z "$data" ]; then
      echo '{"text":"","class":"discord","tooltip":"Discord"}'
      exit 0
    fi

    urgent=$(${pkgs.jq}/bin/jq -r '
      map(select(
        ((.class // "") | ascii_downcase == "discord") or
        ((.initialClass // "") | ascii_downcase == "discord")
      ) | select(.urgent == true))
      | length > 0
    ' <<<"$data" 2>/dev/null || printf 'false')

    if [ "$urgent" = "true" ]; then
      echo '{"text":"","class":"discord unread","tooltip":"Unread Discord notifications"}'
    else
      echo '{"text":"","class":"discord","tooltip":"Discord"}'
    fi
  '';
in
{
  programs.waybar = {
    enable = true;
    # Waybar otherwise forces widget opacity to zero immediately on SIGUSR1,
    # bypassing GTK transitions. Its existing .hidden class drives the fade.
    package = pkgs.waybar.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./waybar-clock-anchor.patch
        # Reloads must disconnect monitor callbacks before binding them again.
        ./waybar-reload.patch
      ];
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/bar.cpp \
          --replace-fail 'window.set_opacity(0);' '// Opacity is animated by the shared GTK style.'
      '';
    });

    settings.mainBar = {
      layer = "overlay";
      position = "bottom";
      # One horizontal anchor lets GTK request the clock's natural width.
      # The local package patch implements this without a fixed date-text width.
      anchor-right = true;
      exclusive = false;
      passthrough = true;
      height = 40;
      spacing = 6;
      margin = "0 5 5 0";
      modules-left = [ ];
      modules-center = [ ];
      modules-right = [  "clock" ];
      # Keep the fading clock above windows until its alpha reaches zero.
      # Waybar's built-in invisible mode otherwise moves it behind them at once.
      modes.invisible = {
        layer = "overlay";
        exclusive = false;
        passthrough = true;
        visible = false;
      };

      clock = {
        format = "{:%a %d %b  %H:%M}";
        tooltip = false;
      };
    };

    style = theme.renderCss ''
      * {
        border: none;
        border-radius: 0;
        font-family: "@font@", "Noto Sans", sans-serif;
        font-size: 12pt;
        font-weight: 500;
        min-height: 0;
      }

      window#waybar {
        background: transparent;
        color: @foreground;
        padding: 0;
        margin: 0;
        opacity: 1;
        transition: opacity ${toString (theme.fadeSpeed / 10.0)}s ease;
      }

      window#waybar.hidden { opacity: 0; }

      #clock {
        background-color: alpha(@background, @glass-opacity@);
        background-image: @glass-sheen@;
        border-radius: @radius@px;
        padding: 11px 20px 9px 20px;
        letter-spacing: 0.3px;
        color: @foreground;
        border: none;
        font-family: "@font@", "Noto Sans", sans-serif;
        font-weight: 400;
      }

    '';
  };
}
