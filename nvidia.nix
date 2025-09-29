{ config, pkgs, lib, ... }:


{
  # allow open drivers
  services.xserver.enable = true;
  services.xserver.videoDrivers = [ "nouveau" ];
  
  # This enables OpenGL support
  hardware.graphics.enable = true;
}

