{ config, pkgs, lib, ... }:

{
  imports = [
    ./telescope.nix
    ./comment-nvim.nix
  ];

  programs.nvf = {
    enable = true;

    settings = {
      vim = {
        viAlias = true;
        vimAlias = true;
        preventJunkFiles = true;

        # Load custom Lua configuration from this repo
        additionalRuntimePaths = [ ./lua ];
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
