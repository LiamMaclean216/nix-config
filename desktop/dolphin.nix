{ config, lib, pkgs, ... }:
let
  theme = import ./theme.nix;
  styleValues = theme.colors // {
    inherit (theme) font;
    control-radius = toString theme.qt.controlRadius;
    sidebar-width = toString theme.qt.sidebarWidth;
  };
  style = pkgs.writeText "dolphin.qss" (builtins.replaceStrings
    (map (name: "@${name}@") (builtins.attrNames styleValues))
    (builtins.attrValues styleValues)
    (builtins.readFile ./qt/dolphin.qss));
  dolphin = (pkgs.callPackage ./dolphin/package.nix {}).overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      wrapProgram "$out/bin/dolphin" --add-flags "-stylesheet ${config.xdg.configHome}/dolphin/theme.qss"
    '';
  });
in {
  imports = [./dolphin-context-menu.nix];
  home.packages = [dolphin pkgs.kdePackages.kservice];
  xdg.configFile."dolphin/theme.qss".source = style;

  # KService needs an actual menu even outside Plasma. DefaultAppDirs discovers
  # both profile applications and the user's custom .desktop entries.
  xdg.configFile."menus/applications.menu".text = ''
    <!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
      "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
    <Menu>
      <Name>Applications</Name>
      <DefaultAppDirs/>
      <DefaultDirectoryDirs/>
      <DefaultMergeDirs/>
      <Include><All/></Include>
    </Menu>
  '';

  # The user's mimeapps.list stays writable and is never reset on activation.
  home.activation.dolphinApplicationCache = lib.hm.dag.entryAfter ["linkGeneration" "installPackages"] ''
    run ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 --noincremental
  '';

}
