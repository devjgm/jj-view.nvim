-- Pure, side-effect-free helpers: text layout and parsing of jj output. Kept
-- separate from the nvim/jj glue in init.lua so they can be unit tested without
-- a running jj or any windows.

local M = {}

-- Greedy word-wrap a single line to width w. Splits on whitespace.
function M.wrap_text(s, w)
    if s == "" then
        return { "" }
    end
    local out, line = {}, ""
    for word in s:gmatch("%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= w then
            line = line .. " " .. word
        else
            table.insert(out, line)
            line = word
        end
    end
    if line ~= "" then
        table.insert(out, line)
    end
    return out
end

-- Greedily pack whole items onto lines no wider than w (two spaces between
-- items). Unlike wrap_text this never splits an item, so "p preview" stays
-- together.
function M.pack(items, w)
    local out, line = {}, ""
    for _, it in ipairs(items) do
        local cand = line == "" and it or (line .. "  " .. it)
        if #cand <= w then
            line = cand
        else
            if line ~= "" then
                table.insert(out, line)
            end
            line = it
        end
    end
    if line ~= "" then
        table.insert(out, line)
    end
    return out
end

-- Truncate keeping the tail (the basename), which is the informative end of a
-- path. Works in display columns and trims whole characters, so multibyte
-- paths are neither split mid-codepoint nor left over-wide.
function M.truncate_left(s, max)
    if vim.fn.strdisplaywidth(s) <= max then
        return s
    end
    local chars = vim.fn.strchars(s)
    local keep = chars
    while keep > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(s, chars - keep)) > max - 3 do
        keep = keep - 1
    end
    return "..." .. vim.fn.strcharpart(s, chars - keep)
end

-- Highlight group for a jj --summary status letter.
function M.status_group(s)
    if s == "A" then
        return "JjViewAdded"
    elseif s == "D" then
        return "JjViewRemoved"
    elseif s == "R" or s == "C" then
        return "JjViewRenamed"
    end
    return "JjViewModified"
end

-- Parse the metadata template output (change\nbookmark\ndescription...). The
-- description is last so it may span the remaining lines.
function M.parse_meta(out)
    local lines = vim.split(out, "\n", { plain = true })
    local desc = table.concat(vim.list_slice(lines, 3), "\n"):gsub("%s+$", "")
    return { change = lines[1] or "", bookmark = lines[2] or "", description = desc }
end

-- Parse `jj diff --summary` lines ("M path") into {status, path, abs}, with abs
-- joined onto the workspace root so it opens regardless of cwd.
function M.parse_summary(out, root)
    local files = {}
    for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
        if line ~= "" then
            local status, path = line:sub(1, 1), line:sub(3)
            -- jj renders renames/copies condensed, e.g. "a/b/{old.rs => new.rs}"
            -- or "{a/x.rs => c/y.rs}". Resolve to the new path so it opens.
            local pre, _, new, post = path:match("^(.-){(.-) => (.-)}(.*)$")
            if pre then
                path = pre .. new .. post
            end
            table.insert(files, { status = status, path = path, abs = root .. "/" .. path })
        end
    end
    return files
end

-- Parse the parent template output. Each line is "change\x1fbookmarks"; \x1f
-- keeps a bookmark's spaces from being confused with the field separator.
function M.parse_parents(out)
    local parents = {}
    for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
        if line ~= "" then
            local change, bookmark = line:match("^(.-)\x1f(.*)$")
            table.insert(parents, { change = change or line, bookmark = bookmark or "" })
        end
    end
    return parents
end

-- Build the panel body from already-fetched data. Pure (no windows, no jj), so
-- the whole layout is unit-testable. Returns:
--   lines       list of strings
--   hl          list of { row, col, end_col, group }; end_col -1 = to line end
--   line_files  map of 1-based line number -> absolute path to open
-- The panel is fully colored; the file paths are underlined (JjViewFile), the
-- one visual cue that those are the actionable lines.
function M.build_lines(meta, files, parents, width, version)
    local lines, hl, line_files = {}, {}, {}
    local function add(text)
        table.insert(lines, text)
        return #lines - 1
    end
    local function mark(row, col, end_col, group)
        table.insert(hl, { row, col, end_col, group })
    end

    mark(add(" jj-view  v" .. version), 0, -1, "JjViewTitle")
    add("")

    local row = add("  Change    " .. meta.change)
    mark(row, 2, 8, "JjViewLabel")
    mark(row, 12, -1, "JjViewChange")

    local has_bookmark = meta.bookmark ~= ""
    row = add("  Bookmark  " .. (has_bookmark and meta.bookmark or "(none)"))
    mark(row, 2, 10, "JjViewLabel")
    mark(row, 12, -1, has_bookmark and "JjViewBookmark" or "JjViewLabel")
    add("")

    if meta.description == "" then
        mark(add("  (no description)"), 0, -1, "JjViewLabel")
    else
        for _, dline in ipairs(vim.split(meta.description, "\n", { plain = true })) do
            for _, w in ipairs(M.wrap_text(dline, width - 3)) do
                mark(add("  " .. w), 0, -1, "JjViewDesc")
            end
        end
    end
    add("")

    mark(add("  Files (" .. #files .. ")"), 0, -1, "JjViewTitle")
    if #files == 0 then
        mark(add("  (working copy clean)"), 0, -1, "JjViewLabel")
    else
        for _, f in ipairs(files) do
            local frow = add("  " .. f.status .. " " .. M.truncate_left(f.path, width - 5))
            mark(frow, 2, 3, M.status_group(f.status)) -- status letter, diff-colored
            mark(frow, 4, -1, "JjViewFile") -- path, underlined = actionable
            line_files[frow + 1] = f.abs
        end
    end

    add("")
    mark(add("  Parent"), 0, -1, "JjViewLabel")
    for _, p in ipairs(parents) do
        local text = "   " .. p.change
        local bm_col
        if p.bookmark ~= "" then
            bm_col = #text + 2
            text = text .. "  " .. p.bookmark
        end
        local prow = add(text)
        mark(prow, 3, 3 + #p.change, "JjViewChange")
        if bm_col then
            mark(prow, bm_col, -1, "JjViewBookmark")
        end
    end

    add("")
    for _, l in ipairs(M.pack({ "CR open", "p preview", "R refresh", "q close" }, width - 2)) do
        mark(add(" " .. l), 0, -1, "JjViewHint")
    end

    return lines, hl, line_files
end

return M
