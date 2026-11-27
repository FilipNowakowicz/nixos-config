# Terminal UI for GitHub Actions; not packaged in nixpkgs.
{ buildGoModule, fetchFromGitHub }:
buildGoModule {
  pname = "lazyactions";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "nnnkkk7";
    repo = "lazyactions";
    rev = "7058157e1ac3723c905cf2f9bf0138f8ebfb4465";
    hash = "sha256-2y4jmuCBe6HDpn2tj9YMAHNBx46z/LsmMoPOWAGkbAk=";
  };
  vendorHash = "sha256-cDLLpU0xsv57yE2cOMddcf2/mHsmGAe69pbNYGSL1XE=";
  subPackages = [ "cmd/lazyactions" ];
}
