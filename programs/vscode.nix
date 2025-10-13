{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;

    profiles.default.userSettings = {
      "python.analysis.typeCheckingMode" = "strict";
      "explorer.confirmDelete" = false;

      "vim.useSystemClipboard" = true;
      "vim.hlsearch" = true;
      "vim.incsearch" = true;
      "vim.cursorStylePerMode.insert" = "line";
      "vim.cursorStylePerMode.normal" = "block";
      "vim.cursorStylePerMode.visual" = "block";
      "editor.lineNumbers" = "relative";
      "notebook.lineNumbers" = "on";
      "notebook.relativeLineNumbers" = true;
    };

    profiles.default.extensions = with pkgs.vscode-extensions; [
      ms-python.python
      ms-toolsai.jupyter
      ms-toolsai.jupyter-keymap
      ms-toolsai.jupyter-renderers
      ms-python.vscode-pylance
      vscodevim.vim
    ];

    mutableExtensionsDir = false;
  };
}
