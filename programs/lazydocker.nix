{ lib, ... }:

{
  xdg.configFile."lazydocker/config.yml".text =
    lib.generators.toYAML {} {
      gui.returnImmediately = true;
      customCommands.containers = [
        {
          name = "Compose up (build)";
          attach = false;
          command = "{{ .DockerCompose }} up --build -d";
          serviceNames = [];
        }
      ];
    };
}
