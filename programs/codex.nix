{ pkgs, inputs, ... }:

let
  codex = inputs.codex-nix.packages.${pkgs.system}.default;

  # `codex remote-control start` intentionally launches app-server from the
  # fixed standalone-installer path rather than resolving `codex` from PATH.
  # Mirror that layout while keeping the binary managed by Nix.
  codexStandalone = pkgs.runCommand "codex-standalone" { } ''
    mkdir -p "$out"
    ln -s "${codex}/bin/codex" "$out/codex"
  '';

  codexWrapper = pkgs.writeShellScriptBin "codexvenv" ''
    source ~/.venv/bin/activate
    exec "${codex}/bin/codex" "$@"
  '';

  agentModePython = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  agentModeConnect = pkgs.writeShellScriptBin "agent-mode-connect" ''
    export PATH="${pkgs.systemd}/bin:$PATH"
    exec ${agentModePython}/bin/python ${./nvim/agent-mode-connect.py} "$@"
  '';
  agentModeChat = pkgs.writeShellScriptBin "agent-mode-chat" ''
    set -e
    ${pkgs.systemd}/bin/systemctl --user start codex-app-server.service
    exec "$@"
  '';

  # Codex passes a JSON payload as the final argument whenever a turn ends.
  # Agent Mode uses the token only to identify a CLI-created conversation.
  # Runtime status comes from the shared app-server connection.
  agentModeNotify = pkgs.writeShellScriptBin "agent-mode-notify" ''
    set -eu
    if [ "$#" -eq 3 ]; then
      exec 9>>"$1.lock"
      ${pkgs.util-linux}/bin/flock 9
      printf '%s\t%s\n' "$2" "$3" >> "$1"
    fi
  '';
in {
  home.packages = [ codexWrapper agentModeNotify agentModeConnect agentModeChat ];

  # Run in the foreground under systemd. Codex's detached daemon keeps a PID
  # record across reboots, which can refer to an unrelated process after boot.
  systemd.user.services.codex-app-server = {
    Unit.Description = "Codex app server";
    Service = {
      Type = "exec";
      WorkingDirectory = "%h";
      Environment = [ "PATH=%h/.nix-profile/bin:/run/current-system/sw/bin" ];
      ExecStart = "${codexWrapper}/bin/codexvenv app-server --listen unix:// --remote-control";
      # systemctl start returns only after the WebSocket accepts connections.
      ExecStartPost = "${agentModeConnect}/bin/agent-mode-connect --wait";
      Restart = "on-failure";
      RestartSec = 2;
      TimeoutStartSec = 45;
      TimeoutStopSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };

  home.file.".codex/packages/standalone/current" = {
    source = codexStandalone;
    # Codex's standalone updater can replace this link at runtime. Restore the
    # Nix-managed target on the next Home Manager activation without requiring
    # a manual backup or deletion.
    force = true;
  };
}
