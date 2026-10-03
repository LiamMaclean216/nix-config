{ pkgs }:
let
  theme = import ../theme.nix;
  assets = pkgs.runCommand "wofi-themed-assets" {} ''
    mkdir -p $out
    cp ${../wofi}/* $out/
    chmod u+w $out/*.css
    cp ${pkgs.writeText "wofi-style.css" (theme.renderCss (builtins.readFile ../wofi/style.css))} $out/style.css
    cp ${pkgs.writeText "wofi-style-fallback.css" (theme.renderCss (builtins.readFile ../wofi/style-fallback.css))} $out/style-fallback.css
  '';
  # Keep changes local to this launcher; other users of the system Wofi are unaffected.
  wofi = pkgs.wofi.overrideAttrs (old: {
    patches = (old.patches or []) ++ [ ./dismiss-on-deactivate.patch ];
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/wofi.c \
        --replace-fail 'zwlr_layer_surface_v1_set_keyboard_interactivity(surface, true);' \
          'zwlr_layer_surface_v1_set_keyboard_interactivity(surface, 2);
           zwlr_layer_surface_v1_set_exclusive_zone(surface, -1);' \
        --replace-fail 'gtk_widget_set_size_request(scroll, width, height - alloc.height);' \
          'GtkBorder padding, border;
           GtkStyleContext *style = gtk_widget_get_style_context(outer_box);
           gtk_style_context_get_padding(style, GTK_STATE_FLAG_NORMAL, &padding);
           gtk_style_context_get_border(style, GTK_STATE_FLAG_NORMAL, &border);
           gtk_widget_set_size_request(scroll,
             width - padding.left - padding.right - border.left - border.right,
             height - alloc.height - padding.top - padding.bottom - border.top - border.bottom);'
    '';
  });
in pkgs.writeShellApplication {
  name = "wofi-glass";
  runtimeInputs = [ wofi pkgs.hyprland pkgs.jq pkgs.coreutils pkgs.util-linux ];
  text = ''
    export WOFI_GLASS_ASSETS=${assets}
  '' + builtins.readFile ./launch.sh;
}
