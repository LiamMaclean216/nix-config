{
  description="flake";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/release-25.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    codex-nix.url = "github:sadjow/codex-nix";

    nvf.url = "github:notashelf/nvf";
    nvf.inputs.nixpkgs.follows = "nixpkgs";

    hyprland.url = "github:hyprwm/Hyprland";

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    stylix.url = "github:nix-community/stylix/release-25.05";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{self, nixpkgs, home-manager, nvf, ...}:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      nixosConfigurations = {
        nixos = lib.nixosSystem {
          inherit system;
          modules = [
            inputs.stylix.nixosModules.stylix
            ./configuration.nix
          ];
          specialArgs = { inherit inputs; };
        };
      };
      homeConfigurations = {
        liam = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            inputs.stylix.homeModules.stylix
            nvf.homeManagerModules.default
            ./home.nix
          ];
          extraSpecialArgs = { inherit inputs; };
        };
      };

    };

}
