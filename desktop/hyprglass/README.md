# Rust liquid glass

An original Rust-driven GLES 3 optical material for Wofi, the bottom-right Waybar
clock, dictation and Wlogout. `rust/src/liquid.frag` refracts the live compositor
backdrop using a convex slab normal and Snell's law, with different refractive
indices for red, green and blue. Schlick Fresnel, directional reflections, a
polished lip and a small caustic give the edges thickness. A restrained, smooth
spectral rim avoids unfiltered subpixel diffraction bands. This is an Apple-inspired
screen-space material, not Apple's proprietary renderer or a full wave simulation.

`rust/src/lib.rs` embeds the shader, caches uniform locations, validates optical
parameters and submits the GPU pass. It has no Cargo dependencies. The GPU runs
GLSL; the host renderer is Rust. `rust-renderer.patch` connects it to the pinned
HyprGlass 0.8.0 C++ integration, which retains Hyprland's private ABI, scene
sampling, blur, damage tracking and GL context ownership. This is deliberately
not a from-scratch rewrite of that compositor integration. The ABI/version check
remains intact. No screenshots, screen-recording permission or CPU readback are
used during desktop rendering.

Wofi and the clock use exact rounded-box distance fields and continuous normals.
The clock package's `anchor-right` patch makes its layer fit GTK's natural width,
so lensing is centered on the pill rather than the whole monitor. `fwidth`
filters the outer silhouette; premultiplied composition applies edge coverage
once. Empty padding samples track Waybar's GTK opacity fade independently of
Hyprland's layer fade. The pane opacity and radius are compiled from `theme.nix`.
Refraction thickness follows bevel size, avoiding excessive clock distortion.

Other, irregular layers such as Wlogout retain an alpha-contour fallback with
24 directions and eight binary refinements. This is still an approximation;
very narrow shapes can lose detail, and it costs more than analytic geometry.
Scene capture extends monitor-edge texels into off-screen padding before blur,
avoiding black contamination near the clock. Foreground GTK content is composited
afterward in premultiplied alpha, so text stays sharp. Ordinary windows remain excluded (`compositor.enabled = false`
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

GTK's `surfaceOpacity` supplies the silhouette and a charcoal tint (now 22%). Its
CSS sheen is disabled because lighting comes from the shader. Live resampling is
damage-driven and capped at 60 fps. Optical rendering is tested on the real GPU
using an isolated EGL device context; this leaves the desktop and focus alone.
The timing covers the material pass, excluding compositor capture, blur and
client rendering. Overall GPU utilization includes unrelated applications.

Build and check without changing the running session:

```sh
nix build path:.#hyprglass --no-link -L
```

The derivation runs Rust material/FFI tests, GLSL validation, and a surfaceless
Mesa GLES test of the actual Rust draw pass. Pixel assertions cover transparent
corners and empty bar regions, supersampled silhouette coverage, unchanged opaque
text, displacement, dispersion, premultiplied fades, zero opacity, and immediate scene updates. Mesa is used only
for deterministic build tests; the desktop uses Hyprland's current GPU context.

`rust/tests/render.py` accepts `--artifacts DIR --label after` to save overview
images and enlarged edge crops, and `--benchmark 100 --egl-device 0` for GPU
timer queries on supported drivers. Pass the pinned EGL/GLES libraries and the
Rust cdylib as its three positional arguments. On NVIDIA, select
`__EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json`.
Hardware access may require the normal sandbox approval. `--shader-file` can
compare a saved old shader using the same Rust draw path.

RTX 3090 measurements (100 old / 80 new frames, `GL_EXT_disjoint_timer_query`):

| Material pass | Previous median | Refined median |
| --- | --- | --- |
| Wofi, 620×460 | 0.042 ms | 0.011 ms |
| Clock, old 3435×40 surface → new 224×40 pill | 0.015 ms | 0.002 ms |

The generic screen-wide fallback alone increased from 0.015 to 0.040 ms due to
extra contour refinement. Wofi and the tightened clock bypass that fallback.
These are isolated measurements at the GPU's then-current clocks, not a promise
of total compositor frame time or a change in system-wide utilization.

Apply the Home Manager configuration with:

```sh
nix run .#home-manager -- switch --flake path:.#liam
```

Log out and back in to load the rebuilt plugin; changing its path while the old
plugin is loaded is not a reliable replacement. If your running compositor is
older than the pinned Hyprland, apply the NixOS build before logging back in.
Afterward check `hyprctl plugin list` and `hyprctl configerrors`. Home Manager
generations retain the old plugin and theme for rollback.
