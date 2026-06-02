# `services.hardened`

`services.hardened` applies a reusable systemd sandboxing baseline to selected
NixOS services. It is meant for services that already have a normal NixOS unit
and need a consistent hardening layer without copying the same `serviceConfig`
block around host files.

Import it from this flake with:

```nix
{
  imports = [
    inputs.nix-config.nixosModules.services-hardened
  ];
}
```

The module exposes one option namespace:

```nix
services.hardened.<unit-name> = {
  enable = true;
  relaxBase = [ ];
  extraConfig = { };
};
```

`<unit-name>` matches the systemd service name without `.service`.

## Baseline

The baseline denies common escalation paths and narrows service visibility:

- `NoNewPrivileges = true`
- `PrivateTmp = true`
- `PrivateDevices = true`
- `ProtectSystem = "strict"`
- `ProtectHome = true`
- `ProtectProc = "invisible"`
- `ProcSubset = "pid"`
- `ProtectControlGroups = true`
- `ProtectKernelTunables = true`
- `ProtectKernelModules = true`
- `ProtectKernelLogs = true`
- `ProtectHostname = true`
- `ProtectClock = true`
- `LockPersonality = true`
- `MemoryDenyWriteExecute = true`
- `CapabilityBoundingSet = ""`
- `AmbientCapabilities = ""`
- `KeyringMode = "private"`
- `RestrictSUIDSGID = true`
- `RestrictRealtime = true`
- `RestrictNamespaces = true`
- `SystemCallArchitectures = "native"`
- `SystemCallFilter = [ "@system-service" ]`
- `RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ]`

Some low-blast-radius keys are forced so upstream unit defaults cannot silently
weaken the advertised baseline:

- `NoNewPrivileges`
- `PrivateTmp`
- `PrivateDevices`
- `ProtectProc`
- `ProcSubset`

To weaken one of those keys, list it in `relaxBase`. Setting it directly in
`extraConfig` is not enough. Non-forced baseline keys are defaults, so
`extraConfig` can override them directly.

Use `relaxBase` when a baseline key should be omitted. Use `extraConfig` when a
service needs additional permissions, writable paths, capabilities, or a
replacement value for a non-forced baseline key.

Null values are rejected in `extraConfig`; use `relaxBase` instead of assigning
`null`.

## Examples

### Nginx

Nginx needs to bind low ports and write cache, log, and certificate files.

```nix
services.hardened.nginx.extraConfig = {
  CapabilityBoundingSet = "CAP_NET_BIND_SERVICE";
  AmbientCapabilities = "CAP_NET_BIND_SERVICE";
  ReadWritePaths = [
    "/var/cache/nginx"
    "/var/log/nginx"
    "/var/lib/nginx/certs"
  ];
};
```

### Vaultwarden

Vaultwarden can run with no Linux capabilities, but it needs write access to its
state directory.

```nix
services.hardened.vaultwarden.extraConfig = {
  ReadWritePaths = [ "/var/lib/vaultwarden" ];
};
```

### Custom Local Helper

This example creates a local helper that only needs Unix sockets and a writable
state directory.

```nix
{
  systemd.services.example-helper = {
    description = "Example helper";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.example-helper}/bin/example-helper";
      StateDirectory = "example-helper";
      DynamicUser = true;
    };
  };

  services.hardened.example-helper.extraConfig = {
    RestrictAddressFamilies = [ "AF_UNIX" ];
    ReadWritePaths = [ "/var/lib/example-helper" ];
  };
}
```

### Relaxing A Forced Key

Services that genuinely need device access must opt out explicitly:

```nix
services.hardened.fwupd = {
  relaxBase = [ "PrivateDevices" ];
  extraConfig.RestrictAddressFamilies = [
    "AF_UNIX"
    "AF_NETLINK"
  ];
};
```

## Validation

The module has focused evaluation tests for merge priority and invalid null
values, plus the `profile-hardening` VM test for rendered systemd behavior.

For local changes, start with:

```sh
bash scripts/validate.sh flake-eval
bash scripts/validate.sh profile-hardening
```
