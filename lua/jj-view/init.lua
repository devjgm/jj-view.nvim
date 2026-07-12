-- jj-view: a narrow side panel showing the current jj change and its
-- working-copy files, with file-explorer style jumping. No diffing.

local util = require("jj-view.util")

local M = {}

M.version = "0.1.0"

local config = {
    width = 38,
    -- toggle key. Ctrl-Shift-J needs a terminal that speaks the kitty
    -- keyboard protocol (ghostty, kitty, wezterm, ...); otherwise use :JjView.
    key = "<C-S-j>",
}

local ns = vim.api.nvim_create_namespace("jjview")
-- win/buf are reused across toggles; line_files maps a buffer line (1-based) to
-- the absolute path to open; prev_win is where <CR> sends the file; root is the
-- workspace root cached at open (it can't change mid-session). refresh_pending
-- (set on demand) holds the ignore_wc of a coalesced render, or nil when idle.
local state = { win = nil, buf = nil, prev_win = nil, line_files = {}, root = nil }

-- ===== jj plumbing =====

-- Run jj with a list of args (no shell, so no quoting worries). jj disables
-- color when stdout is not a tty, so the output is clean text. Returns
-- ok, stdout, stderr.
--
-- ignore_wc adds --ignore-working-copy: jj then reads the repo state without
-- snapshotting our working copy. Used for the frequent focus/enter refreshes
-- so we don't race a snapshot against a jj running in another terminal (which
-- is what produces divergent operations). External changes are already
-- snapshotted by that other terminal, so we still see them.
local function jj(args, ignore_wc)
    local cmd = { "jj" }
    if ignore_wc then
        table.insert(cmd, "--ignore-working-copy")
    end
    vim.list_extend(cmd, args)
    -- pcall so a missing jj binary degrades to "not a jj repo" instead of an
    -- error; the timeout keeps a hung jj (lock contention, slow fsmonitor) from
    -- freezing nvim.
    local ok, res = pcall(function()
        return vim.system(cmd, { text = true }):wait(2000)
    end)
    if not ok then
        return false, "", tostring(res)
    end
    return res.code == 0, res.stdout or "", res.stderr or ""
end

-- Absolute workspace root, so files open correctly regardless of nvim's cwd
-- (jj prints its file paths relative to this root).
local function get_root()
    local ok, out = jj({ "root" })
    if not ok then
        return nil
    end
    return (out:gsub("%s+$", ""))
end

-- change id, local bookmarks, and description of the working-copy commit, in
-- one call. description is last in the template so it can span lines.
local function get_meta(ignore_wc)
    local ok, out = jj({
        "log",
        "-r",
        "@",
        "--no-graph",
        "-T",
        'change_id.short(8) ++ "\n" ++ local_bookmarks.join(" ") ++ "\n" ++ description',
    }, ignore_wc)
    if not ok then
        return nil
    end
    return util.parse_meta(out)
end

-- Working-copy changes (@ against its parent), same set `jj st` shows.
local function get_files(root, ignore_wc)
    local ok, out = jj({ "diff", "-r", "@", "--summary" }, ignore_wc)
    if not ok then
        return {}
    end
    return util.parse_summary(out, root)
end

-- The parent commit(s) of @: short change id and local bookmarks. Usually one;
-- a merge has several. \x1f separates the fields so a bookmark's spaces survive.
local function get_parents(ignore_wc)
    local ok, out = jj({
        "log",
        "-r",
        "@-",
        "--no-graph",
        "-T",
        'change_id.short(8) ++ "\x1f" ++ local_bookmarks.join(" ") ++ "\n"',
    }, ignore_wc)
    if not ok then
        return {}
    end
    return util.parse_parents(out)
end

-- ===== rendering helpers =====

