{ lib, pkgs, ... }:
let
  launcher = pkgs.writeShellApplication {
    name = "chrome-new-window";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      state="''${XDG_CONFIG_HOME:-$HOME/.config}/google-chrome/Local State"

      # Supplying the last-used profile explicitly bypasses the startup picker.
      directory=Default
      if [[ -r "$state" ]]; then
        directory=$(jq -r '.profile.last_used // "Default"' "$state")
      fi

      # Manual launches create a new window; links reuse an existing window.
      if (( $# == 0 )); then
        set -- --new-window
      fi
      exec google-chrome-stable --profile-directory="$directory" "$@"
    '';
  };
in {
  home.packages = [ launcher ];

  xdg.desktopEntries.google-chrome = {
    name = "Google Chrome";
    genericName = "Web Browser";
    comment = "Browse the web; links open in your most recently used profile";
    exec = "${lib.getExe launcher} %U";
    icon = "google-chrome";
    terminal = false;
    categories = [ "Network" "WebBrowser" ];
    mimeType = [
      "text/html" "application/xhtml+xml" "application/pdf"
      "x-scheme-handler/http" "x-scheme-handler/https"
      "x-scheme-handler/about" "x-scheme-handler/unknown"
    ];
    settings.StartupWMClass = "google-chrome";
  };
}
