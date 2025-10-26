{ config, pkgs, lib, ... }:

{
  imports = [
    ./plugins.nix
    ./comment-nvim.nix
  ];

  programs.nvf = {
    enable = true;

    settings = {
      vim = {
        viAlias = true;
        vimAlias = true;
        preventJunkFiles = true;

        theme = {
          enable = true;
          name = "gruvbox";
          style = "dark";
        };

        # Load custom Lua configuration from this repo
        additionalRuntimePaths = [ .nvim/lua ];

        luaConfigRC.myconfig-dir = ''
            require("config")
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
