# run0.nvim

Edit files that need root from Neovim, using systemd's [`run0`](https://www.freedesktop.org/software/systemd/man/latest/run0.html) instead of sudo. No setuid binary, no password piped through stdin: run0 asks polkit, and polkit asks you.

## How it works

Files you can't read or write are reopened as `run0://<path>` buffers. Neovim refuses to `:write` a real file it can't write before any plugin gets a say, so the buffer can't keep the file's own name (vim-suda does the same).

- **Saving** writes the buffer as you to a private temp file, then runs `run0 cp -- <tmp> <file>`. cp writes into the existing file, so its owner and mode stay the same. Only `cp` runs as root.
- **Opening** a readable file reads it directly with no prompt. An unreadable file is copied with `run0 cp` into a temp file you own, then loaded.

Expect one polkit prompt per save (and per open of an unreadable file). run0 doesn't cache authorization.

## Requirements

- Neovim 0.11+
- systemd 256+ with polkit running
- a polkit agent: your desktop's, or the terminal prompt mode below

## Install

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/AuthenticSm1les/run0.nvim' })
```

With lazy.nvim:

```lua
{ 'AuthenticSm1les/run0.nvim', lazy = false }
```

The plugin sets itself up when loaded. If you use vim-suda, remove it or turn off `suda_smart_edit`, since both would try to take over the same buffers.

## Configuration

Set `vim.g.run0` before the plugin loads, or call `require('run0').setup()` afterwards:

```lua
vim.g.run0 = {
  cmd = { 'run0', '--background=' }, -- elevation command; empty --background turns off run0's red tint
  prompt = 'auto', -- 'gui' | 'terminal' | 'auto'
  smart = true,    -- reopen files that need root as run0:// buffers automatically
}
```

- `gui` runs run0 synchronously; your desktop's polkit agent shows the password dialog.
- `terminal` runs run0 in a floating terminal so it can prompt there (for TTYs and SSH). Saving finishes asynchronously, so `:wq` stops with "No write since last change" instead of quitting. Use `:w`, then `:q`.
- `auto` picks `gui` when `$WAYLAND_DISPLAY` or `$DISPLAY` is set, `terminal` otherwise.

## Commands

- `:Run0Edit [file]` opens a file (default: the current one) as a `run0://` buffer.
- `:[range]Run0Write [file]` writes the buffer, or a range of it, as root, from any buffer.

## Limitations

- `run0://` buffers are not real file buffers, so LSP clients and other plugins that only look at normal files skip them. Filetype detection and syntax highlighting still work.
- Writes go through `cp` into the existing file, not an atomic write-and-rename. A failure partway through can leave the file truncated.
- New files created in root-owned directories are owned by root with mode 0644.
