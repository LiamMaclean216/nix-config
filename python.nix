# python.nix
{ pkgs }:

pkgs.python311.withPackages (ps: with ps; [
  numpy
  pandas
  requests
  jupyter
  ipykernel
])
