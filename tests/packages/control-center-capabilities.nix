# Unit tests for the control-center capability-detection layer.
#
# capabilities.py is intentionally stdlib-only (no gi/GTK import) so it can be
# exercised by a plain python3 here, the same way views consume it to decide
# whether an optional integration is present or merely off.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "control-center-capabilities-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./control-center-capabilities.py} \
      ${../../packages/control-center/src/control_center/capabilities.py}
    touch $out
  ''
