-- API / integration checks. open() now requires a real jj repo, so set up a
-- throwaway one in a tempdir and run inside it. Skipped if jj is unavailable.

local jv = require("jj-view")

local function panel_win()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "jjview" then
            return w
        end
    end
end

local function panel_count()
    local n = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "jjview" then
            n = n + 1
        end
    end
    return n
end

if vim.fn.executable("jj") ~= 1 then
    it("api tests skipped: jj not on PATH", function() end)
    return
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
if vim.system({ "jj", "git", "init" }, { cwd = dir }):wait().code ~= 0 then
    it("api tests skipped: jj git init failed", function() end)
    return
end
vim.fn.writefile({ "hello" }, dir .. "/a.txt")
vim.cmd("cd " .. vim.fn.fnameescape(dir))

it("setup: creates the :JjView command", function()
    jv.setup()
    eq(vim.fn.exists(":JjView") == 2, true)
end)

it("open then close: manages exactly one panel window", function()
    jv.setup()
    jv.open()
    eq(panel_win() ~= nil, true)
    jv.close()
    eq(panel_win() == nil, true)
end)

it("open is idempotent: a second open does not stack panels", function()
    jv.setup()
    jv.open()
    jv.open()
    eq(panel_count(), 1)
    jv.close()
end)

it("toggle: flips the panel on and off", function()
    jv.setup()
    jv.toggle()
    eq(panel_win() ~= nil, true)
    jv.toggle()
    eq(panel_win() == nil, true)
end)

it("open: renders the version banner and the working-copy file", function()
    jv.setup()
    jv.open()
    local buf = vim.api.nvim_win_get_buf(panel_win())
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    eq(text:find("jj-view  v", 1, true) ~= nil, true)
    eq(text:find("a.txt", 1, true) ~= nil, true)
    jv.close()
end)

it("auto-close: panel stays while another real window remains", function()
    jv.setup()
    jv.open() -- panel + the original window
    -- make a second non-panel window, then close one of them
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= panel_win() then
            vim.api.nvim_set_current_win(w)
            break
        end
    end
    vim.cmd("vsplit")
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "jjview" then
            vim.api.nvim_win_close(w, false)
            break
        end
    end
    vim.wait(100)
    eq(panel_win() ~= nil, true)
    jv.close()
end)
