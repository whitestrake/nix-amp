{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.amp;
  ampinstmgr = lib.getExe' cfg.package "ampinstmgr";
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
      services =
        {
          ampinstmgr = {
            description = "AMP Instance Manager";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            wantedBy = ["multi-user.target"];
            restartIfChanged = false;
            stopIfChanged = false;
            environment = serviceEnvironment;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "amp";
              Group = "amp";
              WorkingDirectory = cfg.home;
              ExecStart = "${ampinstmgr} startboot true";
              ExecStop = "${ampinstmgr} stopall";
              TimeoutStartSec = cfg.startTimeout;
              TimeoutStopSec = cfg.stopTimeout;
            };
          };

          amptasks = {
            description = "AMP Instance Manager Pending Tasks";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            environment = serviceEnvironment;
            serviceConfig = {
              Type = "oneshot";
              KillMode = "process";
              User = "amp";
              Group = "amp";
              WorkingDirectory = cfg.home;
              ExecStart = "${ampinstmgr} ProcessPendingTasks";
              TimeoutStartSec = 60;
            };
          };
        }
        // lib.optionalAttrs cfg.firewallSync.enable {
          ampfirewall = {
            description = "AMP Instance Manager Firewall";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            environment = serviceEnvironment;
            serviceConfig = {
              Type = "oneshot";
              User = "root";
              Group = "root";
              WorkingDirectory = cfg.home;
              ExecStart = "${ampinstmgr} --silent updatefirewall amp";
              TimeoutStartSec = 60;
            };
          };
        };

      timers =
        {
          amptasks = {
            description = "AMP Instance Manager Pending Tasks";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnActiveSec = "1s";
              OnBootSec = "1m";
              OnUnitActiveSec = "1m";
            };
          };
        }
        // lib.optionalAttrs cfg.firewallSync.enable {
          ampfirewall = {
            description = "AMP Instance Manager Firewall";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnActiveSec = "1s";
              OnBootSec = "1m";
              OnUnitActiveSec = cfg.firewallSync.interval;
            };
          };
        };
    };
  };
}
