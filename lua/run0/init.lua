-- run0.nvim: read and write files that need root, using systemd's run0.
--
-- Files that need root are edited as `run0://<path>` buffers. Neovim refuses
-- to :write a real file it can't write (E505) before any autocommand runs, so
-- the buffer can't keep the file's own name; suda.vim works the same way.
--
-- Writing: the buffer is written as you to a private temp file, then
-- `run0 cp -- <tmp> <file>` copies it over the target. cp writes into the
-- existing file, so its owner and mode are kept. Only cp runs as root.
--
-- Reading: readable files are read directly. Unreadable ones are copied with
-- `run0 cp -- <file> <tmp>` into a temp file you own, then loaded.

local M = {}

M.config = {
  -- argv prefix used to elevate. An empty --background disables run0's tint.
  cmd = { 'run0', '--background=' },
  -- 'gui': run synchronously and let your desktop polkit agent prompt.
  -- 'terminal': run in a floating terminal so run0 can prompt there.
  -- 'auto': 'gui' when $WAYLAND_DISPLAY or $DISPLAY is set, else 'terminal'.
  prompt = 'auto',
  -- Reopen files you can't read or write as run0:// buffers automatically.
  smart = true,
}

local scheme = 'run0://'
local group = vim.api.nvim_create_augroup('run0', { clear = true })

local function notify(msg, level)
  vim.notify('run0: ' .. msg, level or vim.log.levels.INFO)
end

local function use_terminal()
  if M.config.prompt == 'auto' then
    return vim.env.WAYLAND_DISPLAY == nil and vim.env.DISPLAY == nil
  end
  return M.config.prompt == 'terminal'
end

--- The file a buffer edits: the part after run0:// for run0 buffers.
local function file_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.startswith(name, scheme) then
    return name:sub(#scheme + 1)
  end
  return name ~= '' and vim.fn.fnamemodify(name, ':p') or nil
end
M.file = file_of

--- Whether writing `path` needs root.
function M.needs_root(path)
  if vim.uv.fs_stat(path) then
    return vim.fn.filewritable(path) ~= 1
  end
  return vim.fn.filewritable(vim.fs.dirname(path)) ~= 2
end

--- Run `argv` elevated and call `on_done(ok)` when it finishes.
--- Synchronous in gui mode, asynchronous in terminal mode.
local function run(argv, on_done)
  local full = vim.list_extend(vim.deepcopy(M.config.cmd), argv)

  if not use_terminal() then
    local ok, res = pcall(function()
      return vim.system(full, { text = true }):wait()
    end)
    if not ok then
      notify(tostring(res), vim.log.levels.ERROR)
      return on_done(false)
    end
    if res.code ~= 0 and res.stderr ~= '' then
      notify(vim.trim(res.stderr), vim.log.levels.ERROR)
    end
    return on_done(res.code == 0)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(8, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' run0 ',
    title_pos = 'center',
  })
  vim.fn.jobstart(full, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        on_done(code == 0)
      end)
    end,
  })
  vim.cmd.startinsert()
end

-- Tell Neovim the file on disk changed because of us, so it doesn't warn
-- "file has changed since editing started" (W11) later. Only matters for
-- buffers that carry the real file name (:Run0Write from a normal buffer).
local function sync_timestamp(buf)
  local g = vim.api.nvim_create_augroup('run0_timestamp', { clear = true })
  vim.api.nvim_create_autocmd('FileChangedShell', {
    group = g,
    buffer = buf,
    callback = function()
      vim.v.fcs_choice = ''
    end,
  })
  vim.cmd('silent! checktime ' .. buf)
  vim.api.nvim_del_augroup_by_id(g)
end

