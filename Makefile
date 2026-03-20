.PHONY: nixos home hypr all update cleanup resetairpods

AIRPODS_MAC ?= 9C:F3:AC:2C:E7:C6
BT_ADAPTER ?= 5C:F3:70:94:5F:A2

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

# Forget AirPods and clear local BlueZ cache/profile state
resetairpods:
	bluetoothctl remove '$(AIRPODS_MAC)' || true
	sudo rm -rf "/var/lib/bluetooth/$(BT_ADAPTER)/$(AIRPODS_MAC)" "/var/lib/bluetooth/$(BT_ADAPTER)/cache/$(AIRPODS_MAC)"
	sudo systemctl restart bluetooth
	sleep 2
	bluetoothctl info '$(AIRPODS_MAC)' || true

# Do everything: NixOS, Home Manager, then Hyprland reload
all: nixos home hypr
