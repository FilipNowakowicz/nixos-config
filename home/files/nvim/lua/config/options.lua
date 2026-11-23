vim.g.mapleader = " "

if vim.g.neovide then
  vim.o.guifont = "JetBrainsMono Nerd Font:h11"
  vim.g.neovide_scroll_animation_length = 0.0
  vim.g.neovide_cursor_animation_length = 0.03
  vim.g.neovide_cursor_trail_size = 0.2
  vim.g.neovide_hide_mouse_when_typing = true
end

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.clipboard = "unnamedplus"
vim.opt.termguicolors = true
vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.opt.undofile = true

-- Neovim's default SwapExists handler (augroup nvim.swapfile) picks "Edit
-- anyway" whenever another live Nvim owns the swapfile. Two writable copies of
-- one file then save over each other, and the second also overwrites the
-- shared undofile, so the lost text can't be undone back. Open it read-only
-- instead while the owner runs; a dead owner still gets the recover prompt.
pcall(vim.api.nvim_del_augroup_by_name, "nvim.swapfile")
vim.api.nvim_create_autocmd("SwapExists", {
  group = vim.api.nvim_create_augroup("config.swapfile", { clear = true }),
  desc = "Open read-only when another running Nvim is editing the file",
  callback = function()
    local info = vim.fn.swapinfo(vim.v.swapname)
    local alive = not info.error and info.pid > 0 and vim.uv.kill(info.pid, 0) == 0
    if not alive then
      vim.v.swapchoice = "" -- Show the prompt, which offers recovery.
      return
    end
    vim.v.swapchoice = "o"
    vim.schedule(function()
      vim.notify(
        ("Already open in Nvim process %d: opened read-only"):format(info.pid),
        vim.log.levels.WARN
      )
    end)
  end,
})
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4

vim.opt.foldmethod = "expr"
vim.opt.foldexpr   = "v:lua.vim.treesitter.foldexpr()"
vim.opt.foldenable = false   -- open by default, fold manually with zc/zo
