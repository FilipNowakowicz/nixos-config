{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "scan-plaintext-secrets-check"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      git
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_NOSYSTEM=1

    scan="$src/scripts/scan-plaintext-secrets.sh"

    new_fixture() {
      mkdir -p "$TMPDIR/fixture-$1"
      cd "$TMPDIR/fixture-$1"
      git init -q
    }

    # Construct the fake key at runtime so the source file itself does not
    # match the AKIA pattern and trigger the pre-commit secrets scan.
    fake_key="$(printf 'AKIA%s' '0123456789ABCDEF')"

    # 1. Plaintext secret in a tracked file → exit 1
    new_fixture plain-secret
    printf 'api_key = "%s"\n' "$fake_key" > secret.txt
    git add secret.txt
    if bash "$scan"; then
      echo "expected exit 1 for plaintext secret" >&2
      exit 1
    fi

    # 2. Path covered by .plaintext-secrets-allowlist → exit 0
    echo "secret.txt" > .plaintext-secrets-allowlist
    bash "$scan" || { echo "expected exit 0 when path is allowlisted" >&2; exit 1; }

    # 3. .enc and .age files are skipped regardless of content → exit 0
    new_fixture encrypted
    printf 'api_key = "%s"\n' "$fake_key" > secret.enc
    printf 'api_key = "%s"\n' "$fake_key" > secret.age
    git add secret.enc secret.age
    bash "$scan" || { echo "expected exit 0 for .enc/.age files" >&2; exit 1; }

    # 4. SOPS-formatted YAML under hosts/*/secrets/ → exit 0
    new_fixture sops-yaml
    mkdir -p hosts/main/secrets
    cat > hosts/main/secrets/data.yaml <<'YAML'
    service_password: ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]
    sops:
      age: []
      mac: ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]
      version: 3.13.0
    YAML
    git add hosts/main/secrets/data.yaml
    bash "$scan" || { echo "expected exit 0 for SOPS-managed YAML" >&2; exit 1; }

    # 5. Non-SOPS file under hosts/*/secrets/ → exit 1 (invalid file type)
    new_fixture invalid-secrets
    mkdir -p hosts/main/secrets
    printf 'plain content\n' > hosts/main/secrets/plain.txt
    git add hosts/main/secrets/plain.txt
    if bash "$scan"; then
      echo "expected exit 1 for non-SOPS file in secrets dir" >&2
      exit 1
    fi

    touch "$out"
  ''
