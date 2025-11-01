{ config, pkgs, lib, inputs, ... }:

let
  myPython = import ./python.nix { inherit pkgs; };
  dir = "${config.home.homeDirectory}/nix-config";
in
{
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
    pkgs.lazygit
    pkgs.wl-clipboard
    pkgs.hyprpaper
    pkgs.hyprshot
    pkgs.hypridle
    pkgs.ruff

    myPython
  ];
  programs.hyprlock.enable = true;
  nixpkgs.config.allowUnfree = true;


  home.sessionVariables = {
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/node_modules";
    TERMINAL = "alacritty";
  };

# ensure $HOME/node_modules/bin is on PATH at shell runtime
    home.file.".profile".text = ''
    if [ -d "$HOME/node_modules/bin" ] && ! echo "$PATH" | grep -q "$HOME/node_modules/bin"; then
      export PATH="$HOME/node_modules/bin:$PATH"
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

  home.file.".config/mako" = {
      source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/mako");
      recursive = true;
  };

  home.file.".config/nvf/lua/config" = {
      source = config.lib.file.mkOutOfStoreSymlink (dir + "/programs/nvim/lua/");
      recursive = true;
  };

  # Hyprland configuration moved to module file
  #home.file.".config/hypr/hyprland.conf".source = ./desktop/hyprland.conf;

  # Hyprpaper: set wallpaper to the repository image
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = /home/liam/nix-config/desktop/background.png
    wallpaper = ,/home/liam/nix-config/desktop/background.png
  '';
  xdg.configFile."hypr/hypridle.conf".text = ''
    general {
      after_sleep_cmd = hyprctl dispatch dpms on
      lock_cmd = pidof hyprlock || hyprlock
    }

    listener {
      timeout = 150
      on-timeout = loginctl lock-session
    }

    listener {
      timeout = 180
      on-timeout = hyprctl dispatch dpms off
      on-resume = hyprctl dispatch dpms on
    }

    listener {
      timeout = 3600
      on-timeout = systemctl suspend
      on-resume = hyprctl dispatch dpms on
    }
  '';

  home.file.".config/hypr/hyprlock.conf".source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/hyprlock.conf");

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
      ${pkgs.pywal}/bin/wal -i ${dir}/desktop/background.png -n -q -s -t
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
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  imports = [
    ./programs/nvim/nvim.nix
    ./programs/vscode.nix
    ./programs/codex.nix
    ./programs/claude-code.nix
    ./programs/lazydocker.nix
    ./programs/fastfetch.nix
    ./desktop/hyprland.nix
    ./desktop/workspaces.nix
    ./desktop/keybindings.nix
    ./desktop/waybar.nix
  ];

}
