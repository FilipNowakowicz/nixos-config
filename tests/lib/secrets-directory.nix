{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
pkgs.runCommand "secrets-directory-check"
  {
    src = ../../.;
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      sops
    ];
  }
  ''
    export PLAINTEXT_MARKER_PATTERN_FILE="$src/scripts/lib/plaintext-secret-pattern.txt"

    cd "$src"
    bash ${../../scripts/check-secrets-directory.sh} --working-tree

    fixture="$TMPDIR/secrets-directory-fixture"
    mkdir -p "$fixture/hosts/main/secrets" "$fixture/home/users/user/secrets"
    cd "$fixture"

    cat > hosts/main/secrets/secrets.yaml <<'YAML'
    service_password: ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]
    sops:
      age: []
      mac: ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]
      version: 3.13.0
    YAML

    cat > home/users/user/secrets/codex-auth.json <<'JSON'
    {
      "tokens": {
        "access_token": "ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]"
      },
      "sops": {
        "age": [],
        "mac": "ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]",
        "version": "3.13.0"
      }
    }
    JSON

    cat > home/users/user/secrets/README.md <<'EOF'
    This documentation file is allowed beside SOPS-managed auth backups.
    EOF

    bash ${../../scripts/check-secrets-directory.sh} --working-tree

    cat > home/users/user/secrets/plain-auth.json <<'JSON'
    {
      "access_token": "plain"
    }
    JSON

    if bash ${../../scripts/check-secrets-directory.sh} --working-tree; then
      echo "expected plaintext user auth backup to fail" >&2
      exit 1
    fi
    rm home/users/user/secrets/plain-auth.json

    fake_token="$(printf '%s_%s' 'ghp' '012345678901234567890123456789012345')"
    cat > home/users/user/secrets/plain-token.json <<JSON
    {
      "access_token": "$fake_token",
      "sops": {
        "age": [],
        "mac": "ENC[AES256_GCM,data:example,iv:example,tag:example,type:str]",
        "version": "3.13.0"
      }
    }
    JSON

    if bash ${../../scripts/check-secrets-directory.sh} --working-tree; then
      echo "expected SOPS file with plaintext token marker to fail" >&2
      exit 1
    fi

    export SOPS_AGE_KEY_FILE="$src/tests/fixtures/sops-host/age-key.txt"
    decrypted="$(sops --decrypt --extract '["service_password"]' "$src/tests/fixtures/sops-host/secrets/secrets.yaml")"
    if [[ "$decrypted" != "test-host-secret" ]]; then
      echo "expected test host SOPS fixture to decrypt" >&2
      exit 1
    fi

    touch "$out"
  ''
