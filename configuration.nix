# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  inputs,
  config,
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
    ./stylix.nix
    ./programs/firefox.nix
  ];

  # env vars configured later alongside Wayland tweaks
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        # Shows battery charge of connected devices on supported
        # Bluetooth adapters. Defaults to 'false'.
        Experimental = true;
        # When enabled other devices can connect faster to us, however
        # the tradeoff is increased power consumption. Defaults to
        # 'false'.
        FastConnectable = true;
        ControllerMode = "dual";
      };
      Policy = {
        # Enable all controllers when they are found. This includes
        # adapters present on start as well as adapters that are plugged
        # in later on. Defaults to 'true'.
        AutoEnable = true;
      };
    };
  };
  services.blueman.enable = true;
  # boot.kernelModules = ["iwlwifi" "btusb" "rtw88_8822be"]; # Conflicting/unnecessary modules removed
  # Switch to default LTS kernel for better stability
  boot.kernelPackages = pkgs.linuxPackages;

  # Fix for MediaTek MT7925e WiFi card hanging/disappearing
  # Disables Active State Power Management (ASPM) to prevent hardware lockups
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=1 power_save=0
  '';
  
  # Enable firmware updates for WiFi and other hardware
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];

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
        command = "Hyprland > /dev/null 2>&1";
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
      extraConfig = {
        "51-bluez-config" = {
          "monitor.bluez.properties" = {
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
            "bluez5.dummy-avrcp-player" = true;
            "bluez5.roles" = [
              "a2dp_sink"
              "a2dp_source"
              "hfp_hf"
              "hfp_ag"
              "hsp_hs"
              "hsp_ag"
            ];
          };
          "monitor.bluez.rules" = [
            {
              matches = [
                {
                  "device.name" = "~bluez_card.*";
                }
              ];
              actions = {
                "update-props" = {
                  "bluez5.auto-connect" = [
                    "a2dp_sink"
                    "hfp_hf"
                    "hfp_ag"
                    "hsp_hs"
                    "hsp_ag"
                  ];
                };
              };
            }
          ];
        };
        "11-bluetooth-policy" = {
          "wireplumber.settings" = {
            "bluetooth.autoswitch-to-headset-profile" = false;
            "device.restore-profile" = false;
          };
        };
        "12-bluetooth-profile-priority" = {
          "device.profile.priority.rules" = [
            {
              matches = [
                {
                  "device.name" = "~bluez_card.*";
                }
              ];
              actions = {
                "update-props" = {
                  priorities = [
                    "a2dp-sink"
                    "a2dp-sink-sbc_xq"
                    "a2dp-sink-sbc"
                    "headset-head-unit"
                    "headset-head-unit-cvsd"
                  ];
                };
              };
            }
          ];
        };
        "13-bluetooth-settings" = {
          "wireplumber.settings" = {
            "device.restore-routes" = true;
          };
        };
      };
    };
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with 'passwd'.
  hardware.bluetooth.settings.Policy.ReconnectAttempts = 7;
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
    vesktop
    pkgs-unstable.discord
    lazydocker
    lazygit
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

    pywal
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

  environment.pathsToLink = ["/libexec"]; # links /libexec from derivations to /run/current-system/sw

  services.xserver = {
    enable = true;
    desktopManager = {xterm.enable = true;};
  };

  # Switch to Hyprland (Wayland)
  programs.hyprland.enable = true;

  # PAM entry so hyprlock can authenticate
  security.pam.services.hyprlock = {};

  # XDG portal setup for Wayland (incl. Hyprland)
  xdg.mime = {
    enable = true;
    defaultApplications = {
      # Web browser defaults
      "text/html" = ["firefox.desktop"];
      "application/xhtml+xml" = ["firefox.desktop"];
      "x-scheme-handler/http" = ["firefox.desktop"];
      "x-scheme-handler/https" = ["firefox.desktop"];
      "x-scheme-handler/about" = ["firefox.desktop"];
      "x-scheme-handler/unknown" = ["firefox.desktop"];

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

      "application/pdf" = ["firefox.desktop"];
    };
  };
  programs.obs-studio.enable = true; # enables OBS plugins packaged by NixOS

  xdg.portal.enable = true;
  xdg.portal.extraPortals = with pkgs; [
    xdg-desktop-portal-hyprland
    kdePackages.xdg-desktop-portal-kde
    xdg-desktop-portal-gtk
  ];
  xdg.portal.config = {
    common = {
      default = ["hyprland" "kde" "gtk"];
      "org.freedesktop.portal.ScreenCast" = ["hyprland"];
      "org.freedesktop.portal.Notification" = ["gtk"];
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
