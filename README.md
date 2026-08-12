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
- The AMP manager, its ADS management instance, and Satisfactory servers have
  been successfully tested on NixOS with rootless Podman.

## NixOS module

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

## ADS setup and licence

By default, create the initial ADS management instance interactively:

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

For unattended setup, supply runtime credential files:

```nix
services.amp = {
  enable = true;

  ads.bootstrap = {
    adminUsername = "admin";
    adminPasswordFile = "/run/keys/amp-admin-password";
    licenceKeyFile = "/run/keys/amp-licence"; # Optional.
  };
};
```

The files must already exist and be readable by root. Use a secret manager or
another runtime-only location; do not create them with `builtins.toFile` or
otherwise place their contents in the Nix store. Systemd reads them as root and
passes them to the `amp` bootstrap service as credentials. Keep them available
while `ads.bootstrap` remains configured; after bootstrap completes, you may
remove that option and retire the files.

Bootstrap creates only a new `ADS01`. It refuses to adopt or overwrite an
existing instance without its `.ampdata/.nix-amp/bootstrap-state` completion
marker. A failed partial bootstrap must be recovered or removed explicitly
before retrying.

CubeCoders' command-line interface accepts the initial password and licence
only as arguments. The module therefore cannot keep them out of the transient
process argument list: the password appears base64-encoded and the licence key
appears verbatim while the relevant command runs. They are not placed in the
Nix store, service environment, unit definition, or journal by the module.

You can still omit `ads.bootstrap` and activate or reactivate AMP through its
interface or an interactive `amp` user session. If you also declare managed
settings, apply them after interactive setup:

```console
sudo systemctl restart ampads-reconcile.service
```

## Declarative ADS settings

Settings declared under `services.amp.ads.settings` are reconciled when their
NixOS configuration changes:

```nix
services.amp.ads.settings = {
  createInContainers = true;
  containerManager = "Automatic";
  allowAnalytics = false;
};
```

The module changes only declared settings. If drift is found, it stops ADS
when necessary, calls AMP's native `reconfigureinstance`, verifies the written
configuration, and starts ADS again. An unchanged switch leaves ADS running.
A failed reconfiguration leaves the unit failed and attempts to restore an ADS
instance that was running before reconciliation.

Every typed setting defaults to `null`, which leaves that AMP setting
unmanaged:

| Area | Setting | Type | Purpose |
| ---------------- | ------------------------------------------ | --------- | ---------------------------------------------------------------------- |
| Deployment | `createInContainers` | boolean | Create new instances in containers. |
| Deployment | `containerManager` | string | Select AMP's container manager, such as `Automatic`. |
| Deployment | `autoStartInstances` | boolean | Start managed instances automatically with ADS. |
| Deployment | `excludeNewInstancesFromFirewall` | boolean | Exclude new instances from AMP's firewall synchronisation. |
| Networking | `useHostNetworkingForNewContainers` | boolean | Give new containers host networking. |
| Networking | `defaultAuthServerUrl` | string | Set the authentication server URL for new instances. |
| Networking | `propagateAuthServer` | boolean | Propagate ADS's authentication server to managed instances. |
| Networking | `defaultInstanceBindAddress` | string | Set the web-interface bind address for new instances. |
| Networking | `defaultApplicationBindAddress` | string | Set the application bind address for new instances. |
| Privacy | `allowAnalytics` | boolean | Send anonymous usage analytics to CubeCoders. |
| Privacy | `autoReportFatalExceptions` | boolean | Automatically report fatal exceptions to CubeCoders. |
| Privacy | `enhancedLicenceReporting` | boolean | Send enhanced licence usage reports to CubeCoders. |

Advanced users can pass additional non-secret AMP provisioning settings:

```nix
services.amp.ads.settings.extraSettings = {
  "ADSModule.Defaults.DefaultReleaseStream" = "Mainline";
};
```

Use complete AMP provisioning keys. Invalid keys and values, duplicates of the
built-in options, and bootstrap-owned settings are rejected during evaluation.
Unknown-but-well-formed keys are passed to AMP and may fail during
reconciliation.

## Module options

The module intentionally has a small option surface:

