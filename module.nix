{
  config,
  lib,
  pkgs,
  ...
}: let
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
  ampServiceCommand =
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
  podmanService = lib.optionalAttrs podmanEnabled {
    after = ["linger-users.service"];
    wants = ["linger-users.service"];
  };
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
  firewallBridgeCleanup = pkgs.writeShellApplication {
    name = "ampfirewall-bridge-cleanup";
    text = ''
      state=/run/ampfirewall-bridge/input-policy

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

      ${iptables} -w -C INPUT -j nixos-fw
      ${iptables} -w -S nixos-fw-refuse >/dev/null

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
      description = "Home directory containing AMP's mutable .ampdata state.";
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

    firewallSync = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable;
        defaultText = lib.literalExpression "config.services.amp.enable";
        description = "Whether AMP synchronizes its declared firewall ports.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Systemd interval between AMP firewall synchronizations.";
      };

      podman = lib.mkOption {
        type = lib.types.bool;
        default = cfg.firewallSync.enable && config.virtualisation.podman.enable;
        defaultText = lib.literalExpression ''
          config.services.amp.firewallSync.enable
          && config.virtualisation.podman.enable
        '';
        description = "Whether Podman container events trigger immediate AMP firewall synchronization.";
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
        message = "services.amp.home must be normalized, writable, outside /nix/store, and not below /home/amp.";
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
    ];

    environment = {
      etc."ampinstmgr.conf".source = "${cfg.package}/share/ampinstmgr/ampinstmgr.conf";
      ldso = lib.mkOverride 900 "${pkgs.nix-ld}/libexec/nix-ld";
      systemPackages = [cfg.package];
    };

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
      packages = [cfg.package];

      # Root-level firewall commands still resolve the amp user through /home/amp.
      tmpfiles.settings = lib.optionalAttrs (cfg.home != "/home/amp") {
        "10-amp"."/home/amp".L.argument = cfg.home;
      };

      services =
        {
          ampinstmgr =
            {
              overrideStrategy = "asDropin";
              wantedBy = ["multi-user.target"];
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
                  "${ampServiceCommand} startboot true"
                ];
                ExecStop = [
                  ""
                  "${ampServiceCommand} stopall"
                ];
                TimeoutStartSec = cfg.startTimeout;
                TimeoutStopSec = cfg.stopTimeout;
              };
            }
            // podmanService;

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
                  "${ampServiceCommand} ProcessPendingTasks"
                ];
              };
            }
            // podmanService;
        }
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
            unitConfig.RequiresMountsFor = [cfg.home];
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
        };

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
