{ pkgs, ... }:
let
  theme = import ./theme.nix;
  assets = pkgs.runCommand "wlogout-themed-assets" {} ''
    mkdir -p $out
    cp ${./wlogout}/* $out/
    chmod u+w $out/*.css
    cp ${pkgs.writeText "wlogout-style.css" (theme.renderCss (builtins.readFile ./wlogout/style.css))} $out/style.css
    cp ${pkgs.writeText "wlogout-style-fallback.css" (theme.renderCss (builtins.readFile ./wlogout/style-fallback.css))} $out/style-fallback.css
  '';
  # Center the natural-size grid instead of stretching four buttons over the screen.
  wlogout = pkgs.wlogout.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace main.c --replace-fail \
        'GtkWidget *grid = gtk_grid_new();' \
        'GtkWidget *grid = gtk_grid_new();
         gtk_widget_set_halign(grid, GTK_ALIGN_CENTER);
         gtk_widget_set_valign(grid, GTK_ALIGN_CENTER);'
    '';
  });
  launcher = pkgs.writeShellApplication {
    name = "wlogout-glass";
    runtimeInputs = [ wlogout pkgs.hyprland pkgs.jq pkgs.mako pkgs.util-linux ];
    text = ''
      exec 9>"''${XDG_RUNTIME_DIR:?A Wayland session is required}/wlogout-glass.lock"
      flock -n 9 || exit 0
      style=${assets}/style-fallback.css
      if hyprctl plugin list -j 2>/dev/null | jq -e 'any(.[]; .name == "hyprglass")' >/dev/null; then
        style=${assets}/style.css
      fi
      makoctl dismiss --all 2>/dev/null || true
      # Keep the singleton lock out of launched logout/reboot commands.
      wlogout --protocol layer-shell --buttons-per-row 2 --margin 0 \
        --layout ${assets}/layout --css "$style" "$@" 9>&-
    '';
  };
in {
  home.packages = [
    launcher
    (pkgs.writeShellScriptBin "wlogout" ''
      exec ${launcher}/bin/wlogout-glass "$@"
    '')
  ];
}
