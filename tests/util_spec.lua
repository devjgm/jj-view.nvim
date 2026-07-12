-- Unit tests for the pure helpers. No jj or windows involved.

local util = require("jj-view.util")

it("wrap_text: empty string is one empty line", function()
    eq(util.wrap_text("", 5), { "" })
end)

it("wrap_text: wraps on word boundaries", function()
    eq(util.wrap_text("aa bb cc", 5), { "aa bb", "cc" })
end)

it("wrap_text: a word longer than the width is not split", function()
    eq(util.wrap_text("supercalifragilistic ok", 6), { "supercalifragilistic", "ok" })
end)

it("pack: keeps multi-word items whole", function()
    eq(util.pack({ "CR open", "p preview" }, 9), { "CR open", "p preview" })
end)

it("pack: fits items on one line when they can", function()
    eq(util.pack({ "a", "b", "c" }, 10), { "a  b  c" })
end)

it("pack: two-space separator counts toward the width", function()
    eq(util.pack({ "aaa", "bbb" }, 7), { "aaa", "bbb" })
end)

it("truncate_left: short strings are unchanged", function()
    eq(util.truncate_left("short.rs", 20), "short.rs")
end)

it("truncate_left: long strings keep the tail behind ...", function()
    eq(util.truncate_left("a/b/c/long.rs", 8), "...ng.rs")
end)

it("truncate_left: multibyte paths are cut on character boundaries", function()
    -- must not split a codepoint, and must fit in the display width
    local got = util.truncate_left("docs/\227\129\130\227\129\132\227\129\134.md", 8)
    eq(got:sub(1, 3), "...")
    eq(vim.fn.strdisplaywidth(got) <= 8, true)
    eq(vim.fn.strchars(got) >= 4, true) -- "..." plus at least one whole char
end)

it("status_group: maps summary letters", function()
    eq(util.status_group("A"), "JjViewAdded")
    eq(util.status_group("D"), "JjViewRemoved")
    eq(util.status_group("M"), "JjViewModified")
    eq(util.status_group("R"), "JjViewRenamed")
    eq(util.status_group("C"), "JjViewRenamed")
end)

it("parse_meta: fields plus a multi-line description", function()
    local out = "abcd1234\ngreg/foo\nTitle line\n\nmore body\n"
    eq(util.parse_meta(out), {
        change = "abcd1234",
        bookmark = "greg/foo",
        description = "Title line\n\nmore body",
    })
end)

it("parse_meta: no bookmark and no description", function()
    eq(util.parse_meta("abcd1234\n\n\n"), {
        change = "abcd1234",
        bookmark = "",
        description = "",
    })
end)

it("parse_summary: status + path, absolutized against root", function()
    eq(util.parse_summary("M a/b.rs\nA c.rs\n", "/root"), {
        { status = "M", path = "a/b.rs", abs = "/root/a/b.rs" },
        { status = "A", path = "c.rs", abs = "/root/c.rs" },
    })
end)

it("parse_summary: empty output is no files", function()
    eq(util.parse_summary("", "/root"), {})
end)

it("parse_summary: rename within a dir resolves to the new path", function()
    eq(util.parse_summary("R a/b/{old.rs => new.rs}\n", "/root"), {
        { status = "R", path = "a/b/new.rs", abs = "/root/a/b/new.rs" },
    })
end)

it("parse_summary: cross-directory rename resolves to the new path", function()
    eq(util.parse_summary("R {a/b/x.rs => c/y.rs}\n", "/root"), {
        { status = "R", path = "c/y.rs", abs = "/root/c/y.rs" },
    })
end)

it("parse_parents: change and bookmark, bookmark spaces preserved", function()
    eq(util.parse_parents("abcd1234\x1fgreg/foo bar\n"), {
        { change = "abcd1234", bookmark = "greg/foo bar" },
    })
end)

it("parse_parents: no bookmark", function()
    eq(util.parse_parents("abcd1234\x1f\n"), {
        { change = "abcd1234", bookmark = "" },
    })
end)

it("parse_parents: multiple parents (a merge)", function()
    eq(util.parse_parents("aaaa1111\x1fmain\nbbbb2222\x1f\n"), {
        { change = "aaaa1111", bookmark = "main" },
        { change = "bbbb2222", bookmark = "" },
    })
end)

it("build_lines: banner + version, files map to abs paths, parent at the bottom", function()
    local meta = { change = "abcd1234", bookmark = "greg/x", description = "hi" }
    local files = {
        { status = "M", path = "a.rs", abs = "/r/a.rs" },
        { status = "A", path = "b.rs", abs = "/r/b.rs" },
    }
    local parents = { { change = "pppp0000", bookmark = "main" } }
    local lines, hl, line_files = util.build_lines(meta, files, parents, 38, "9.9.9")

    eq(lines[1], " jj-view  v9.9.9")

    local abses = {}
    for _, abs in pairs(line_files) do
        abses[abs] = true
    end
    eq(abses, { ["/r/a.rs"] = true, ["/r/b.rs"] = true })

    local has_files, has_parent = false, false
    for _, l in ipairs(lines) do
        if l == "  Files (2)" then
            has_files = true
        elseif l == "   pppp0000  main" then
            has_parent = true
        end
    end
    eq(has_files, true)
    eq(has_parent, true)
    eq(#hl > 0, true)
end)
