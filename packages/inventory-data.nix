{
  lib,
  pkgs,
  hostRegistry,
  allNixosConfigs,
  hostAssertions ? { },
  includeClosureSizes ? true,
}:
let
  inventoryData = import ../lib/inventory-data.nix {
    inherit
      lib
      pkgs
      hostRegistry
      allNixosConfigs
      hostAssertions
      ;
  };
  dataJson = builtins.toJSON inventoryData.data;
  inherit (inventoryData) hostSpec;
in
pkgs.runCommand "inventory-data"
  (
    {
      nativeBuildInputs = lib.optionals includeClosureSizes [
        pkgs.jq
        pkgs.nix
      ];
      passAsFile = [ "dataJson" ] ++ lib.optionals includeClosureSizes [ "hostSpec" ];
      inherit dataJson;
    }
    // lib.optionalAttrs includeClosureSizes {
      inherit hostSpec;
    }
  )
  (
    if includeClosureSizes then
      ''
        mkdir -p "$out"
        sizes_jsonl="$TMPDIR/closure-sizes.jsonl"
        sizes_json="$TMPDIR/closure-sizes.json"
        : > "$sizes_jsonl"

        while IFS=$'\t' read -r hostName closurePath || [ -n "$hostName" ]; do
          [ -n "$hostName" ] || continue
          if closureInfo="$(nix path-info -S "$closurePath" 2>/dev/null)"; then
            closureBytes="$(printf '%s\n' "$closureInfo" | awk '{print $2}')"
            jq -n --arg name "$hostName" --argjson closureSizeBytes "$closureBytes" \
              '{name: $name, closureSizeBytes: $closureSizeBytes}' >> "$sizes_jsonl"
          else
            jq -n --arg name "$hostName" '{name: $name, closureSizeBytes: null}' >> "$sizes_jsonl"
          fi
        done < "$hostSpecPath"

        jq -s 'map({(.name): {closureSizeBytes: .closureSizeBytes}}) | add // {}' \
          "$sizes_jsonl" > "$sizes_json"
        jq --slurpfile sizes "$sizes_json" \
          '.hosts |= map(. + {closureSizeBytes: (($sizes[0][.name].closureSizeBytes) // null)})' \
          "$dataJsonPath" > "$out/inventory.json"
      ''
    else
      ''
        mkdir -p "$out"
        cp "$dataJsonPath" "$out/inventory.json"
      ''
  )
