# Evaluate only likely package attributes from the closure, then require exact
# output-path equality in the uploader. Unknown/generated/overridden paths are
# withheld; guessing an attribute name never grants a license to another path.
{ nixpkgs, candidatesFile }:
let
  pkgs = import nixpkgs { config.allowUnfree = true; };
  candidates = builtins.fromJSON (builtins.readFile candidatesFile);
  inspect =
    name:
    let
      attempted = builtins.tryEval (
        let
          package = pkgs.${name};
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
    if !(builtins.hasAttr name pkgs) then
      { }
    else if attempted.success then
      attempted.value
    else
      { };
in
builtins.listToAttrs (
  map (name: {
    inherit name;
    value = inspect name;
  }) candidates
)
