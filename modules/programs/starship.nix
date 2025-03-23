{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.programs.starship;

  tomlFormat = pkgs.formats.toml { };

  starshipCmd = "${config.home.profileDirectory}/bin/starship";

  initFish =
    if cfg.enableInteractive then "interactiveShellInit" else "shellInitLast";
in {
  meta.maintainers = [ ];

  options.programs.starship = {
    enable = mkEnableOption "starship";

    package = mkOption {
      type = types.package;
      default = pkgs.starship;
      defaultText = literalExpression "pkgs.starship";
      description = "The package to use for the starship binary.";
    };

    settings = mkOption {
      type = tomlFormat.type;
      default = { };
      example = literalExpression ''
        {
          add_newline = false;
          format = lib.concatStrings [
            "$line_break"
            "$package"
            "$line_break"
            "$character"
          ];
          scan_timeout = 10;
          character = {
            success_symbol = "➜";
            error_symbol = "➜";
          };
        }
      '';
      description = ''
        Configuration written to
        {file}`$XDG_CONFIG_HOME/starship.toml`.

        See <https://starship.rs/config/> for the full list
        of options.
      '';
    };

    enableBashIntegration =
      lib.hm.shell.mkBashIntegrationOption { inherit config; };

    enableFishIntegration =
      lib.hm.shell.mkFishIntegrationOption { inherit config; };

    enableIonIntegration =
      lib.hm.shell.mkIonIntegrationOption { inherit config; };

    enableNushellIntegration =
      lib.hm.shell.mkNushellIntegrationOption { inherit config; };

    enableZshIntegration =
      lib.hm.shell.mkZshIntegrationOption { inherit config; };

    enableInteractive = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Only enable starship when the shell is interactive. This option is only
        valid for the Fish shell.

        Some plugins require this to be set to `false` to function correctly.
      '';
    };

    enableTransience = mkOption {
      type = types.bool;
      default = false;
      description = ''
        The TransientPrompt feature of Starship replaces previous prompts with a
        custom string. This is only a valid option for the Fish shell.

        For documentation on how to change the default replacement string and
        for more information visit
        https://starship.rs/advanced-config/#transientprompt-and-transientrightprompt-in-cmd
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."starship.toml" = mkIf (cfg.settings != { }) {
      source = tomlFormat.generate "starship-config" cfg.settings;
    };

    programs.bash.initExtra = mkIf cfg.enableBashIntegration ''
      if [[ $TERM != "dumb" ]]; then
        eval "$(${starshipCmd} init bash --print-full-init)"
      fi
    '';

    programs.zsh.initContent = mkIf cfg.enableZshIntegration ''
      if [[ $TERM != "dumb" ]]; then
        eval "$(${starshipCmd} init zsh)"
      fi
    '';

    programs.fish.${initFish} = mkIf cfg.enableFishIntegration ''
      if test "$TERM" != "dumb"
        ${starshipCmd} init fish | source
        ${lib.optionalString cfg.enableTransience "enable_transience"}
      end
    '';

    programs.ion.initExtra = mkIf cfg.enableIonIntegration ''
      if test $TERM != "dumb"
        eval $(${starshipCmd} init ion)
      end
    '';

    programs.nushell = mkIf cfg.enableNushellIntegration {
      # Unfortunately nushell doesn't allow conditionally sourcing nor
      # conditionally setting (global) environment variables, which is why the
      # check for terminal compatibility (as seen above for the other shells) is
      # not done here.
      extraEnv = ''
        let starship_cache = "${config.xdg.cacheHome}/starship"
        if not ($starship_cache | path exists) {
          mkdir $starship_cache
        }
        ${starshipCmd} init nu | save --force ${config.xdg.cacheHome}/starship/init.nu
      '';
      extraConfig = ''
        use ${config.xdg.cacheHome}/starship/init.nu
      '';
    };
  };
}
