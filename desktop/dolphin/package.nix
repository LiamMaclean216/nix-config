{ kdePackages }:

# Small UI changes against the repository's pinned Dolphin. Keep Ark's native
# extraction actions so progress, cancellation, errors and trash stay intact.
kdePackages.dolphin.overrideAttrs (old: {
  patches = (old.patches or []) ++ [
    ./archive-actions-first.patch
    ./remove-split-actions.patch
    ./hide-unavailable-terminal.patch
    ./clean-navigation.patch
    ./stable-preview.patch
    ./stable-item-resize.patch
    ./responsive-info-panel.patch
  ];
})
