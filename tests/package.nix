{
  pkgs,
  ampinstmgr,
}: let
  contract =
    pkgs.runCommand "ampinstmgr-package-contract"
    {
      nativeBuildInputs = with pkgs; [
        file
        glibc.bin
        gzip
        patchelf
        shadow
      ];
    }
    ''
      set -euxo pipefail

      test "$(id -u)" -ne 0

      archive="$TMPDIR/archive"
      mkdir "$archive"
      tar -xzf ${ampinstmgr.src} -C "$archive"
      cd "$archive"

      required=(
        etc/ampinstmgr.conf
        etc/systemd/system/ampfirewall.service
        etc/systemd/system/ampfirewall.timer
        etc/systemd/system/ampinstmgr.service
        etc/systemd/system/amptasks.service
        etc/systemd/system/amptasks.timer
        opt/cubecoders/amp/ampinstmgr
        opt/cubecoders/amp/ioredir.so
        opt/cubecoders/amp/plugins/ADSModule.dll
        opt/cubecoders/amp/shared/WebRoot/installState.json
      )
      for path in "''${required[@]}"; do
        test -e "$path"
      done

      test "$(stat -c %a opt/cubecoders/amp/ampinstmgr)" = 755
      test "$(stat -c %a opt/cubecoders/amp/ioredir.so)" = 755
      test "$(readlink usr/bin/ampinstmgr)" = /opt/cubecoders/amp/ampinstmgr
      test "$(readlink usr/bin/getamp)" = /opt/cubecoders/amp/getamp

      sha256sum -c <<'HASHES'
      73baf27046da9e0f048cb5da52a2fb01360afefb7094194baee1d194fd23f7fc  etc/ampinstmgr.conf
      b553ea67eaa2cb538a28d56bf78a99ce6ba475e17ec11f3da666865c61d670ae  etc/systemd/system/ampfirewall.service
      dbc627bd89c6b541e78865f45e41c4fc2df2f40786a5a05f6ce1f4508d3a99f7  etc/systemd/system/ampfirewall.timer
      6fc12dc40171d03fdb9531f744f98ec3282ec9213700b2fa765495dfc316569a  etc/systemd/system/ampinstmgr.service
      d8cfedc01ed4b95cb2b921356a05a39ff762e2d1d89606147a34a7b2c0bb4091  etc/systemd/system/amptasks.service
      8f6f8014b742ec42fb42ac322da3649f45a5357e559dc35d9a825916021e5159  etc/systemd/system/amptasks.timer
      HASHES

      test -x ${ampinstmgr}/bin/ampinstmgr
      test -x ${ampinstmgr}/opt/cubecoders/amp/ampinstmgr
      test -x ${ampinstmgr}/opt/cubecoders/amp/ioredir.so
      test ! -e ${ampinstmgr}/bin/getamp
      test ! -e ${ampinstmgr}/opt/cubecoders/amp/getamp

      test -f ${ampinstmgr}/share/ampinstmgr/ampinstmgr.conf
      for unit in ampfirewall.service ampfirewall.timer ampinstmgr.service amptasks.service amptasks.timer; do
        test -f "${ampinstmgr}/share/ampinstmgr/upstream-systemd/$unit"
      done

      file ${ampinstmgr}/opt/cubecoders/amp/.ampinstmgr-wrapped | grep -F 'ELF 64-bit LSB'

      interpreter="$(patchelf --print-interpreter ${ampinstmgr}/opt/cubecoders/amp/.ampinstmgr-wrapped)"
      case "$interpreter" in
        /nix/store/*) ;;
        *) echo "unexpected interpreter: $interpreter" >&2; exit 1 ;;
      esac

      if ldd ${ampinstmgr}/opt/cubecoders/amp/.ampinstmgr-wrapped | grep -F 'not found'; then
        exit 1
      fi

      export HOME="$TMPDIR/home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export XDG_DATA_HOME="$HOME/.local/share"
      mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

      ${ampinstmgr}/bin/ampinstmgr -version | tee "$TMPDIR/version"
      grep -F '2.8.0.4' "$TMPDIR/version"
      ${ampinstmgr}/bin/ampinstmgr --help >"$TMPDIR/help"
      test -s "$TMPDIR/help"

      touch "$out"
    '';

  vm = pkgs.testers.runNixOSTest {
    name = "ampinstmgr-package";

    nodes.machine = {
      environment.systemPackages = [
        ampinstmgr
        pkgs.strace
      ];

      users.groups.amp-spike = {};
      users.users.amp-spike = {
        isSystemUser = true;
        group = "amp-spike";
        home = "/var/lib/amp-spike";
        createHome = true;
      };

      systemd.tmpfiles.rules = [
        "d /run/amp-spike 0700 amp-spike amp-spike -"
      ];
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.succeed("test $(stat -c %U /var/lib/amp-spike) = amp-spike")

      command = (
          "runuser -u amp-spike -- env -i "
          "HOME=/var/lib/amp-spike "
          "XDG_CONFIG_HOME=/var/lib/amp-spike/.config "
          "XDG_DATA_HOME=/var/lib/amp-spike/.local/share "
          "XDG_RUNTIME_DIR=/run/amp-spike "
          "TMPDIR=/tmp "
          "PATH=/run/current-system/sw/bin "
          "strace -ff -yy -s 256 -o /tmp/amp.trace "
          "-e trace=%file,%process,%network,%desc "
          "ampinstmgr"
      )

      machine.succeed(f"{command} -version")
      machine.succeed(f"{command} --help")
      machine.succeed("test -n \"$(find /tmp -maxdepth 1 -name 'amp.trace.*' -print -quit)\"")

      machine.fail(
          r"""grep -hE 'execve\("([^"]*/)?(apt|apt-get|systemctl|docker|podman)"' /tmp/amp.trace.*"""
      )
      writes = machine.succeed(
          r"""grep -hE '(open|openat)\([^\\n]*(O_WRONLY|O_RDWR|O_CREAT)|(^|[[:space:]])(mkdir|mkdirat|unlink|unlinkat|rename|renameat)\(' /tmp/amp.trace.* """
          r"""| grep -Ev '(/var/lib/amp-spike|/tmp/|/run/|/dev/null)' || true"""
      )
      assert not writes.strip(), writes
    '';
  };
in {
  inherit contract vm;
}
