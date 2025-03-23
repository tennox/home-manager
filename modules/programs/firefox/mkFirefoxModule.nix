{ modulePath, name, description ? null, wrappedPackageName ? null
, unwrappedPackageName ? null, platforms, visible ? false
, enableBookmarks ? true, }:
{ config, lib, pkgs, ... }:
with lib;
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  appName = name;

  moduleName = concatStringsSep "." modulePath;

  cfg = getAttrFromPath modulePath config;

  jsonFormat = pkgs.formats.json { };

  supportedPlatforms = flatten (attrVals (attrNames platforms) lib.platforms);

  isWrapped = versionAtLeast config.home.stateVersion "19.09"
    && wrappedPackageName != null;

  defaultPackageName =
    if isWrapped then wrappedPackageName else unwrappedPackageName;

  packageName = if wrappedPackageName != null then
    wrappedPackageName
  else
    unwrappedPackageName;

  profilesPath =
    if isDarwin then "${cfg.configPath}/Profiles" else cfg.configPath;

  # The extensions path shared by all profiles; will not be supported
  # by future browser versions.
  extensionPath = "extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";

  profiles = flip mapAttrs' cfg.profiles (_: profile:
    nameValuePair "Profile${toString profile.id}" {
      Name = profile.name;
      Path = if isDarwin then "Profiles/${profile.path}" else profile.path;
      IsRelative = 1;
      Default = if profile.isDefault then 1 else 0;
    }) // {
      General = {
        StartWithLastProfile = 1;
      } // lib.optionalAttrs (cfg.profileVersion != null) {
        Version = cfg.profileVersion;
      };
    };

  profilesIni = generators.toINI { } profiles;

  userPrefValue = pref:
    builtins.toJSON (if isBool pref || isInt pref || isString pref then
      pref
    else
      builtins.toJSON pref);

  mkUserJs = prePrefs: prefs: extraPrefs: bookmarksFile: extensions:
    let
      prefs' = lib.optionalAttrs (bookmarksFile != null) {
        "browser.bookmarks.file" = toString bookmarksFile;
        "browser.places.importBookmarksHTML" = true;
      } // lib.optionalAttrs (extensions != { }) {
        "extensions.webextensions.ExtensionStorageIDB.enabled" = false;
      } // prefs;
    in ''
      // Generated by Home Manager.

      ${prePrefs}

      ${concatStrings (mapAttrsToList (name: value: ''
        user_pref("${name}", ${userPrefValue value});
      '') prefs')}

      ${extraPrefs}
    '';

  mkContainersJson = containers:
    let
      containerToIdentity = _: container: {
        userContextId = container.id;
        name = container.name;
        icon = container.icon;
        color = container.color;
        public = true;
      };
    in ''
      ${builtins.toJSON {
        version = 5;
        lastUserContextId =
          foldlAttrs (acc: _: value: if value.id > acc then value.id else acc) 0
          containers;
        identities = mapAttrsToList containerToIdentity containers ++ [
          {
            userContextId = 4294967294; # 2^32 - 2
            name = "userContextIdInternal.thumbnail";
            icon = "";
            color = "";
            accessKey = "";
            public = false;
          }
          {
            userContextId = 4294967295; # 2^32 - 1
            name = "userContextIdInternal.webextStorageLocal";
            icon = "";
            color = "";
            accessKey = "";
            public = false;
          }
        ];
      }}
    '';

  mkNoDuplicateAssertion = entities: entityKind:
    (let
      # Return an attribute set with entity IDs as keys and a list of
      # entity names with corresponding ID as value. An ID is present in
      # the result only if more than one entity has it. The argument
      # entities is a list of AttrSet of one id/name pair.
      findDuplicateIds = entities:
        filterAttrs (_entityId: entityNames: length entityNames != 1)
        (zipAttrs entities);

      duplicates = findDuplicateIds (mapAttrsToList
        (entityName: entity: { "${toString entity.id}" = entityName; })
        entities);

      mkMsg = entityId: entityNames:
        "  - ID ${entityId} is used by " + concatStringsSep ", " entityNames;
    in {
      assertion = duplicates == { };
      message = ''
        Must not have a ${appName} ${entityKind} with an existing ID but
      '' + concatStringsSep "\n" (mapAttrsToList mkMsg duplicates);
    });

  wrapPackage = package:
    let
      # The configuration expected by the Firefox wrapper.
      fcfg = { enableGnomeExtensions = cfg.enableGnomeExtensions; };

      # A bit of hackery to force a config into the wrapper.
      browserName =
        package.browserName or (builtins.parseDrvName package.name).name;

      # The configuration expected by the Firefox wrapper builder.
      bcfg = setAttrByPath [ browserName ] fcfg;
    in if package == null then
      null
    else if isDarwin then
      package
    else if isWrapped then
      package.override (old: {
        cfg = old.cfg or { } // fcfg;
        extraPolicies = (old.extraPolicies or { }) // cfg.policies;
        pkcs11Modules = (old.pkcs11Modules or [ ]) ++ cfg.pkcs11Modules;
      })
    else
      (pkgs.wrapFirefox.override { config = bcfg; }) package { };
in {
  options = setAttrByPath modulePath {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether to enable ${appName}.${
          optionalString (description != null) " ${description}"
        }
        ${optionalString (!visible)
        "See `${moduleName}` for more configuration options."}
      '';
    };

    package = mkOption {
      inherit visible;
      type = with types; nullOr package;
      default = pkgs.${defaultPackageName};
      defaultText = literalExpression "pkgs.${packageName}";
      example = literalExpression ''
        pkgs.${packageName}.override {
          # See nixpkgs' firefox/wrapper.nix to check which options you can use
          nativeMessagingHosts = [
            # Gnome shell native connector
            pkgs.gnome-browser-connector
            # Tridactyl native connector
            pkgs.tridactyl-native
          ];
        }
      '';
      description = ''
        The ${appName} package to use. If state version ≥ 19.09 then
        this should be a wrapped ${appName} package. For earlier state
        versions it should be an unwrapped ${appName} package.
        Set to `null` to disable installing ${appName}.
      '';
    };

    languagePacks = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        The language packs to install. Available language codes can be found
        on the releases page:
        `https://releases.mozilla.org/pub/firefox/releases/''${version}/linux-x86_64/xpi/`,
        replacing `''${version}` with the version of ${appName} you have.
      '';
      example = [ "en-GB" "de" ];
    };

    name = mkOption {
      internal = true;
      type = types.str;
      default = name;
      example = "Firefox";
      description = "The name of the browser.";
    };

    wrappedPackageName = mkOption {
      internal = true;
      type = with types; nullOr str;
      default = wrappedPackageName;
      description = "Name of the wrapped browser package.";
    };

    vendorPath = mkOption {
      internal = true;
      type = with types; nullOr str;
      default = null;
      example = ".mozilla";
      description =
        "Directory containing the native messaging hosts directory.";
    };

    configPath = mkOption {
      internal = true;
      type = types.str;
      default = with platforms;
        if isDarwin then darwin.configPath else linux.configPath;
      example = ".mozilla/firefox";
      description = "Directory containing the ${appName} configuration files.";
    };

    nativeMessagingHosts = mkOption {
      inherit visible;
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Additional packages containing native messaging hosts that should be
        made available to ${appName} extensions.
      '';
    };

    finalPackage = mkOption {
      inherit visible;
      type = with types; nullOr package;
      readOnly = true;
      description = "Resulting ${appName} package.";
    };

    policies = optionalAttrs (wrappedPackageName != null) (mkOption {
      inherit visible;
      type = types.attrsOf jsonFormat.type;
      default = { };
      description =
        "[See list of policies](https://mozilla.github.io/policy-templates/).";
      example = {
        DefaultDownloadDirectory = "\${home}/Downloads";
        BlockAboutConfig = true;
      };
    });

    profileVersion = mkOption {
      internal = true;
      type = types.nullOr types.ints.unsigned;
      default = if isDarwin then null else 2;
      description = "profile version, set null for nix-darwin";
    };

    profiles = mkOption {
      inherit visible;
      type = types.attrsOf (types.submodule ({ config, name, ... }: {
        imports = [ (pkgs.path + "/nixos/modules/misc/assertions.nix") ];

        options = {
          name = mkOption {
            type = types.str;
            default = name;
            description = "Profile name.";
          };

          id = mkOption {
            type = types.ints.unsigned;
            default = 0;
            description = ''
              Profile ID. This should be set to a unique number per profile.
            '';
          };

          preConfig = mkOption {
            type = types.lines;
            default = "";
            description = ''
              Extra preferences to add to {file}`user.js`, before
              [](#opt-programs.firefox.profiles._name_.settings).

              Use [](#opt-programs.firefox.profiles._name_.extraConfig), unless
              you want to overwrite in
              [](#opt-programs.firefox.profiles._name_.settings), then use this
              option.
            '';
          };

          settings = mkOption {
            type = types.attrsOf (jsonFormat.type // {
              description =
                "${appName} preference (int, bool, string, and also attrs, list, float as a JSON string)";
            });
            default = { };
            example = literalExpression ''
              {
                "browser.startup.homepage" = "https://nixos.org";
                "browser.search.region" = "GB";
                "browser.search.isUS" = false;
                "distribution.searchplugins.defaultLocale" = "en-GB";
                "general.useragent.locale" = "en-GB";
                "browser.bookmarks.showMobileBookmarks" = true;
                "browser.newtabpage.pinned" = [{
                  title = "NixOS";
                  url = "https://nixos.org";
                }];
              }
            '';
            description = ''
              Attribute set of ${appName} preferences.

              ${appName} only supports int, bool, and string types for
              preferences, but home-manager will automatically
              convert all other JSON-compatible values into strings.
            '';
          };

          extraConfig = mkOption {
            type = types.lines;
            default = "";
            description = ''
              Extra preferences to add to {file}`user.js`.
            '';
          };

          userChrome = mkOption {
            type = types.oneOf [ types.lines types.path ];
            default = "";
            description = "Custom ${appName} user chrome CSS.";
            example = ''
              /* Hide tab bar in FF Quantum */
              @-moz-document url(chrome://browser/content/browser.xul), url(chrome://browser/content/browser.xhtml) {
                #TabsToolbar {
                  visibility: collapse !important;
                  margin-bottom: 21px !important;
                }

                #sidebar-box[sidebarcommand="treestyletab_piro_sakura_ne_jp-sidebar-action"] #sidebar-header {
                  visibility: collapse !important;
                }
              }
            '';
          };

          userContent = mkOption {
            type = types.oneOf [ types.lines types.path ];
            default = "";
            description = "Custom ${appName} user content CSS.";
            example = ''
              /* Hide scrollbar in FF Quantum */
              *{scrollbar-width:none !important}
            '';
          };

          bookmarks = mkOption {
            type = (with types;
              coercedTo (listOf anything) (bookmarks:
                warn ''
                  ${cfg.name} bookmarks have been refactored into a submodule that now explicitly require a 'force' option to be enabled.

                  Replace:

                  ${moduleName}.profiles.${name}.bookmarks = [ ... ];

                  With:

                  ${moduleName}.profiles.${name}.bookmarks = {
                    force = true;
                    settings = [ ... ];
                  };
                '' {
                  force = true;
                  settings = bookmarks;
                }) (submodule ({ config, ... }:
                  import ./profiles/bookmarks.nix {
                    inherit config lib pkgs;
                    modulePath = modulePath ++ [ "profiles" name "bookmarks" ];
                  })));
            default = { };
            internal = !enableBookmarks;
            description = "Declarative bookmarks.";
          };

          path = mkOption {
            type = types.str;
            default = name;
            description = "Profile path.";
          };

          isDefault = mkOption {
            type = types.bool;
            default = config.id == 0;
            defaultText = "true if profile ID is 0";
            description = "Whether this is a default profile.";
          };

          search = mkOption {
            type = types.submodule (args:
              import ./profiles/search.nix {
                inherit (args) config;
                inherit lib pkgs appName;
                package = cfg.finalPackage;
                modulePath = modulePath ++ [ "profiles" name "search" ];
                profilePath = config.path;
              });
            default = { };
            description = "Declarative search engine configuration.";
          };

          containersForce = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether to force replace the existing containers configuration.
              This is recommended since ${appName} will replace the symlink on
              every launch, but note that you'll lose any existing configuration
              by enabling this.
            '';
          };

          containers = mkOption {
            type = types.attrsOf (types.submodule ({ name, ... }: {
              options = {
                name = mkOption {
                  type = types.str;
                  default = name;
                  description = "Container name, e.g., shopping.";
                };

                id = mkOption {
                  type = types.ints.unsigned;
                  default = 0;
                  description = ''
                    Container ID. This should be set to a unique number per container in this profile.
                  '';
                };

                # List of colors at
                # https://searchfox.org/mozilla-central/rev/5ad226c7379b0564c76dc3b54b44985356f94c5a/toolkit/components/extensions/parent/ext-contextualIdentities.js#32
                color = mkOption {
                  type = types.enum [
                    "blue"
                    "turquoise"
                    "green"
                    "yellow"
                    "orange"
                    "red"
                    "pink"
                    "purple"
                    "toolbar"
                  ];
                  default = "pink";
                  description = "Container color.";
                };

                icon = mkOption {
                  type = types.enum [
                    "briefcase"
                    "cart"
                    "circle"
                    "dollar"
                    "fence"
                    "fingerprint"
                    "gift"
                    "vacation"
                    "food"
                    "fruit"
                    "pet"
                    "tree"
                    "chill"
                  ];
                  default = "fruit";
                  description = "Container icon.";
                };
              };
            }));
            default = { };
            example = {
              "shopping" = {
                id = 1;
                color = "blue";
                icon = "cart";
              };
              "dangerous" = {
                id = 2;
                color = "red";
                icon = "fruit";
              };
            };
            description = ''
              Attribute set of container configurations. See
              [Multi-Account
              Containers](https://support.mozilla.org/en-US/kb/containers)
              for more information.
            '';
          };
          extensions = mkOption {
            type = types.coercedTo (types.listOf types.package) (packages: {
              packages = mkIf (builtins.length packages > 0) (warn ''
                In order to support declarative extension configuration,
                extension installation has been moved from
                ${moduleName}.profiles.<profile>.extensions
                to
                ${moduleName}.profiles.<profile>.extensions.packages
              '' packages);
            }) (types.submodule {
              options = {
                packages = mkOption {
                  type = types.listOf types.package;
                  default = [ ];
                  example = literalExpression ''
                    with pkgs.nur.repos.rycee.firefox-addons; [
                      privacy-badger
                    ]
                  '';
                  description = ''
                    List of ${name} add-on packages to install for this profile.
                    Some pre-packaged add-ons are accessible from the Nix User Repository.
                    Once you have NUR installed run

                    ```console
                    $ nix-env -f '<nixpkgs>' -qaP -A nur.repos.rycee.firefox-addons
                    ```

                    to list the available ${name} add-ons.

                    Note that it is necessary to manually enable these extensions
                    inside ${name} after the first installation.

                    To automatically enable extensions add
                    `"extensions.autoDisableScopes" = 0;`
                    to
                    [{option}`${moduleName}.profiles.<profile>.settings`](#opt-${moduleName}.profiles._name_.settings)
                  '';
                };

                force = mkOption {
                  description = ''
                    Whether to override all previous firefox settings.

                    This is required when using `settings`.
                  '';
                  default = false;
                  example = true;
                  type = types.bool;
                };

                settings = mkOption {
                  default = { };
                  example = literalExpression ''
                    {
                      # Example with uBlock origin's extensionID
                      "uBlock0@raymondhill.net".settings = {
                        selectedFilterLists = [
                          "ublock-filters"
                          "ublock-badware"
                          "ublock-privacy"
                          "ublock-unbreak"
                          "ublock-quick-fixes"
                        ];
                      };

                      # Example with Stylus' UUID-form extensionID
                      "{7a7a4a92-a2a0-41d1-9fd7-1e92480d612d}".settings = {
                        dbInChromeStorage = true; # required for Stylus
                      }
                    }
                  '';
                  description = ''
                    Attribute set of options for each extension.
                    The keys of the attribute set consist of the ID of the extension
                    or its UUID wrapped in curly braces.
                  '';
                  type = types.attrsOf (types.submodule {
                    options = {
                      settings = mkOption {
                        type = types.attrsOf jsonFormat.type;
                        description =
                          "Json formatted options for the specified extensionID";
                      };
                      force = mkOption {
                        type = types.bool;
                        default = false;
                        example = true;
                        description = ''
                          Forcibly override any existing configuration for
                          this extension.
                        '';
                      };
                    };
                  });
                };
              };
            });
            default = { };
            description = ''
              Submodule for installing and configuring extensions.
            '';
            example = literalExpression ''
              {
                packages = with pkgs.nur.repos.rycee.firefox-addons; [
                  ublock-origin
                ];
                settings."uBlock0@raymondhill.net".settings = {
                  selectedFilterLists = [
                    "ublock-filters"
                    "ublock-badware"
                    "ublock-privacy"
                    "ublock-unbreak"
                    "ublock-quick-fixes"
                  ];
                };
              }
            '';
          };
        };

        config = {
          assertions = [
            (mkNoDuplicateAssertion config.containers "container")
            {
              assertion = config.extensions.settings == { }
                || config.extensions.force;
              message = ''
                Using '${
                  lib.showAttrPath (modulePath
                    ++ [ "profiles" profileName "extensions" "settings" ])
                }' will override all previous extensions settings.
                Enable '${
                  lib.showAttrPath (modulePath
                    ++ [ "profiles" profileName "extensions" "force" ])
                }' to acknowledge this.
              '';
            }
          ] ++ config.bookmarks.assertions;
        };
      }));
      default = { };
      description = "Attribute set of ${appName} profiles.";
    };

    enableGnomeExtensions = mkOption {
      inherit visible;
      type = types.bool;
      default = false;
      description = ''
        Whether to enable the GNOME Shell native host connector. Note, you
        also need to set the NixOS option
        `services.gnome.gnome-browser-connector.enable` to
        `true`.
      '';
    };

    pkcs11Modules = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Additional packages to be loaded as PKCS #11 modules in Firefox.
      '';
    };
  };

  config = mkIf cfg.enable ({
    assertions = [
      (hm.assertions.assertPlatform moduleName pkgs supportedPlatforms)

      (let
        defaults =
          catAttrs "name" (filter (a: a.isDefault) (attrValues cfg.profiles));
      in {
        assertion = cfg.profiles == { } || length defaults == 1;
        message = "Must have exactly one default ${appName} profile but found "
          + toString (length defaults) + optionalString (length defaults > 1)
          (", namely " + concatStringsSep ", " defaults);
      })

      (let
        getContainers = profiles:
          flatten
          (mapAttrsToList (_: value: (attrValues value.containers)) profiles);

        findInvalidContainerIds = profiles:
          filter (container: container.id >= 4294967294)
          (getContainers profiles);
      in {
        assertion = cfg.profiles == { }
          || length (findInvalidContainerIds cfg.profiles) == 0;
        message = "Container id must be smaller than 4294967294 (2^32 - 2)";
      })

      {
        assertion = cfg.languagePacks == [ ] || cfg.package != null;
        message = ''
          '${moduleName}.languagePacks' requires '${moduleName}.package'
          to be set to a non-null value.
        '';
      }

      (mkNoDuplicateAssertion cfg.profiles "profile")
    ] ++ (concatMap (profile: profile.assertions) (attrValues cfg.profiles));

    warnings = optional (cfg.enableGnomeExtensions or false) ''
      Using '${moduleName}.enableGnomeExtensions' has been deprecated and
      will be removed in the future. Please change to overriding the package
      configuration using '${moduleName}.package' instead. You can refer to
      its example for how to do this.
    '' ++ optional (cfg.vendorPath != null) ''
      Using '${moduleName}.vendorPath' has been deprecated and
      will be removed in the future. Native messaging hosts will function normally without specifying this path.
    '';

    home.packages = lib.optional (cfg.finalPackage != null) cfg.finalPackage;

    mozilla.firefoxNativeMessagingHosts = cfg.nativeMessagingHosts
      # package configured native messaging hosts (entire browser actually)
      ++ (lib.optional (cfg.finalPackage != null) cfg.finalPackage);

    home.file = mkMerge ([{
      "${cfg.configPath}/profiles.ini" =
        mkIf (cfg.profiles != { }) { text = profilesIni; };
    }] ++ flip mapAttrsToList cfg.profiles (_: profile:
      # Merge the regular profile settings with extension settings
      mkMerge ([{
        "${profilesPath}/${profile.path}/.keep".text = "";

        "${profilesPath}/${profile.path}/chrome/userChrome.css" =
          mkIf (profile.userChrome != "") (let
            key =
              if builtins.isString profile.userChrome then "text" else "source";
          in { "${key}" = profile.userChrome; });

        "${profilesPath}/${profile.path}/chrome/userContent.css" =
          mkIf (profile.userContent != "") (let
            key = if builtins.isString profile.userContent then
              "text"
            else
              "source";
          in { "${key}" = profile.userContent; });

        "${profilesPath}/${profile.path}/user.js" = mkIf (profile.preConfig
          != "" || profile.settings != { } || profile.extraConfig != ""
          || profile.bookmarks.configFile != null) {
            text =
              mkUserJs profile.preConfig profile.settings profile.extraConfig
              profile.bookmarks.configFile profile.extensions.settings;
          };

        "${profilesPath}/${profile.path}/containers.json" =
          mkIf (profile.containers != { }) {
            text = mkContainersJson profile.containers;
            force = profile.containersForce;
          };

        "${profilesPath}/${profile.path}/search.json.mozlz4" =
          mkIf (profile.search.enable) {
            enable = profile.search.enable;
            force = profile.search.force;
            source = profile.search.file;
          };

        "${profilesPath}/${profile.path}/extensions" =
          mkIf (profile.extensions.packages != [ ]) {
            source = let
              extensionsEnvPkg = pkgs.buildEnv {
                name = "hm-firefox-extensions";
                paths = profile.extensions.packages;
              };
            in "${extensionsEnvPkg}/share/mozilla/${extensionPath}";
            recursive = true;
            force = true;
          };
      }] ++
        # Add extension settings as separate attributes
        optional (profile.extensions.settings != { }) (mkMerge (mapAttrsToList
          (name: settingConfig: {
            "${profilesPath}/${profile.path}/browser-extension-data/${name}/storage.js" =
              {
                force = settingConfig.force || profile.extensions.force;
                text = generators.toJSON { } settingConfig.settings;
              };
          }) profile.extensions.settings)))));
  } // setAttrByPath modulePath {
    finalPackage = wrapPackage cfg.package;

    policies = {
      ExtensionSettings = lib.mkIf (cfg.languagePacks != [ ]) (listToAttrs (map
        (lang:
          nameValuePair "langpack-${lang}@firefox.mozilla.org" {
            installation_mode = "normal_installed";
            install_url =
              "https://releases.mozilla.org/pub/firefox/releases/${cfg.package.version}/linux-x86_64/xpi/${lang}.xpi";
          }) cfg.languagePacks));
    };
  });
}
