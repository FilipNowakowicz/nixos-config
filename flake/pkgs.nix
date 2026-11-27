{ nixpkgs }:
let
  # Local packages nixpkgs does not ship, available as `pkgs.<name>` on every
  # host and in `packages.<system>`.
  overlays = [
    (_: prev: {
      lazyactions = prev.callPackage ../packages/lazyactions { };
    })
  ];
in
{
  inherit overlays;

  mkPkgs =
    {
      system,
      config ? {
        allowUnfree = true;
      },
    }:
    import nixpkgs {
      inherit
        config
        overlays
        system
        ;
    };
}
