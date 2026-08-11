{pkgs}: let
  # A minimal persistent workload with one TCP and one UDP listener exercises
  # the rootless runtime without depending on AMP's proprietary payload.
  image = pkgs.dockerTools.buildImage {
    name = "amp-runtime-test";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "amp-runtime-test-root";
      paths = [pkgs.busybox];
      pathsToLink = ["/bin"];
    };
    extraCommands = "mkdir -p state";
    config.Cmd = [
      "/bin/sh"
      "-c"
      ''
        test -f /state/marker || echo persistent > /state/marker
        httpd -f -p 8081 -h /state &
        while true; do
          echo udp | nc -u -l -p 7777
        done
      ''
    ];
  };

  rootlessUser = {
    isSystemUser = true;
    group = "amp";
    home = "/home/amp";
    createHome = true;
    autoSubUidGidRange = true;
    linger = true;
  };
in
  pkgs.testers.runNixOSTest {
    name = "amp-container-runtimes";

    nodes = {
      # Test rootless Podman alone, then beside rootful Docker to catch socket
      # aliasing or daemon-level integration conflicts.
      podman = {
        virtualisation.podman.enable = true;
        users.groups.amp = {};
        users.users.amp = rootlessUser;
        environment.systemPackages = [pkgs.curl pkgs.podman pkgs.socat];
      };

      coexist = {
        virtualisation = {
          docker.enable = true;
          podman.enable = true;
        };
        users.groups.amp = {};
        users.users.amp = rootlessUser;
        environment.systemPackages = [
          pkgs.curl
          pkgs.docker
          pkgs.podman
        ];
      };
    };

    testScript = ''
      podman.start(allow_reboot=True)
      coexist.start()

      for node in (podman, coexist):
          node.wait_for_unit("multi-user.target")
          node.wait_for_unit("user@$(id -u amp).service")
          node.succeed("grep -F 'amp:' /etc/subuid")
          node.succeed("grep -F 'amp:' /etc/subgid")
          node.succeed("test $(loginctl show-user amp -P Linger) = yes")
          node.succeed("test -S /run/user/$(id -u amp)/podman/podman.sock")

      # Keep every interactive Podman call in the amp user's runtime context.
      amp_podman = (
          "runuser -u amp -- env HOME=/home/amp "
          "XDG_RUNTIME_DIR=/run/user/$(id -u amp) podman"
      )

      with subtest("rootless Podman publishes TCP and UDP and preserves state"):
          podman.succeed(
              "install -d -o amp -g amp /home/amp/runtime-test"
          )
          podman.succeed(f"{amp_podman} load -i ${image}")
          podman.succeed(
              f"{amp_podman} run -d --name AMP_RuntimeTest "
              "-p 127.0.0.1:18081:8081/tcp "
              "-p 127.0.0.1:17777:7777/udp "
              "-v /home/amp/runtime-test:/state "
              "localhost/amp-runtime-test:latest"
          )
          podman.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:18081/marker "
              "| grep -Fx persistent"
          )
          podman.succeed(
              "printf probe | socat - UDP:127.0.0.1:17777,so-broadcast "
              "| grep -Fx udp"
          )
          podman.succeed(f"{amp_podman} restart AMP_RuntimeTest")
          podman.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:18081/marker "
              "| grep -Fx persistent"
          )

          podman.reboot()
          podman.wait_for_unit("multi-user.target")
          podman.wait_for_unit("user@$(id -u amp).service")
          podman.succeed(f"{amp_podman} start AMP_RuntimeTest")
          podman.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:18081/marker "
              "| grep -Fx persistent"
          )

      with subtest("Docker and rootless Podman coexist without socket aliasing"):
          coexist.wait_for_unit("docker.service")
          coexist.succeed("test -S /run/docker.sock")
          coexist.succeed("test -S /run/podman/podman.sock")
          coexist.succeed(
              "test /run/docker.sock -ef /run/podman/podman.sock && exit 1 || true"
          )
          coexist.succeed("docker load -i ${image}")
          coexist.succeed(
              "docker run -d --name Docker_RuntimeTest "
              "-p 127.0.0.1:28081:8081/tcp "
              "amp-runtime-test:latest"
          )
          coexist.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:28081/marker "
              "| grep -Fx persistent"
          )
          coexist.succeed(f"{amp_podman} load -i ${image}")
          coexist.succeed(
              f"{amp_podman} run -d --name AMP_RuntimeTest "
              "-p 127.0.0.1:38081:8081/tcp "
              "localhost/amp-runtime-test:latest"
          )
          coexist.wait_until_succeeds(
              "curl -fsS http://127.0.0.1:38081/marker "
              "| grep -Fx persistent"
          )
    '';
  }
