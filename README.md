



## Copy paste commands

### Use config on a fresh system
```git clone https://github.com/LiamMaclean216/nix-config.git /tmp/nix-config && \
git clone https://github.com/LiamMaclean216/nix-config ~/nix-config && \
cp /etc/nixos/hardware-configuration.nix ~/nix-config/ && \
sudo nixos-rebuild switch --flake ~/nix-config#nixos && \
home-manager switch --flake ~/nix-config#liam && \
sudo reboot

```

### Install requirements to the venv. Pyright is configured to use this venv

`source ~/.venv/bin/activate && pip install -r requirements.txt`
