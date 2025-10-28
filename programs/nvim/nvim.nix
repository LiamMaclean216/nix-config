{ config, pkgs, lib, ... }:

{
  imports = [
    ./plugins.nix
    ./comment-nvim.nix
    ./languages.nix
  ];

  programs.nvf = {
    enable = true;

    settings = {
      vim = {
        viAlias = true;
        vimAlias = true;
        preventJunkFiles = true;

        theme = {
          enable = false;
        };

        # Enable auto-completion with nvim-cmp
        autocomplete.enable = true;

        # Add melange colorscheme plugin
        startPlugins = with pkgs.vimPlugins; [
          melange-nvim
        ];

        # Load custom Lua configuration from this repo
        additionalRuntimePaths = [ .nvim/lua ];

        luaConfigRC.myconfig-dir = ''
            require("config")
          '';

        # Set melange colorscheme
        luaConfigRC.melange-colorscheme = ''
          vim.cmd.colorscheme('melange')
        '';
      };
    };
  };

  # Extra packages needed for formatters and LSPs
  home.packages = with pkgs; [
    python312Packages.debugpy
    nodePackages.stylelint
    nodePackages.svelte-language-server
    nodePackages.prettier
    hadolint
  ];
}
