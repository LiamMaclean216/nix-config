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
rounded Places selection use `colors.folder` and `colors.selection`.
Places and the file list share the same selection highlight.
The information-panel preview, file rows and icon zoom update without size transitions.
The right information panel collapses when filenames need more room and returns
when the window is wider; explicitly hiding it keeps it hidden.
Activation removes the Music bookmark from Places while keeping the folder.
The details list has no side padding or inline folder-expansion gutter.

`dolphin.nix` installs the styled Dolphin, supplies the application menu that
KService needs outside Plasma, and refreshes its cache after package activation.
The KDE integration uses the styled native Open With dialog, so Other Application
works without a Plasma application-chooser portal.
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

The GTK `LiquidGlass` theme gives Blueman and Pavucontrol the same opaque
charcoal surfaces, cream text, amber sliders and rounded controls as Dolphin.
It is installed as a base theme so the glass overlays keep their own styling.
Reopen existing GTK apps after activation to pick up the theme.

The bottom-right Waybar clock stays visible on hover. Clicking the date or time
text hides the whole bar for 30 seconds, then it fades back in. The clock's
padding and the gap beside the speaker do not trigger hiding. Click the speaker icon
for a compact Sound panel above the bar. Main output volume stays at the top;
active playback apps appear below with their icons and volume sliders.
Click outside, click the icon again or the close button, or press Escape to close it.
Scroll only moves the list; it never changes any volume. There are no input,
microphone, mute or device-selection controls. Moving a muted output's slider
above zero unmutes it. The speaker has no tooltip; right-click opens the full mixer.
The popup uses the same glass tint, opacity and radius as the clock and sits just
above it. Controls follow audio hotplug and reconnect if the audio server restarts.

`audio-volume-memory.service` remembers playback levels by application identity.
It restores those levels when an app recreates its stream, after the app's initial
volume request, and remembers later changes from the popup or full mixer. This
keeps reconnects from replacing saved app levels with their startup defaults.
It does not restore microphone or master-device levels. State lives under
`$XDG_STATE_HOME/audio-popup/` (normally `~/.local/state/audio-popup/`).
