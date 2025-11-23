.PHONY: nixos home hypr all update

# Update flake inputs to get latest packages
update:
	nix flake update

# Rebuild and switch NixOS from this flake
nixos:
	sudo nixos-rebuild switch --flake .#nixos

# Rebuild and switch Home Manager from this flake
home:
	home-manager switch --flake .#liam
	hyprctl reload

# Reload Hyprland config
hypr:
	hyprctl reload

# Cleanup boot entries
cleanup:
	nix-collect-garbage
	nix-collect-garbage -d
	nix-env --delete-generations --profile /nix/var/nix/profiles/system 1d

# Do everything: NixOS, Home Manager, then Hyprland reload
all: nixos home hypr

