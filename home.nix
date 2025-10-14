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

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    pkgs.hello
    pkgs.lazygit
    pkgs.wl-clipboard
    pkgs.hyprpaper
    pkgs.hyprlock
    pkgs.hyprshot
    pkgs.hypridle

    myPython

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];
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


  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  # Ensure ~/venv exists with pynvim
  home.file.".venv/.keep".text = ''
      # placeholder to create venv folder
  '';

  home.file.".config/wofi" = {
      source = config.lib.file.mkOutOfStoreSymlink (dir + "/desktop/wofi");
      recursive = true;
  };


  # Hyprland configuration moved to module file
  #home.file.".config/hypr/hyprland.conf".source = ./desktop/hyprland.conf;

  # Hyprpaper: set wallpaper to the repository image
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = /home/liam/nix-config/desktop/background.png
    wallpaper = ,/home/liam/nix-config/desktop/background.png
  '';
  xdg.configFile."hypr/autostart.conf".text = ''
    hyprpaper &
  '';
  xdg.configFile."hypr/hypridle.conf".text = ''
    general {
      after_sleep_cmd = hyprctl dispatch dpms on
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
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Alacritty terminal
  programs.alacritty.enable = true;

  imports = [
    ./programs/nvim.nix
    ./programs/vscode.nix
    ./programs/codex.nix
    ./programs/claude-code.nix
    ./desktop/hyprland.nix
    ./desktop/waybar.nix
  ];

}
