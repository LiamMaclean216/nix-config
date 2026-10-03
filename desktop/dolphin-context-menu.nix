{ lib, pkgs, ... }:

{
  # Merge only the requested menu preferences. KDE can keep updating the rest
  # of these files, including settings changed interactively in Dolphin.
  home.activation.dolphinContextMenu = lib.hm.dag.entryAfter ["linkGeneration"] ''
    for plugin in kactivitymanagerd_fileitem_linking_plugin tagsfileitemaction; do
      run ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 \
        --file kservicemenurc --group Show --key "$plugin" --type bool false
    done
    for action in ShowOpenInSplitView ShowCopyToOtherSplitView ShowMoveToOtherSplitView; do
      run ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 \
        --file dolphinrc --group ContextMenu --key "$action" --type bool false
    done
  '';
}
