{
  config,
  pkgs,
  lib,
  ...
}: let
  # Build strudel.nvim as a Vim plugin with npm dependencies
  strudel-nvim = pkgs.buildNpmPackage {
    pname = "strudel-nvim";
    version = "unstable-2024-12-12";

    src = pkgs.fetchFromGitHub {
      owner = "gruvw";
      repo = "strudel.nvim";
      rev = "a6b9752b0084a20c37786b54eef2095bb31daff7";
      hash = "sha256-LhS41aKsYJpKqoF2S3ZzeDLYGBKA4iMN2o34k8YOWHs=";
    };

    npmDepsHash = "sha256-K016bVIMjO3972O67N3os/o3wryMyo5D244RhBNCvkY=";

    PUPPETEER_SKIP_DOWNLOAD = "1";
    PUPPETEER_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";

    dontNpmBuild = true;

    # Restructure output to be vim-plugin compatible
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r lua $out/
      cp -r js $out/
      cp -r node_modules $out/
      cp package.json $out/ 2>/dev/null || true

      runHook postInstall
    '';
  };
in {
  programs.nvf.settings.vim = {
    # Add strudel.nvim plugin
    startPlugins = [strudel-nvim];

    # Set Chromium path for Puppeteer
    luaConfigRC.strudel-env = ''
      vim.env.PUPPETEER_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium"
    '';
  };

}
