rec {
  # Shared fixed desktop palette. Hex values omit # for use in Hyprland too.
  colors = {
    background = "282b32";
    foreground = "f7f8fc";
    accent = "94a3ff";
    muted = "aeb8c9";
    error = "f09296";
    shadow = "000000";
  };

  radius = 28;
  font = "Inter";
  renderCss = css: gtkColors + builtins.replaceStrings
    [ "@radius@" "@font@" ] [ (toString radius) font ] css;

  gtkColors = builtins.concatStringsSep "\n" (
    builtins.attrValues (builtins.mapAttrs
      (name: value: "@define-color ${name} #${value};") colors)
  ) + "\n\n";
}
