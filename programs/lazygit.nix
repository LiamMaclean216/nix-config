{ pkgs, ... }:

let
  lazygitWithWorktreePath = pkgs.lazygit.overrideAttrs (oldAttrs: {
    postPatch = (oldAttrs.postPatch or "") + ''
      substituteInPlace pkg/gui/controllers/helpers/worktree_helper.go \
        --replace-fail \
          'Title: self.c.Tr.NewWorktreePath,' \
          'Title: self.c.Tr.NewWorktreePath, InitialContent: "../worktrees/",'
    '';
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
