{ pkgs, ... }:

let
  yamlFormat = pkgs.formats.yaml {};
in
{
  xdg.configFile."lazydocker/config.yml".source = yamlFormat.generate "lazydocker-config" {
    gui = {
      returnImmediately = true;
    };
    customCommands = {
      services = [
        {
          name = "docker compose up (build)";
          attach = true;
          command = "{{ .DockerCompose }} up --build -d";
          serviceNames = [];
        }
      ];
    };
  };
}
