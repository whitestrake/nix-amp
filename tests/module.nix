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
            'uid=%s gid=%s home=%s term=%s nix_ld=%s libraries=%s argv=%s%s\n' \
            "$(id -u)" \
            "$(id -g)" \
            "$HOME" \
            "$TERM" \
            "$NIX_LD" \
            "$NIX_LD_LIBRARY_PATH" \
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
    ];
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
          interval = "7m";
        };
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
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.TimeoutStartSec == 180;
  assert validSystem.config.systemd.services.ampinstmgr.serviceConfig.TimeoutStopSec == 180;
  assert validSystem.config.systemd.services.amptasks.serviceConfig.KillMode == "process";
  assert !(validSystem.config.systemd.services ? ampfirewall);
  assert !(validSystem.config.systemd.timers ? ampfirewall);
  assert firewallSystem.config.systemd.services ? ampfirewall;
  assert firewallSystem.config.systemd.timers.ampfirewall.timerConfig.OnUnitActiveSec == "7m";
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
        services.amp.firewallSync.enable = true;
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
              "cmp /etc/ampinstmgr.conf "
              "${fakeAmpinstmgr}/share/ampinstmgr/ampinstmgr.conf"
          )
          machine.succeed(
              r"""readlink -f /lib64/ld-linux-x86-64.so.2 """
              r"""| grep -E '^/nix/store/.*-nix-ld-[^/]+/bin/nix-ld$'"""
          )
          machine.succeed(
              r"""grep -E 'uid=[0-9]+ gid=[0-9]+ home=/home/amp """
              r"""term=xterm-256color nix_ld=/nix/store/[^ ]+ """
              r"""libraries=/nix/store/[^ ]+ argv=startboot true' """
              "/run/amp-test/invocations"
          )

      with subtest("default lifecycle and pending-task child"):
          machine.fail("systemctl cat ampfirewall.service")
          machine.fail("systemctl cat ampfirewall.timer")
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
          firewall.succeed("systemctl start ampfirewall.service")
          firewall.succeed(
              r"""grep -E 'uid=0 gid=0 .*argv=--silent updatefirewall amp' """
              "/run/amp-test/invocations"
          )
    '';
  };
in {
  inherit contract vm;
}
