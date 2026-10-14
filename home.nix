{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  myPython = import ./python.nix {inherit pkgs;};
  dir = "${config.home.homeDirectory}/nix-config";
  theme = import ./desktop/theme.nix;
  # Add the shared palette to GTK styles; keep other desktop files linked.
  desktopFiles = name: lib.mapAttrs' (file: _: lib.nameValuePair
    ".config/${name}/${file}"
    (if lib.hasSuffix ".css" file then {
      text = theme.renderCss (builtins.readFile (./desktop + "/${name}/${file}"));
    } else {
      source = config.lib.file.mkOutOfStoreSymlink "${dir}/desktop/${name}/${file}";
    })
  ) (builtins.readDir (./desktop + "/${name}"));
in {
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "liam";
  home.homeDirectory = "/home/liam";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05"; # Please read the comment before changing.

  home.packages = [
    pkgs.hello
    pkgs.wl-clipboard
    pkgs.ruff
    # Shared development tools for local coding agents.
    pkgs.chromium
    pkgs.jq
    pkgs.fd
    pkgs.shellcheck
    pkgs.android-tools

    myPython
  ];
  nixpkgs.config.allowUnfree = true;

  home.sessionVariables = {
    BROWSER = "chrome-new-window";
    CHROMIUM_EXECUTABLE = "${pkgs.chromium}/bin/chromium";
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/node_modules";
    TERMINAL = "alacritty";
    HYPRLOCK_SOLAR_DEFAULT_TZ = "America/Toronto";
    HYPRLOCK_SOLAR_DEFAULT_CITY = "Toronto";
    HYPRLOCK_SOLAR_DEFAULT_LAT = "43.6532";
    HYPRLOCK_SOLAR_DEFAULT_LON = "-79.3832";
    # Common Android SDK location when installing emulator/build tools later.
    ANDROID_HOME = "${config.home.homeDirectory}/Android/Sdk";
    ANDROID_SDK_ROOT = "${config.home.homeDirectory}/Android/Sdk";
    LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
      pkgs.glib
      pkgs.libGL
      pkgs.libGLU
    ]}";
  };

  xdg.mimeApps = {
    enable = true;
    associations.added."application/vnd.openxmlformats-officedocument.wordprocessingml.document" = [ "libreoffice-3.desktop" "libreoffice-2.desktop" ];
    defaultApplications = {
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = [ "libreoffice-3.desktop" ];
      "x-scheme-handler/claude-cli" = [ "claude-code-url-handler.desktop" ];
      "x-scheme-handler/discord" = [ "vesktop.desktop" ];
      "text/html" = [ "google-chrome.desktop" ];
      "application/xhtml+xml" = [ "google-chrome.desktop" ];
      "x-scheme-handler/http" = [ "google-chrome.desktop" ];
      "x-scheme-handler/https" = [ "google-chrome.desktop" ];
      "x-scheme-handler/about" = [ "google-chrome.desktop" ];
      "x-scheme-handler/unknown" = [ "google-chrome.desktop" ];
      "application/pdf" = [ "google-chrome.desktop" ];
    };
  };

  home.sessionPath = [
    "${config.home.homeDirectory}/Android/Sdk/platform-tools"
    "${config.home.homeDirectory}/Android/Sdk/emulator"
    "${config.home.homeDirectory}/Android/Sdk/cmdline-tools/latest/bin"
  ];

  home.shellAliases = {
    adb-expo = "adb reverse tcp:8081 tcp:8081";
    expo-usb = "adb reverse tcp:8081 tcp:8081 && npx expo start --localhost";
  };

  # ensure $HOME/node_modules/bin is on PATH at shell runtime
  home.file.".profile".text = ''
    # Set permissive umask for all new files
    umask 0002

    if [ -d "$HOME/node_modules/bin" ] && ! echo "$PATH" | grep -q "$HOME/node_modules/bin"; then
      export PATH="$PATH:$HOME/node_modules/bin"
    fi
  '';

  home.activation.enable = lib.mkAfter ''
    mkdir -p $HOME/node_modules
    export PATH="$HOME/node_modules/bin:$PATH"
  '';

  # Older generations linked these entire directories back into this repository.
  # Detach those links before per-file management, which would otherwise replace
  # repository sources with links to their own generated Home Manager files.
  home.activation.migrateDesktopConfigDirectories = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    for desktopName in wofi wlogout; do
      desktopConfig="$HOME/.config/$desktopName"
      if [[ -L "$desktopConfig" ]] &&
         [[ "$(readlink "$desktopConfig")" == /nix/store/*-home-manager-files/.config/"$desktopName" ]]; then
        run rm -- "$desktopConfig"
        run mkdir -p -- "$desktopConfig"
      fi
    done
  '';

  # Ensure ~/venv exists with pynvim
  home.file.".venv/.keep".text = ''
    # placeholder to create venv folder
  '';

  home.file.".config/nvf/lua/config" = {
    source = config.lib.file.mkOutOfStoreSymlink (dir + "/programs/nvim/lua/");
    recursive = true;
  };

  home.activation.createPythonVenv = lib.hm.dag.entryAfter ["writeBoundary"] ''
    VENV="$HOME/.venv"
    PYTHON="${pkgs.python311}/bin/python3"
    if [ ! -d "$VENV" ]; then
      "$PYTHON" -m venv "$VENV"
      "$VENV/bin/pip" install --upgrade pip pynvim
    fi
  '';

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/liam/etc/profile.d/hm-session-vars.sh
  #
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  imports = [
    ./programs/chrome.nix
    { home.file = desktopFiles "wofi" // desktopFiles "wlogout"; }
    ./programs/nvim/nvim.nix
    ./programs/vscode.nix
    ./programs/codex.nix
    ./programs/claude-code.nix
    ./programs/opencode.nix
    ./programs/gemini-cli.nix
    ./programs/lazygit
    ./programs/lazydocker.nix
    ./programs/fastfetch.nix
    ./desktop/hyprland.nix
    ./desktop/appearance.nix
    ./desktop/dolphin.nix
    ./desktop/hyprpaper.nix
    ./desktop/hypridle.nix
    ./desktop/hyprlock.nix
    ./desktop/workspaces.nix
    ./desktop/keybindings.nix
    ./desktop/wofi.nix
    ./desktop/wlogout.nix
    ./desktop/waybar.nix
    ./desktop/mako.nix
    ./desktop/screen-record.nix
    ./desktop/voice-input.nix
  ];
}
