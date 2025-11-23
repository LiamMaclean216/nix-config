{ config, pkgs, lib, ... }:

{
  imports = [
    ./plugins.nix
    ./comment-nvim.nix
    ./languages.nix
    # ./strudel.nix
    ./theme.nix
  ];

  programs.nvf = {
    enable = true;

    settings = {
      vim = {
        viAlias = true;
        vimAlias = true;
        preventJunkFiles = true;

        # Enable auto-completion with nvim-cmp
        autocomplete.nvim-cmp.enable = true;

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
    nodePackages.typescript-language-server
    nodePackages.prettier
    hadolint
  ];
}
