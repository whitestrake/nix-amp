# nix-amp

Unofficial Nix packaging and NixOS integration for
[CubeCoders AMP](https://cubecoders.com/AMP).

This project is not affiliated with or supported by CubeCoders. It packages
CubeCoders' proprietary AMP Instance Manager; it does not change the licence
required to run AMP. The upstream binary remains governed by the
[CubeCoders terms](https://cubecoders.com/TermsOfSale).

## Status

- Project status: experimental.
- Supported target: x86_64 NixOS 26.05.
- The manager, ADS, and Satisfactory servers have been successfully tested on
  NixOS with rootless Podman.

## Use

Add the flake input and import the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nix-amp = {
      url = "github:whitestrake/nix-amp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    nix-amp,
    ...
  }: {
    nixosConfigurations.gameserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-amp.nixosModules.default
        {
          services.amp.enable = true;
        }
      ];
    };
  };
}
```

This creates the `amp` system user and group, installs the manager, preserves
AMP's packaged systemd units, and starts boot-enabled instances.

The package is also available as:

```nix
inputs.nix-amp.packages.x86_64-linux.ampinstmgr
```

The flake also exports `overlays.default` for configurations that already
manage packages through overlays.

## Command line

Run `ampinstmgr` through the module-managed `amp` account:

```console
sudo -iu amp
ampinstmgr status
```

For a single command:

```console
sudo -iu amp ampinstmgr status
```

The package supplies the required compatibility environment and utilities.
Avoid running ordinary instance-management commands as root. The login form
above selects the module-managed home and `PATH`.

Systemd-managed AMP processes receive the rootless Podman socket environment
automatically. For an interactive command that operates on Podman containers,
set it explicitly:

```console
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
ampinstmgr status
```

## First-time setup and licence

After enabling the module, create the initial ADS management instance:

```console
sudo -iu amp
ampinstmgr quickstart
```

Follow the interactive prompts, then open the URL printed by `quickstart` to
complete AMP setup and licence activation.

If ADS is not directly reachable, use a reachable host address or forward its
default port over SSH:

```console
ssh -N -L 18080:127.0.0.1:8080 user@gameserver
```

Then open `http://127.0.0.1:18080/`.

The module intentionally has no licence-key option. Putting the key in Nix
configuration would copy it into the Nix store. Activate or reactivate AMP
through its interface or from an interactive `amp` user session instead.

The module intentionally has a small option surface:

| Option | Default | Purpose |
| ------------------------------------ | ----------- | ------------------------------------------------- |
| `services.amp.enable` | `false` | Enable the AMP manager and pending-task timer. |
| `services.amp.package` | flake build | Select the immutable manager package. |
| `services.amp.home` | `/home/amp` | Locate AMP's mutable home and `.ampdata`. |
| `services.amp.startTimeout` | `180` | Allow manager startup this many seconds. |
| `services.amp.stopTimeout` | `180` | Allow graceful `stopall` this many seconds. |
| `services.amp.firewallSync.enable` | AMP enabled | Let AMP reconcile its declared firewall ports. |
| `services.amp.firewallSync.interval` | `5m` | Set the steady-state reconciliation interval. |
| `services.amp.firewallSync.podman` | Sync and Podman enabled | Reconcile after AMP Podman container events. |

## Rootless Podman

AMP and ADS run directly on NixOS. AMP creates and owns the game containers;
do not declare those containers through `virtualisation.oci-containers`.
CubeCoders likewise documents that the manager and ADS must remain outside
containers while game instances may be containerized.

The module deliberately does not enable a container engine or choose host
storage and networking policy. A minimal rootless Podman host configuration
looks like this:

```nix
{
  services.amp.enable = true;
  virtualisation.podman.enable = true;
}
```

The module automatically configures the `amp` account, subordinate UID/GID
ranges, lingering user runtime, Podman executable, and the rootless socket
environment used by AMP's systemd services. It does not grant `amp` access to
the rootful Podman socket.

In AMP, enable container creation under **Configuration → Instance
Deployment**. “Use Host Networking for New Containers” controls only new
containers; change an existing instance through that instance's own setting.
Both host and bridge networking remain AMP choices.

For Podman instances, set the AMP Auth Server URL to
`http://host.containers.internal:8080/`. This hostname dynamically refers to
the container host and has been tested with both bridge and host networking.
`localhost:8080` points inside a bridge-networked container and will make
**Manage Instance** fail even when ADS itself is healthy.

