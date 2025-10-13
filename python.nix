# python.nix
{ pkgs }:

pkgs.python311.withPackages (ps: with ps; [
  ipykernel
  jupyterlab
  notebook
  numpy
  pandas
  matplotlib
  scipy
  requests
])