| Option | Default | Purpose |
| ------------------------------------ | ----------- | ------------------------------------------------- |
| `services.amp.enable` | `false` | Enable the AMP manager and pending-task timer. |
| `services.amp.package` | flake build | Select the immutable manager package. |
| `services.amp.home` | `/home/amp` | Locate AMP's mutable home and `.ampdata`. |
| `services.amp.startTimeout` | `180` | Allow AMP and ADS startup this many seconds. |
| `services.amp.stopTimeout` | `180` | Allow graceful AMP instance shutdown this many seconds. |
| `services.amp.ads.bootstrap` | `null` | Optionally create and activate ADS01 unattended. |
| `services.amp.ads.settings` | `{}` | Declaratively reconcile selected ADS settings. |
| `services.amp.firewallSync.enable` | AMP enabled | Let AMP reconcile its declared firewall ports. |
| `services.amp.firewallSync.interval` | `5m` | Set the steady-state reconciliation interval. |
| `services.amp.firewallSync.podman` | Sync and Podman enabled | Reconcile after AMP Podman container events. |

## Rootless Podman

AMP and ADS run directly on NixOS. AMP creates and owns the game containers;
do not declare those containers through `virtualisation.oci-containers`.
CubeCoders likewise documents that the manager and ADS must remain outside
containers while game instances may be containerised.

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

## Firewall behaviour

By default, AMP manages the firewall ports declared by its instances, so
adding or changing a game server does not require rebuilding NixOS. This gives
AMP permission to open and close host firewall ports. When Podman is enabled,
container changes are handled automatically without additional AMP options.

Firewall synchronisation is the module's privileged AMP component. AMP
requires UID 0 for this operation. Systemd restricts it to DAC read/search,
network-administration, and raw-network capabilities and makes the system
filesystem read-only. This reduces its authority but is not a complete
sandbox; enabling synchronisation explicitly trusts this AMP component.

The module keeps unmatched input denied while allowing IPv4 host firewall
rules added after NixOS's generated rules to take effect. This applies to all
later IPv4 `INPUT` rules, not only rules created by AMP.

AMP-managed synchronisation is currently IPv4-only. Declare any required IPv6
ports through NixOS.

To manage every port declaratively through NixOS, or when using
`networking.firewall.backend = "nftables"`, disable AMP synchronisation and
declare the required ports yourself. Disabling synchronisation removes the
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

To retain normal synchronisation without reacting immediately to Podman
container changes, set
`services.amp.firewallSync.podman = false`.

## State, updates, and maintenance

### State and backups

The Nix store owns the immutable `ampinstmgr` package. Treat the complete
`${services.amp.home}` as AMP's mutable persistence and backup boundary. AMP
keeps its controller state under `.ampdata`, but game templates may write
elsewhere in the home, including `.config`. The default home is:

```text
/home/amp
```

If you override `services.amp.home`, keep it persistent, writable by `amp`, and
outside `/nix/store` and `/home/amp`. Back up the complete home separately from
the NixOS configuration. Stop AMP instances before taking an
application-consistent backup or restoring one.

### Moving the AMP home

Choose a custom home before the first activation when possible. When moving an
existing installation, quiesce every AMP worker and terminate the lingering
`amp` user manager before moving its home:

```console
sudo systemctl stop 'amptasks.*' 'ampfirewall*' ampinstmgr.service
sudo loginctl terminate-user amp
systemctl --state=active 'amp*'
```

The final command should return no units. Move the complete home, then ensure
`/home/amp` no longer exists before rebuilding. The module creates a
compatibility symlink from `/home/amp` to the configured home. The firewall
synchroniser will not run while that link is absent or resolves somewhere
else, preventing it from silently reading stale state.

Before changing a custom home back to `/home/amp`, stop AMP, remove the symlink,
and restore the state as a real `/home/amp` directory. The module will refuse to
start AMP while the old custom-home symlink remains.

After copying or restoring AMP state, ensure the complete home is owned by the
current host's `amp:amp` account. Numeric UID and GID values retained from
another host may not match. After a host migration or material identity change,
verify the ADS licence state and reactivate it if required before declaring the
migration complete.

### Updating

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

### Rollback

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
- An active `ampinstmgr.service` records successful lifecycle orchestration; it
  does not continuously verify ADS health. Monitor the configured ADS endpoint
  separately where ongoing availability matters.
- AMP downloads additional mutable executables after installation. The module
  provides a narrowly scoped compatibility environment, but a future payload
  may still introduce an unhandled FHS or library dependency.

Report Nix package, module, or NixOS integration defects in this repository.
Report AMP product defects, licence issues, and game-template problems to
[CubeCoders support](https://discourse.cubecoders.com/).