Rootless Podman is the supported container backend. Docker can be configured
separately, but access to its rootful socket grants the `amp` account
root-equivalent host control. Rootless Docker is unverified.

## Firewall behavior

By default, AMP manages the firewall ports declared by its instances, so
adding or changing a game server does not require rebuilding NixOS. This gives
AMP permission to open and close host firewall ports. When Podman is enabled,
container changes are handled automatically without additional AMP options.

Firewall synchronization is the module's privileged AMP component. AMP
requires UID 0 for this operation. Systemd restricts it to DAC read/search,
network-administration, and raw-network capabilities and makes the system
filesystem read-only. This reduces its authority but is not a complete
sandbox; enabling synchronization explicitly trusts this AMP component.

The module keeps unmatched input denied while allowing IPv4 host firewall
rules added after NixOS's generated rules to take effect. This applies to all
later IPv4 `INPUT` rules, not only rules created by AMP.

AMP-managed synchronization is currently IPv4-only. Declare any required IPv6
ports through NixOS.

To manage every port declaratively through NixOS, or when using
`networking.firewall.backend = "nftables"`, disable AMP synchronization and
declare the required ports yourself. Disabling synchronization removes the
runtime IPv4 `INPUT` accepts that AMP marked as its own.

```nix
{
  services.amp.firewallSync.enable = false;

  networking.firewall = {
    allowedTCPPorts = [8080]; # Add the TCP ports used by your instances.
    allowedUDPPorts = []; # Add the UDP ports used by your instances.
  };
}
```

To retain normal synchronization without reacting immediately to Podman
container changes, set
`services.amp.firewallSync.podman = false`.

## State, updates, and maintenance

The Nix store owns the immutable `ampinstmgr` package. AMP owns mutable ADS,
instance, download, configuration, licence, and game data under
`${services.amp.home}/.ampdata`. The default is:

```text
/home/amp/.ampdata
```

If you override `services.amp.home`, keep it persistent, writable by `amp`, and
outside `/nix/store` and `/home/amp`. Back up the state directory separately
from the NixOS configuration. Stop AMP instances before taking an
application-consistent backup or restore.

Choose a custom home before the first activation when possible. Before moving
or restoring state, quiesce every AMP worker:

```console
sudo systemctl stop 'amptasks.*' 'ampfirewall*' ampinstmgr.service
systemctl --state=active 'amp*'
```

The second command should return no units. Move the state and replace
`/home/amp` with a symlink to the configured home before rebuilding. The
firewall synchronizer will not run when `/home/amp` resolves somewhere else,
preventing it from silently reading stale state.

Before changing a custom home back to `/home/amp`, stop AMP, remove the symlink,
and restore the state as a real `/home/amp` directory. The module will refuse to
start AMP while the old custom-home symlink remains.

The manager package is pinned by version and hash. Update the flake input and
rebuild NixOS:

```console
nix flake update nix-amp
sudo nixos-rebuild switch --flake .#gameserver
```

NixOS activation leaves running AMP instances untouched, so activate the new
manager package during a maintenance window:

```console
sudo systemctl restart ampinstmgr.service
```

ADS and game instances are updated separately through AMP. They can be updated
and restarted individually or together during a maintenance window.

Confirm ADS, every expected instance, game connectivity, saves, firewall
rules, and backups afterward.

Rollback has two parts:

- Select the previous flake revision or NixOS generation.
- Restore the matching AMP state snapshot if the newer build migrated mutable
  state incompatibly.

Then restart `ampinstmgr.service` during the maintenance window so the restored
manager package takes effect. Do not assume a package downgrade can reverse a
state migration.

## Known limitations

- Native AMP on NixOS is not an upstream-supported installation method.
- The module provides the generic AMP service boundary, not storage,
  reverse-proxy, TLS, DNS, monitoring, backup, deployment, or secret policy.
- AMP downloads additional mutable executables after installation. The module
  provides a narrowly scoped compatibility environment, but a future payload
  may still introduce an unhandled FHS or library dependency.

Report Nix package, module, or NixOS integration defects in this repository.
Report AMP product defects, licence issues, and game-template problems to
[CubeCoders support](https://discourse.cubecoders.com/).