-- Link our groups to standard ones so we follow the active colorscheme. The
-- whole panel is colored; the only actionable lines (the file paths) are
-- underlined, so it's clear that <CR> acts on those and not on the context.
local function set_highlights()
    local function d(name, link)
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
    d("JjViewTitle", "Title") -- banner and the "Files (N)" heading
    d("JjViewLabel", "Comment") -- field labels: Change / Bookmark / Parent
    d("JjViewChange", "Identifier") -- change ids
    d("JjViewBookmark", "Special") -- bookmark names
    d("JjViewDesc", "Normal") -- the description text
    d("JjViewHint", "Comment") -- the footer key hints
    d("JjViewAdded", "Added")
    d("JjViewModified", "Changed")
    d("JjViewRemoved", "Removed")
    d("JjViewRenamed", "Changed")
    -- actionable file paths: underlined (like a link), colored by Normal
    vim.api.nvim_set_hl(0, "JjViewFile", { underline = true, default = true })
end

-- Rebuild the panel contents from a fresh jj query. ignore_wc is forwarded to
-- jj (see the jj() comment): true for cheap focus/enter re-reads, false when we
-- want a snapshot (open, save, manual refresh) so our own edits show. The root
-- is cached at open; a bail here means the panel is not open or lost its repo.
local function render(ignore_wc)
    local root = state.root
    if not root then
        return false
    end
    local meta = get_meta(ignore_wc) or { change = "?", bookmark = "", description = "" }
    local files = get_files(root, ignore_wc)
    local parents = get_parents(ignore_wc)
    local lines, hl, line_files = util.build_lines(meta, files, parents, config.width, M.version)

    -- remember the file under the cursor so a refresh does not move the rug
    local keep_abs
    if
        state.win
        and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_get_current_win() == state.win
    then
        keep_abs = state.line_files[vim.api.nvim_win_get_cursor(state.win)[1]]
    end
    state.line_files = line_files

    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    for _, h in ipairs(hl) do
        local row, col, end_col, group = h[1], h[2], h[3], h[4]
        local opts = { hl_group = group }
        if end_col == -1 then
            opts.end_row, opts.end_col = row + 1, 0
        else
            opts.end_col = end_col
        end
        pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, row, col, opts)
    end

    -- put the cursor back on the same file if it is still listed
    if keep_abs then
        for lnum, abs in pairs(line_files) do
            if abs == keep_abs then
                pcall(vim.api.nvim_win_set_cursor, state.win, { lnum, 0 })
                break
            end
        end
    end
    return true
end

-- ===== window management =====

local function is_open()
    return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function ensure_buf()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide" -- survive close so we can reuse it
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = "jjview"
    pcall(vim.api.nvim_buf_set_name, buf, "jj-view")

    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    map("<CR>", M.open_file)
    map("o", M.open_file)
    map("p", function()
        M.open_file(true) -- open but keep focus in the panel
    end)
    map("q", M.close)
    map("R", M.refresh)
    map(config.key, M.toggle)
    state.buf = buf
end

function M.open()
    if is_open() then
        return
    end
    -- resolve the repo before opening anything: outside a jj repo (or with no
    -- jj), warn once and don't leave a dead panel that re-warns on every refresh.
    local root = get_root()
    if not root then
        vim.notify("jj-view: not in a jj repo", vim.log.levels.WARN)
        return
    end
    state.root = root
    state.prev_win = vim.api.nvim_get_current_win()
    ensure_buf()

    vim.cmd("topleft vsplit") -- full-height window on the far left
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.api.nvim_win_set_width(state.win, config.width)

    local wo = vim.wo[state.win]
    wo.number, wo.relativenumber = false, false
    wo.signcolumn, wo.foldcolumn = "no", "0"
    wo.wrap, wo.list = false, false
    wo.cursorline, wo.winfixwidth = true, true
    wo.statusline = " jj-view"

    if render(false) then
        -- land on the first file for immediate jumping
        local first = math.huge
        for lnum in pairs(state.line_files) do
            first = math.min(first, lnum)
        end
        if first ~= math.huge then
            vim.api.nvim_win_set_cursor(state.win, { first, 0 })
        end
    end
end

function M.close()
    if is_open() then
        vim.api.nvim_win_close(state.win, true)
    end
    state.win = nil
end

function M.toggle()
    if is_open() then
        M.close()
    else
        M.open()
    end
