{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  myPython = import ./python.nix {inherit pkgs;};
  dir = "${config.home.homeDirectory}/nix-config";
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

  # Enable Qt theming with stylix
  qt.enable = true;
  qt.platformTheme.name = "qtct";
  qt.style.name = "kvantum";

  # Stylix Qt theming
  stylix.targets.qt.enable = true;

  home.packages = [
    pkgs.libsForQt5.qt5ct
    pkgs.libsForQt5.qtstyleplugin-kvantum
    pkgs.kdePackages.qtstyleplugin-kvantum
    pkgs.hello
    pkgs.wl-clipboard
    pkgs.ruff
    pkgs.android-tools

    myPython
  ];
  nixpkgs.config.allowUnfree = true;

  home.sessionVariables = {
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

  # Ensure ~/venv exists with pynvim
  home.file.".venv/.keep".text = ''
    # placeholder to create venv folder
  '';

  home.file.".config/wofi" = {
    source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/wofi");
    recursive = true;
  };

  home.file.".config/wlogout" = {
    source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/wlogout");
    recursive = true;
  };

  home.file.".config/nvf/lua/config" = {
    source = config.lib.file.mkOutOfStoreSymlink (dir + "/programs/nvim/lua/");
    recursive = true;
  };

  # Configure Dolphin to use Alacritty as the terminal
  home.file.".config/kdeglobals".text = ''
    [General]
    TerminalApplication=alacritty
    TerminalService=alacritty.desktop
  '';

  home.activation.createPythonVenv = lib.hm.dag.entryAfter ["writeBoundary"] ''
    VENV="$HOME/.venv"
    PYTHON="${pkgs.python311}/bin/python3"
    if [ ! -d "$VENV" ]; then
      "$PYTHON" -m venv "$VENV"
      "$VENV/bin/pip" install --upgrade pip pynvim
    fi
  '';

  # Generate pywal color scheme from background image
  home.activation.generatePywalColors = lib.hm.dag.entryAfter ["writeBoundary"] ''
    rm -rf "$HOME/.cache/wal"
    ${pkgs.pywal}/bin/wal -i ${dir}/desktop/background.webp -n -q -s -t
    # Reload mako service if it's running to pick up new colors
    if systemctl --user is-active --quiet mako.service; then
      systemctl --user reload mako.service || true
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
    ./programs/nvim/nvim.nix
    ./programs/vscode.nix
    ./programs/codex.nix
    ./programs/claude-code.nix
    ./programs/opencode.nix
    ./programs/gemini-cli.nix
    ./programs/lazygit.nix
    ./programs/lazydocker.nix
    ./programs/fastfetch.nix
    ./desktop/hyprland.nix
    ./desktop/hyprpaper.nix
    ./desktop/hypridle.nix
    ./desktop/hyprlock.nix
    ./desktop/workspaces.nix
    ./desktop/keybindings.nix
    ./desktop/waybar.nix
    ./desktop/mako.nix
    ./desktop/screen-record.nix
  ];
}
