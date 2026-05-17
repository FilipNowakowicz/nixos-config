{ lib, ... }:
{
  imports = [
    ./browsing.nix
    ./coding.nix
    ./latex.nix
    ./learning.nix
  ];

  options.workflowPacks = {
    browsing.enable = lib.mkEnableOption "browser workflow pack (Chromium)";
    coding.enable = lib.mkEnableOption "coding workflow pack (VS Code)";
    latex.enable = lib.mkEnableOption "LaTeX workflow pack (TeX Live, latexmk, PDF viewer)";
    learning.enable = lib.mkEnableOption "learning workflow pack (Anki flashcard app)";
  };
}
