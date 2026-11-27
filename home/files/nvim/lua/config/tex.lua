local tex_group = vim.api.nvim_create_augroup("tex_qol", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = tex_group,
  pattern = { "tex", "plaintex" },
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spelllang = "en_gb"
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
    vim.opt_local.formatoptions:append("t")

    vim.opt_local.conceallevel = 0
    vim.opt_local.foldmethod = "expr"
    vim.opt_local.foldexpr = "vimtex#fold#level(v:lnum)"
    vim.opt_local.foldtext = "vimtex#fold#text()"
  end,
})

-- VimTeX respects $out_dir and $aux_dir from a project's latexmkrc but not
-- $jobname, so it looks for <main>.pdf while latexmk writes <jobname>.pdf and
-- the viewer opens a missing file. Pass the latexmkrc jobname to VimTeX.
vim.api.nvim_create_autocmd("User", {
  group = tex_group,
  pattern = "VimtexEventInitPost",
  callback = function()
    vim.cmd([[
      if exists('b:vimtex.compiler.file_info') && b:vimtex.compiler.name ==# 'latexmk'
        let s:job = vimtex#compiler#latexmk#get_rc_opt(b:vimtex.root, 'jobname', 0, '')[0]
        if !empty(s:job) && index(b:vimtex.compiler.options, '-jobname=' . s:job) < 0
          let b:vimtex.compiler.options = b:vimtex.compiler.options + ['-jobname=' . s:job]
          let b:vimtex.compiler.file_info.jobname = s:job
        endif
      endif
    ]])
  end,
})

pcall(function()
  local npairs = require("nvim-autopairs")
  local Rule = require("nvim-autopairs.rule")
  npairs.add_rules({
    Rule("$", "$", { "tex", "plaintex" }):with_pair(function(opts)
      -- Don't pair if next char is already "$" (would create "$$$")
      -- Don't pair if already inside an odd number of "$" (inside inline math)
      local before = opts.line:sub(1, opts.col - 1)
      local after  = opts.line:sub(opts.col, opts.col)
      local count  = select(2, before:gsub("%$", ""))
      return after ~= "$" and (count % 2 == 0)
    end),
  })
end)
