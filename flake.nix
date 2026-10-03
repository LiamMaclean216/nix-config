{
  description="flake";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    # Update GitHub CLI independently of the system and desktop packages.
    nixpkgs-gh.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/release-25.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    codex-nix.url = "github:sadjow/codex-nix";
    nix-claude-code.url = "github:ryoppippi/nix-claude-code";
    nix-claude-code.inputs.nixpkgs.follows = "nixpkgs-unstable";

    nvf.url = "github:notashelf/nvf";
    nvf.inputs.nixpkgs.follows = "nixpkgs";

    # Keep the compositor and its private-API glass plugin on matching releases.
    hyprland.url = "github:hyprwm/Hyprland/v0.56.2";
    hyprglass = {
      url = "github:hyprnux/hyprglass/v0.8.0";
      flake = false;
    };
    # 0.56.2 requires Glaze 7, but its upstream Nix input now supplies Glaze 8.
    hyprland-glaze = {
      url = "github:stephenberry/glaze/v7.2.0";
      flake = false;
    };

  };

  outputs = inputs@{self, nixpkgs, home-manager, nvf, ...}:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      desktopOverlay = final: prev: {
        gh = inputs.nixpkgs-gh.legacyPackages.${system}.gh;
        # Firefox 146 crashes against newer Wayland color-management globals.
        firefox = inputs.hyprland.inputs.nixpkgs.legacyPackages.${system}.firefox;
        # The lock-screen controls use the current Hyprlock widget options.
        hyprlock = inputs.hyprland.inputs.nixpkgs.legacyPackages.${system}.hyprlock;
        hyprland = inputs.hyprland.packages.${system}.hyprland.override {
          glaze-hyprland = (inputs.hyprland.inputs.nixpkgs.legacyPackages.${system}.glaze.override {
            enableSSL = false;
            enableInterop = false;
          }).overrideAttrs {
            version = "7.2.0";
            src = inputs.hyprland-glaze;
          };
        };
        xdg-desktop-portal-hyprland = inputs.hyprland.packages.${system}.xdg-desktop-portal-hyprland.override {
          inherit (final) hyprland;
        };
        hyprglass = prev.callPackage ./desktop/hyprglass {
          inherit (final) hyprland;
          src = inputs.hyprglass;
        };
      };
      pkgs = import nixpkgs { inherit system; overlays = [ desktopOverlay ]; };
    in {
      packages.${system} = {
        inherit (pkgs) gh hyprland hyprglass;
        home-manager = home-manager.packages.${system}.home-manager;
        codex = inputs.codex-nix.packages.${system}.default;
      };
      nixosConfigurations = {
        nixos = lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ desktopOverlay ]; }
            ./configuration.nix
          ];
          specialArgs = { inherit inputs; };
        };
      };
      homeConfigurations = {
        liam = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            nvf.homeManagerModules.default
            ./home.nix
          ];
          extraSpecialArgs = { inherit inputs; };
        };
      };

    };

}
