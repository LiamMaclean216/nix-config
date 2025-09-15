{ config, pkgs, lib, ... }:


{
  # Enable OpenGL
  hardware.graphics.enable = true;

  # Load NVIDIA driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Modesetting is required
    modesetting.enable = true;

    # Nvidia power management. Experimental
    powerManagement.enable = false;

    # Fine-grained power management
    powerManagement.finegrained = false;

    # Use the Nvidia open source kernel module (Turing or newer only)
    open = false;

    # Enable the Nvidia settings menu
    nvidiaSettings = true;

    # By default, use the stable driver from nixpkgs
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}

