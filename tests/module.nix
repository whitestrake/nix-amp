{
  ampModule,
  lib,
  pkgs,
}: let
  # This file-backed AMP emulator models only the command surface the module
  # consumes. Files under /run/amp-test deliberately inject lifecycle failures
  # so the VM can exercise recovery and timeout paths deterministically.
  fakeAmpinstmgr = pkgs.symlinkJoin {
    name = "fake-ampinstmgr";
    paths = [
      (pkgs.writeShellApplication {
        name = "ampinstmgr";
        runtimeInputs = [pkgs.coreutils pkgs.gawk];
        text = ''
          operation="$1"
          shift

          while read -r key value _; do
            if test "$key" = "CapEff:"; then
              capabilities="$value"
              break
            fi
          done < /proc/self/status

          root_home=hidden
          if test -r /root/amp-test-secret; then
            root_home=visible
          fi

          case "$operation" in
            create) logged_args="<redacted-bootstrap-arguments>" ;;
            reactivate) logged_args="ADS01 <redacted-licence-key>" ;;
            reconfigureinstance)
              case "$*" in
                *"+ADSModule.Defaults.NewInstanceKey"*)
                  logged_args="ADS01 +ADSModule.Defaults.NewInstanceKey <redacted-licence-key>"
                  ;;
                *) logged_args="$*" ;;
              esac
              ;;
            *) logged_args="$*" ;;
          esac

          printf \
            'uid=%s gid=%s capabilities=%s root_home=%s home=%s cwd=%s term=%s nix_ld=%s libraries=%s manager=%s xdg=%s docker=%s argv=%s%s\n' \
            "$(id -u)" \
            "$(id -g)" \
            "$capabilities" \
            "$root_home" \
            "$HOME" \
            "$PWD" \
            "$TERM" \
            "$NIX_LD" \
            "$NIX_LD_LIBRARY_PATH" \
            "$(command -v ampinstmgr || true)" \
            "''${XDG_RUNTIME_DIR-}" \
            "''${DOCKER_HOST-}" \
            "$operation" \
            "''${logged_args:+ $logged_args}" \
            >> /run/amp-test/invocations

          # Mutable ADS01 state and configuration model
          instance="$HOME/.ampdata/instances/ADS01"

          set_setting() {
            provisioning_key="$1"
            value="$2"
            case "$provisioning_key" in
              Core.*)
                file="$instance/AMPConfig.conf"
                key="''${provisioning_key#Core.}"
                ;;
              *.*)
                area="''${provisioning_key%%.*}"
                file="$instance/$area.kvp"
                key="''${provisioning_key#*.}"
                ;;
              *) exit 64 ;;
            esac

            install -d "$instance"
            touch "$file"
            awk -F= -v key="$key" -v value="$value" '
              BEGIN { found = 0 }
              $1 == key {
                if (!found) print key "=" value
                found = 1
                next
              }
              { print }
              END {
                if (!found) print key "=" value
              }
            ' "$file" > "$file.new"
            mv "$file.new" "$file"
          }

          start_ads_now() {
            rm -f "$instance/.starting"
            touch "$instance/.running"
            sleep 300 >/dev/null 2>&1 &
            printf '%s\n' "$!" > "$instance/.running-pid"
          }

          # Lifecycle controls consult /run/amp-test markers to emulate delayed,
          # asynchronous, failed, or permanently hung upstream operations.
          start_ads() {
            if test -e /run/amp-test/start-never; then
              return
            fi
            if test -e /run/amp-test/start-async; then
              touch "$instance/.starting"
              rm -f "$instance/.status-attempts"
              return
            fi
            start_ads_now
          }

          stop_ads() {
            if test -e /run/amp-test/stop-hang; then
              printf '%s\n' "$$" > /run/amp-test/stop-hang-pid
              trap -- "" TERM
              sleep 300
            fi
            if test -e /run/amp-test/stop-delay; then
              sleep 5
            fi
            if test -e "$instance/.running-pid"; then
              read -r pid < "$instance/.running-pid"
              kill "$pid" 2>/dev/null || true
            fi
            rm -f \
              "$instance/.running" \
              "$instance/.running-pid" \
              "$instance/.starting" \
              "$instance/.status-attempts"
          }

          # Minimal ampinstmgr command surface used by the module
          case "$operation" in
            ProcessPendingTasks)
              sleep 300 &
              echo "$!" > /run/amp-test/pending-child.pid
              ;;
            status)
              if test -e /run/amp-test/status-fail; then
                exit 70
              fi
              if test -e /run/amp-test/status-fail-next; then
                rm /run/amp-test/status-fail-next
                exit 70
              fi
              if test -e /run/amp-test/status-fail-after-one; then
                mv \
                  /run/amp-test/status-fail-after-one \
                  /run/amp-test/status-fail-next
              fi
              if test -e "$instance/.registered"; then
                if test -e "$instance/.starting"; then
                  attempts=0
                  test ! -e "$instance/.status-attempts" ||
                    read -r attempts < "$instance/.status-attempts"
                  attempts=$((attempts + 1))
                  printf '%s\n' "$attempts" > "$instance/.status-attempts"
                  if test "$attempts" -ge 2; then
                    rm "$instance/.starting"
                    start_ads_now
                  fi
                fi
                if test -e "$instance/.running"; then
                  running="✓"
                else
                  running=""
                fi
                printf 'ADS01 ADS01 ADS 0.0.0.0 8080 %s\n' "$running"
              fi
              ;;
            create)
              test "$1" = ADS
              test "$2" = ADS01
              bind_address="$3"
              port="$4"
              test -z "$5"
              admin_username="$6"
              admin_password="$7"
              shift 7

              if test -z "$admin_username"; then
                exit 64
              fi
              case "$admin_password" in
                base64:*)
                  decoded="$(
                    printf %s "''${admin_password#base64:}" | base64 -d
                  )"
                  test -n "$decoded"
                  ;;
                *) exit 64 ;;
              esac

              install -d "$instance"
              touch "$instance/.registered"
              set_setting Core.Webserver.IPBinding "$bind_address"
              set_setting Core.Webserver.Port "$port"

              while test "$#" -gt 0; do
                key="''${1#+}"
                value="$2"
                shift 2
                set_setting "$key" "$value"
              done
              ;;
            reactivate)
              test "$1" = ADS01
              test -e "$instance/.registered"
              test "$2" != invalid
              stop_ads
              touch "$instance/.licensed"
              ;;
            setstartboot)
              test "$1" = ADS01
              test "$2" = true
              test -e "$instance/.registered"
              touch "$instance/.start-on-boot"
              ;;
            startinstance)
              test "$1" = ADS01
              test -e "$instance/.registered"
              start_ads
              ;;
            stopinstance)
              test "$1" = ADS01
              stop_ads
              test ! -e /run/amp-test/stop-fail-after-effect
              ;;
            reconfigureinstance)
              test "$1" = ADS01
              shift
              test ! -e /run/amp-test/reconfigure-fail
              while test "$#" -gt 0; do
                key="''${1#+}"
                value="$2"
                shift 2
                set_setting "$key" "$value"
              done
              ;;
          esac
        '';
      })
      # Upstream configuration and units imported by module.nix
      (pkgs.writeTextDir "share/ampinstmgr/ampinstmgr.conf" ''
        ampinstmgr.startonboot=amp
        ampinstmgr.updatefirewall=amp
        ampinstmgr.upnpsyncenabled=false
      '')
      (pkgs.writeTextDir "lib/systemd/system/ampinstmgr.service" ''
        [Unit]
        Description=Upstream AMP Instance Manager

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        User=amp
        Group=amp
        ExecStart=/opt/cubecoders/amp/ampinstmgr startboot true
        TimeoutSec=180
        ExecStop=/opt/cubecoders/amp/ampinstmgr stopall
        TimeoutStopSec=180

        [Install]
        WantedBy=multi-user.target
      '')
      (pkgs.writeTextDir "lib/systemd/system/amptasks.service" ''
        [Unit]
        Description=Upstream AMP Pending Tasks

        [Service]
        Type=oneshot
        KillMode=none
        User=amp
        Group=amp
        ExecStart=/opt/cubecoders/amp/ampinstmgr ProcessPendingTasks
        TimeoutSec=60
      '')
      (pkgs.writeTextDir "lib/systemd/system/amptasks.timer" ''
        [Unit]
        Description=Upstream AMP Pending Tasks

        [Timer]
        OnActiveSec=1
        OnBootSec=1m
        OnUnitActiveSec=1m

        [Install]
        WantedBy=multi-user.target
      '')
      (pkgs.writeTextDir "lib/systemd/system/ampfirewall.service" ''
        [Unit]
        Description=Upstream AMP Firewall

        [Service]
        Type=oneshot
        User=root
        Group=root
        ExecStart=/opt/cubecoders/amp/ampinstmgr --silent updatefirewall amp
        TimeoutSec=60
      '')
      (pkgs.writeTextDir "lib/systemd/system/ampfirewall.timer" ''
        [Unit]
        Description=Upstream AMP Firewall

        [Timer]
        OnActiveSec=1
        OnBootSec=1m
        OnUnitActiveSec=5m

        [Install]
        WantedBy=multi-user.target
      '')
      (pkgs.writeTextDir "opt/cubecoders/amp/.keep" "")
    ];
  };

  # Podman event source used by the firewall watcher
  fakeJournalctl = pkgs.writeShellApplication {
    name = "journalctl";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      case " $* " in
        *" --lines=0 "*) ;;
        *) exit 64 ;;
      esac

      printf '%s\n' \
        '{"PODMAN_EVENT":"health_status","PODMAN_NAME":"AMP_Ignored"}' \
        '{"PODMAN_EVENT":"create","PODMAN_NAME":"ignored"}' \
        '{"PODMAN_EVENT":"create","PODMAN_NAME":"AMP_Satisfactory01"}'
      sleep 300
    '';
  };

  # Shared module configuration for evaluation fixtures and both VM nodes
  baseModule = {
    imports = [ampModule];

    services.amp = {
      enable = true;
      package = fakeAmpinstmgr;
    };

    systemd.tmpfiles.rules = [
      "f /root/amp-test-secret 0600 root root - secret"
      "d /run/amp-test 0777 root root -"
      "f /run/amp-test/invocations 0666 root root -"
    ];

    system.stateVersion = "26.05";
  };

  # Successful configurations exercise defaults and optional feature shapes.
  validSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [baseModule];
  };

  disabledSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {services.amp.enable = lib.mkForce false;}
    ];
  };

  podmanDefaultSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {virtualisation.podman.enable = true;}
    ];
  };

  firewallOptOutSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {
        services.amp.firewallSync.enable = false;
        virtualisation.podman.enable = true;
      }
    ];
  };

  customHomeSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {services.amp.home = "/var/lib/amp";}
    ];
  };

  spacedHomeSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {services.amp.home = "/srv/AMP Data";}
    ];
  };

  bootstrapSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {
        services.amp.ads.bootstrap.adminPasswordFile = "/run/secrets/amp-admin-password";
        services.amp.ads.settings.createInContainers = true;
        virtualisation.podman.enable = true;
      }
    ];
  };

  settingsSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {
        services.amp.ads.settings = {
          createInContainers = true;
          containerManager = "Automatic";
          autoStartInstances = true;
          excludeNewInstancesFromFirewall = false;
          propagateAuthServer = true;
          defaultAuthServerUrl = "http://host.containers.internal:8080/";
          allowAnalytics = false;
          autoReportFatalExceptions = false;
          enhancedLicenceReporting = false;
          extraSettings."ADSModule.Defaults.DefaultReleaseStream" = "Mainline";
        };
      }
    ];
  };

  # Failed evaluations keep each public validation boundary independently
  # observable without booting a VM.
  tryHome = home:
    builtins.tryEval (
      (lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          baseModule
          {services.amp.home = home;}
        ];
      }).config.system.build.toplevel.drvPath
    );

  invalidStoreHome = tryHome "${fakeAmpinstmgr}";
  invalidStoreRoot = tryHome "/nix/store";
  invalidStoreRootDoubleSlash = tryHome "/nix//store";
  invalidStoreRootDot = tryHome "/nix/./store";
  invalidNestedHome = tryHome "/home/amp/data";

  # ADS validation fixtures use the same evaluation-only pattern.
  tryAds = ads:
    builtins.tryEval (
      (lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          baseModule
          {services.amp.ads = ads;}
        ];
      }).config.system.build.toplevel.drvPath
    );

  missingBootstrapPassword = tryAds {
    bootstrap = {};
  };
  invalidOperationMode = tryAds {
    bootstrap = {
      adminPasswordFile = "/run/secrets/amp-admin-password";
      operationMode = "Cluster";
    };
  };
  collidingSetting = tryAds {
    settings = {
      createInContainers = true;
      extraSettings."ADSModule.Defaults.UseDocker" = false;
    };
  };
  reservedMode = tryAds {
    settings.extraSettings."ADSModule.ADS.Mode" = "Standalone";
  };
  reservedBinding = tryAds {
    settings.extraSettings."Core.Webserver.IPBinding" = "127.0.0.1";
  };
  reservedPort = tryAds {
    settings.extraSettings."Core.Webserver.Port" = 8081;
  };
  malformedSetting = tryAds {
    settings.extraSettings.NoDot = "value";
  };
  tabSetting = tryAds {
    settings.extraSettings."ADSModule.Defaults.ContainerManager" = "Auto\tmatic";
  };
  carriageReturnSetting = tryAds {
    settings.extraSettings."ADSModule.Defaults.ContainerManager" = "Auto\rmatic";
  };
  newlineSetting = tryAds {
    settings.extraSettings."ADSModule.Defaults.ContainerManager" = "Auto\nmatic";
  };

  # Upstream service overrides and the default account
  contract = assert validSystem.config.systemd.services.ampinstmgr.restartIfChanged == false;
  assert validSystem.config.systemd.services.ampinstmgr.stopIfChanged == false;
  assert builtins.elem fakeAmpinstmgr validSystem.config.systemd.packages;
  assert validSystem.config.systemd.services.ampinstmgr.overrideStrategy == "asDropin";
  assert validSystem.config.systemd.services.amptasks.overrideStrategy == "asDropin";
  assert validSystem.config.systemd.timers.amptasks.overrideStrategy == "asDropin";
  assert validSystem.config.systemd.timers.amptasks.wantedBy == ["multi-user.target"];
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.TimeoutStartSec == 180;
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.TimeoutStopSec == 180;
  assert validSystem.config.systemd.services.amptasks.serviceConfig.KillMode == "process";
  assert builtins.elem "/run/wrappers" validSystem.config.systemd.services.ampinstmgr.path;
  assert builtins.elem "/run/wrappers" validSystem.config.systemd.services.amptasks.path;
  assert validSystem.config.users.groups ? amp;
  assert validSystem.config.users.users.amp.isSystemUser;
  assert validSystem.config.users.users.amp.group == "amp";
  assert validSystem.config.users.users.amp.home == "/home/amp";
  assert validSystem.config.users.users.amp.homeMode == "0700";
  assert validSystem.config.users.users.amp.createHome;
  assert validSystem.config.systemd.tmpfiles.settings."10-amp"."/bin/rm".L.argument
  == "${pkgs.coreutils}/bin/rm";
  assert validSystem.config.services.amp.firewallSync.enable;
  assert !validSystem.config.services.amp.firewallSync.podman;
  assert validSystem.config.systemd.services ? ampfirewall;
  assert validSystem.config.systemd.paths ? ampfirewall-ads;
  assert !(validSystem.config.systemd.services ? ampfirewall-watch);
  assert validSystem.config.systemd.timers ? ampfirewall;
  assert (validSystem.config.systemd.services.ampinstmgr.unitConfig.RequiresMountsFor or [])
  == ["/home/amp"];
  assert (validSystem.config.systemd.services.amptasks.unitConfig.RequiresMountsFor or [])
  == ["/home/amp"];
  assert (validSystem.config.systemd.services.ampfirewall.unitConfig.RequiresMountsFor or [])
  == ["/home/amp"];
  assert validSystem.config.systemd.services.ampfirewall.unitConfig.StartLimitIntervalSec == 0;
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.ExecCondition != [];
  assert validSystem.config.systemd.services.amptasks.serviceConfig.ExecCondition != [];
  # Disabling the module removes every module-owned account and unit.
  assert !disabledSystem.config.services.amp.firewallSync.enable;
  assert !disabledSystem.config.services.amp.firewallSync.podman;
  assert !(disabledSystem.config.users.groups ? amp);
  assert !(disabledSystem.config.users.users ? amp);
  assert !(disabledSystem.config.systemd.services ? ampfirewall);
  assert !(disabledSystem.config.systemd.paths ? ampfirewall-ads);
  # Rootless Podman defaults and service ordering
  assert podmanDefaultSystem.config.services.amp.firewallSync.enable;
  assert podmanDefaultSystem.config.services.amp.firewallSync.podman;
  assert podmanDefaultSystem.config.users.users.amp.autoSubUidGidRange;
  assert podmanDefaultSystem.config.users.users.amp.linger;
  assert builtins.elem pkgs.podman podmanDefaultSystem.config.systemd.services.ampinstmgr.path;
  assert builtins.elem pkgs.podman podmanDefaultSystem.config.systemd.services.amptasks.path;
  assert builtins.elem
  "linger-users.service"
  podmanDefaultSystem.config.systemd.services.ampinstmgr.after;
  assert builtins.elem
  "linger-users.service"
  podmanDefaultSystem.config.systemd.services.amptasks.after;
  assert builtins.elem
  "ampinstmgr.service"
  bootstrapSystem.config.systemd.services.ampads-bootstrap.after;
  assert builtins.elem
  "network-online.target"
  bootstrapSystem.config.systemd.services.ampads-bootstrap.after;
  assert builtins.elem
  "linger-users.service"
  bootstrapSystem.config.systemd.services.ampads-bootstrap.after;
  assert builtins.elem
  "ampads-bootstrap.service"
  bootstrapSystem.config.systemd.services.ampads-reconcile.after;
  assert builtins.elem
  "ampinstmgr.service"
  bootstrapSystem.config.systemd.services.ampads-reconcile.after;
  assert builtins.elem
  "linger-users.service"
  bootstrapSystem.config.systemd.services.ampads-reconcile.after;
  # Explicit firewall opt-out removes every synchronisation trigger.
  assert podmanDefaultSystem.config.systemd.services ? ampfirewall-watch;
  assert !firewallOptOutSystem.config.services.amp.firewallSync.enable;
  assert !firewallOptOutSystem.config.services.amp.firewallSync.podman;
  assert !(firewallOptOutSystem.config.systemd.services ? ampfirewall);
  assert !(firewallOptOutSystem.config.systemd.paths ? ampfirewall-ads);
  assert !(firewallOptOutSystem.config.systemd.services ? ampfirewall-watch);
  # Custom-home compatibility and path watching
  assert customHomeSystem.config.users.users.amp.home == "/var/lib/amp";
  assert customHomeSystem.config.systemd.paths.ampfirewall-ads.pathConfig.PathChanged
  == "/var/lib/amp/.ampdata/instances/ADS01/AMPConfig.conf";
  assert customHomeSystem.config.systemd.paths.ampfirewall-ads.pathConfig.Unit
  == "ampfirewall.service";
  assert customHomeSystem.config.systemd.services.ampfirewall.serviceConfig.ExecCondition
  != [];
  assert builtins.elem
  "/var/lib/amp:/home/amp"
  customHomeSystem.config.systemd.services.ampfirewall.serviceConfig.BindReadOnlyPaths;
  assert customHomeSystem.config.systemd.tmpfiles.settings."10-amp"."/home/amp".L.argument
  == "/var/lib/amp";
  assert spacedHomeSystem.config.systemd.tmpfiles.settings."10-amp"."/home/amp".L.argument
  == "/srv/AMP Data";
  assert !(validSystem.config.systemd.tmpfiles.settings."10-amp" ? "/home/amp");
  assert lib.all
  (warning: !(lib.hasInfix "services.amp.firewallSync may conflict" warning))
  validSystem.config.warnings;
  # Firewall bridge lifecycle, privilege boundary, and retry schedule
  assert podmanDefaultSystem.config.systemd.services ? ampfirewall;
  assert podmanDefaultSystem.config.systemd.services ? ampfirewall-bridge;
  assert podmanDefaultSystem.config.systemd.services ? ampfirewall-watch;
  assert podmanDefaultSystem.config.systemd.timers.ampfirewall.timerConfig.OnUnitActiveSec
  == [
    ""
    "5m"
  ];
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.overrideStrategy == "asDropin";
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.ExecStart
  == [
    ""
    "${fakeAmpinstmgr}/bin/ampinstmgr --silent updatefirewall amp"
  ];
  assert (podmanDefaultSystem.config.systemd.services.ampfirewall.environment.DOTNET_BUNDLE_EXTRACT_BASE_DIR or null)
  == "/var/cache/ampfirewall";
  assert (podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.CacheDirectory or null)
  == "ampfirewall";
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.CapabilityBoundingSet
  == ["CAP_DAC_READ_SEARCH" "CAP_NET_ADMIN" "CAP_NET_RAW"];
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.AmbientCapabilities
  == ["CAP_DAC_READ_SEARCH" "CAP_NET_ADMIN" "CAP_NET_RAW"];
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.NoNewPrivileges;
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.ProtectSystem
  == "strict";
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.ProtectHome
  == "read-only";
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.InaccessiblePaths
  == ["/root"];
  assert builtins.elem
  "/home/amp"
  podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.BindReadOnlyPaths;
  assert podmanDefaultSystem.config.systemd.services.ampfirewall.serviceConfig.PrivateTmp;
  assert podmanDefaultSystem.config.systemd.services.ampfirewall-bridge.serviceConfig.User
  == "root";
  assert podmanDefaultSystem.config.systemd.services.ampfirewall-bridge.serviceConfig.Group
  == "root";
  assert podmanDefaultSystem.config.systemd.timers.ampfirewall.overrideStrategy == "asDropin";
  assert podmanDefaultSystem.config.systemd.timers.ampfirewall.wantedBy == ["multi-user.target"];
  assert podmanDefaultSystem.config.systemd.timers.ampfirewall.timerConfig.OnBootSec
  == [
    "1m30s"
    "2m"
    "2m30s"
    "3m"
    "3m30s"
    "4m"
    "4m30s"
    "5m"
  ];
  assert lib.hasInfix
  "systemctl start --no-block ampfirewall.service"
  validSystem.config.networking.firewall.extraCommands;
  # Loader scope and rejected home paths
  assert !validSystem.config.programs.nix-ld.enable;
  assert !invalidStoreHome.success;
  assert !invalidStoreRoot.success;
  assert !invalidStoreRootDoubleSlash.success;
  assert !invalidStoreRootDot.success;
  assert !invalidNestedHome.success;
  # ADS bootstrap, reconciliation, and input validation
  assert bootstrapSystem.config.services.amp.ads.bootstrap.operationMode
  == "Standalone";
  assert bootstrapSystem.config.services.amp.ads.bootstrap.adminUsername
  == "admin";
  assert bootstrapSystem.config.services.amp.ads.bootstrap.bindAddress
  == "0.0.0.0";
  assert bootstrapSystem.config.services.amp.ads.bootstrap.port == 8080;
  assert settingsSystem.config.services.amp.ads.settings.createInContainers
  == true;
  assert settingsSystem.config.services.amp.ads.settings.defaultAuthServerUrl
  == "http://host.containers.internal:8080/";
  assert settingsSystem.config.services.amp.ads.settings.extraSettings
  == {"ADSModule.Defaults.DefaultReleaseStream" = "Mainline";};
  assert bootstrapSystem.config.systemd.services ? ampads-bootstrap;
  assert bootstrapSystem.config.systemd.services.ampads-bootstrap.serviceConfig.User
  == "amp";
  assert bootstrapSystem.config.systemd.services.ampads-bootstrap.serviceConfig.KillMode
  == "none";
  assert bootstrapSystem.config.systemd.services.ampads-bootstrap.serviceConfig.LoadCredential
  == ["admin-password:/run/secrets/amp-admin-password"];
  assert settingsSystem.config.systemd.services ? ampads-reconcile;
  assert settingsSystem.config.systemd.services.ampads-reconcile.serviceConfig.User
  == "amp";
  assert settingsSystem.config.systemd.services.ampads-reconcile.serviceConfig.KillMode
  == "none";
  assert settingsSystem.config.systemd.services.ampads-reconcile.serviceConfig.RemainAfterExit;
  assert !(validSystem.config.systemd.services ? ampads-bootstrap);
  assert !(validSystem.config.systemd.services ? ampads-reconcile);
  assert !(disabledSystem.config.systemd.services ? ampads-bootstrap);
  assert !(disabledSystem.config.systemd.services ? ampads-reconcile);
  assert !missingBootstrapPassword.success;
  assert !invalidOperationMode.success;
  assert !collidingSetting.success;
  assert !reservedMode.success;
  assert !reservedBinding.success;
  assert !reservedPort.success;
  assert !malformedSetting.success;
  assert !tabSetting.success;
  assert !carriageReturnSetting.success;
  assert !newlineSetting.success;
    pkgs.runCommand "amp-module-contract" {} ''
      touch "$out"
    '';

  vm = pkgs.testers.runNixOSTest {
    name = "amp-module";

    nodes = {
      machine = {
        imports = [baseModule];
        services.amp.firewallSync.enable = false;
      };
      firewall = {config, ...}: {
        imports = [baseModule];
        services.amp.home = "/var/lib/amp";
        virtualisation.podman.enable = true;
        services.amp.firewallSync = {
          enable = true;
          podman = true;
        };
        systemd.services.ampfirewall.serviceConfig.ReadWritePaths = ["/run/amp-test"];
        specialisation."firewall-sync-off".configuration = {
          services.amp.firewallSync.enable = lib.mkForce false;
          systemd.services.ampfirewall-watch.enable = false;
        };
        systemd.services.ampfirewall-watch.path = lib.mkIf config.services.amp.firewallSync.podman (
          lib.mkForce [
            pkgs.coreutils
            fakeJournalctl
            pkgs.jq
            pkgs.systemd
          ]
        );
      };
      bootstrap = {config, ...}: {
        imports = [baseModule];
        services.amp = {
          home = "/var/lib/amp-bootstrap";
          firewallSync.enable = false;
          startTimeout = 2;
          stopTimeout = 6;
          ads.bootstrap = {
            adminPasswordFile = "/run/amp-bootstrap/admin-password";
            licenceKeyFile = "/run/amp-bootstrap/licence-key";
          };
          ads.settings = {
            createInContainers = true;
            containerManager = "Automatic";
            autoStartInstances = true;
            excludeNewInstancesFromFirewall = false;
            propagateAuthServer = true;
            allowAnalytics = false;
            autoReportFatalExceptions = false;
            enhancedLicenceReporting = false;
          };
        };
        systemd.services =
          {
            ampads-bootstrap.wantedBy = lib.mkForce [];
          }
          // lib.optionalAttrs (
            config.services.amp.ads.settings.createInContainers != null
          ) {
            ampads-reconcile.wantedBy = lib.mkForce [];
          };
        specialisation."release-ads-settings".configuration = {
          services.amp.ads.settings = {
            createInContainers = lib.mkForce null;
            containerManager = lib.mkForce null;
            autoStartInstances = lib.mkForce null;
            excludeNewInstancesFromFirewall = lib.mkForce null;
            propagateAuthServer = lib.mkForce null;
            allowAnalytics = lib.mkForce null;
            autoReportFatalExceptions = lib.mkForce null;
            enhancedLicenceReporting = lib.mkForce null;
          };
        };
        specialisation."change-ads-settings".configuration = {
          services.amp.ads.settings.createInContainers = lib.mkForce false;
          systemd.services.ampads-reconcile.wantedBy =
            lib.mkOverride 40 ["sysinit-reactivation.target"];
        };
      };
    };

    testScript = ''
      start_all()

      for node in (machine, firewall, bootstrap):
          node.wait_for_unit("multi-user.target")
          node.wait_for_unit("ampinstmgr.service")
          node.wait_for_unit("amptasks.timer")

      bootstrap.succeed(
          "systemctl show ampads-reconcile.service -P Requires "
          "| grep -Fw ampads-bootstrap.service"
      )

      # Phase 1: unattended ADS bootstrap and recovery
      with subtest("credential-backed bootstrap is resumable and idempotent"):
          bootstrap.succeed(
              "install -d -m 0700 /run/amp-bootstrap "
              "&& printf '%s\\n' test-admin-password "
              "> /run/amp-bootstrap/admin-password "
              "&& printf '%s\\n' invalid "
              "> /run/amp-bootstrap/licence-key "
              "&& chmod 0400 /run/amp-bootstrap/*"
          )
          bootstrap.fail("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "grep -Fx in-progress "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state"
          )
          bootstrap.succeed(
              "test $(grep -c 'argv=create <redacted-bootstrap-arguments>' "
              "/run/amp-test/invocations) = 1"
          )
          bootstrap.succeed(
              "test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.start-on-boot "
              "&& grep -F 'argv=setstartboot ADS01 true' "
              "/run/amp-test/invocations"
          )
          bootstrap.succeed(
              "! grep -F test-admin-password /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "! grep -F invalid /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "printf '%s\\n' test-licence-key "
              "> /run/amp-bootstrap/licence-key "
              "&& chmod 0400 /run/amp-bootstrap/licence-key "
              "&& systemctl reset-failed ampads-bootstrap.service "
              "&& systemctl start ampads-bootstrap.service"
          )
          bootstrap.succeed(
              "grep -Fx complete "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state"
          )
          bootstrap.succeed(
              "grep -F 'argv=startinstance ADS01' /run/amp-test/invocations "
              "&& test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running"
          )
          bootstrap.succeed(
              "test $(grep -c 'argv=create <redacted-bootstrap-arguments>' "
              "/run/amp-test/invocations) = 1"
          )
          bootstrap.succeed("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "test $(grep -c 'argv=create <redacted-bootstrap-arguments>' "
              "/run/amp-test/invocations) = 1"
          )
          bootstrap.succeed(
              "test $(grep -c 'argv=reactivate ADS01 <redacted-licence-key>' "
              "/run/amp-test/invocations) = 2"
          )
          bootstrap.succeed(
              "grep -Fx 'Defaults.NewInstanceKey=test-licence-key' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& ! grep -F test-licence-key /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "grep -Fx 'Defaults.ContainerManager=Automatic' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& grep -Fx 'ADS.AutostartInstances=True' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& grep -Fx 'Defaults.ExcludeFromFirewall=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& grep -Fx 'Defaults.PropagateAuthServer=True' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& grep -Fx 'Privacy.AllowAnalytics=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/AMPConfig.conf "
              "&& grep -Fx 'Privacy.AutoReportFatalExceptions=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/AMPConfig.conf "
              "&& grep -Fx 'Privacy.EnhancedLicenceReporting=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/AMPConfig.conf"
          )

      with subtest("complete bootstrap state still requires registered ADS"):
          bootstrap.succeed(
              "mv /var/lib/amp-bootstrap/.ampdata/instances/ADS01/.registered "
              "/run/amp-test/registered "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-bootstrap.service")
          bootstrap.succeed(
              "grep -Fx complete "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state "
              "&& ! grep -F 'argv=create ' /run/amp-test/invocations "
              "&& mv /run/amp-test/registered "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.registered"
          )

      with subtest("complete bootstrap state propagates status failure"):
          bootstrap.succeed(
              "touch /run/amp-test/status-fail "
              "&& systemctl reset-failed ampads-bootstrap.service"
          )
          bootstrap.fail("systemctl restart ampads-bootstrap.service")
          bootstrap.succeed(
              "rm /run/amp-test/status-fail "
              "&& grep -Fx complete "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state"
          )

      with subtest("in-progress registered bootstrap starts stopped ADS"):
          bootstrap.succeed(
              "systemctl reset-failed ampads-bootstrap.service "
              "&& kill \"$(cat "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running-pid)\" "
              "&& rm "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running-pid "
              "&& printf '%s\\n' in-progress "
              "> /var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl restart ampads-bootstrap.service "
              "&& grep -F 'argv=startinstance ADS01' "
              "/run/amp-test/invocations "
              "&& grep -Fx complete "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state"
          )

      with subtest("bootstrap refuses ambiguous or incomplete state"):
          bootstrap.succeed(
              "kill \"$(cat "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running-pid)\" "
              "&& rm /var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state"
          )
          bootstrap.fail("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "rm -rf /var/lib/amp-bootstrap/.ampdata/instances/ADS01 "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp"
          )
          bootstrap.succeed(
              "install -d "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01"
          )
          bootstrap.fail("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "test -d /var/lib/amp-bootstrap/.ampdata/instances/ADS01"
          )

      with subtest("bootstrap validates credentials before changing state"):
          bootstrap.succeed(
              "rm -rf /var/lib/amp-bootstrap/.ampdata/instances/ADS01 "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp "
              "&& printf '%s\\n' test-admin-password "
              "> /run/amp-bootstrap/admin-password "
              "&& chmod 0400 /run/amp-bootstrap/admin-password "
              "&& touch /run/amp-test/status-fail "
              "&& systemctl reset-failed ampads-bootstrap.service"
          )
          bootstrap.fail("systemctl restart ampads-bootstrap.service")
          bootstrap.succeed(
              "rm /run/amp-test/status-fail "
              "&& test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state "
              "&& test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01 "
              "&& rm /run/amp-bootstrap/admin-password"
          )
          bootstrap.fail("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state "
              "&& test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01"
          )
          bootstrap.succeed(
              "install -m 0400 /dev/null "
              "/run/amp-bootstrap/admin-password"
          )
          bootstrap.fail("systemctl start ampads-bootstrap.service")
          bootstrap.succeed(
              "test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/bootstrap-state "
              "&& test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01"
          )

      # Phase 2: declarative ADS settings and lifecycle recovery
      with subtest("managed ADS settings reconcile only when they drift"):
          bootstrap.succeed(
              "printf '%s\\n' test-admin-password "
              "> /run/amp-bootstrap/admin-password "
              "&& printf '%s\\n' test-licence-key "
              "> /run/amp-bootstrap/licence-key "
              "&& chmod 0400 /run/amp-bootstrap/* "
              "&& systemctl reset-failed ampads-bootstrap.service "
              "&& systemctl start ampads-bootstrap.service "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl start ampads-reconcile.service"
          )
          bootstrap.succeed(
              "test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running"
          )
          bootstrap.succeed(
              "kill -0 \"$(cat "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running-pid)\""
          )
          bootstrap.succeed(
              "! grep -F 'argv=reconfigureinstance ADS01' "
              "/run/amp-test/invocations"
          )
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl restart ampads-reconcile.service"
          )
          bootstrap.succeed(
              "grep -Fx 'Defaults.UseDocker=True' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp"
          )
          bootstrap.succeed(
              "grep -F 'argv=stopinstance ADS01' /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "grep -F 'argv=reconfigureinstance ADS01 "
              "+ADSModule.Defaults.UseDocker True' "
              "/run/amp-test/invocations"
          )
          bootstrap.succeed(
              "grep -F 'argv=startinstance ADS01' /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "truncate -s 0 /run/amp-test/invocations "
              "&& systemctl restart ampads-reconcile.service "
              "&& ! grep -Eq 'argv=(stopinstance|startinstance|reconfigureinstance)' "
              "/run/amp-test/invocations"
          )

      with subtest("reconciliation propagates registration status failure"):
          bootstrap.succeed(
              "touch /run/amp-test/status-fail "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "rm /run/amp-test/status-fail "
              "&& ! grep -Eq 'argv=(stopinstance|startinstance|reconfigureinstance)' "
              "/run/amp-test/invocations"
          )

      with subtest("reconciliation propagates running status failure"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/status-fail-after-one "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl reset-failed ampads-reconcile.service"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "rm -f /run/amp-test/status-fail-next "
              "&& ! grep -Eq 'argv=(stopinstance|startinstance|reconfigureinstance)' "
              "/run/amp-test/invocations"
          )

      with subtest("reconciliation restores ADS after mutation failure"):
          bootstrap.succeed(
              "touch /run/amp-test/reconfigure-fail "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running"
          )
          bootstrap.succeed(
              "rm /run/amp-test/reconfigure-fail "
              "&& systemctl reset-failed ampads-reconcile.service "
              "&& systemctl restart ampads-reconcile.service"
          )

      with subtest("reconciliation recovers when stop fails after taking effect"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/stop-fail-after-effect "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "&& grep -F 'argv=stopinstance ADS01' /run/amp-test/invocations "
              "&& grep -F 'argv=startinstance ADS01' /run/amp-test/invocations "
              "&& rm /run/amp-test/stop-fail-after-effect "
              "&& systemctl reset-failed ampads-reconcile.service "
              "&& systemctl restart ampads-reconcile.service"
          )

      with subtest("reconciliation waits for asynchronous ADS restart"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/start-async "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl restart ampads-reconcile.service "
              "&& test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "&& test $(cat "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.status-attempts"
              ") -ge 2 "
              "&& rm /run/amp-test/start-async"
          )

      with subtest("ADS mutations share one lifecycle lock"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.succeed(
              "systemd-run --unit=amp-test-lock-holder "
              "${pkgs.util-linux}/bin/flock "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/lifecycle.lock "
              "${pkgs.coreutils}/bin/sleep 5; "
              "locked=false; for attempt in $(seq 1 20); do "
              "if ! ${pkgs.util-linux}/bin/flock --nonblock "
              "/var/lib/amp-bootstrap/.ampdata/.nix-amp/lifecycle.lock "
              "true; then locked=true; break; fi; sleep 0.1; done; "
              "test \"$locked\" = true"
          )
          bootstrap.succeed(
              "started=$(date +%s) "
              "&& systemctl restart ampads-reconcile.service "
              "&& elapsed=$(($(date +%s) - started)) "
              "&& test \"$elapsed\" -ge 3 "
              "&& systemctl is-active --quiet ampads-reconcile.service "
              "&& grep -F 'argv=reconfigureinstance ADS01' "
              "/run/amp-test/invocations"
          )

      with subtest("reconciliation honours the ADS stop timeout"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/stop-delay "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& systemctl restart ampads-reconcile.service "
              "&& test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "&& grep -F 'argv=stopinstance ADS01' /run/amp-test/invocations "
              "&& rm /run/amp-test/stop-delay"
          )

      with subtest("reconciliation kills a hung AMP stop command"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/stop-hang "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "pid=$(cat /run/amp-test/stop-hang-pid) "
              "&& ! kill -0 \"$pid\" 2>/dev/null "
              "&& test -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "&& rm /run/amp-test/stop-hang /run/amp-test/stop-hang-pid "
              "&& systemctl reset-failed ampads-reconcile.service "
              "&& systemctl restart ampads-reconcile.service"
          )

      with subtest("reconciliation fails when ADS never restarts"):
          bootstrap.succeed(
              "sed -i 's/^Defaults.UseDocker=.*/Defaults.UseDocker=False/' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& touch /run/amp-test/start-never "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "test ! -e "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.running "
              "&& test $(grep -c 'argv=startinstance ADS01' "
              "/run/amp-test/invocations) = 2 "
              "&& rm /run/amp-test/start-never "
              "&& su - amp -c 'NIX_LD=unused "
              "NIX_LD_LIBRARY_PATH=unused TERM=xterm-256color "
              "ampinstmgr startinstance ADS01' "
              "&& systemctl reset-failed ampads-reconcile.service "
              "&& systemctl restart ampads-reconcile.service"
          )

      with subtest("managed settings command skips an unregistered ADS"):
          bootstrap.succeed(
              "mv /var/lib/amp-bootstrap/.ampdata/instances/ADS01/.registered "
              "/run/amp-test/registered "
              "&& truncate -s 0 /run/amp-test/invocations "
              "&& reconcile=$(sed -n 's/^ExecStart=//p' "
              "/etc/systemd/system/ampads-reconcile.service) "
              "&& su - amp -c 'NIX_LD=unused "
              "NIX_LD_LIBRARY_PATH=unused TERM=xterm-256color '\"$reconcile\" "
              "&& ! grep -Eq 'argv=(stopinstance|startinstance|reconfigureinstance)' "
              "/run/amp-test/invocations "
              "&& mv /run/amp-test/registered "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/.registered"
          )

      with subtest("duplicate managed keys fail before mutation"):
          bootstrap.succeed(
              "printf '%s\\n' 'Defaults.UseDocker=True' "
              ">> /var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& truncate -s 0 /run/amp-test/invocations"
          )
          bootstrap.fail("systemctl restart ampads-reconcile.service")
          bootstrap.succeed(
              "! grep -Eq 'argv=(stopinstance|startinstance|reconfigureinstance)' "
              "/run/amp-test/invocations"
          )
          bootstrap.succeed(
              "sed -i '$d' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp"
          )

      with subtest("changed generation retries failed settings reconciliation"):
          bootstrap.succeed(
              "truncate -s 0 /run/amp-test/invocations "
              "&& /run/current-system/specialisation/change-ads-settings/"
              "bin/switch-to-configuration test "
              "&& grep -Fx 'Defaults.UseDocker=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp "
              "&& grep -F 'argv=reconfigureinstance ADS01 "
              "+ADSModule.Defaults.UseDocker False' "
              "/run/amp-test/invocations"
          )

      with subtest("removing a managed setting releases it without reverting"):
          bootstrap.succeed(
              "/run/booted-system/specialisation/release-ads-settings/"
              "bin/switch-to-configuration test"
          )
          bootstrap.succeed(
              "test -z \"$(systemctl show ampads-reconcile.service -P ExecStart)\""
          )
          bootstrap.succeed(
              "grep -Fx 'Defaults.UseDocker=False' "
              "/var/lib/amp-bootstrap/.ampdata/instances/ADS01/ADSModule.kvp"
          )

      # Phase 3: core account, package, and upstream service integration
      with subtest("account, state, config, and compatibility environment"):
          machine.succeed("test $(stat -c %U:%G /home/amp) = amp:amp")
          machine.succeed("test $(stat -c %a /home/amp) = 700")
          firewall.succeed("test $(readlink -f /home/amp) = /var/lib/amp")
          machine.succeed(
              r"""getent passwd amp | cut -d: -f6,7 """
              r"""| grep -F '/home/amp:/run/current-system/sw/bin/bash'"""
          )
          machine.succeed(
              "su - amp -c 'command -v ampinstmgr' "
              "| grep -F /run/current-system/sw/bin/ampinstmgr"
          )
          machine.succeed(
              "cmp /etc/ampinstmgr.conf "
              "${fakeAmpinstmgr}/share/ampinstmgr/ampinstmgr.conf"
          )
          machine.succeed(
              r"""readlink -f /lib64/ld-linux-x86-64.so.2 """
              r"""| grep -E '^/nix/store/.*-nix-ld-[^/]+/bin/nix-ld$'"""
          )
          machine.succeed(
              "touch /tmp/amp-rm-test "
              "&& /bin/rm /tmp/amp-rm-test "
              "&& test ! -e /tmp/amp-rm-test"
          )
          machine.succeed(
              r"""grep -E 'uid=[0-9]+ gid=[0-9]+ capabilities=[0-9a-f]+ root_home=hidden home=/home/amp """
              r"""cwd=${fakeAmpinstmgr}/opt/cubecoders/amp """
              r"""term=xterm-256color nix_ld=/nix/store/[^ ]+ """
              r"""libraries=/nix/store/[^ ]+ manager=${fakeAmpinstmgr}/bin/ampinstmgr """
              r"""xdg= docker= """
              r"""argv=startboot true' """
              "/run/amp-test/invocations"
          )

      with subtest("default lifecycle and pending-task child"):
          machine.succeed(
              "systemctl cat ampinstmgr.service "
              "| grep -F 'Description=Upstream AMP Instance Manager'"
          )
          machine.succeed(
              "systemctl cat amptasks.timer "
              "| grep -F 'Description=Upstream AMP Pending Tasks'"
          )
          machine.succeed("systemctl cat ampfirewall.service")
          machine.succeed("systemctl cat ampfirewall.timer")
          machine.fail("systemctl is-active --quiet ampfirewall.timer")
          machine.succeed(
              "test $(systemctl show amptasks.service -P KillMode) = process"
          )
          machine.succeed("systemctl start amptasks.service")
          machine.succeed("test -s /run/amp-test/pending-child.pid")
          machine.succeed("kill -0 $(cat /run/amp-test/pending-child.pid)")
          machine.succeed(
              "grep -F 'argv=ProcessPendingTasks' /run/amp-test/invocations"
          )
          machine.succeed("systemctl stop ampinstmgr.service")
          machine.succeed("grep -F 'argv=stopall' /run/amp-test/invocations")
          machine.succeed("systemctl start ampinstmgr.service")
          machine.succeed(
              "test $(grep -c 'argv=startboot true' /run/amp-test/invocations) = 2"
          )
          machine.succeed("kill $(cat /run/amp-test/pending-child.pid)")

      with subtest("default home rejects a stale custom-home alias"):
          machine.succeed("systemctl stop ampinstmgr.service")
          machine.succeed("mv /home/amp /home/amp.default")
          machine.succeed("ln -s /home/amp.default /home/amp")
          machine.succeed("systemctl start ampinstmgr.service")
          machine.fail("systemctl is-active --quiet ampinstmgr.service")
          machine.succeed(
              "test $(grep -c 'argv=startboot true' /run/amp-test/invocations) = 2"
          )
          machine.succeed("rm /home/amp")
          machine.succeed("mv /home/amp.default /home/amp")
          machine.succeed("systemctl start ampinstmgr.service")

      # Phase 4: firewall bridge and rootless Podman integration
      with subtest("opt-in firewall synchronisation"):
          firewall.wait_for_unit("ampfirewall-bridge.service")
          firewall.wait_for_unit("ampfirewall.timer")
          firewall.succeed(
              "test $(stat -c %U:%G "
              "/run/ampfirewall-bridge/input-policy) = root:root"
          )
          firewall.succeed(
              "test $(iptables -S nixos-fw-refuse "
              "| grep -c 'nix-amp-firewall-bridge') = 1"
          )
          firewall.succeed(
              "iptables -S INPUT | grep -Fx -- '-P INPUT DROP'"
          )
          firewall.succeed(
              "systemctl cat ampfirewall.timer > /tmp/ampfirewall.timer"
          )
          firewall.succeed(
              "grep -F 'Description=Upstream AMP Firewall' "
              "/tmp/ampfirewall.timer"
          )
          firewall.succeed(
              "test $(grep -c '^OnBootSec=' /tmp/ampfirewall.timer) = 9"
          )
          firewall.succeed(
              "grep -F 'OnBootSec=1m' /tmp/ampfirewall.timer"
          )
          for delay in (
              "1m30s",
              "2m",
              "2m30s",
              "3m",
              "3m30s",
              "4m",
              "4m30s",
              "5m",
          ):
              firewall.succeed(
                  f"grep -F 'OnBootSec={delay}' /tmp/ampfirewall.timer"
              )
          firewall.succeed(
              "grep -Fx 'OnUnitActiveSec=' /tmp/ampfirewall.timer"
          )
          firewall.succeed(
              "test $(grep -c '^OnUnitActiveSec=5m$' "
              "/tmp/ampfirewall.timer) = 2"
          )
          firewall.succeed(
              "grep -Fx 'AccuracySec=1s' /tmp/ampfirewall.timer"
          )
          firewall.succeed("systemctl start ampfirewall.service")
          firewall.succeed(
              r"""grep -E 'uid=0 gid=0 capabilities=0000000000003004 root_home=hidden home=/var/lib/amp """
              r"""cwd=${fakeAmpinstmgr}/opt/cubecoders/amp .*"""
              r"""xdg= docker= """
              r"""argv=--silent updatefirewall amp' """
              "/run/amp-test/invocations"
          )

      with subtest("ADS configuration changes reconcile immediately"):
          firewall.wait_for_unit("ampfirewall-ads.path")
          firewall.succeed(
              "systemctl stop ampfirewall.timer "
              "ampfirewall-watch.service ampfirewall.service"
          )
          firewall.succeed("truncate -s 0 /run/amp-test/invocations")
          firewall.succeed(
              "install -d -o amp -g amp "
              "/var/lib/amp/.ampdata/instances/ADS01"
          )
          firewall.succeed(
              "echo 'Webserver.Port=8080' "
              "> /var/lib/amp/.ampdata/instances/ADS01/AMPConfig.conf"
          )
          firewall.wait_until_succeeds(
              "test $(grep -c 'argv=--silent updatefirewall amp' "
              "/run/amp-test/invocations) = 1",
              timeout=10,
          )
          firewall.succeed(
              "echo 'Webserver.Port=8081' "
              ">> /var/lib/amp/.ampdata/instances/ADS01/AMPConfig.conf"
          )
          firewall.wait_until_succeeds(
              "test $(grep -c 'argv=--silent updatefirewall amp' "
              "/run/amp-test/invocations) = 2",
              timeout=10,
          )
          firewall.sleep(2)
          firewall.succeed(
              "test $(grep -c 'argv=--silent updatefirewall amp' "
              "/run/amp-test/invocations) = 2"
          )

      with subtest("AMP Podman events reconcile immediately"):
          firewall.succeed(
              "systemctl stop ampfirewall.timer "
              "ampfirewall-watch.service ampfirewall.service"
          )
          firewall.succeed("truncate -s 0 /run/amp-test/invocations")
          firewall.succeed("systemctl start ampfirewall-watch.service")
          firewall.wait_until_succeeds(
              "grep -F 'argv=--silent updatefirewall amp' "
              "/run/amp-test/invocations",
              timeout=10,
          )
          firewall.succeed(
              "test $(grep -c 'argv=--silent updatefirewall amp' "
              "/run/amp-test/invocations) = 1"
          )

      with subtest("rootless Podman integration is automatic"):
          uid = firewall.succeed("id -u amp").strip()
          firewall.succeed("grep -E '^amp:[0-9]+:65536$' /etc/subuid")
          firewall.succeed("grep -E '^amp:[0-9]+:65536$' /etc/subgid")
          firewall.succeed("test -e /var/lib/systemd/linger/amp")
          firewall.succeed("systemctl restart ampinstmgr.service")
          firewall.succeed(
              f"grep -E 'xdg=/run/user/{uid} "
              f"docker=unix:///run/user/{uid}/podman/podman.sock .*"
              "argv=startboot true' "
              "/run/amp-test/invocations"
          )

      with subtest("native AMP rules remain effective across firewall reloads"):
          firewall.succeed(
              "systemd-run --unit=amp-allowed-probe "
              "${pkgs.python3}/bin/python -m http.server 18080 "
              "--bind 0.0.0.0"
          )
          firewall.succeed(
              "systemd-run --unit=amp-blocked-probe "
              "${pkgs.python3}/bin/python -m http.server 18081 "
              "--bind 0.0.0.0"
          )
          firewall.wait_for_open_port(18080)
          firewall.wait_for_open_port(18081)
          firewall.succeed(
              "iptables -A INPUT -p tcp --dport 18080 "
              "-m comment --comment AMP:Probe -j ACCEPT"
          )
          firewall_ip = firewall.succeed(
              "ip -4 -o address show dev eth1 "
              "| cut -d' ' -f7 | cut -d/ -f1"
          ).strip()
          machine.succeed(
              f"${pkgs.curl}/bin/curl --fail --max-time 5 "
              f"http://{firewall_ip}:18080/"
          )
          machine.fail(
              f"${pkgs.curl}/bin/curl --fail --max-time 2 "
              f"http://{firewall_ip}:18081/"
          )
          firewall.succeed("systemctl reload firewall.service")
          machine.succeed(
              f"${pkgs.curl}/bin/curl --fail --max-time 5 "
              f"http://{firewall_ip}:18080/"
          )
          machine.fail(
              f"${pkgs.curl}/bin/curl --fail --max-time 2 "
              f"http://{firewall_ip}:18081/"
          )

      with subtest("missing bridge state never weakens the input policy"):
          firewall.succeed(
              "rm /run/ampfirewall-bridge/input-policy"
          )
          firewall.succeed("iptables -P INPUT DROP")
          firewall.succeed("systemctl stop ampfirewall-bridge.service")
          firewall.succeed(
              "iptables -S INPUT | grep -Fx -- '-P INPUT DROP'"
          )
          firewall.succeed("iptables -P INPUT ACCEPT")
          firewall.succeed("systemctl start ampfirewall-bridge.service")

      with subtest("disabling synchronisation removes the firewall bridge"):
          firewall.succeed(
              "/run/current-system/specialisation/firewall-sync-off/"
              "bin/switch-to-configuration test"
          )
          firewall.fail(
              "systemctl is-active --quiet ampfirewall-bridge.service"
          )
          firewall.succeed(
              "! iptables -S nixos-fw-refuse "
              "| grep -F 'nix-amp-firewall-bridge'"
          )
          firewall.succeed("! iptables -S INPUT | grep -F 'AMP:Probe'")
          firewall.succeed(
              "iptables -S INPUT | grep -Fx -- '-P INPUT ACCEPT'"
          )
          firewall.succeed("systemctl reload firewall.service")
          firewall.succeed(
              "iptables -S INPUT | grep -Fx -- '-P INPUT ACCEPT'"
          )
          machine.fail(
              f"${pkgs.curl}/bin/curl --fail --max-time 2 "
              f"http://{firewall_ip}:18080/"
          )
    '';
  };
in {
  inherit contract vm;
}
