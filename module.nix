{
  config,
  lib,
  pkgs,
  ...
}: let
  # Shared paths and service environment
  cfg = config.services.amp;
  ampRoot = "${cfg.package}/opt/cubecoders/amp";
  ampinstmgr = lib.getExe' cfg.package "ampinstmgr";
  homeSubpath = lib.removePrefix "/" cfg.home;
  homeIsNormalized =
    lib.hasPrefix "/" cfg.home
    && lib.path.subpath.isValid homeSubpath
    && "/${lib.removePrefix "./" (lib.path.subpath.normalise homeSubpath)}" == cfg.home;
  iptables = lib.getExe' config.networking.firewall.package "iptables";
  podmanEnabled = config.virtualisation.podman.enable;
  servicePath = [cfg.package "/run/wrappers"];
  bridgeTag = "nix-amp-firewall-bridge";
  runtimeLibraries = with pkgs; [
    icu
    openssl
    stdenv.cc.cc.lib
    zlib
  ];
  serviceEnvironment = {
    HOME = cfg.home;
    NIX_LD = pkgs.stdenv.cc.bintools.dynamicLinker;
    NIX_LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibraries;
    TERM = "xterm-256color";
  };

  # AMP speaks Docker's API. When Podman is enabled, point system services at
  # the dedicated amp user's rootless socket rather than the rootful socket.
  ampinstmgrServiceExe =
    if podmanEnabled
    then
      pkgs.writeShellScript "ampinstmgr-podman" ''
        uid="$(${pkgs.coreutils}/bin/id -u)"
        export XDG_RUNTIME_DIR="/run/user/$uid"
        export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
        exec ${ampinstmgr} "$@"
      ''
    else ampinstmgr;
  ampServicePath = servicePath ++ lib.optional podmanEnabled pkgs.podman;
  podmanUnitOrdering = lib.optionalAttrs podmanEnabled {
    after = ["linger-users.service"];
    wants = ["linger-users.service"];
  };

  # Custom homes retain /home/amp as a compatibility path for upstream
  # root-level commands. Refuse to run if that path does not match cfg.home.
  ampHomeCondition = pkgs.writeShellScript "amp-home-compatible" ''
    ${
      if cfg.home == "/home/amp"
      then ''
        if ${pkgs.coreutils}/bin/test -L /home/amp; then
          echo "/home/amp is still a custom-home symlink; restore the default home before starting AMP" >&2
          exit 1
        fi
      ''
      else ''
        if ! ${pkgs.coreutils}/bin/test /home/amp -ef ${lib.escapeShellArg cfg.home}; then
          echo "/home/amp must resolve to services.amp.home (${cfg.home})" >&2
          exit 1
        fi
      ''
    }
  '';

  # Declarative ADS settings
  adsSettingsType = lib.types.submodule {
    options = {
      createInContainers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether new AMP instances are created in containers.";
      };

      useHostNetworkingForNewContainers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether new containers use host networking.";
      };

      defaultAuthServerUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default AMP authentication server URL for new instances.";
      };

      defaultInstanceBindAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default web-interface bind address for new instances.";
      };

      defaultApplicationBindAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default application bind address for new instances.";
      };

      extraSettings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.bool
            lib.types.int
            lib.types.str
          ]
        );
        default = {};
        description = "Additional non-secret ADS provisioning settings.";
      };
    };
  };
  formatAdsValue = value:
    if builtins.isBool value
    then
      if value
      then "True"
      else "False"
    else toString value;
  typedAdsSettings = lib.filter (setting: setting.value != null) [
    {
      provisioningKey = "ADSModule.Defaults.UseDocker";
      value = cfg.ads.settings.createInContainers;
    }
    {
      provisioningKey = "ADSModule.Network.UseDockerHostNetwork";
      value = cfg.ads.settings.useHostNetworkingForNewContainers;
    }
    {
      provisioningKey = "ADSModule.Defaults.DefaultAuthServerURL";
      value = cfg.ads.settings.defaultAuthServerUrl;
    }
    {
      provisioningKey = "ADSModule.Network.DefaultIPBinding";
      value = cfg.ads.settings.defaultInstanceBindAddress;
    }
    {
      provisioningKey = "ADSModule.Network.DefaultAppIPBinding";
      value = cfg.ads.settings.defaultApplicationBindAddress;
    }
  ];
  extraAdsSettings =
    lib.mapAttrsToList (provisioningKey: value: {
      inherit provisioningKey value;
    })
    cfg.ads.settings.extraSettings;
  typedAdsSettingKeys = map (setting: setting.provisioningKey) typedAdsSettings;
  extraAdsSettingKeys = builtins.attrNames cfg.ads.settings.extraSettings;
  reservedAdsSettingKeys = [
    "ADSModule.ADS.Mode"
    "Core.Webserver.IPBinding"
    "Core.Webserver.Port"
  ];
  validAdsSettingKey = key:
    builtins.match "^[^.\t\r\n]+(\\.[^.\t\r\n]+)+$" key
    != null
    && builtins.match ".*[[:cntrl:]].*" key == null;
  validAdsSettingValue = value:
    !builtins.isString value
    || builtins.match ".*[[:cntrl:]].*" value == null;

  # Core.* settings live in AMPConfig.conf; all other areas use <area>.kvp.
  toManagedAdsFileSetting = setting: let
    parts = lib.splitString "." setting.provisioningKey;
    area = builtins.head parts;
    target =
      if lib.hasPrefix "Core." setting.provisioningKey
      then {
        targetFile = "AMPConfig.conf";
        targetKey = lib.removePrefix "Core." setting.provisioningKey;
      }
      else {
        targetFile = "${area}.kvp";
        targetKey = lib.concatStringsSep "." (builtins.tail parts);
      };
  in
    setting
    // target
    // {value = formatAdsValue setting.value;};
  managedAdsSettings =
    lib.sort
    (left: right: left.provisioningKey < right.provisioningKey)
    (map toManagedAdsFileSetting (typedAdsSettings ++ extraAdsSettings));
  adsSettingsEnabled = managedAdsSettings != [];
  adsSettingsManifest = pkgs.writeText "amp-ads-settings.tsv" (
    lib.concatMapStringsSep "\n" (setting:
      lib.concatStringsSep "\t" [
        setting.provisioningKey
        setting.targetFile
        setting.targetKey
        setting.value
      ])
    managedAdsSettings
    + lib.optionalString adsSettingsEnabled "\n"
  );
  adsBootstrap = cfg.ads.bootstrap;

  # Shared ADS lifecycle helpers
  #
  # Bootstrap and reconciliation serialise ADS01 changes through descriptor 9.
  # AMP is invoked with that descriptor closed so persistent children cannot
  # retain the lifecycle lock after the oneshot exits.
  adsLifecycleFunctions = ''
    lock_ads() {
      install -d -m 0700 "$HOME/.ampdata/.nix-amp"
      exec 9>"$HOME/.ampdata/.nix-amp/lifecycle.lock"
      flock --exclusive \
        --timeout ${toString (cfg.startTimeout + cfg.stopTimeout)} 9
    }

    run_amp() {
      timeout --kill-after=1 ${toString cfg.startTimeout} \
        ${ampinstmgrServiceExe} "$@" 9>&-
    }

    read_status() {
      if ! status_output="$(run_amp status)"; then
        echo "Could not read AMP instance status" >&2
        exit 1
      fi
    }

    ads_registered() {
      awk '$1 == "ADS01" { found = 1 } END { exit !found }' \
        <<< "$status_output"
    }

    ads_running() {
      awk '$1 == "ADS01" && $NF == "✓" { found = 1 } END { exit !found }' \
        <<< "$status_output"
    }

    wait_for_ads() {
      message="$1"
      deadline=$((SECONDS + ${toString cfg.startTimeout}))
      while true; do
        read_status
        ads_running && return
        if test "$SECONDS" -ge "$deadline"; then
          echo "$message" >&2
          exit 1
        fi
        sleep 1
      done
    }
  '';

  # Bootstrap creates only a new ADS01. "in-progress" permits an explicit
  # recovery attempt; "complete" is written only after ADS is registered and
  # running.
  adsBootstrapCommand = pkgs.writeShellApplication {
    name = "ampads-bootstrap";
    runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.util-linux];
    text = ''
      state_dir="$HOME/.ampdata/.nix-amp"
      state="$state_dir/bootstrap-state"
      instance="$HOME/.ampdata/instances/ADS01"

      ${adsLifecycleFunctions}

      lock_ads

      # Keep the marker transition atomic so interrupted runs remain recoverable.
      write_state() {
        printf '%s\n' "$1" > "$state.new"
        mv "$state.new" "$state"
      }

      if test -e "$state"; then
        IFS= read -r current_state < "$state" || true
        case "$current_state" in
          complete)
            read_status
            if ! ads_registered; then
              echo "ADS01 bootstrap is marked complete but ADS01 is not registered" >&2
              exit 1
            fi
            exit 0
            ;;
          in-progress) ;;
          *)
            echo "Unknown ADS bootstrap state: $current_state" >&2
            exit 1
            ;;
        esac
      else
        current_state=
      fi

      # systemd credentials keep secrets out of the Nix store and unit
      # environment. AMP's CLI still requires them as transient arguments.
      password_file="$CREDENTIALS_DIRECTORY/admin-password"
      test -s "$password_file"
      password="$(<"$password_file")"
      test -n "$password"
      password_argument="base64:$(printf %s "$password" | base64 -w0)"
      unset password

      ${
        if adsBootstrap.licenceKeyFile == null
        then "licence="
        else ''
          licence_file="$CREDENTIALS_DIRECTORY/licence-key"
          test -s "$licence_file"
          licence="$(<"$licence_file")"
          test -n "$licence"
        ''
      }

      # A missing marker means nix-amp must not adopt pre-existing AMP state.
      read_status
      if test -z "$current_state"; then
        if ads_registered; then
          echo "ADS01 already exists without nix-amp bootstrap state; refusing to adopt it" >&2
          exit 1
        fi
        if test -e "$instance"; then
          echo "An unregistered ADS01 directory already exists; refusing to overwrite it" >&2
          exit 1
        fi

        write_state in-progress
      fi

      if ! ads_registered; then
        if test -e "$instance"; then
          echo "ADS01 bootstrap is incomplete; remove or recover the partial instance explicitly" >&2
          exit 1
        fi

        arguments=(
          create
          ADS
          ADS01
          ${lib.escapeShellArg adsBootstrap.bindAddress}
          ${toString adsBootstrap.port}
          ""
          ${lib.escapeShellArg adsBootstrap.adminUsername}
          "$password_argument"
          +ADSModule.ADS.Mode
          ${lib.escapeShellArg adsBootstrap.operationMode}
          ${lib.concatMapStringsSep "\n          " (setting:
        lib.escapeShellArgs [
          "+${setting.provisioningKey}"
          setting.value
        ])
      managedAdsSettings}
        )

        run_amp "''${arguments[@]}"

        read_status
        if ! ads_registered; then
          echo "AMP CreateInstance returned without registering ADS01" >&2
          exit 1
        fi
      fi

      run_amp setstartboot ADS01 true

      if test -n "$licence"; then
        run_amp reactivate ADS01 "$licence"
        unset licence
      fi

      read_status
      if ! ads_running; then
        run_amp startinstance ADS01
      fi

      wait_for_ads "ADS01 did not reach running state after bootstrap"

      # Registration and a running process are the bootstrap commit point.
      write_state complete
    '';
  };

  # Reconciliation compares AMP's written files with the managed manifest,
  # invokes reconfigureinstance only for drift, verifies the result, and
  # restores an ADS instance that was running if a later step fails.
  adsReconcileCommand = pkgs.writeShellApplication {
    name = "ampads-reconcile";
    runtimeInputs = [pkgs.coreutils pkgs.gawk pkgs.util-linux];
    text = ''
      instance="$HOME/.ampdata/instances/ADS01"

      ${adsLifecycleFunctions}

      lock_ads

      read_status
      if ! ads_registered; then
        echo "ADS01 is not registered; skipping managed settings"
        exit 0
      fi

      # Return codes distinguish a missing key (10) from duplicate, malformed,
      # or unreadable configuration (11-13), which cannot be changed safely.
      read_setting() {
        file="$1"
        key="$2"
        test -r "$file" || return 13
        awk -v key="$key" '
          /^[[:space:]]*($|#)/ { next }
          index($0, "=") == 0 { malformed = 1; next }
          {
            candidate = substr($0, 1, index($0, "=") - 1)
            if (candidate == key) {
              count++
              value = substr($0, index($0, "=") + 1)
            }
          }
          END {
            if (malformed) exit 12
            if (count == 0) exit 10
            if (count > 1) exit 11
            print value
          }
        ' "$file"
      }

      arguments=(reconfigureinstance ADS01)
      drift=0
      while IFS=$'\t' read -r provisioning_key target_file target_key desired; do
        if actual="$(read_setting "$instance/$target_file" "$target_key")"; then
          if test "$actual" != "$desired"; then
            arguments+=("+$provisioning_key" "$desired")
            drift=1
          fi
        else
          result=$?
          case "$result" in
            10)
              arguments+=("+$provisioning_key" "$desired")
              drift=1
              ;;
            *)
              echo "Cannot safely read $target_key from $target_file" >&2
              exit 1
              ;;
          esac
        fi
      done < ${adsSettingsManifest}

      if test "$drift" -eq 0; then
        exit 0
      fi

      # Preserve the pre-reconciliation running state across success or failure.
      was_running=false
      read_status
      if ads_running; then
        was_running=true
      fi

      restore_on_failure() {
        result=$?
        if test "$result" -ne 0 && test "$was_running" = true; then
          run_amp startinstance ADS01 || true
        fi
        exit "$result"
      }
      trap restore_on_failure EXIT

      if test "$was_running" = true; then
        timeout --kill-after=1 ${toString cfg.stopTimeout} \
          ${ampinstmgrServiceExe} stopinstance ADS01 9>&-
      fi

      run_amp "''${arguments[@]}"

      # AMP returning successfully is not sufficient; verify every written key.
      while IFS=$'\t' read -r _ target_file target_key desired; do
        actual="$(read_setting "$instance/$target_file" "$target_key")"
        if test "$actual" != "$desired"; then
          echo "AMP did not apply $target_key in $target_file" >&2
          exit 1
        fi
      done < ${adsSettingsManifest}

      if test "$was_running" = true; then
        run_amp startinstance ADS01
        wait_for_ads "ADS01 did not reach running state after reconciliation"
      fi

      trap - EXIT
    '';
  };

  # NixOS rejects unmatched input before AMP's appended INPUT rules. The
  # bridge returns from nixos-fw-refuse, then relies on an INPUT DROP policy:
  # NixOS accepts still win, AMP's later accepts become reachable, and all
  # remaining traffic stays denied.
  firewallBridgeCleanup = pkgs.writeShellApplication {
    name = "ampfirewall-bridge-cleanup";
    text = ''
      state=/run/ampfirewall-bridge/input-policy

      # Remove every copy in case a prior interrupted reload left duplicates.
      while ${iptables} -w -C nixos-fw-refuse \
        -m comment --comment ${bridgeTag} -j RETURN 2>/dev/null; do
        ${iptables} -w -D nixos-fw-refuse \
          -m comment --comment ${bridgeTag} -j RETURN
      done

      if test -r "$state"; then
        policy=
        IFS= read -r policy < "$state" || true
        case "$policy" in
          ACCEPT | DROP) ${iptables} -w -P INPUT "$policy" ;;
        esac
      fi
    '';
  };
  firewallBridgeTeardown = pkgs.writeShellApplication {
    name = "ampfirewall-bridge-teardown";
    text = ''
      # AMP owns rules carrying its "/* AMP:" comment marker.
      rules=
      while read -r number target rest; do
        case "$number:$target:$rest" in
          [0-9]*:ACCEPT:*"/* AMP:"*) rules="$number $rules" ;;
        esac
      done < <(${iptables} -w -L INPUT --line-numbers -n)

      for number in $rules; do
        ${iptables} -w -D INPUT "$number"
      done

      exec ${lib.getExe firewallBridgeCleanup}
    '';
  };
  firewallBridgeApply = pkgs.writeShellApplication {
    name = "ampfirewall-bridge-apply";
    text = ''
      state=/run/ampfirewall-bridge/input-policy

      cleanup() {
        ${lib.getExe firewallBridgeCleanup}
      }
      trap cleanup ERR

      # Apply only to a complete NixOS iptables ruleset.
      ${iptables} -w -C INPUT -j nixos-fw
      ${iptables} -w -S nixos-fw-refuse >/dev/null

      # Save the policy once so disable/removal can restore what it inherited.
      if ! test -e "$state"; then
        policy=
        while read -r operation chain candidate _; do
          if test "$operation" = -P && test "$chain" = INPUT; then
            policy="$candidate"
            break
          fi
        done < <(${iptables} -w -S INPUT)

        case "$policy" in
          ACCEPT | DROP) ;;
          *) exit 1 ;;
        esac
        umask 077
        printf '%s\n' "$policy" > "$state"
      fi

      ${iptables} -w -P INPUT DROP

      # Replace any stale bridge copies with one first-position RETURN.
      while ${iptables} -w -C nixos-fw-refuse \
        -m comment --comment ${bridgeTag} -j RETURN 2>/dev/null; do
        ${iptables} -w -D nixos-fw-refuse \
          -m comment --comment ${bridgeTag} -j RETURN
      done

      ${iptables} -w -I nixos-fw-refuse 1 \
        -m comment --comment ${bridgeTag} -j RETURN

      trap - ERR
    '';
  };
