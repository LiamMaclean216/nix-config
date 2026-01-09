{
  config,
  pkgs,
  ...
}: {
  # Screen recording script
  home.file.".local/bin/screen-record" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash

      # Create Videos directory if it doesn't exist
      mkdir -p "$HOME/Videos"

      # Generate filename with current date and time
      FILENAME="$HOME/Videos/screen-record-$(date +%Y-%m-%d-%H-%M-%S).mp4"

      # Get the selected area
      GEOMETRY="$(${pkgs.slurp}/bin/slurp)"

      if [ -n "$GEOMETRY" ]; then
        # Launch terminal with wf-recorder
        alacritty -e bash -c "${pkgs.wf-recorder}/bin/wf-recorder -g \"$GEOMETRY\" -f \"$FILENAME\"; echo 'Recording saved to $FILENAME'; read -p 'Press Enter to close...'"
      fi
    '';
  };

  # Desktop entry for wofi app picker
  home.file.".local/share/applications/screen-record.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Screen Record
    Comment=Record a screen area with wf-recorder
    Exec=${config.home.homeDirectory}/.local/bin/screen-record
    Icon=video-display
    Terminal=false
    Categories=Utility;Video;
  '';
}
