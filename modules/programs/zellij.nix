{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.programs.zellij;
  yamlFormat = pkgs.formats.yaml { };
  zellijCmd = getExe cfg.package;

in
{
  meta.maintainers = with hm.maintainers; [ mainrs tennox ];

  options.programs.zellij = {
    enable = mkEnableOption "zellij";

    package = mkOption {
      type = types.package;
      default = pkgs.zellij;
      defaultText = literalExpression "pkgs.zellij";
      description = ''
        The zellij package to install.
      '';
    };

    settings = mkOption {
      type = yamlFormat.type;
      default = { };
      example = literalExpression ''
        {
          theme = "custom";
          themes.custom.fg = "#ffffff";
        }
      '';
      description = ''
        Configuration written to
        {file}`$XDG_CONFIG_HOME/zellij/config.kdl`.

        If `programs.zellij.package.version` is older than 0.32.0, then
        the configuration is written to {file}`$XDG_CONFIG_HOME/zellij/config.yaml`.

        See <https://zellij.dev/documentation> for the full
        list of options.
      '';
    };

    enableBashIntegration =
      lib.hm.shell.mkBashIntegrationOption { inherit config; };

    enableFishIntegration =
      lib.hm.shell.mkFishIntegrationOption { inherit config; extraDescription = "Enables both enableFishAutoStart and enableFishCompletions"; };

    enableZshIntegration =
      lib.hm.shell.mkZshIntegrationOption { inherit config; };

    enableFishCompletions = mkEnableOption "load zellij completions" // {
      default = true;
    };
    enableFishAutoStart =
      mkEnableOption "autostart zellij in interactive sessions" // {
        default = false;
      };
    autoStartAttachIfSessionExists = mkEnableOption
      "attach to the default session, if a zellij session already exists (otherwise starting a new session)"
    // {
      default = false;
    };
    autoStartExitShellOnZellijExit =
      mkEnableOption "exit the shell when zellij exits." // {
        default = false;
      };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Zellij switched from yaml to KDL in version 0.32.0:
    # https://github.com/zellij-org/zellij/releases/tag/v0.32.0
    xdg.configFile."zellij/config.yaml" = mkIf
      (cfg.settings != { } && (versionOlder cfg.package.version "0.32.0"))
      {
        source = yamlFormat.generate "zellij.yaml" cfg.settings;
      };

    xdg.configFile."zellij/config.kdl" = mkIf
      (cfg.settings != { } && (versionAtLeast cfg.package.version "0.32.0"))
      {
        text = lib.hm.generators.toKDL { } cfg.settings;
      };

    programs.bash.initExtra = mkIf cfg.enableBashIntegration (mkOrder 200 ''
      eval "$(${zellijCmd} setup --generate-auto-start bash)"
    '');

    programs.zsh.initContent = mkIf cfg.enableZshIntegration (mkOrder 200 ''
      eval "$(${zellijCmd} setup --generate-auto-start zsh)"
    '');

    home.sessionVariables = {
      ZELLIJ_AUTO_ATTACH =
        if cfg.autoStartAttachIfSessionExists then "true" else "false";
      ZELLIJ_AUTO_EXIT =
        if cfg.autoStartExitShellOnZellijExit then "true" else "false";
    };

    programs.fish.interactiveShellInit = mkIf
      (cfg.enableFishIntegration
        || cfg.enableFishAutoStart || cfg.enableFishCompletions)
      (mkOrder 200
        ((if cfg.enableFishIntegration || cfg.enableFishCompletions then ''
          eval (${zellijCmd} setup --generate-completion fish | string collect)
        '' else
          "") + (if cfg.enableFishIntegration || cfg.enableFishAutoStart then ''
          eval (${zellijCmd} setup --generate-auto-start fish | string collect)
        '' else
          "")));

  };
}
