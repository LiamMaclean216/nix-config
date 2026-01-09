# python.nix
{ pkgs }:

pkgs.python311.withPackages (ps: with ps; [
  (pydevd.overridePythonAttrs (old: { doCheck = false; }))
  ipykernel
  # jupyterlab
  notebook
  numpy
  pandas
  matplotlib
  scipy
  requests
])
