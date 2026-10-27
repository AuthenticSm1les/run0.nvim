if vim.g.loaded_run0 then
  return
end
vim.g.loaded_run0 = true

local run0 = require('run0')

-- Registers the run0:// handlers; a later setup() call reconfigures them.
run0.setup(vim.g.run0 or {})

local function target(o)
  local path = o.args ~= '' and o.args or run0.file(0)
  if not path then
    vim.notify('run0: buffer has no file name', vim.log.levels.ERROR)
  end
  return path
end

vim.api.nvim_create_user_command('Run0Write', function(o)
  local path = target(o)
  if path then
    run0.write(0, path, o.line1, o.line2)
  end
end, { nargs = '?', range = '%', complete = 'file', desc = 'Write buffer as root with run0' })

vim.api.nvim_create_user_command('Run0Edit', function(o)
  local path = target(o)
  if path then
    run0.edit(path)
  end
end, { nargs = '?', complete = 'file', desc = 'Edit file as root with run0' })
