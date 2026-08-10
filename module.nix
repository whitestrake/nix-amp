{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.amp;
  ampRoot = "${cfg.package}/opt/cubecoders/amp";
  ampinstmgr = lib.getExe' cfg.package "ampinstmgr";
  servicePath = [cfg.package "/run/wrappers"];
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
      enable = lib.mkEnableOption "AMP firewall synchronization";

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Systemd interval between AMP firewall synchronizations.";
      };

      podman = lib.mkEnableOption "immediate AMP firewall synchronization after Podman container events";
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
          lib.hasPrefix "/" cfg.home
          && cfg.home != "/"
          && !lib.hasPrefix "/nix/store/" cfg.home;
        message = "services.amp.home must be an absolute writable path outside /nix/store.";
      }
    ];

    warnings = lib.optional (cfg.firewallSync.enable && config.networking.firewall.enable) ''
      services.amp.firewallSync may conflict with the declarative NixOS firewall.
    '';

    environment = {
      etc."ampinstmgr.conf".source = "${cfg.package}/share/ampinstmgr/ampinstmgr.conf";
      ldso = lib.mkOverride 900 "${pkgs.nix-ld}/libexec/nix-ld";
      systemPackages = [cfg.package];
    };

    users = {
      groups.amp = {};
      users.amp = {
        isSystemUser = true;
        group = "amp";
        home = cfg.home;
        homeMode = "0700";
        createHome = true;
        shell = pkgs.bashInteractive;
      };
    };

    systemd = {
      packages = [cfg.package];

      services =
        {
          ampinstmgr = {
            overrideStrategy = "asDropin";
            wantedBy = ["multi-user.target"];
            restartIfChanged = false;
            stopIfChanged = false;
            path = servicePath;
            environment = serviceEnvironment;
            serviceConfig = {
              WorkingDirectory = ampRoot;
              ExecStart = [
                ""
                "${ampinstmgr} startboot true"
              ];
              ExecStop = [
                ""
                "${ampinstmgr} stopall"
              ];
              TimeoutStartSec = cfg.startTimeout;
              TimeoutStopSec = cfg.stopTimeout;
            };
          };

          amptasks = {
            overrideStrategy = "asDropin";
            path = servicePath;
            environment = serviceEnvironment;
            serviceConfig = {
              KillMode = "process";
              WorkingDirectory = ampRoot;
              ExecStart = [
                ""
                "${ampinstmgr} ProcessPendingTasks"
              ];
            };
          };
        }
        // lib.optionalAttrs cfg.firewallSync.enable {
          ampfirewall = {
            overrideStrategy = "asDropin";
            after = ["ampinstmgr.service" "firewall.service" "network-online.target"];
            wants = ["network-online.target"];
            path = servicePath ++ lib.optional cfg.firewallSync.podman pkgs.podman;
            environment = serviceEnvironment;
            serviceConfig = {
              WorkingDirectory = ampRoot;
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
                --no-tail \
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
  };
}
