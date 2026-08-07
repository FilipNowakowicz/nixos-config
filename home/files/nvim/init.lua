-- Core modules
require("config.options")

-- Must be set before VimTeX initializes a compiler for a .tex file passed on
-- Neovim's command line.  Otherwise VimTeX can retain an older latexmk
-- wrapper from a Nix profile.
vim.g.vimtex_compiler_latexmk = {
  executable = "/etc/profiles/per-user/user/bin/latexmk",
}

require("config.keymaps")
require("config.plugins")

-- Plugins
require("config.ui")
require("config.lsp")
require("config.format")
require("config.dap")
require("config.tests")
require("config.tex")
require("config.lint")
require("config.terminal")
require("config.session")
