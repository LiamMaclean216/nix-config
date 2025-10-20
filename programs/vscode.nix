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
      "jupyter.askForKernelRestart" = false;
      "python.analysis.inlayHints.variableTypes" = false;
      "python.analysis.inlayHints.functionReturnTypes" = false;
      "python.analysis.inlayHints.callArgumentNames" = "none";
      "python.analysis.inlayHints.functionParameters" = "none";
      "python.analysis.inlayHints.pytestParameters" = false;
    };

    profiles.default.extensions = with pkgs.vscode-extensions; [
      ms-python.python
      ms-toolsai.jupyter
      ms-toolsai.jupyter-keymap
      ms-toolsai.jupyter-renderers
      ms-python.vscode-pylance
      #vscodevim.vim
    ];

    profiles.default.keybindings = [
      {
        "key" = "ctrl+w";
        "command" = "workbench.action.closeActiveEditor";
        "when" = "!terminalFocus";
      }
    ];

    mutableExtensionsDir = false;
  };
}
