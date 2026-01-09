{ config, pkgs, ... }:

{
  # 1. Enable Unfree Packages (Required for Nvidia drivers)
  nixpkgs.config.allowUnfree = true;

  # 2. Enable OpenGL and Drivers
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Modesetting is required for most modern setups
    modesetting.enable = true;

    # Use the stable driver (or production)
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # Enable the Nvidia Settings menu
    nvidiaSettings = true;

    # IMPORTANT: Disable open kernel modules for full fan control support on consumer cards
    open = false;
  };

  # 3. Enable "Coolbits" to unlock Fan Control
  # This adds Option "Coolbits" "4" to the Xorg config
  services.xserver.deviceSection = ''
    Option "Coolbits" "4"
  '';

  # 4. Systemd Service to Enforce Power Limit at Boot
  # This runs as root before you even log in.
  systemd.services.nvidia-safe-mode = {
    description = "Set Nvidia Power Limit for Longevity";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Set power limit to 300W (adjust as needed: 280W-300W is the sweet spot)
      ExecStart = "${pkgs.linuxPackages.nvidia_x11.bin}/bin/nvidia-smi -pl 300";
    };
  };

  # 5. Aggressive Fan Curve via CoolerControl (kicks in at 65°C)
  # This service automatically configures the fan curve without GUI interaction
  # systemd.services.nvidia-fan-curve = {
  #   description = "Aggressive Nvidia Fan Curve for ML Workloads";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "nvidia-safe-mode.service" "display-manager.service" ];
  #   environment = {
  #     DISPLAY = ":0";
  #     XAUTHORITY = "/run/user/1000/.Xauthority";
  #   };
  #   serviceConfig = {
  #     Type = "simple";
  #     Restart = "always";
  #     RestartSec = "10s";
  #     ExecStart = pkgs.writeShellScript "nvidia-fan-curve" ''
  #       # Wait for X server and CoolerControl to be ready
  #       sleep 10

  #       # Enable manual fan control
  #       ${pkgs.linuxPackages.nvidia_x11.settings}/bin/nvidia-settings -a "[gpu:0]/GPUFanControlState=1"

  #       while true; do
  #         # Get GPU temperature
  #         TEMP=$(${pkgs.linuxPackages.nvidia_x11.bin}/bin/nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits)

  #         # Aggressive fan curve starting at 65°C
  #         if [ "$TEMP" -ge 85 ]; then
  #           FAN_SPEED=100
  #         elif [ "$TEMP" -ge 80 ]; then
  #           FAN_SPEED=95
  #         elif [ "$TEMP" -ge 75 ]; then
  #           FAN_SPEED=90
  #         elif [ "$TEMP" -ge 70 ]; then
  #           FAN_SPEED=85
  #         elif [ "$TEMP" -ge 65 ]; then
  #           FAN_SPEED=75
  #         elif [ "$TEMP" -ge 60 ]; then
  #           FAN_SPEED=60
  #         else
  #           FAN_SPEED=50
  #         fi

  #         # Apply fan speed
  #         ${pkgs.linuxPackages.nvidia_x11.settings}/bin/nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=$FAN_SPEED" > /dev/null 2>&1

  #         # Check every 3 seconds
  #         sleep 3
  #       done
  #     '';
  #   };
  # };
}
