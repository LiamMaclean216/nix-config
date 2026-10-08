{ pkgs, ... }:

let
  theme = import ./theme.nix;
  audioPopup = pkgs.callPackage ./audio-popup { };

in
{
  home.packages = [ audioPopup ];

  programs.waybar = {
    enable = true;
    systemd = {
      enable = true;
      target = "hyprland-session.target";
    };
    # Waybar otherwise forces widget opacity to zero immediately on SIGUSR1,
    # bypassing GTK transitions. Its existing .hidden class drives the fade.
    package = pkgs.waybar.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./waybar-clock-anchor.patch
        # Hide on the clock's text bounds, leaving padding and audio untouched.
        ./waybar-clock-hide.patch
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
      passthrough = false;
      height = 40;
      spacing = 6;
      margin = "0 5 5 0";
      modules-left = [ ];
      modules-center = [ ];
      modules-right = [ "pulseaudio" "clock" ];
      pulseaudio = {
        format = "{icon}";
        format-muted = "󰝟";
        format-icons = { default = [ "󰕿" "󰖀" "󰕾" ]; };
        tooltip = false;
        on-click = "${audioPopup}/bin/audio-popup";
        on-click-right = "${pkgs.pavucontrol}/bin/pavucontrol";
        # Override the module's built-in wheel volume control.
        on-scroll-up = ":";
        on-scroll-down = ":";
        max-volume = 100;
      };

      clock = {
        format = "{:%a %d %b  %H:%M}";
        tooltip = false;
        hide-on-click = 30;
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

      .modules-right {
        background-color: alpha(@background, @glass-opacity@);
        background-image: @glass-sheen@;
        border-radius: @radius@px;
        padding: 0 6px;
        letter-spacing: 0.3px;
        color: @foreground;
        border: none;
        font-family: "@font@", "Noto Sans", sans-serif;
        font-weight: 400;
      }

      #clock { padding: 11px 15px 9px 8px; }
      #pulseaudio {
        padding: 0 13px;
        margin: 5px 0;
        border-radius: 20px;
        font-family: "Symbols Nerd Font Mono";
        font-size: 18px;
        color: @foreground;
      }
      #pulseaudio:hover { background: alpha(@foreground, 0.10); }
      #pulseaudio.muted { color: @muted; }
      tooltip {
        background: @background;
        color: @foreground;
        border-radius: 10px;
      }
    '';
  };

  systemd.user.services.audio-volume-memory = {
    Unit = {
      Description = "Remember application playback volumes across reconnects";
      After = [ "pipewire-pulse.service" ];
      PartOf = [ "hyprland-session.target" ];
    };
    Install.WantedBy = [ "hyprland-session.target" ];
    Service = {
      ExecStart = "${audioPopup}/bin/audio-volume-memory";
      Restart = "on-failure";
      RestartSec = 2;
      UnsetEnvironment = [ "LD_LIBRARY_PATH" ];
    };
  };

  # The session's newer PipeWire JACK override is incompatible with Waybar's
  # pinned glibc. Use Waybar's own Nix library paths, including on restarts.
  systemd.user.services.waybar.Service.UnsetEnvironment = [ "LD_LIBRARY_PATH" ];
}
