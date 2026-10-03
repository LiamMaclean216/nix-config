.PHONY: nixos home hypr all update update-cli cleanup resetairpods trustairpods connectairpods

AIRPODS_MAC ?= 9C:F3:AC:2C:E7:C6

# Update flake inputs to get latest packages
update:
	nix flake update

# Refresh and activate the independently installed CLI packages.
# NixOS and Home Manager use these same pins on their next rebuild.
update-cli:
	nix flake update codex-nix nixpkgs-gh
	nix profile upgrade gh codex
	gh --version
	codex --version

# Rebuild and switch NixOS from this flake
nixos:
	sudo nixos-rebuild switch --flake .#nixos

# Rebuild and switch Home Manager. Hyprland watches its active Lua config.
# A config-format or compositor upgrade takes effect at the next login.
# Use the pinned CLI even before Home Manager is installed in the user profile.
home:
	nix run .#home-manager -- switch --flake .#liam

# Reload Hyprland config
hypr:
	hyprctl reload

# Cleanup boot entries
cleanup:
	nix-collect-garbage
	nix-collect-garbage -d
	nix-env --delete-generations --profile /nix/var/nix/profiles/system 1d

# Forget AirPods through BlueZ so its saved bond and live state agree.
# Re-pair in Blueman with the case flashing white after using this target.
# Use connectairpods for normal reconnects; resetting discards the pairing key.
resetairpods:
	timeout 20s bluetoothctl remove '$(AIRPODS_MAC)'
	@printf '%s\n' 'AirPods forgotten. Put the case in flashing-white pairing mode and pair in Blueman.'

# Mark AirPods as trusted so reconnects work reliably
trustairpods:
	timeout 10s bluetoothctl trust '$(AIRPODS_MAC)'
	timeout 10s bluetoothctl info '$(AIRPODS_MAC)'

# Reconnect using the saved pairing key without resetting Bluetooth.
connectairpods: trustairpods
	timeout 30s bluetoothctl connect '$(AIRPODS_MAC)'

# Rebuild both configurations without forcing a reload across a format upgrade.
all: nixos home
