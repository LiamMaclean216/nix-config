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
        {
          name = "restart";
          attach = false;
          command = "sh -c '{{ .DockerCompose }} down && {{ .DockerCompose }} up -d'";
          serviceNames = [];
        }
        {
          name = "restart with volumes deleted";
          attach = false;
          command = "sh -c '{{ .DockerCompose }} down -v && {{ .DockerCompose }} up -d'";
          serviceNames = [];
        }
        {
          name = "full rebuild";
          attach = false;
          command = "sh -c '{{ .DockerCompose }} down -v && {{ .DockerCompose }} up -d --build'";
          serviceNames = [];
        }
      ];
    };
  };
}
