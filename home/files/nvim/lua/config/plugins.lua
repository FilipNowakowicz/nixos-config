local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  { "sainnhe/gruvbox-material", lazy = false, priority = 1000 },

  { "nvim-tree/nvim-web-devicons", lazy = true },

  -----------------------------------------------------------
  -- LSP + formatting + linting
  -----------------------------------------------------------
  { "neovim/nvim-lspconfig" },
  { "stevearc/conform.nvim" },
  { "mfussenegger/nvim-lint" },

  -----------------------------------------------------------
  -- Completion (blink.cmp replaces nvim-cmp)
  -----------------------------------------------------------
  { "L3MON4D3/LuaSnip" },
  {
    "saghen/blink.cmp",
    version = "*",
    dependencies = {
      "rafamadriz/friendly-snippets",
      { "giuxtaposition/blink-cmp-copilot", dependencies = { "zbirenbaum/copilot.lua" } },
      { "saghen/blink.compat", version = "*" },
      "hrsh7th/cmp-omni",
      "kdheepak/cmp-latex-symbols",
    },
    config = function(_, opts)
      require("blink.cmp").setup(opts)
      require("luasnip.loaders.from_vscode").lazy_load()
    end,
    opts = {
      keymap = {
        ["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
        ["<C-e>"]     = { "cancel", "fallback" },
        ["<C-y>"]     = { "select_and_accept" },
        ["<CR>"]      = { "accept", "fallback" },
        ["<Tab>"]     = { "select_next", "snippet_forward", "fallback" },
        ["<S-Tab>"]   = { "select_prev", "snippet_backward", "fallback" },
        ["<C-n>"]     = { "select_next", "fallback" },
        ["<C-p>"]     = { "select_prev", "fallback" },
        ["<C-b>"]     = { "scroll_documentation_up", "fallback" },
        ["<C-f>"]     = { "scroll_documentation_down", "fallback" },
      },
      sources = {
        default = { "lsp", "path", "snippets", "buffer", "copilot" },
        per_filetype = {
          tex      = { "omni", "latex_symbols", "lsp", "snippets", "buffer", "path" },
          plaintex = { "omni", "latex_symbols", "lsp", "snippets", "buffer", "path" },
        },
        providers = {
          copilot = {
            name = "copilot",
            module = "blink-cmp-copilot",
            score_offset = 100,
            async = true,
          },
          omni = {
            name = "omni",
            module = "blink.compat.source",
            opts = { name = "omni" },
          },
          latex_symbols = {
            name = "latex_symbols",
            module = "blink.compat.source",
            opts = { name = "latex_symbols" },
          },
        },
      },
      snippets = { preset = "luasnip" },
      completion = {
        accept = { auto_brackets = { enabled = true } },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 200,
        },
        menu = {
          draw = { treesitter = { "lsp" } },
        },
      },
      appearance = { nerd_font_variant = "mono" },
    },
  },

  -- Copilot backend (suggestion mode off — blink-copilot shows in completion menu)
  {
    "zbirenbaum/copilot.lua",
    event = "InsertEnter",
    opts = {
      suggestion = { enabled = false },
      panel = { enabled = false },
      filetypes = { markdown = true },
    },
  },

  -----------------------------------------------------------
  -- Debugging + testing
  -----------------------------------------------------------
  { "mfussenegger/nvim-dap" },
  { "nvim-neotest/nvim-nio" },
  { "rcarriga/nvim-dap-ui" },
  { "nvim-neotest/neotest" },
  { "nvim-neotest/neotest-python" },

  -----------------------------------------------------------
  -- UI
  -----------------------------------------------------------
  { "nvim-lualine/lualine.nvim" },
  { "stevearc/oil.nvim" },
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      notifier  = { enabled = true },
      bigfile   = { enabled = true },
      words     = { enabled = true },
      dashboard = { enabled = true },
    },
  },

  -----------------------------------------------------------
  -- Treesitter
  -----------------------------------------------------------
  { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
  { "nvim-treesitter/nvim-treesitter-textobjects", dependencies = { "nvim-treesitter/nvim-treesitter" } },
  { "nvim-treesitter/nvim-treesitter-context" },

  -----------------------------------------------------------
  -- Navigation + search
  -----------------------------------------------------------
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
  },
  { url = "https://codeberg.org/andyg/leap.nvim" },

  -----------------------------------------------------------
  -- Git
  -----------------------------------------------------------
  { "lewis6991/gitsigns.nvim" },
  { "tpope/vim-fugitive" },

  -----------------------------------------------------------
  -- Editing utilities
  -----------------------------------------------------------
  {
    "numToStr/Comment.nvim",
    opts = {
      pre_hook = function()
        if vim.bo.filetype == "tex" or vim.bo.filetype == "plaintex" then
          return vim.bo.commentstring
        end
      end,
    },
  },
  { "windwp/nvim-autopairs" },
  { "kylechui/nvim-surround", opts = {} },
  { "tpope/vim-sleuth" },

  -----------------------------------------------------------
  -- Workspace
  -----------------------------------------------------------
  { "folke/trouble.nvim" },
  { "folke/which-key.nvim" },
  { "folke/persistence.nvim", event = "BufReadPre" },
  { "lukas-reineke/indent-blankline.nvim", main = "ibl" },
  { "akinsho/toggleterm.nvim" },

  -----------------------------------------------------------
  -- Language-specific
  -----------------------------------------------------------
  { "ellisonleao/glow.nvim", cmd = "Glow", opts = {} },
  {
    "lervag/vimtex",
    ft = { "tex", "plaintex" },
    init = function()
      vim.g.vimtex_view_method = "zathura"
      vim.g.vimtex_compiler_method = "latexmk"
      vim.g.tex_flavor = "latex"
      vim.g.vimtex_quickfix_open_on_warning = 0
      vim.g.vimtex_quickfix_mode = 2
      vim.g.vimtex_imaps_enabled = 0
      vim.g.vimtex_syntax_enabled = 0
      vim.g.vimtex_compiler_latexmk = {
        out_dir = "build",
        options = {
          "-pdf",
          "-interaction=nonstopmode",
          "-synctex=1",
        },
      }
    end,
  },
}, {
  -- For NixOS compatibility
  lockfile = vim.fn.stdpath("data") .. "/lazy/lazy-lock.json",

  checker = { enabled = false },
  change_detection = { notify = false },
})
