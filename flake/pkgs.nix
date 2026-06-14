{
  nixpkgs,
  overlays,
}:
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
