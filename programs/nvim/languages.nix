{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.nvf.settings.vim = {
    languages = {
      # Python (includes Django support via LSP)
      python = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          servers = ["pyright"]; # Provides inline diagnostics, type checking, and auto-imports
        };
        format = {
          enable = true;
          type = ["ruff"]; # Fast linter and formatter
        };
      };

      # Go
      go = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          servers = ["gopls"];
        };
        format.enable = true;
      };

      # Nix
      nix = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          servers = ["nixd"];
        };
        format.enable = true;
      };

      # HTML
      html = {
        enable = true;
        treesitter.enable = true;
      };

      # TypeScript/JavaScript (includes React/Next.js support)
      typescript = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
          servers = ["typescript-language-server"]; # Supports JSX/TSX and React
        };
        # format = {
        #   enable = true;
        #   package = pkgs.nodePackages.prettier;
        # };
      };

      # Svelte
      svelte = {
        enable = true;
        treesitter.enable = true;
        lsp = {
          enable = true;
        };
        # format = {
        #   enable = true;
        #   package = pkgs.nodePackages.prettier;
        # };
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
    lsp.presets.tailwindcss-language-server.enable = true;

    # Enable treesitter globally
    treesitter = {
      enable = true;
      highlight.enable = true;
      indent.enable = true;  # Required for proper indentation (Python, etc.)
      fold = true;
      grammars = pkgs.vimPlugins.nvim-treesitter.passthru.allGrammars;
    };
  };
}
