_: {
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    shfmt.enable = true;
    prettier.enable = true;
  };

  settings = {
    formatter.shfmt.includes = [ "scripts/**/*.sh" ];
    formatter.prettier = {
      includes = [
        "*.md"
        "**/*.md"
      ];
      # Learning candidates are strict single-line, grep-routed metadata consumed by
      # .agents/learning/scripts/*. Prettier would rewrap their flow arrays onto
      # multiple lines, breaking the single-line field extraction. Leave them as-is.
      # QML JavaScript libraries start with `.pragma library`, which prettier can't parse.
      excludes = [
        ".agents/learning/candidates/**"
        "packages/quiet-shell/shell/*.js"
      ];
    };
  };
}
