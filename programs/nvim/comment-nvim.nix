{ config, pkgs, lib, ... }:

{
  programs.nvf.settings.vim.comments.comment-nvim = {
    enable = true;

    mappings = {
      toggleCurrentLine = "<C-q>";
      toggleCurrentBlock = "<C-q>";
      toggleOpLeaderBlock = "gb";
      toggleOpLeaderLine = "gc";
      toggleSelectedLine = "q";
    };

    setupOpts = {
      ignore = "^$";  # Skip blank lines when commenting
    };
  };
}
