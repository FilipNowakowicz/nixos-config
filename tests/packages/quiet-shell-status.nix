# status.py is the only reader of system state, so check it against the same faked
# commands the acceptance suite uses, including every tool being absent.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "quiet-shell-status-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./quiet-shell-status.py} \
      ${../../packages/quiet-shell/shell/scripts/status.py} \
      ${../quiet-shell/fakes/fake.py}
    touch $out
  ''
