-- Colours follow the desktop theme; see config/theme.lua.
require("config.theme").apply()

-----------------------------------------------------------
-- Oil (file explorer)
-----------------------------------------------------------
pcall(function()
  require("oil").setup({
    default_file_explorer = true,
    view_options = { show_hidden = false },
  })
end)

-----------------------------------------------------------
-- Autopairs
-----------------------------------------------------------
pcall(function()
  require("nvim-autopairs").setup()
end)

-----------------------------------------------------------
-- Treesitter
-----------------------------------------------------------
pcall(function()
  require("nvim-treesitter.configs").setup({
    ensure_installed = { "c", "python", "lua", "nix", "latex", "bibtex" },
    highlight = { enable = true },
    indent = { enable = true },
    incremental_selection = {
      enable = true,
      keymaps = {
        init_selection = "gnn",
        node_incremental = "grn",
        scope_incremental = "grc",
        node_decremental = "grm",
      },
    },
    textobjects = {
      select = {
        enable = true,
        lookahead = true,
        keymaps = {
          ["af"] = "@function.outer",
          ["if"] = "@function.inner",
          ["ac"] = "@class.outer",
          ["ic"] = "@class.inner",
        },
      },
    },
  })
end)

pcall(function()
  require("treesitter-context").setup({ max_lines = 3 })
end)

-----------------------------------------------------------
-- Telescope
-----------------------------------------------------------
pcall(function()
  require("telescope").setup({
    defaults = {
      sorting_strategy = "ascending",
      layout_config = { prompt_position = "top" },
    },
  })
  pcall(require("telescope").load_extension, "fzf")
end)

-----------------------------------------------------------
-- Git / motion / statusline
-----------------------------------------------------------
pcall(function() require("gitsigns").setup() end)
pcall(function() require("lualine").setup() end)

pcall(function()
  require("leap").add_default_mappings()
end)

-----------------------------------------------------------
-- Trouble
-----------------------------------------------------------
pcall(function()
  require("trouble").setup()
end)

pcall(function()
  require("which-key").add({
    { "<leader>c", group = "Copilot" },
    { "<leader>d", group = "Debug" },
    { "<leader>f", group = "Find" },
    { "<leader>g", group = "Git" },
    { "<leader>h", group = "Hunk" },
    { "<leader>l", group = "LSP" },
    { "<leader>q", group = "Session" },
    { "<leader>t", group = "Test" },
    { "<leader>u", group = "UI" },
    { "<leader>v", group = "LaTeX" },
    { "<leader>x", group = "Trouble" },
  })
end)
