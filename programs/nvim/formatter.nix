{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.nvf.settings.vim = {
    # Enable conform.nvim for formatting
    formatter.conform-nvim = {
      enable = true;
      setupOpts = {
        formatters_by_ft = {
          html = ["prettier"];
        };
        formatters = {
          prettier = {
            prepend_args = ["--tab-width" "2"];
          };
        };
      };
    };
  };
}