in {
  options.services.amp = {
    enable = lib.mkEnableOption "CubeCoders AMP instance manager";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The AMP instance manager package.";
    };

    home = lib.mkOption {
      type = lib.types.str;
      default = "/home/amp";
      description = "Home directory containing all mutable AMP and game state.";
    };

    startTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Seconds allowed for AMP startup.";
    };

    stopTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = "Seconds allowed for AMP shutdown.";
    };

    ads = {
      bootstrap = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            adminUsername = lib.mkOption {
              type = lib.types.str;
              default = "admin";
              description = "Initial ADS administrator username.";
            };

            adminPasswordFile = lib.mkOption {
              type = lib.types.strMatching "^/.*";
              description = ''
                Absolute path to a root-readable file containing the initial
                ADS administrator password. A string path keeps the secret out
                of the Nix store.
              '';
            };

            licenceKeyFile = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "^/.*");
              default = null;
              description = ''
                Optional absolute path to a root-readable file containing the
                AMP licence key. A string path keeps the secret out of the Nix
                store.
              '';
            };

            bindAddress = lib.mkOption {
              type = lib.types.str;
              default = "0.0.0.0";
              description = "Initial ADS web-interface bind address.";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 8080;
              description = "Initial ADS web-interface port.";
            };

            operationMode = lib.mkOption {
              type = lib.types.enum [
                "Standalone"
                "Controller"
                "Target"
                "Hybrid"
              ];
              default = "Standalone";
              description = "Initial ADS operation mode.";
            };
          };
        });
        default = null;
        description = "Optional unattended creation of the ADS01 instance.";
      };

      settings = lib.mkOption {
        type = adsSettingsType;
        default = {};
        description = ''
          Declaratively managed ADS settings. Null typed fields are unmanaged.
          Applying detected drift may restart ADS.
        '';
      };
    };

    firewallSync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        defaultText = lib.literalExpression "config.services.amp.enable";
        description = "Whether AMP synchronises its declared firewall ports.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Systemd interval between AMP firewall synchronisations.";
      };

      podman = lib.mkOption {
        type = lib.types.bool;
        default = cfg.firewallSync.enable && config.virtualisation.podman.enable;
        defaultText = lib.literalExpression ''
          config.services.amp.firewallSync.enable
          && config.virtualisation.podman.enable
        '';
        description = "Whether Podman container events trigger immediate AMP firewall synchronisation.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "services.amp supports only x86_64-linux.";
      }
      {
        assertion =
          homeIsNormalized
          && cfg.home != "/"
          && cfg.home != "/nix/store"
          && !lib.hasPrefix "/nix/store/" cfg.home
          && (cfg.home == "/home/amp" || !lib.hasPrefix "/home/amp/" cfg.home);
        message = "services.amp.home must be normalised, writable, outside /nix/store, and not below /home/amp.";
      }
      {
        assertion = !cfg.firewallSync.enable || config.networking.firewall.enable;
        message = "services.amp.firewallSync requires networking.firewall.enable.";
      }
      {
        assertion =
          !cfg.firewallSync.enable
          || config.networking.firewall.backend == "iptables";
        message = "services.amp.firewallSync supports only the NixOS iptables firewall backend.";
      }
      {
        assertion =
          lib.intersectLists typedAdsSettingKeys extraAdsSettingKeys == [];
        message = "services.amp.ads.settings.extraSettings must not duplicate a built-in ADS setting.";
      }
      {
        assertion =
          lib.intersectLists reservedAdsSettingKeys extraAdsSettingKeys == [];
        message = "services.amp.ads.settings.extraSettings contains a bootstrap-owned ADS setting.";
      }
      {
        assertion =
          lib.all validAdsSettingKey extraAdsSettingKeys
          && lib.all (setting: validAdsSettingValue setting.value) managedAdsSettings;
        message = "services.amp.ads settings must be valid single-line AMP provisioning keys and values.";
      }
    ];

    # AMP downloads native executables after evaluation. Expose the conventional
    # loader without enabling the full global programs.nix-ld environment.
    environment = {
      etc."ampinstmgr.conf".source = "${cfg.package}/share/ampinstmgr/ampinstmgr.conf";
      ldso = lib.mkOverride 900 "${pkgs.nix-ld}/libexec/nix-ld";
      systemPackages = [cfg.package];
    };

    # Account and compatibility paths
    users = {
      groups.amp = {};
      users.amp =
        {
          isSystemUser = true;
          group = "amp";
          home = cfg.home;
          homeMode = "0700";
          createHome = true;
          shell = pkgs.bashInteractive;
        }
        // lib.optionalAttrs podmanEnabled {
          autoSubUidGidRange = lib.mkDefault true;
          linger = lib.mkDefault true;
        };
    };

    systemd = {
      # Import upstream unit metadata, then correct commands and lifecycle
      # behaviour through NixOS drop-ins below.
      packages = [cfg.package];

      # Root-level firewall commands still resolve the amp user through /home/amp.
      tmpfiles.settings = lib.optionalAttrs (cfg.home != "/home/amp") {
        "10-amp"."/home/amp".L.argument = cfg.home;
      };

      # Core upstream services
      services =
        {
          ampinstmgr =
            {
              overrideStrategy = "asDropin";
              wantedBy = ["multi-user.target"];
              # A NixOS switch must not interrupt running game instances.
              restartIfChanged = false;
              stopIfChanged = false;
              path = ampServicePath;
              environment = serviceEnvironment;
              unitConfig.RequiresMountsFor = [cfg.home];
              serviceConfig = {
                ExecCondition = ampHomeCondition;
                WorkingDirectory = ampRoot;
                ExecStart = [
                  ""
                  "${ampinstmgrServiceExe} startboot true"
                ];
                ExecStop = [
                  ""
                  "${ampinstmgrServiceExe} stopall"
                ];
                TimeoutStartSec = cfg.startTimeout;
                TimeoutStopSec = cfg.stopTimeout;
              };
            }
            // podmanUnitOrdering;

          amptasks =
            {
              overrideStrategy = "asDropin";
              path = ampServicePath;
              environment = serviceEnvironment;
              unitConfig.RequiresMountsFor = [cfg.home];
              serviceConfig = {
                ExecCondition = ampHomeCondition;
                KillMode = "process";
                WorkingDirectory = ampRoot;
                ExecStart = [
                  ""
                  "${ampinstmgrServiceExe} ProcessPendingTasks"
                ];
              };
            }
            // podmanUnitOrdering;
        }
        # Privileged firewall synchronisation
        // lib.optionalAttrs cfg.firewallSync.enable {
          ampfirewall-bridge = {
            description = "AMP firewall bridge";
            after = ["firewall.service"];
            bindsTo = ["firewall.service"];
            wantedBy = ["firewall.service" "multi-user.target"];
            unitConfig.ReloadPropagatedFrom = "firewall.service";
            serviceConfig = {
              AmbientCapabilities = ["CAP_NET_ADMIN"];
              CapabilityBoundingSet = ["CAP_NET_ADMIN"];
              ExecStart = lib.getExe firewallBridgeApply;
              ExecReload = lib.getExe firewallBridgeApply;
              ExecStopPost = lib.getExe firewallBridgeTeardown;
              Group = "root";
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              RemainAfterExit = true;
              RuntimeDirectory = "ampfirewall-bridge";
              RuntimeDirectoryMode = "0700";
              Type = "oneshot";
              User = "root";
            };
          };

          ampfirewall = {
            overrideStrategy = "asDropin";
            after = [
              "ampfirewall-bridge.service"
              "ampinstmgr.service"
              "firewall.service"
              "network-online.target"
            ];
            bindsTo = ["ampfirewall-bridge.service"];
            wants = ["network-online.target"];
            path =
              servicePath
              ++ [config.networking.firewall.package]
              ++ lib.optional cfg.firewallSync.podman pkgs.podman;
            environment =
              serviceEnvironment
              // {DOTNET_BUNDLE_EXTRACT_BASE_DIR = "/var/cache/ampfirewall";};
            unitConfig = {
              RequiresMountsFor = [cfg.home];
              StartLimitIntervalSec = 0;
            };
            serviceConfig = {
              AmbientCapabilities = ["CAP_DAC_READ_SEARCH" "CAP_NET_ADMIN" "CAP_NET_RAW"];
              BindReadOnlyPaths =
                [cfg.home]
                ++ lib.optional (cfg.home != "/home/amp") "${cfg.home}:/home/amp";
              CacheDirectory = "ampfirewall";
              CapabilityBoundingSet = ["CAP_DAC_READ_SEARCH" "CAP_NET_ADMIN" "CAP_NET_RAW"];
              InaccessiblePaths = ["/root"];
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectHome = "read-only";
              ProtectSystem = "strict";
              WorkingDirectory = ampRoot;
              ExecCondition = ampHomeCondition;
              ExecStart = [
                ""
                "${ampinstmgr} --silent updatefirewall amp"
              ];
            };
          };
        }
        # Optional rootless Podman event trigger
        // lib.optionalAttrs (cfg.firewallSync.enable && cfg.firewallSync.podman) {
          ampfirewall-watch = {
            description = "AMP Podman Firewall Watcher";
            after = ["ampinstmgr.service"];
            wantedBy = ["multi-user.target"];
            path = [pkgs.coreutils pkgs.jq pkgs.systemd];
            script = ''
              journalctl \
                --follow \
                --lines=0 \
                --output=json \
                "_UID=$(id -u amp)" \
                SYSLOG_IDENTIFIER=podman \
                PODMAN_TYPE=container |
              jq --unbuffered -r \
                '[.PODMAN_EVENT // "", .PODMAN_NAME // ""] | @tsv' |
              while IFS=$'\t' read -r status name; do
                case "$status:$name" in
                  create:AMP_* | start:AMP_* | restart:AMP_* | stop:AMP_* | remove:AMP_* | update:AMP_*)
                    # Let AMP finish persisting the container change before
                    # asking its firewall inventory to reconcile.
                    sleep 2
                    systemctl start --no-block ampfirewall.service
                    ;;
                esac
              done
            '';
            serviceConfig = {
              Restart = "always";
              RestartSec = 5;
            };
          };
        }
        # ADS bootstrap and declarative reconciliation
        // lib.optionalAttrs (adsBootstrap != null) {
          ampads-bootstrap = lib.mkMerge [
            {
              description = "Bootstrap the AMP ADS01 instance";
              after = [
                "ampinstmgr.service"
                "network-online.target"
              ];
              wantedBy = ["multi-user.target"];
              wants = ["network-online.target"];
              path = ampServicePath;
              environment = serviceEnvironment;
              unitConfig = {
                RequiresMountsFor = [cfg.home];
                StartLimitIntervalSec = 0;
              };
              serviceConfig = {
                ExecStart = lib.getExe adsBootstrapCommand;
                ExecStartPre = ampHomeCondition;
                Group = "amp";
                LoadCredential =
                  ["admin-password:${adsBootstrap.adminPasswordFile}"]
                  ++ lib.optional (adsBootstrap.licenceKeyFile != null)
                  "licence-key:${adsBootstrap.licenceKeyFile}";
                # ponytail: AMP starts persistent ADS children from this oneshot;
                # replace this when upstream exposes a detached lifecycle.
                KillMode = "none";
                Type = "oneshot";
                User = "amp";
                WorkingDirectory = ampRoot;
              };
            }
            podmanUnitOrdering
          ];
        }
        // lib.optionalAttrs adsSettingsEnabled {
          ampads-reconcile = lib.mkMerge [
            {
              description = "Reconcile declarative AMP ADS01 settings";
              after =
                ["ampinstmgr.service"]
                ++ lib.optional (adsBootstrap != null) "ampads-bootstrap.service";
              requires =
                lib.optional (adsBootstrap != null) "ampads-bootstrap.service";
              wantedBy = [
                "multi-user.target"
                "sysinit-reactivation.target"
              ];
              restartTriggers = [adsSettingsManifest];
              path = ampServicePath;
              environment = serviceEnvironment;
              unitConfig.RequiresMountsFor = [cfg.home];
              serviceConfig = {
                ExecCondition = ampHomeCondition;
                ExecStart = lib.getExe adsReconcileCommand;
                Group = "amp";
                # ponytail: reconfiguration may restart ADS as a child process.
                KillMode = "none";
                RemainAfterExit = true;
                Type = "oneshot";
                User = "amp";
                WorkingDirectory = ampRoot;
              };
            }
            podmanUnitOrdering
          ];
        };

      # ADS configuration changes and periodic firewall reconciliation
      paths = lib.optionalAttrs cfg.firewallSync.enable {
        ampfirewall-ads = {
          wantedBy = ["multi-user.target"];
          pathConfig = {
            PathChanged = "${cfg.home}/.ampdata/instances/ADS01/AMPConfig.conf";
            Unit = "ampfirewall.service";
          };
        };
      };

      timers =
        {
          amptasks = {
            overrideStrategy = "asDropin";
            wantedBy = ["multi-user.target"];
          };
        }
        // lib.optionalAttrs cfg.firewallSync.enable {
          ampfirewall = {
            overrideStrategy = "asDropin";
            wantedBy = ["multi-user.target"];
            timerConfig = {
              AccuracySec = "1s";
              # Retain upstream's one-minute run, then add bounded early-boot
              # retries until the five-minute steady-state interval takes over.
              OnBootSec = [
                "1m30s"
                "2m"
                "2m30s"
                "3m"
                "3m30s"
                "4m"
                "4m30s"
                "5m"
              ];
              OnUnitActiveSec = [
                ""
                cfg.firewallSync.interval
              ];
            };
          };
        };
    };

    networking.firewall.extraCommands = lib.optionalString cfg.firewallSync.enable ''
      systemctl start --no-block ampfirewall.service
    '';

    networking.firewall.extraStopCommands = lib.optionalString cfg.firewallSync.enable ''
      ${lib.getExe firewallBridgeCleanup}
    '';
  };
}