--- Write lines `line1`..`line2` of `buf` to `path`, as root when needed.
--- When the whole buffer goes to its own file, it is marked unmodified.
function M.write(buf, path, line1, line2)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  path = vim.fn.fnamemodify(path, ':p')
  local own = path == file_of(buf)
  local whole = line1 == 1 and line2 == vim.api.nvim_buf_line_count(buf)

  if own and whole then
    vim.api.nvim_exec_autocmds('BufWritePre', { buffer = buf, modeline = false })
    line2 = vim.api.nvim_buf_line_count(buf) -- formatters may change it
  end

  local function done()
    if own and whole and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      sync_timestamp(buf)
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf, modeline = false })
    end
  end

  if not M.needs_root(path) then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd(('noautocmd keepalt %d,%dwrite! %s'):format(line1, line2, vim.fn.fnameescape(path)))
    end)
    return done()
  end

  local tmp = vim.fn.tempname()
  vim.api.nvim_buf_call(buf, function()
    vim.cmd(('silent noautocmd keepalt %d,%dwrite! %s'):format(line1, line2, vim.fn.fnameescape(tmp)))
  end)

  run({ 'cp', '--', tmp, path }, function(ok)
    os.remove(tmp)
    if not ok then
      return notify('failed to write ' .. path, vim.log.levels.ERROR)
    end
    done()
    notify(('"%s" written'):format(vim.fn.fnamemodify(path, ':~')))
  end)
end

-- Replace the contents of `buf` with the file `src`.
local function load(buf, src, path)
  vim.api.nvim_buf_call(buf, function()
    local ul = vim.bo.undolevels
    vim.bo.undolevels = -1 -- loading isn't an undoable change
    vim.cmd('silent keepalt noautocmd %delete _')
    if src then
      vim.cmd('silent keepalt noautocmd 0read ++edit ' .. vim.fn.fnameescape(src))
      vim.cmd('silent keepalt noautocmd $delete _')
    end
    vim.bo.undolevels = ul
    vim.bo.modified = false
    local ft = vim.filetype.match({ filename = path, buf = buf })
    if ft and ft ~= vim.bo.filetype then
      vim.bo.filetype = ft
    end
  end)
end

-- BufReadCmd for run0://<path>
local function on_read(ev)
  local buf, path = ev.buf, file_of(ev.buf)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].swapfile = false

  if not vim.uv.fs_stat(path) then
    return load(buf, nil, path)
  end
  if vim.fn.filereadable(path) == 1 then
    return load(buf, path, path)
  end

  local tmp = vim.fn.tempname()
  local f = assert(io.open(tmp, 'w'))
  f:close()
  run({ 'cp', '--', path, tmp }, function(ok)
    if ok and vim.api.nvim_buf_is_valid(buf) then
      load(buf, tmp, path)
    elseif not ok then
      notify('failed to read ' .. path, vim.log.levels.ERROR)
    end
    os.remove(tmp)
  end)
end

-- BufWriteCmd for run0://<path>
local function on_write(ev)
  M.write(ev.buf, file_of(ev.buf), vim.fn.line("'["), vim.fn.line("']"))
end

--- Edit `path` as a run0:// buffer in the current window.
function M.edit(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(scheme .. vim.fn.fnamemodify(path, ':p')))
end

-- Whether a normal buffer's file needs root to read or write.
local function wants_run0(path)
  local stat = vim.uv.fs_stat(path)
  if stat then
    return stat.type == 'file' and (vim.fn.filereadable(path) == 0 or vim.fn.filewritable(path) ~= 1)
  end
  return vim.fn.isdirectory(vim.fs.dirname(path)) == 1 and M.needs_root(path)
end

-- Swap a normal buffer for its run0:// twin in every window showing it.
local function convert(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified or vim.bo[buf].buftype ~= '' then
    return
  end
  local path = file_of(buf)
  local wins = vim.fn.win_findbuf(buf)
  if not path or #wins == 0 or vim.startswith(vim.api.nvim_buf_get_name(buf), scheme) then
    return
  end
  if not wants_run0(path) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(wins[1])
  vim.api.nvim_win_call(wins[1], function()
    vim.cmd('keepalt keepjumps edit ' .. vim.fn.fnameescape(scheme .. path))
  end)
  local new = vim.api.nvim_win_get_buf(wins[1])
  for i = 2, #wins do
    vim.api.nvim_win_set_buf(wins[i], new)
  end
  if new ~= buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  pcall(vim.api.nvim_win_set_cursor, wins[1], cursor)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd('BufReadCmd', { group = group, pattern = scheme .. '*', callback = on_read })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, pattern = scheme .. '*', callback = on_write })
  if M.config.smart then
    -- An unreadable file only fires BufAdd, so listen for that as well.
    vim.api.nvim_create_autocmd({ 'BufAdd', 'BufReadPost', 'BufNewFile', 'BufEnter' }, {
      group = group,
      callback = function(ev)
        vim.schedule(function()
          convert(ev.buf)
        end)
      end,
    })
  end
end

return M
