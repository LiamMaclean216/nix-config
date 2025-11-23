{ config, pkgs, lib, ... }:

{
  programs.nvf.settings.vim = {
    languages = {
      # Python (includes Django support via LSP)
      python = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          server = "pyright";  # Provides inline diagnostics, type checking, and auto-imports
        };
        format = {
          enable = true;
          type = "ruff";  # Fast linter and formatter
        };
      };

      # Go
      go = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          server = "gopls";
        };
        format.enable = true;
      };

      # Nix
      nix = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          server = "nixd";
        };
        format.enable = true;
      };

      # HTML
      html = {
        enable = true;
        treesitter.enable = true;
      };

      # Tailwind CSS
      tailwind = {
        enable = true;
        lsp.enable = true;
      };

      # TypeScript/JavaScript
      ts = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          server = "ts_ls";
        };
      };

      # Svelte
      svelte = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
        };
        format = {
          enable = true;
          package = pkgs.nodePackages.prettier;
        };
      };

      # SQL
      sql = {
        enable = true;
        treesitter.enable = true;
        lsp.enable = true;
      };
            
      # YAML
      yaml = {
        enable = true;
        treesitter.enable = true;
        lsp.enable = true;
      };

      # CSS (useful alongside Tailwind)
      css = {
        enable = true;
        treesitter.enable = true;
        lsp.enable = true;
      };
    };

    # Enable LSP globally
    lsp.enable = true;

    # Enable treesitter globally
    treesitter = {
      enable = true;
      fold = true;
    };
  };
}
