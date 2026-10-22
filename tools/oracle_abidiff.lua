-- tools/oracle_abidiff.lua : what changed in the script ABI (tools/oracle_abijson.lua) from each
-- build to the next.
--
--   luajit tools/oracle_abidiff.lua <out.md> <summary.tsv> <name>=<abi.json> ...   (oldest first)
--
-- out.md: per pair of consecutive builds, the triggers and effects added and removed and those
-- whose class changed, the classes added and removed, and per class the keys added and removed and
-- those whose reader or object changed. summary.tsv: one line per build: name, triggers, effects,
-- classes, keys, then the counts of changes from the build before (keywords added, removed,
-- changed; classes added, removed; keys added, removed, changed).
--
-- A class's `ReadMember` address and a key's token id change with every build; they are not
-- compared, nor are token ids in a class's template arguments. A key whose value failed in one build and not the other is not a change either (the
-- emulator's, not the game's).

-- JSON (what oracle_abijson.lua writes) -------------------------------------------------------------
local function decode(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local value
    local function str()
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == '"' then break end
            if c == "\\" then
                local e = s:sub(j + 1, j + 1)
                if e == "u" then
                    out[#out + 1] = string.char(tonumber(s:sub(j + 2, j + 5), 16) % 256)
                    j = j + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t", r = "\r" })[e] or e
                    j = j + 2
                end
            else
                local k = s:find('["\\]', j)
                out[#out + 1] = s:sub(j, k - 1)
                j = k
            end
        end
        i = j + 1
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = i + 1
            ws()
            if s:sub(i, i) == "}" then i = i + 1 return t end
            while true do
                ws()
                local k = str()
                ws()
                i = i + 1  -- :
                t[k] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            i = i + 1
            ws()
            if s:sub(i, i) == "]" then i = i + 1 return t end
            while true do
                t[#t + 1] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then
            i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then
            i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then
            i = i + 4 return nil
        else
            local n = s:match("^-?[%d.eE+-]+", i)
            i = i + #n
            return tonumber(n)
        end
    end
    return value()
end

local function load(path)
    local f = assert(io.open(path, "rb"))
    local t = decode(f:read("*a"))
    f:close()
    return t
end

-- the comparison --------------------------------------------------------------------------------------
local function sorted_keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end
local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- what a key is, without what changes with every build or with the emulator
local function key_form(k)
    return (k.reader or "-") .. " | " .. (k.object or "-")
end
local function class_form(c)
    return string.format("statements %s, any key %s, ignores unknown %s", tostring(c.statements),
        tostring(c.any_key), tostring(c.ignores_unknown))
end
-- a class without the token ids in its template arguments (CStoredTechPointsTrigger<16533>: the
-- id of a token, renumbered when tokens are added)
local function class_name(c)
    return (c or "?"):gsub("<%d+>", "<id>")
end
local function keyword_form(k)
    return class_name(k.class) .. " | " .. table.concat(k.keys or {}, " ") .. " | " .. tostring(k.statements)
end

local function diff(a, b, out)
    local n = { kw_added = 0, kw_removed = 0, kw_changed = 0, cl_added = 0, cl_removed = 0,
        k_added = 0, k_removed = 0, k_changed = 0 }
    local lines = {}
    local function w(s) lines[#lines + 1] = s end
    for _, kind in ipairs({ "triggers", "effects" }) do
        local added, removed, changed = {}, {}, {}
        for _, name in ipairs(sorted_keys(b[kind])) do
            local x, y = a[kind][name], b[kind][name]
            if not x then
                added[#added + 1] = name
            elseif keyword_form(x) ~= keyword_form(y) then
                local parts = {}
                if class_name(x.class) ~= class_name(y.class) then
                    parts[#parts + 1] = "class " .. x.class .. " → " .. y.class
                end
                local kx, ky = {}, {}
                for _, k in ipairs(x.keys or {}) do kx[k] = true end
                for _, k in ipairs(y.keys or {}) do ky[k] = true end
                local plus, minus = {}, {}
                for _, k in ipairs(sorted_keys(ky)) do if not kx[k] then plus[#plus + 1] = k end end
                for _, k in ipairs(sorted_keys(kx)) do if not ky[k] then minus[#minus + 1] = k end end
                if #plus > 0 then parts[#parts + 1] = "+" .. table.concat(plus, " +") end
                if #minus > 0 then parts[#parts + 1] = "-" .. table.concat(minus, " -") end
                if x.statements ~= y.statements then
                    parts[#parts + 1] = "statements " .. tostring(x.statements) .. " → " .. tostring(y.statements)
                end
                -- a class renamed with the same keys is not worth a line of its own
                if #parts > 0 then changed[#changed + 1] = "`" .. name .. "`: " .. table.concat(parts, "; ") end
            end
        end
        for _, name in ipairs(sorted_keys(a[kind])) do
            if not b[kind][name] then removed[#removed + 1] = name end
        end
        n.kw_added, n.kw_removed, n.kw_changed = n.kw_added + #added, n.kw_removed + #removed,
            n.kw_changed + #changed
        if #added + #removed + #changed > 0 then
            w("### " .. kind:sub(1, 1):upper() .. kind:sub(2))
            w("")
            if #added > 0 then w("- added (" .. #added .. "): `" .. table.concat(added, "`, `") .. "`") end
            if #removed > 0 then w("- removed (" .. #removed .. "): `" .. table.concat(removed, "`, `") .. "`") end
            for _, c in ipairs(changed) do w("- " .. c) end
            w("")
        end
    end
    local cadd, crem, cchg = {}, {}, {}
    for _, name in ipairs(sorted_keys(b.classes)) do
        local x, y = a.classes[name], b.classes[name]
        if not x then
            cadd[#cadd + 1] = name
        else
            local parts = {}
            for _, k in ipairs(sorted_keys(y.keys)) do
                local kx = x.keys and x.keys[k]
                if not kx then
                    parts[#parts + 1] = "+`" .. k .. "`"
                    n.k_added = n.k_added + 1
                elseif key_form(kx) ~= key_form(y.keys[k]) then
                    parts[#parts + 1] = "`" .. k .. "` " .. key_form(kx) .. " → " .. key_form(y.keys[k])
                    n.k_changed = n.k_changed + 1
                end
            end
            for _, k in ipairs(sorted_keys(x.keys)) do
                if not (y.keys and y.keys[k]) then
                    parts[#parts + 1] = "-`" .. k .. "`"
                    n.k_removed = n.k_removed + 1
                end
            end
            if class_form(x) ~= class_form(y) then parts[#parts + 1] = class_form(x) .. " → " .. class_form(y) end
            if #parts > 0 then cchg[#cchg + 1] = "- `" .. name .. "`: " .. table.concat(parts, ", ") end
        end
    end
    for _, name in ipairs(sorted_keys(a.classes)) do
        if not b.classes[name] then crem[#crem + 1] = name end
    end
    n.cl_added, n.cl_removed = #cadd, #crem
    if #cadd + #crem + #cchg > 0 then
        w("### Classes")
        w("")
        if #cadd > 0 then w("- added (" .. #cadd .. "): `" .. table.concat(cadd, "`, `") .. "`") end
        if #crem > 0 then w("- removed (" .. #crem .. "): `" .. table.concat(crem, "`, `") .. "`") end
        for _, c in ipairs(cchg) do w(c) end
        w("")
    end
    return n, lines
end

-- main ------------------------------------------------------------------------------------------------
local out_path, summary_path = arg[1], arg[2]
local builds = {}
for i = 3, #arg do
    local name, path = arg[i]:match("^(.-)=(.*)$")
    builds[#builds + 1] = { name = name, path = path }
end
local md = assert(io.open(out_path, "wb"))
local tsv = assert(io.open(summary_path, "wb"))
tsv:write("# build\ttriggers\teffects\tclasses\tkeys\tkeywords added\tremoved\tchanged\tclasses added\tremoved\tkeys added\tremoved\tchanged\n")
md:write("# What changed in the script ABI, build to build\n\n",
    "Made by `tools/oracle_abidiff.lua` (stellar-lua-pdxscript) from the ABIs in `abi/`, oldest first. ",
    "A key is `reader | object`: the first function its value goes to, and the class of a block.\n\n")
local prev
for _, b in ipairs(builds) do
    local abi = load(b.path)
    for _, s in ipairs({ "triggers", "effects", "classes" }) do abi[s] = abi[s] or {} end
    local keys = 0
    for _, c in pairs(abi.classes) do keys = keys + count(c.keys) end
    local row = { b.name, count(abi.triggers), count(abi.effects), count(abi.classes), keys }
    if prev then
        local n, lines = diff(prev.abi, abi, md)
        for _, f in ipairs({ "kw_added", "kw_removed", "kw_changed", "cl_added", "cl_removed", "k_added",
            "k_removed", "k_changed" }) do row[#row + 1] = n[f] end
        md:write("## ", prev.name, " → ", b.name, "\n\n")
        if #lines == 0 then md:write("No change.\n\n") else md:write(table.concat(lines, "\n"), "\n") end
        io.stderr:write(string.format("%s -> %s: keywords +%d -%d ~%d, classes +%d -%d, keys +%d -%d ~%d\n",
            prev.name, b.name, n.kw_added, n.kw_removed, n.kw_changed, n.cl_added, n.cl_removed, n.k_added,
            n.k_removed, n.k_changed))
    end
    for i = 1, #row do row[i] = tostring(row[i]) end
    tsv:write(table.concat(row, "\t"), "\n")
    prev = { name = b.name, abi = abi }
end
md:close()
tsv:close()
