{ pkgs, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  programs.vscode = {
    enable = true;
    package = pkgs-unstable.vscode;

    profiles.default.userSettings = {
      "python.analysis.typeCheckingMode" = "basic";
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

    profiles.default.extensions = with pkgs-unstable.vscode-extensions; [
      ms-python.python
      ms-toolsai.jupyter
      ms-toolsai.jupyter-keymap
      ms-toolsai.jupyter-renderers
      ms-python.vscode-pylance
      vscodevim.vim
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
