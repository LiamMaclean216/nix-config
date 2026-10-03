# Desktop appearance

Edit **`theme.nix`** to keep the desktop consistent. It owns the charcoal,
amber and copper palette, Inter font, radii, Qt sizing, glass material and fade
timing. Wofi, dictation, Wlogout, Waybar, Hyprlock and KDE consume this file.
Window geometry animations are disabled; the shared fade remains enabled.
GTK cards use `radius`; every application window uses the same 8px `windowRadius`.
`glass.surfaceOpacity` controls the panels; `qt.surfaceOpacity = 1.0` keeps
Dolphin and its app picker opaque.

`appearance.nix` generates the Kvantum theme from the pinned KvMojave assets.
`qt/dolphin.qss` defines Dolphin's sidebar, toolbar and menu layout, using palette
tokens from `theme.nix`. `qt/apply-settings.py` merges appearance settings into
writable KDE configuration while preserving other preferences. File associations
remain in the user's writable `~/.config/mimeapps.list`.

Dolphin uses uniform file backgrounds, soft selection, a quieter column header
and a minimal toolbar without dropdown chevrons. The folder tree panel above
Places and the selection plus overlays are hidden. The status bar is disabled,
including folder counts and selected-file details. Light yellow folder icons and the
darker, rounded Places selection use `colors.folder` and `colors.sidebarSelection`.
The information-panel preview, file rows and icon zoom update without size transitions.
Activation removes the Music bookmark from Places while keeping the folder.
The details list has no side padding or inline folder-expansion gutter.

`dolphin.nix` installs the styled Dolphin, supplies the application menu that
KService needs outside Plasma, and refreshes its cache after package activation.
`dolphin-context-menu.nix` disables Activities, Tags and split context actions.
The small patches in `dolphin/` remove Split from the toolbar and menus, omit the
embedded terminal when Konsole is unavailable, and move Ark's own extraction
actions to the top of the context menu. Ark still handles extraction, errors,
progress and its optional move-to-Trash behavior.

`hyprlock.conf` styles the login/lock screen with the shared palette: a compact
charcoal sign-in card, lighter clock and date, solar-times dock, and Windows
boot button. `hyprlock.nix` renders its font, card and control radii, and fade
duration from `theme.nix`; solar updates and the Windows action keep their
existing helpers. Changes appear the next time the screen locks.

Apply with `make home`, then reopen Dolphin. Home Manager generations provide
rollback. New files must be tracked by Git for a Git-backed flake evaluation;
while developing untracked modules, use
`nix run .#home-manager -- switch --flake path:.#liam`.
