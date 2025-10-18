.PHONY: nixos home hypr all

# Rebuild and switch NixOS from this flake
nixos:
	sudo nixos-rebuild switch --flake .#nixos

# Rebuild and switch Home Manager from this flake
home:
	home-manager switch --flake .#liam

# Reload Hyprland config
hypr:
	hyprctl reload

# Cleanup boot entries
cleanup:
	nix-collect-garbage
	nix-collect-garbage -d

# Do everything: NixOS, Home Manager, then Hyprland reload
all: nixos home hypr

