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

          printf \
            'uid=%s gid=%s home=%s cwd=%s term=%s nix_ld=%s libraries=%s manager=%s xdg=%s docker=%s argv=%s%s\n' \
            "$(id -u)" \
            "$(id -g)" \
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
      "d /run/amp-test 0777 root root -"
      "f /run/amp-test/invocations 0666 root root -"
    ];

    system.stateVersion = "26.05";
  };

  validSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [baseModule];
  };

  firewallSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {
        networking.firewall.enable = false;
        services.amp.firewallSync = {
          enable = true;
          podman = true;
        };
      }
    ];
  };

  firewallWithoutPodmanSystem = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      baseModule
      {
        networking.firewall.enable = false;
        services.amp.firewallSync.enable = true;
      }
    ];
  };

  invalidStoreHome = builtins.tryEval (
    (lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        baseModule
        {services.amp.home = "${fakeAmpinstmgr}";}
      ];
    }).config.system.build.toplevel.drvPath
  );

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
  assert !(validSystem.config.systemd.services ? ampfirewall);
  assert !(validSystem.config.systemd.services ? ampfirewall-watch);
  assert !(validSystem.config.systemd.timers ? ampfirewall);
  assert firewallSystem.config.systemd.services ? ampfirewall;
  assert firewallSystem.config.systemd.services ? ampfirewall-watch;
  assert firewallSystem.config.systemd.timers.ampfirewall.timerConfig.OnUnitActiveSec
  == [
    ""
    "5m"
  ];
  assert firewallSystem.config.systemd.services.ampfirewall.overrideStrategy == "asDropin";
  assert firewallSystem.config.systemd.services.ampfirewall.serviceConfig.ExecStart
  == [
    ""
    "${fakeAmpinstmgr}/bin/ampinstmgr --silent updatefirewall amp"
  ];
  assert firewallSystem.config.systemd.timers.ampfirewall.overrideStrategy == "asDropin";
  assert firewallSystem.config.systemd.timers.ampfirewall.wantedBy == ["multi-user.target"];
  assert firewallSystem.config.systemd.timers.ampfirewall.timerConfig.OnBootSec
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
  firewallWithoutPodmanSystem.config.networking.firewall.extraCommands;
  assert !validSystem.config.programs.nix-ld.enable;
  assert !invalidStoreHome.success;
    pkgs.runCommand "amp-module-contract" {} ''
      touch "$out"
    '';

  vm = pkgs.testers.runNixOSTest {
    name = "amp-module";

    nodes = {
      machine = baseModule;
      firewall = {
        imports = [baseModule];
        networking.firewall.enable = false;
        services.amp.firewallSync = {
          enable = true;
          podman = true;
        };
        systemd.services.ampfirewall-watch.path = lib.mkForce [
          pkgs.coreutils
          fakeJournalctl
          pkgs.jq
          pkgs.systemd
        ];
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
              r"""grep -E 'uid=[0-9]+ gid=[0-9]+ home=/home/amp """
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

      with subtest("opt-in firewall synchronization"):
          firewall.wait_for_unit("ampfirewall.timer")
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
              r"""grep -E 'uid=0 gid=0 home=/home/amp """
              r"""cwd=${fakeAmpinstmgr}/opt/cubecoders/amp .*"""
              r"""xdg= docker= """
              r"""argv=--silent updatefirewall amp' """
              "/run/amp-test/invocations"
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
    '';
  };
in {
  inherit contract vm;
}
