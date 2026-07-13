# jj-view.nvim

A narrow side panel for [jj](https://github.com/jj-vcs/jj), like a file
explorer for your working-copy changes.

It shows:

- the current change id
- the current bookmark, if any
- the current description
- every file edited in the working copy (`jj st`)
- the parent change: short id and bookmark

Press `<CR>` on a file to open it in the main window, `p` to open it while
keeping focus in the panel, or `d` to pop up its `jj diff` in a float.

## Install

With the builtin `vim.pack`:

```lua
vim.pack.add({ "https://github.com/devjgm/jj-view.nvim" })
require("jj-view").setup()
```

## Keys

| Key            | Where  | Action                          |
| -------------- | ------ | ------------------------------- |
| `:JjView`      | global | toggle the panel                |
| `<CR>` / `o`   | panel  | open the file under the cursor  |
| `p`            | panel  | open the file, keep focus here  |
| `d`            | panel  | `jj diff` the file in a float   |
| `R`            | panel  | refresh                         |
| `q`            | panel  | close                           |

jj-view sets no global keymap. Map `:JjView` to whatever you like:

```lua
vim.keymap.set("n", "<leader>j", "<cmd>JjView<cr>", { desc = "jj-view" })
```

## Config

```lua
require("jj-view").setup({
    width = 38,      -- panel width
})
```

## Requirements

- Neovim 0.10+
- the `jj` binary on `PATH`

## Appearance

The whole panel is colored. The file paths are underlined, which is the one
cue that those are the actionable lines (`<CR>` acts on them, not on the
context around them). Every highlight links to a standard group, so it follows
your colorscheme and can be overridden:

```lua
vim.api.nvim_set_hl(0, "JjViewFile", { link = "Directory" })
```

Groups: `JjViewTitle`, `JjViewLabel`, `JjViewChange`, `JjViewBookmark`,
`JjViewDesc`, `JjViewFile`, `JjViewHint`, `JjViewAdded`, `JjViewModified`,
`JjViewRemoved`, `JjViewRenamed`. See `:help jj-view-highlights`.

## Refreshing

The panel re-reads jj on open, `R`, `:w`, and when Neovim regains focus or you
step into the panel. Focus/enter re-reads use `--ignore-working-copy` so they
never snapshot the working copy, avoiding divergent operations when a `jj` is
running in another terminal. Under tmux, focus refresh needs
`set -g focus-events on`.

## Development

```sh
just test   # headless nvim test suite (no external deps)
just fmt    # stylua
just check  # stylua --check
```

See `:help jj-view` for the full docs.
