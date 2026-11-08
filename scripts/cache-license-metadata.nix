# Exact output paths, never package-name guesses, authorize publication.
{
  nixpkgs,
  candidatesFile,
  flakeDir,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { config.allowUnfree = true; };
  flake = builtins.getFlake flakeDir;
  candidates = builtins.fromJSON (builtins.readFile candidatesFile);
  inspect =
    package:
    let
      attempted = builtins.tryEval (
        let
          result = {
            meta.license = package.meta.license or [ ];
            outputs = builtins.listToAttrs (
              map (output: {
                name = output;
                value = package.${output}.outPath;
              }) (package.outputs or [ "out" ])
            );
          };
        in
        builtins.deepSeq result result
      );
    in
    if !(package ? meta.license) then
      { }
    else if attempted.success then
      attempted.value
    else
      { };
  upstream = builtins.listToAttrs (
    map (name: {
      name = "nixpkgs:${name}";
      value =
        if builtins.hasAttr name pkgs && pkgs.lib.isDerivation pkgs.${name} then
          inspect pkgs.${name}
        else
          { };
    }) candidates
  );
  localPackages = builtins.listToAttrs (
    pkgs.lib.mapAttrsToList (name: package: {
      name = "repo:${name}";
      value = inspect package;
    }) (flake.packages.${system} or { })
  );
in
upstream // localPackages
