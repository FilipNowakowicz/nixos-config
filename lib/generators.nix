# Generators for serializing Nix attrsets to domain-specific config formats.
{ lib }:

let
  indentStr = depth: lib.concatStrings (lib.replicate depth "  ");

  isRef = v: lib.isAttrs v && v ? __alloyRef;
  isBlock = v: lib.isAttrs v && v ? __alloyBlock;

  renderValue =
    depth: v:
    if isRef v then
      v.__alloyRef
    else if lib.isString v then
      "\"${lib.escape [ "\"" "\\" ] v}\""
    else if lib.isInt v || lib.isFloat v then
      toString v
    else if lib.isBool v then
      (if v then "true" else "false")
    else if lib.isList v then
      let
        items = map (renderValue depth) v;
      in
      if items == [ ] then "[]" else "[${lib.concatStringsSep ", " items},]"
    else if lib.isAttrs v && !isBlock v then
      let
        pairs = lib.mapAttrsToList (
          k: val: "${indentStr (depth + 1)}${k} = ${renderValue (depth + 1) val},"
        ) v;
      in
      "{\n${lib.concatStringsSep "\n" pairs}\n${indentStr depth}}"
    else
      throw "toAlloyHCL: unsupported value type: ${lib.generators.toPretty { } v}";

  renderBody =
    depth: attrs:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: value:
        if isBlock value then
          let
            body = lib.removeAttrs value [ "__alloyBlock" ];
          in
          "${indentStr depth}${name} {\n${renderBody (depth + 1) body}\n${indentStr depth}}"
        else if lib.isList value && value != [ ] && lib.all isBlock value then
          lib.concatStringsSep "\n" (
            map (
              block:
              let
                body = lib.removeAttrs block [ "__alloyBlock" ];
              in
              "${indentStr depth}${name} {\n${renderBody (depth + 1) body}\n${indentStr depth}}"
            ) value
          )
        else
          "${indentStr depth}${name} = ${renderValue depth value}"
      ) attrs
    );

  renderComponent =
    {
      type,
      label,
      body,
    }:
    "${type} \"${label}\" {\n${renderBody 1 body}\n}";

  mkNginxProxyLocation =
    {
      target,
      websockets ? false,
      basicAuthFile ? null,
      extraConfig ? "",
      extraOptions ? { },
    }:
    {
      proxyPass = target;
    }
    // lib.optionalAttrs websockets {
      proxyWebsockets = true;
    }
    // lib.optionalAttrs (basicAuthFile != null) {
      inherit basicAuthFile;
    }
    // lib.optionalAttrs (extraConfig != "") {
      inherit extraConfig;
    }
    // extraOptions;

in
{
  # Convert a list of Alloy component definitions to River config text.
  # Each component: { type = "loki.write"; label = "target"; body = { ... }; }
  # body values: strings, ints, bools, lists, inline attrsets,
  #   ref "expr" for unquoted expressions, nestedBlock { } for sub-blocks.
  toAlloyHCL = components: lib.concatStringsSep "\n\n" (map renderComponent components);

  # Unquoted Alloy expression — use for component references in forward_to etc.
  ref = expr: { __alloyRef = expr; };

  # Nested block (rendered as `name { ... }` not `name = { ... }`)
  nestedBlock = body: { __alloyBlock = true; } // body;

  nginx = {
    # Normal reverse-proxy location. Keep one-off nginx behavior in extraConfig
    # or hand-written locations instead of expanding this into a routing DSL.
    proxyLocation = mkNginxProxyLocation;
  };

  systemd = {
    # Timer shape used by recurring homeserver maintenance jobs.
    timer =
      {
        schedule,
        jitter ? null,
        persistent ? true,
        wantedBy ? [ "timers.target" ],
        extraTimerConfig ? { },
      }:
      {
        inherit wantedBy;
        timerConfig = {
          OnCalendar = schedule;
          Persistent = persistent;
        }
        // lib.optionalAttrs (jitter != null) {
          RandomizedDelaySec = jitter;
        }
        // extraTimerConfig;
      };
  };
}
