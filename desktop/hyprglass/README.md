# Rust liquid glass

An original Rust-driven GLES 3 optical material for Wofi, the bottom-right Waybar
clock, dictation and Wlogout. `rust/src/liquid.frag` refracts the live compositor
backdrop using a convex slab normal and Snell's law, with different refractive
indices for red, green and blue. Schlick Fresnel, directional reflections, a
polished lip and a small caustic give the edges thickness. A wavelength-dependent
slit envelope approximates edge diffraction. This is an Apple-inspired
screen-space material, not Apple's proprietary renderer or a full wave simulation.

`rust/src/lib.rs` embeds the shader, caches uniform locations, validates optical
parameters and submits the GPU pass. It has no Cargo dependencies. The GPU runs
GLSL; the host renderer is Rust. `rust-renderer.patch` connects it to the pinned
HyprGlass 0.8.0 C++ integration, which retains Hyprland's private ABI, scene
sampling, blur, damage tracking and GL context ownership. This is deliberately
not a from-scratch rewrite of that compositor integration. The ABI/version check
remains intact. No screenshots, screen-recording permission or CPU readback are
used during desktop rendering.

The alpha contour defines the optical boundary, including the clock pill inside
Waybar's screen-wide transparent surface. Twelve local probes locate nearby
edges; five binary refinements per crossing approximate their distance and
normal. Interior pixels skip refinement. This avoids a full-monitor distance
texture, but it is a sampled approximation and very narrow shapes can lose detail.
Foreground GTK content is composited afterward in premultiplied alpha, so text
stays sharp. Ordinary windows remain excluded (`compositor.enabled = false`
controls windows; `compositor.layers.enabled = true` controls these widgets).

Tune `../theme.nix`, under `glass.compositor`:

| Setting | Effect |
| --- | --- |
| `refraction_strength` | Optical thickness / displacement (0–2) |
| `chromatic_aberration` | RGB dispersion and subtle diffraction fringes (0–1) |
| `fresnel_strength`, `specular_strength` | Rim reflection / directional highlights |
| `edge_thickness` | Bevel width relative to the smaller surface dimension |
| `lens_distortion` | Gentle center magnification |
| `blur_strength`, `blur_iterations` | Scene softness before refraction |
| `tint_color`, `adaptive_dim` | Tint and readability over bright backgrounds |

GTK's `surfaceOpacity` supplies the silhouette and a little charcoal tint. Its
CSS sheen is disabled because lighting comes from the shader. Live resampling is
damage-driven and capped at 60 fps; the contour work still costs more GPU time
than the original material. Actual desktop frame timing must be measured in the
running session; the headless checks do not establish NVIDIA performance.

Build and check without changing the running session:

```sh
nix build path:.#hyprglass --no-link -L
```

The derivation runs Rust material/FFI tests, GLSL validation, and a surfaceless
Mesa GLES test of the actual Rust draw pass. Pixel assertions cover transparent
corners and empty bar regions, unchanged opaque text, displacement, dispersion,
premultiplied fades, zero opacity, and immediate scene updates. Mesa is used only
for deterministic build tests; the desktop uses Hyprland's current GPU context.

Apply the Home Manager configuration with:

```sh
nix run .#home-manager -- switch --flake path:.#liam
```

Log out and back in to load the rebuilt plugin; changing its path while the old
plugin is loaded is not a reliable replacement. If your running compositor is
older than the pinned Hyprland, apply the NixOS build before logging back in.
Afterward check `hyprctl plugin list` and `hyprctl configerrors`. Home Manager
generations retain the old plugin and theme for rollback.
