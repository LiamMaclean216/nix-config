{pkgs, ...}: let
  voiceInput = pkgs.callPackage ./voice-input {};
in {
  home.packages = [voiceInput];

  systemd.user.services.voice-input = {
    Unit = {
      Description = "Mouse 5 Soniox dictation";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${voiceInput}/bin/voice-input daemon";
      Restart = "on-failure";
      RestartSec = 2;
      UMask = "0077";
    };
    Install.WantedBy = ["graphical-session.target"];
  };

  wayland.windowManager.hyprland.settings = {
    # Mouse 5 = BTN_EXTRA. Ignore modifiers so releasing Shift mid-dictation
    # cannot leave the microphone running. Do not enable these on the lock screen.
    bindi = [", mouse:276, exec, ${voiceInput}/bin/voice-input start"];
    bindri = [", mouse:276, exec, ${voiceInput}/bin/voice-input stop"];
    # Pass Escape through so it keeps its normal behavior in applications.
    bindn = [", Escape, exec, ${voiceInput}/bin/voice-input cancel"];
    bind = ["$mainMod SHIFT, Escape, exec, ${voiceInput}/bin/voice-input cancel"];
  };
}
