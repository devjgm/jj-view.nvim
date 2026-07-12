-- Minimal, dependency-free test runner. Run with:  nvim -l tests/run.lua
-- (or `just test`). Loads every tests/*_spec.lua, which register cases with the
-- global `it`; assertions use the global `eq`. Exits non-zero on any failure.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:prepend(root) -- so require("jj-view...") resolves

local passed, failed, failures = 0, 0, {}

_G.it = function(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(failures, name .. "\n      " .. tostring(err))
    end
end

_G.eq = function(got, want)
    if not vim.deep_equal(got, want) then
        error(("expected %s\n      got      %s"):format(vim.inspect(want), vim.inspect(got)), 2)
    end
end

for _, spec in ipairs(vim.fn.glob(root .. "/tests/*_spec.lua", true, true)) do
    dofile(spec)
end

print(("\njj-view: %d passed, %d failed"):format(passed, failed))
for _, f in ipairs(failures) do
    print("  FAIL  " .. f)
end
if failed > 0 then
    os.exit(1)
end
