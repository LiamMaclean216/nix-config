{ pkgs, ... }:

let
  lazygitWithWorktreePath = pkgs.lazygit.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [ ./worktree-path.patch ];
  });
in
{
  programs.lazygit = {
    enable = true;
    package = lazygitWithWorktreePath;
    settings = {
      os.editPreset = "nvim-remote";
      keybinding.universal = {
        edit = "o";
        openFile = "<disabled>";
      };
    };
  };
}
