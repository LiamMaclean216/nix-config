rec {
  # Shared fixed desktop palette. Hex values omit # for use in Hyprland too.
  colors = {
    background = "24211f";
    foreground = "f4e9da";
    accent = "e9b66d";
    secondary = "c9845e";
    muted = "baa995";
    error = "ee9484";
    shadow = "000000";
    sidebar = "191715";
    surface = "393029";
    selection = "493a2c";
    sidebarSelection = "302923";
    # Keep folders yellow independently of the muted selection backgrounds.
    folder = "f6d76f";
  };

  radius = 28;
  # All application windows share this radius; GTK cards use the larger one.
  windowRadius = 8;
  font = "Inter";
  # Hyprland animation speed is measured in tenths of a second.
  fadeSpeed = 2.5;
  windowGeometryAnimations = false;
  qt = {
    name = "LiquidGlass";
    icons = "breeze-dark";
    fontSize = 11;
    surfaceOpacity = 1.0;
    controlRadius = 10;
    sidebarWidth = 220;
    iconSize = 22;
  };

  # Shared material for GTK alpha masks, Qt surfaces and the compositor.
  glass = {
    surfaceOpacity = 0.22;
    # Lighting comes from the GPU material; GTK supplies only tint and silhouette.
    sheen = "none";
    compositor = {
      enabled = false;
      manage_window_blur = true;
      default_theme = "dark";
      blur_strength = 0.8;
      blur_iterations = 1;
      refraction_strength = 0.55;
      chromatic_aberration = 0.10;
      fresnel_strength = 0.40;
      specular_strength = 0.48;
      glass_opacity = 1.0;
      edge_thickness = 0.12;
      # A light charcoal tint leaves the live refracted scene visible.
      tint_color = "0x${colors.background}36";
      lens_distortion = 0.06;
      brightness = 1.0;
      contrast = 1.0;
      saturation = 1.04;
      vibrancy = 0.12;
      vibrancy_darkness = 0.0;
      adaptive_dim = 0.16;
      adaptive_boost = 0.0;
      layers = {
        enabled = true;
        namespaces = "wofi, voice-input, logout_dialog, waybar";
        mask_mode = "alpha";
        namespace_mask_thresholds = "wofi=0.05, voice-input=0.05, logout_dialog=0.05, waybar=0.05";
        live_resample = true;
        # Follow damaged compositor frames, including this monitor's 240 Hz.
        # An idle pane still reuses its cached backdrop.
        live_resample_fps = 0;
        force_live_resample = false;
        manage_blur = true;
      };
    };
  };

  renderCss = css: gtkColors + builtins.replaceStrings
    [ "@radius@" "@font@" "@glass-opacity@" "@glass-sheen@" ]
    [ (toString radius) font (toString glass.surfaceOpacity) glass.sheen ] css;

  gtkColors = builtins.concatStringsSep "\n" (
    builtins.attrValues (builtins.mapAttrs
      (name: value: "@define-color ${name} #${value};") colors)
  ) + "\n\n";
}
