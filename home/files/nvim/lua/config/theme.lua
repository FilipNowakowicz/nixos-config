-----------------------------------------------------------
-- Colours from the running desktop theme (home/theme)
-----------------------------------------------------------
-- The theme module links the running theme's base16 palette to a fixed path,
-- and theme-switch sends SIGUSR1 to every Neovim after relinking it, so open
-- editors repaint with the rest of the desktop. Without that file (a machine
-- without the desktop theme), gruvbox-material stays.
local M = {}

local generated = require("config.generated")
local palette_file = (generated.ui or {}).theme_palette

local function fallback()
  vim.o.background = "dark"
  vim.g.gruvbox_material_background = "medium"
  vim.g.gruvbox_material_foreground = "material"
  pcall(vim.cmd.colorscheme, "gruvbox-material")
end

local function read_theme()
  if not palette_file or not vim.uv.fs_stat(palette_file) then
    return nil
  end
  local ok, theme = pcall(dofile, palette_file)
  if ok and type(theme) == "table" and type(theme.palette) == "table" then
    return theme
  end
  vim.notify("theme: cannot read " .. palette_file, vim.log.levels.WARN)
end

function M.apply()
  local theme = read_theme()
  local has_base16, base16 = pcall(require, "mini.base16")
  if not theme or not has_base16 then
    return fallback()
  end
  vim.o.background = theme.background or "dark"
  base16.setup({ palette = theme.palette, use_cterm = true })
  -- Other plugins (lualine's auto theme) re-read highlights on ColorScheme.
  vim.g.colors_name = "desktop-" .. (theme.name or "theme")
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = vim.g.colors_name, modeline = false })
end

vim.api.nvim_create_autocmd("Signal", {
  pattern = "SIGUSR1",
  desc = "Repaint from the desktop theme after theme-switch",
  callback = function()
    vim.schedule(M.apply)
  end,
})

return M