end

-- ignore_wc: pass true from the cheap focus/enter triggers, false (or nil, e.g.
-- from the `R` keymap) to force a snapshot.
function M.refresh(ignore_wc)
    if is_open() then
        render(ignore_wc == true)
    end
end

-- Open the file on the cursor line in the main editor window. When stay is
-- true, focus returns to the panel afterward (preview style), so you can keep
-- moving through the list.
function M.open_file(stay)
    -- read from the current window (0): the mapping only fires from a window
    -- showing the panel buffer, and state.win may be stale if it is shown twice.
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local path = state.line_files[lnum]
    if not path then
        return
    end
    -- a usable target is a real (non-floating) window other than the panel
    local function usable(w)
        return w
            and vim.api.nvim_win_is_valid(w)
            and w ~= state.win
            and vim.api.nvim_win_get_config(w).relative == ""
    end
    local target = usable(state.prev_win) and state.prev_win or nil
    if not target then
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if usable(w) then
                target = w
                break
            end
        end
    end
    if target then
        vim.api.nvim_set_current_win(target)
    else
        vim.cmd("botright vsplit") -- panel is the only window: make a real one
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if stay and is_open() then
        vim.api.nvim_set_current_win(state.win)
    end
end

-- ===== setup =====

function M.setup(opts)
    config = vim.tbl_extend("force", config, opts or {})
    set_highlights()

    vim.api.nvim_create_user_command("JjView", M.toggle, { desc = "Toggle jj-view panel" })
    vim.keymap.set("n", config.key, M.toggle, { desc = "Toggle jj-view", silent = true })

    local group = vim.api.nvim_create_augroup("JjView", { clear = true })

    -- Coalesce a burst of triggers (`:wa`, focus + enter arriving together) into
    -- one render, and only ever schedule while the panel is open. If a snapshot
    -- refresh (ignore_wc false) lands while a cheap re-read is queued, it wins,
    -- so a save is never under-snapshotted.
    local function schedule_refresh(ignore_wc)
        if not is_open() then
            return
        end
        if state.refresh_pending ~= nil then
            if ignore_wc == false then
                state.refresh_pending = false
            end
            return
        end
        state.refresh_pending = ignore_wc
        vim.schedule(function()
            local wc = state.refresh_pending
            state.refresh_pending = nil
            M.refresh(wc)
        end)
    end

    -- re-link highlights after a colorscheme switch
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

    -- our own save: snapshot so the just-saved file appears
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function()
            schedule_refresh(false)
        end,
    })

    -- Regaining focus catches a jj change made in another terminal; stepping
    -- into the panel catches one made without leaving nvim. Both re-read without
    -- snapshotting. tmux needs `set -g focus-events on` for the focus case.
    vim.api.nvim_create_autocmd("FocusGained", {
        group = group,
        callback = function()
            schedule_refresh(true)
        end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        callback = function()
            -- only when entering the panel itself, not on every window switch
            if is_open() and vim.api.nvim_get_current_win() == state.win then
                schedule_refresh(true)
            end
        end,
    })

    -- Don't strand the panel: when the last real editor window closes, close the
    -- panel too (which lets nvim exit). Every action is guarded, so a lingering
    -- float or an unsaved buffer surfaces vim's own message, not a lua error.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function()
            if not is_open() then
                return
            end
            vim.schedule(function()
                if not is_open() then
                    return
                end
                local wins = vim.api.nvim_tabpage_list_wins(0)
                local others = 0
                for _, w in ipairs(wins) do
                    -- ignore the panel itself and any floating windows
                    if w ~= state.win and vim.api.nvim_win_get_config(w).relative == "" then
                        others = others + 1
                    end
                end
                if others == 0 then
                    -- close the panel; if it is the last window, or a float
                    -- blocks closing it, quit instead. pcall so neither errors.
                    if #wins > 1 and pcall(vim.api.nvim_win_close, state.win, true) then
                        state.win = nil
                    else
                        state.win = nil
                        pcall(vim.cmd, "quit")
                    end
                end
            end)
        end,
    })
end

return M
