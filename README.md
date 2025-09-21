



## Copy paste commands

### Use config on a fresh system
```git clone https://github.com/LiamMaclean216/nix-config.git /tmp/nix-config && \
sudo nixos-rebuild switch --flake /tmp/nix-config#nixos && \
sudo home-manager switch --flake /tmp/nix-config#liam && \
sudo reboot
```

### Install requirements to the venv. Pyright is configured to use this venv

`source ~/.venv/bin/activate && pip install -r requirements.txt`



### Delete old boot entries

`sudo nix-collect-garbage -d`
