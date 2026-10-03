# Live desktop glass

Super+D opens Wofi with the custom Rust liquid-glass material through HyprGlass. The speech-to-text panel uses
the same material and remains anchored 64 logical pixels above the bottom center.
Both surfaces keep their text and controls separate from the compositor-rendered
backdrop. There are no screenshots, temporary backdrop images, or capture loops.

The shared palette and material are configured in `../theme.nix`: a light charcoal tint, one blur
iteration, curved-edge refraction, spectral fringes and highlights, and background updates
capped at 60 fps when the scene changes. The `wofi`, `voice-input`, `waybar`, and
Wlogout `logout_dialog` layer namespaces are enabled; ordinary windows are excluded.
GTK supplies the rounded alpha mask. Layout is in `../wofi/style.css` and
`../voice-input/overlay.py`.

The Rust core and original GPU shader live in `../hyprglass/rust`; see
`../hyprglass/README.md` for architecture, material controls and rendering tests.
The launcher and clock use analytic rounded geometry with filtered coverage;
Waybar's local package patch anchors its naturally sized clock surface at the
right edge. The tint is denser, with gentler refraction and smoother highlights.

The bottom-right clock uses the same material. Its visibility toggle fades for
250 ms using GTK's `.hidden` class; the pinned Waybar package is patched to avoid
forcing opacity to zero before that transition can run. Both hide and show use
SIGUSR1. Timing lives in `theme.nix` as `fadeSpeed` (Hyprland tenths of a second).

Dolphin and its app picker use an opaque Qt interpretation of this palette.
See `../README.md` for the shared appearance entrypoint and Dolphin customizations.

`launcher.nix` packages Wofi with native focus dismissal and corrected CSS sizing.
Dismissal watches the window's active state so arrow-key navigation between
widgets does not close the launcher.
`launch.sh` prevents duplicate openings and selects an opaque fallback if HyprGlass
is unavailable. The speech panel also uses an opaque fallback when its daemon
starts without the plugin and rechecks whenever the bubble opens. Neither panel captures audio or desktop content just
to draw the glass.

Hyprland 0.56.2 and HyprGlass 0.8.0 are pinned in `../../flake.nix`. The plugin
builds with the compositor's compiler and dependency headers; do not bypass its
ABI check. Glaze is pinned to 7.2.0 because this Hyprland release requires Glaze 7
while its upstream Nix package input provides Glaze 8.

After a compositor upgrade, log out and back in (or reboot) to run the new binary.
Reloading configuration cannot upgrade an already running compositor or switch
its configuration parser. The greetd session starts through `start-hyprland`;
Home Manager assembles native Lua from the desktop modules. `make home` no
longer forces a reload, and normal Lua edits are watched by Hyprland. A legacy
session may generate a `.conf` stub during this one-time migration; the new
session prefers the managed `hyprland.lua`. Check
`hyprctl version`, `hyprctl plugin list`, and `hyprctl configerrors` after login.
Future changes use the usual `make nixos` and `make home` workflow. Existing NixOS
boot generations and Home Manager generations provide rollback.

Super+Esc opens the packaged `wlogout-glass` menu: four centered tiles with the
same live material and an opaque fallback. Its existing power/session actions
are unchanged. `../wlogout.nix` packages the grid layout and launcher in Nix.

Hyprlock uses its own renderer and session-lock protocol, rather than a normal
layer surface. Its matching appearance uses a blurred wallpaper, dense neutral
panels, gradient rims and Inter typography. The password field, solar times, and
Windows button remain in place. Hyprlock comes from the already-pinned Hyprland
Nixpkgs input so the existing clickable widgets are supported. Wallpaper and icon
paths are immutable Nix store assets.

Upstream: https://github.com/hyprnux/hyprglass
