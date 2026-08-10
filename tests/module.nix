{
  ampModule,
  lib,
  pkgs,
}: let
  fakeAmpinstmgr = pkgs.symlinkJoin {
    name = "fake-ampinstmgr";
    paths = [
      (pkgs.writeShellApplication {
        name = "ampinstmgr";
        runtimeInputs = [pkgs.coreutils];
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
            "''${*:+ $*}" \
            >> /run/amp-test/invocations

          if test "$operation" = ProcessPendingTasks; then
            sleep 300 &
            echo "$!" > /run/amp-test/pending-child.pid
          fi
        '';
      })
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
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.ExecCondition != [];
  assert validSystem.config.systemd.services.amptasks.serviceConfig.ExecCondition != [];
  assert !disabledSystem.config.services.amp.firewallSync.enable;
  assert !disabledSystem.config.services.amp.firewallSync.podman;
  assert !(disabledSystem.config.users.groups ? amp);
  assert !(disabledSystem.config.users.users ? amp);
  assert !(disabledSystem.config.systemd.services ? ampfirewall);
  assert !(disabledSystem.config.systemd.paths ? ampfirewall-ads);
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
  assert podmanDefaultSystem.config.systemd.services ? ampfirewall-watch;
  assert !firewallOptOutSystem.config.services.amp.firewallSync.enable;
  assert !firewallOptOutSystem.config.services.amp.firewallSync.podman;
  assert !(firewallOptOutSystem.config.systemd.services ? ampfirewall);
  assert !(firewallOptOutSystem.config.systemd.paths ? ampfirewall-ads);
  assert !(firewallOptOutSystem.config.systemd.services ? ampfirewall-watch);
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
  assert !(validSystem.config.systemd.tmpfiles.settings ? "10-amp");
  assert lib.all
  (warning: !(lib.hasInfix "services.amp.firewallSync may conflict" warning))
  validSystem.config.warnings;
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
  assert !validSystem.config.programs.nix-ld.enable;
  assert !invalidStoreHome.success;
  assert !invalidStoreRoot.success;
  assert !invalidStoreRootDoubleSlash.success;
  assert !invalidStoreRootDot.success;
  assert !invalidNestedHome.success;
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
    };

    testScript = ''
      start_all()

      for node in (machine, firewall):
          node.wait_for_unit("multi-user.target")
          node.wait_for_unit("ampinstmgr.service")
          node.wait_for_unit("amptasks.timer")

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

      with subtest("opt-in firewall synchronization"):
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

      with subtest("disabling synchronization removes the firewall bridge"):
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
