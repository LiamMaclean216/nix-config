Hold **Mouse 5** (the forward side button, Hyprland `mouse:276`) to dictate.
The bottom-center overlay shows Soniox's live transcript without taking focus.
Release to stop the microphone, finish the last words, and paste the entire text
into the focused field, then press Enter to submit it. There is no typing animation.
The transcript is copied to the clipboard. Terminals use Ctrl+Shift+V; other
applications use Ctrl+V. Enter follows after a short pause for paste processing.
Empty dictation, errors, and cancellation do not press Enter.
**Escape** (or **Super + Shift + Escape**) cancels before pasting or prevents
the pending Enter after pasting. Text already pasted remains.
Escape also keeps its usual behavior in the application.

After applying Home Manager (`make home`), run:

```sh
voice-input setup-key
```

The hidden prompt saves the key with owner-only permissions to
`~/.config/voice-input/api-key`, outside Git and the Nix store. The service reads
it on each recording, so updating it needs no restart. Never put the key in Nix.

Uses the default PipeWire microphone, 16 kHz mono PCM, and Soniox `stt-rt-v5`
with an English language hint (other languages remain allowed). Audio streams
directly to Soniox only during a hold; neither audio nor transcripts are saved.
Finishing can take a moment after release. If the focused window changes while
finishing, insertion is canceled. Finalized text is inserted immediately on the
server's completion message, before waiting for the WebSocket to close.
The overlay shows the most recent text for
long recordings, while the entire finalized transcript is inserted. Recordings
time out after three minutes. Pressing again discards the previous unfinished
dictation, clears the overlay, and starts a new recording immediately.

```sh
systemctl --user status voice-input
journalctl --user -u voice-input -n 30
systemctl --user restart voice-input
```

The implementation follows the [Soniox WebSocket API](https://soniox.com/docs/api-reference/stt/websocket-api).
It appends final tokens, replaces provisional tokens, and waits for the server's
`finished` response after sending an empty text message to end the audio stream.
Use a text message here: an empty binary message can leave Soniox waiting.

Build the package independently (without staging new files) using:

```sh
nix build --impure --expr 'let
  flake = builtins.getFlake ("git+file://" + toString ./.);
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
in pkgs.callPackage ./desktop/voice-input {}' --no-link
```
