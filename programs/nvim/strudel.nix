{ config, pkgs, lib, ... }:

let
  # Build strudel.nvim as a Vim plugin with npm dependencies
  strudel-nvim = pkgs.buildNpmPackage {
    pname = "strudel-nvim";
    version = "1";

    src = pkgs.fetchFromGitHub {
      owner = "gruvw";
      repo = "strudel.nvim";
      rev = "main";
      hash = "sha256-2n6SL/AUqHEAMNFsxE3UmfSyXUBsE4fnWfg2qsBfjNQ=";
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
in
{
  programs.nvf.settings.vim = {
    # Add strudel.nvim plugin
    startPlugins = [ strudel-nvim ];

    # Set Chromium path for Puppeteer
    luaConfigRC.strudel-env = ''
      vim.env.PUPPETEER_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium"
    '';
  };

  # Add chromium for puppeteer
  home.packages = with pkgs; [
    chromium
  ];
}
