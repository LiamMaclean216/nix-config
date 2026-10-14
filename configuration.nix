# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  inputs,
  pkgs,
  lib,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
  claude-code = inputs.nix-claude-code.packages.${pkgs.system}.default;
  codex = inputs.codex-nix.packages.${pkgs.system}.default;
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./nvidia.nix
    ./fonts.nix
    ./programs/firefox.nix
  ];

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    # Allow the keyboard to be paired again after clearing its saved bond.
    settings.General.JustWorksRepairing = "confirm";
  };
  services.blueman.enable = true;

  # systemd-rfkill restores saved radio state independently of BlueZ's
  # powerOnBoot setting. Clear only Bluetooth blocks before that restore;
  # manual radio toggles during the session still work normally.
  systemd.services.bluetooth-boot-state = {
    description = "Enable Bluetooth at boot regardless of saved radio state";
    restartIfChanged = false;
    before = [ "systemd-rfkill.service" "bluetooth.service" ];
    after = [ "systemd-remount-fs.service" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = "/var/lib/systemd/rfkill";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for state in /var/lib/systemd/rfkill/*:bluetooth; do
        [ -f "$state" ] || continue
        printf '0\n' > "$state"
      done
      if [ -e /dev/rfkill ]; then
        ${pkgs.util-linux}/bin/rfkill unblock bluetooth
      fi
    '';
  };
  systemd.services.systemd-rfkill = {
    requires = [ "bluetooth-boot-state.service" ];
    after = [ "bluetooth-boot-state.service" ];
  };
  systemd.services.bluetooth = {
    requires = [ "bluetooth-boot-state.service" ];
    after = [ "bluetooth-boot-state.service" ];
  };

  # This MT7925 took 18 seconds to initialize at boot. Wait for its BlueZ
  # adapter before enabling it, so a late startup block cannot win the race.
  # RemainAfterExit makes this a one-time startup action, not a radio watchdog.
  systemd.services.bluetooth-startup-radio = {
    description = "Enable Bluetooth once the adapter finishes initializing";
    wantedBy = [ "multi-user.target" ];
    wants = [ "bluetooth.service" ];
    after = [ "bluetooth.service" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 100;
    };
    script = ''
      while (( SECONDS < 90 )); do
        for controller in /sys/class/bluetooth/hci*; do
          [ -e "$controller" ] || continue
          path="/org/bluez/''${controller##*/}"
          if ! ${pkgs.systemd}/bin/busctl --system --timeout=1 get-property \
            org.bluez "$path" org.bluez.Adapter1 Address >/dev/null 2>&1; then
            continue
          fi
          ${pkgs.util-linux}/bin/rfkill unblock bluetooth
          ${pkgs.systemd}/bin/busctl --system --timeout=3 set-property \
            org.bluez "$path" org.bluez.Adapter1 Powered b true && exit 0
        done
        ${pkgs.coreutils}/bin/sleep 1
      done
      echo "No Bluetooth adapter became ready during startup" >&2
      exit 1
    '';
  };

  # The onboard adapter previously hung in USB runtime resume with -110/-71.
  # Disable autosuspend for this USB ID only, including after driver binding.
  services.udev.extraRules = ''
    ACTION=="add|bind|change", SUBSYSTEM=="usb", ATTR{idVendor}=="13d3", ATTR{idProduct}=="3602", TEST=="power/control", ATTR{power/control}="on"
  '';

  boot.kernelPackages = pkgs.linuxPackages;

  # The TP-Link Archer T4U v3 uses RTL8822BU, not MediaTek.
  # Keep it in USB 2 mode: USB 3 mode switching has coincided with register
  # timeouts (-110), USB protocol errors (-71), and startup disconnects.
  # This trades peak throughput for stability; NetworkManager disables Wi-Fi PS.
  boot.extraModprobeConfig = ''
    options rtw88_usb switch_usb_mode=N
  '';
  
  # Enable firmware updates for WiFi and other hardware
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [
    pkgs.linux-firmware
    # Firmware for the ASUS/Broadcom Bluetooth adapter (0b05:17cb).
    pkgs.broadcom-bt-firmware
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Use greetd for auto-login to Hyprland with hyprlock
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "${pkgs.hyprland}/bin/start-hyprland";
        user = "liam";
      };
      default_session = initial_session;
    };
  };
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc.lib  # provides libstdc++.so.6
      zlib
      # Additional libraries for Python packages like jax
      glib
      glibc
      libz
      libGL
      libGLU
    ];

  services.desktopManager.plasma6.enable = false;

  # Disable gnome-keyring to avoid password prompts in lazygit
  services.gnome.gnome-keyring.enable = false;

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  services.libinput = {
    enable = true;
    mouse = {
      accelProfile = "flat";
    };
  };

  virtualisation.docker = {
    enable = true;
    rootless.enable = false;
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;
  # Disabled: avahi causes hanging on shutdown ("CUPS printer discovery")
  # services.avahi = {
  #   enable = true;
  #   nssmdns4 = true;
  #   openFirewall = true;
  # };

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber = {
      enable = true;
      extraConfig."51-bluetooth-playback" = {
        "monitor.bluez.properties" = {
          # Keep Bluetooth headphones on high-quality stereo playback.
          # Leave all available A2DP codecs enabled for automatic selection.
          "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
          "bluez5.hfphsp-backend" = "none";
          "bluez5.enable-sbc-xq" = true;
        };
        "monitor.bluez.rules" = [
          {
            matches = [ { "device.name" = "~bluez_card.*"; } ];
            actions."update-props"."bluez5.auto-connect" = [ "a2dp_sink" ];
          }
        ];
        "wireplumber.settings" = {
          "bluetooth.autoswitch-to-headset-profile" = false;
          # Select the best available profile instead of restoring a mic profile.
          "device.restore-profile" = false;
        };
      };
    };
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with 'passwd'.
  users.groups.librepods = {};
  users.users.liam = {
    isNormalUser = true;
    description = "Liam";
    extraGroups = ["networkmanager" "wheel" "docker" "librepods" "adbusers"];
    packages = with pkgs; [
      kdePackages.kate
      #  thunderbird
    ];
  };

  # Android USB debugging for Expo Go / React Native development.
  programs.adb.enable = true;

  security.wrappers.librepods = {
    source = lib.getExe' pkgs-unstable.librepods "librepods";
    capabilities = "cap_net_admin+ep";
    owner = "root";
    group = "librepods";
  };

  # Enable sudo
  security.sudo.enable = true;
  # Allow wheel group users to run sudo without a password
  security.sudo.wheelNeedsPassword = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    pkgs-unstable.google-chrome
    pkgs-unstable.vesktop
    pkgs-unstable.discord
    lazydocker
    git
    openssl
    gh
    claude-code
    pkgs-unstable.code-cursor-fhs # Cursor IDE (unfree; see nixpkgs code-cursor)
    pkgs-unstable.cursor-cli
    codex
    spotify
    neovim
    neovide
    libreoffice
    pinta
    beekeeper-studio
    awsebcli
    xclip
    github-desktop
    wf-recorder
    ffmpeg
    bluez-tools
    pkgs-unstable.librepods
    nodejs
    watchman
    android-tools
    # redisinsight
    mako
    libnotify
    supabase-cli
    act
    postgresql # Provides psql for vim-dadbod

    ripgrep
    cbonsai
    asciiquarium-transparent
    fastfetch
    (flameshot.override {enableWlrSupport = true;})
    grim
    slurp
    wf-recorder 

    qdirstat
    mission-center
    zip
    unzip
    gnumake
    pciutils
    usbutils
    linux-firmware

    wofi
    hyprshot
    imv
    pavucontrol
    wdisplays
    wlogout
    system-config-printer

    kdePackages.qtsvg
    kdePackages.kio-fuse #to mount remote filesystems via FUSE
    kdePackages.kio-extras #extra protocols support (sftp, fish and more)
    kdePackages.ark # Provides Dolphin's right-click extract actions
    kdePackages.dolphin
    adwaita-icon-theme # Adwaita cursor (includes cursors)
    unimatrix
    ninvaders
  ];

  environment.shellAliases = {
    matrix = "unimatrix -n -s 96 -l o";
    avenv = "source ~/.venv/bin/activate";
  };

  nixpkgs.config.permittedInsecurePackages = [
    "beekeeper-studio-5.1.5"
  ];

  security.polkit.enable = true;
  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
    networking.firewall.allowedTCPPorts = [ 8081 8000];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?
  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.settings.substituters = [ "https://hyprland.cachix.org" ];
  nix.settings.trusted-public-keys = [
    "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
  ];

  environment.pathsToLink = ["/libexec"]; # links /libexec from derivations to /run/current-system/sw

  services.xserver = {
    enable = true;
    desktopManager = {xterm.enable = true;};
  };

  # Switch to Hyprland (Wayland)
  programs.hyprland = {
    enable = true;
    package = pkgs.hyprland;
    portalPackage = pkgs.xdg-desktop-portal-hyprland;
  };

  # PAM entry so hyprlock can authenticate
  security.pam.services.hyprlock = {};

  # XDG portal setup for Wayland (incl. Hyprland)
  xdg.mime = {
    enable = true;
    defaultApplications = {
      # Web browser defaults
      "text/html" = ["google-chrome.desktop"];
      "application/xhtml+xml" = ["google-chrome.desktop"];
      "x-scheme-handler/http" = ["google-chrome.desktop"];
      "x-scheme-handler/https" = ["google-chrome.desktop"];
      "x-scheme-handler/about" = ["google-chrome.desktop"];
      "x-scheme-handler/unknown" = ["google-chrome.desktop"];

      "application/msword" = ["writer.desktop"];
      "application/vnd.ms-word.document.macroEnabled.12" = ["writer.desktop"];
      "application/vnd.ms-word.template.macroEnabled.12" = ["writer.desktop"];
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = ["writer.desktop"];
      "application/vnd.openxmlformats-officedocument.wordprocessingml.template" = ["writer.desktop"];

      "application/vnd.ms-excel" = ["calc.desktop"];
      "application/vnd.ms-excel.sheet.macroEnabled.12" = ["calc.desktop"];
      "application/vnd.ms-excel.template.macroEnabled.12" = ["calc.desktop"];
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = ["calc.desktop"];
      "application/vnd.openxmlformats-officedocument.spreadsheetml.template" = ["calc.desktop"];

      "application/vnd.ms-powerpoint" = ["impress.desktop"];
      "application/vnd.ms-powerpoint.presentation.macroEnabled.12" = ["impress.desktop"];
      "application/vnd.ms-powerpoint.template.macroEnabled.12" = ["impress.desktop"];
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" = ["impress.desktop"];
      "application/vnd.openxmlformats-officedocument.presentationml.template" = ["impress.desktop"];

      "application/pdf" = ["google-chrome.desktop"];
    };
  };
  programs.obs-studio.enable = true; # enables OBS plugins packaged by NixOS

  xdg.portal.enable = true;
  xdg.portal.extraPortals = with pkgs; [
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk
  ];
  xdg.portal.config = {
    common = {
      default = ["gtk"];
    };
    hyprland = {
      default = ["hyprland" "gtk"];
      "org.freedesktop.impl.portal.ScreenCast" = ["hyprland"];
      "org.freedesktop.impl.portal.Screenshot" = ["hyprland"];
      "org.freedesktop.impl.portal.GlobalShortcuts" = ["hyprland"];
      "org.freedesktop.impl.portal.Notification" = ["gtk"];
    };
  };

  # Helpful on some NVIDIA setups using Wayland compositors
  environment.variables = {
    #OPENAI_API_KEY = "";
    #WLR_NO_HARDWARE_CURSORS = lib.mkDefault "1";
  };

  # CoolerControl for GPU and system fan management
  # programs.coolercontrol.enable = true;
  # programs.coolercontrol.nvidiaSupport = true;

  powerManagement.cpuFreqGovernor = "performance";
}
