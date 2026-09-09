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
        # Pass arguments separately so paths and geometry remain safely quoted.
        alacritty -e bash -c '
          geometry="$1"
          filename="$2"

          # Ctrl+C stops the recorder while this shell continues with compression.
          trap : INT
          ${pkgs.wf-recorder}/bin/wf-recorder -g "$geometry" -f "$filename"

          if [ -s "$filename" ]; then
            echo "Compressing recording..."
            compressed=$(mktemp "$filename.compress-XXXXXX.mp4")
            if [ -n "$compressed" ] && ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel warning -nostdin -y \
              -i "$filename" -c:v libx264 -preset medium -crf 26 \
              -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" -pix_fmt yuv420p \
              -c:a copy -movflags +faststart "$compressed"; then
              if [ -s "$compressed" ] && [ "$(stat -c %s "$compressed")" -lt "$(stat -c %s "$filename")" ]; then
                if mv -f -- "$compressed" "$filename"; then
                  echo "Compression complete."
                else
                  echo "Could not replace recording; original kept."
                fi
              else
                echo "Original recording is already smaller; keeping it."
              fi
            else
              echo "Compression failed or was interrupted; original recording kept."
            fi
            if [ -n "$compressed" ]; then
              rm -f -- "$compressed"
            fi
            echo "Recording saved to $filename"
          else
            echo "No recording was saved."
          fi
          read -r -p "Press Enter to close..."
        ' screen-record "$GEOMETRY" "$FILENAME"
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
