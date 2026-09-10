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

  xdg.configFile."hypr/hyprland.lua".text = ''
    -- Ignore modifiers, but never record from the lock screen.
    hl.bind("mouse:276", hl.dsp.exec_cmd("${voiceInput}/bin/voice-input start"), { ignore_mods = true })
    hl.bind("mouse:276", hl.dsp.exec_cmd("${voiceInput}/bin/voice-input stop"), { ignore_mods = true, release = true })
    hl.bind("Escape", hl.dsp.exec_cmd("${voiceInput}/bin/voice-input cancel"), { non_consuming = true })
    hl.bind("SUPER + SHIFT + Escape", hl.dsp.exec_cmd("${voiceInput}/bin/voice-input cancel"))
  '';
}
