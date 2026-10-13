-- tools/oracle_initreport.lua : the start of every build compared (the files of
-- tools/oracle_initrun.lua): InitGame's steps, the databases, their dependencies and the order the
-- game's loop initializes them in, from one version to the next.
--
--   luajit tools/oracle_initreport.lua <dir of .tsv> [--full]
--
-- Builds whose results are the same (steps, table, dependencies, order) are one row, named by
-- the range of their versions. Each change is told between consecutive rows; the full lists are
-- given for the first row (and the last, for InitGame and the waits). --full gives every row's:
-- InitGame's steps, the table, the dependencies, the databases that wait.

local dir = arg[1]
if not dir then
    io.stderr:write("usage: luajit tools/oracle_initreport.lua <dir of .tsv> [--full]\n")
    os.exit(2)
end
local opt = {}
for i = 2, #arg do opt[arg[i]] = true end

-- the steps that are plumbing, not a step of the start: imports (filtered by kind), strings, the
-- log, the arrays, destructors, landing pads, std::function's manager, the profiler
local NOISE = {
    "^CString::", "~", "CPdxCommonStringAllocator", "^CLogger::", "^CLogStream::",
    "^CPdxLogFileAndLine::", "^RefCounted_Release$", "^__clang_call_terminate$", "^std::",
    "^PdxStrFmt", "^CPdxArray<", "^CPdxPreAllocatedArray<", "^%(null object%)$",
    "^NExperimental::", "^CProfileScope::", "^0x%x+$",
}
local function noise(key)
    for _, p in ipairs(NOISE) do
        if key:find(p) then return true end
    end
    return false
end

local function version_key(name)
    local v = name:match("^v([%d%.]+)")
    local key = {}
    for n in (v or "0"):gmatch("%d+") do key[#key + 1] = tonumber(n) end
    return key, (v or name):gsub("%.$", "")
end

local function before(a, b)
    for i = 1, math.max(#a.key, #b.key) do
        local x, y = a.key[i] or -1, b.key[i] or -1
        if x ~= y then return x < y end
    end
    return a.name < b.name
end

local function split(line)
    local f = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do f[#f + 1] = field end
    return f
end

-- reading -----------------------------------------------------------------------------------------

local builds = {}
local p = io.popen('ls "' .. dir .. '"/*.tsv 2>/dev/null')
for path in p:lines() do
    local name = path:match("([^/]+)%.tsv$")
    local key, version = version_key(name)
    local b = { name = name, key = key, version = version, errors = {}, info = {}, steps = {},
        dbs = {}, db_at = {}, deps = {}, order = {}, stuck = {} }
    for line in io.lines(path) do
        local f = split(line)
        local kind = f[1]
        if kind == "#build" then
            b.bits, b.table_fn, b.stride, b.fields = f[3], f[4], f[5], f[6]
        elseif kind == "#error" then
            b.errors[#b.errors + 1] = f[2]
        elseif kind == "#info" then
            b.info[f[2]] = f[3]
        elseif kind == "step" then
            b.steps[#b.steps + 1] = { kind = f[3], site = f[4], reached = f[5] == "1", count = tonumber(f[6]),
                key = f[7], name = f[8], db = f[9] == "db" }
        elseif kind == "db" then
            local d = { index = tonumber(f[2]), name = f[3], create = f[4], destroy = f[5], can_init = f[6],
                init = f[7], post_read = f[8], result = f[9], deps = {} }
            b.dbs[#b.dbs + 1] = d
            b.db_at[d.name] = d
        elseif kind == "dep" then
            local d = b.db_at[f[2]]
            if d then d.deps[#d.deps + 1] = { kind = f[3], what = f[4], symbol = f[5] } end
        elseif kind == "order" then
            b.order[#b.order + 1] = f[3]
        elseif kind == "stuck" then
            b.stuck[#b.stuck + 1] = f[2]
        end
    end
    builds[#builds + 1] = b
end
p:close()
if #builds == 0 then
    print("no .tsv files in " .. dir)
    os.exit(1)
end
table.sort(builds, before)

-- InitGame's steps, as compared: no plumbing, the database loop one step (inline before 4.1: from
-- its first site to its last, the destructors of the table's arrays left out: one is in the
-- landing pads at the end), one entry per site in address order
local function steps_of(b)
    local first, last
    for i, s in ipairs(b.steps) do
        if s.db and not s.key:find("~") then
            first = first or i
            last = i
        end
    end
    -- one call of SetupDatabases (4.1 on), or the loop itself, with what follows it in InitGame and
    -- is inside SetupDatabases from 4.1: the progress report, the error log, the modifier icons
    local outlined = first and first == last and b.steps[first].key:find("SetupDatabases")
    while last and not outlined and last < #b.steps do
        local s = b.steps[last + 1]
        if s.kind == "import" or noise(s.key) or s.key == "CGameApplication::LoadingScreenCallback" or
            s.key == "CModifier::InitDefinitionIcons" then
            last = last + 1
        else
            break
        end
    end
    local out = {}
    for i, s in ipairs(b.steps) do
        if first and i >= first and i <= last then
            if i == first then
                out[#out + 1] = { key = outlined and s.key or "(the database loop, in InitGame)",
                    reached = true, db = true }
            end
        elseif s.kind ~= "import" and not noise(s.key) then
            out[#out + 1] = { key = s.key, reached = s.reached, kind = s.kind, count = s.count }
        end
    end
    return out
end

for _, b in ipairs(builds) do
    b.flow = steps_of(b)
    -- a signature of everything compared
    local parts = { b.table_fn or "", b.fields or "" }
    for _, s in ipairs(b.flow) do parts[#parts + 1] = s.key .. (s.reached and "" or "?") end
    for _, d in ipairs(b.dbs) do
        local deps = {}
        for _, x in ipairs(d.deps) do deps[#deps + 1] = x.kind .. ":" .. x.what end
        parts[#parts + 1] = d.name .. (d.can_init ~= "-" and "+" or "") .. "(" .. table.concat(deps, ",") .. ")"
    end
    parts[#parts + 1] = table.concat(b.order, ",")
    parts[#parts + 1] = table.concat(b.errors, ",")
    b.signature = table.concat(parts, "\n")
end

-- rows: consecutive builds with the same results
local rows = {}
for _, b in ipairs(builds) do
    local r = rows[#rows]
    if r and r.builds[1].signature == b.signature then
        r.builds[#r.builds + 1] = b
    else
        rows[#rows + 1] = { builds = { b } }
    end
end
for _, r in ipairs(rows) do
    local a, z = r.builds[1].version, r.builds[#r.builds].version
    r.label = a == z and a or (a .. ".." .. z)
    r.b = r.builds[1]
end

-- sequences --------------------------------------------------------------------------------------

-- the longest common subsequence of two lists of strings: a set of the indices kept on each side
local function lcs(a, b)
    local n, m = #a, #b
    local L = {}
    for i = 0, n do L[i] = { [0] = 0 } end
    for j = 0, m do L[0][j] = 0 end
    for i = 1, n do
        for j = 1, m do
            if a[i] == b[j] then
                L[i][j] = L[i - 1][j - 1] + 1
            else
                L[i][j] = math.max(L[i - 1][j], L[i][j - 1])
            end
        end
    end
    local ka, kb = {}, {}
    local i, j = n, m
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            ka[i], kb[j] = true, true
            i, j = i - 1, j - 1
        elseif L[i - 1][j] >= L[i][j - 1] then
            i = i - 1
        else
            j = j - 1
        end
    end
    return ka, kb, L[n][m]
end

local function names_of(list, field)
    local out = {}
    for i, x in ipairs(list) do out[i] = field and x[field] or x end
    return out
end

local function set_of(list)
    local s = {}
    for _, x in ipairs(list) do s[x] = true end
    return s
end

-- the elements of `new` that moved relative to the others they share with `old` (not in the
-- longest common subsequence of the shared ones)
local function moved(old, new)
    local so, sn = set_of(old), set_of(new)
    local a, b = {}, {}
    for _, x in ipairs(old) do if sn[x] then a[#a + 1] = x end end
    for _, x in ipairs(new) do if so[x] then b[#b + 1] = x end end
    local _, kb = lcs(a, b)
    local out = {}
    for j, x in ipairs(b) do
        if not kb[j] then out[#out + 1] = x end
    end
    return out
end

local function wrap(prefix, list, width)
    width = width or 100
    local lines, line = {}, prefix
    for i, x in ipairs(list) do
        local piece = x .. (i < #list and ", " or "")
        if #line + #piece > width and line ~= prefix then
            lines[#lines + 1] = line
            line = string.rep(" ", #prefix)
        end
        line = line .. piece
    end
    lines[#lines + 1] = line
    return table.concat(lines, "\n")
end

-- report ------------------------------------------------------------------------------------------

local errors = {}
for _, b in ipairs(builds) do
    for _, e in ipairs(b.errors) do errors[#errors + 1] = b.version .. ": " .. e end
end
print(string.format("%d builds, %s to %s; %d errors; %d rows (consecutive builds with the same results)",
    #builds, builds[1].version, builds[#builds].version, #errors, #rows))
for _, e in ipairs(errors) do print("  " .. e) end

-- the databases that wait: initialized after one that comes later in the table (when the loop
-- first reached them their CanInitialize returned false)
local function waited(b)
    local pos = {}
    for i, d in ipairs(b.dbs) do pos[d.name] = i end
    local out, most = {}, 0
    for _, name in ipairs(b.order) do
        local p = pos[name] or 0
        if p < most then out[#out + 1] = name end
        if p > most then most = p end
    end
    return out
end

print("\n## Summary\n")
print("| versions | builds | table built in | record | InitGame steps | databases | CanInitialize | deps: db / external / other | wait | never ready |")
print("|---|---|---|---|---|---|---|---|---|---|")
for _, r in ipairs(rows) do
    local b = r.b
    local nci, ndb, next, noth = 0, 0, 0, 0
    for _, d in ipairs(b.dbs) do
        if d.can_init ~= "-" then nci = nci + 1 end
        for _, x in ipairs(d.deps) do
            if x.kind == "db" then ndb = ndb + 1 elseif x.kind == "external" then next = next + 1 else noth = noth + 1 end
        end
    end
    local fn = (b.table_fn or "-"):gsub("%(.*$", "")
    local fields = (b.fields or "-"):gsub("^name,", "")
    print(string.format("| %s | %d | %s | %s B: %s | %d | %d | %d | %d / %d / %d | %d | %d |", r.label, #r.builds,
        fn, b.stride or "-", fields, #b.flow, #b.dbs, nci, ndb, next, noth, #waited(b), #b.stuck))
end

-- InitGame
print("\n## CGameApplication::InitGame\n")
print("Its calls in address order (the static calls and the indirect calls of the isolated run), without")
print("the plumbing (strings, log, arrays, destructors, imports). `?`: not reached on the isolated run")
print("(every callee returns the null object); `*`: an indirect call (count, targets folded).\n")
local function print_flow(r)
    print("### " .. r.label .. "\n")
    print("```")
    for _, s in ipairs(r.b.flow) do
        local mark = s.reached and " " or "?"
        local extra = s.kind == "icall" and string.format("  * x%d", s.count or 0) or ""
        print(mark .. " " .. s.key .. extra)
    end
    print("```\n")
end
print_flow(rows[1])
print("Changes (`+` added, `-` removed, `>` moved; `?` now reached / not reached):\n")
for i = 2, #rows do
    local a, b = rows[i - 1].b.flow, rows[i].b.flow
    local ka, kb = lcs(names_of(a, "key"), names_of(b, "key"))
    local added, removed = {}, {}
    for j, s in ipairs(b) do if not kb[j] then added[#added + 1] = s.key end end
    for j, s in ipairs(a) do if not ka[j] then removed[#removed + 1] = s.key end end
    -- a key both removed and added moved
    local ra, rr = set_of(added), set_of(removed)
    local mv, add2, rem2 = {}, {}, {}
    for _, k in ipairs(added) do if rr[k] then mv[#mv + 1] = k else add2[#add2 + 1] = k end end
    for _, k in ipairs(removed) do if not ra[k] then rem2[#rem2 + 1] = k end end
    -- reached on one path and not the other, for the steps kept
    local reach = {}
    do
        local ia, ib = {}, {}
        for j in pairs(ka) do ia[#ia + 1] = j end
        for j in pairs(kb) do ib[#ib + 1] = j end
        table.sort(ia)
        table.sort(ib)
        for k = 1, #ia do
            local x, y = a[ia[k]], b[ib[k]]
            if x.reached ~= y.reached then
                reach[#reach + 1] = y.key .. (y.reached and " (now reached)" or " (no longer reached)")
            end
        end
    end
    local lines = {}
    if #add2 > 0 then lines[#lines + 1] = wrap("  + ", add2) end
    if #rem2 > 0 then lines[#lines + 1] = wrap("  - ", rem2) end
    if #mv > 0 then lines[#lines + 1] = wrap("  > ", mv) end
    if #reach > 0 then lines[#lines + 1] = wrap("  ? ", reach) end
    if #lines > 0 then
        print("- " .. rows[i - 1].label .. " -> " .. rows[i].label .. ":")
        print("```")
        print(table.concat(lines, "\n"))
        print("```")
    end
end
if opt["--full"] then
    for i = 2, #rows do print_flow(rows[i]) end
elseif #rows > 1 then
    print("")
    print_flow(rows[#rows])
end

-- databases
print("\n## Databases\n")
print("| versions | databases | added | removed | moved in the table |")
print("|---|---|---|---|---|")
for i, r in ipairs(rows) do
    local b = r.b
    local added, removed, mv = {}, {}, {}
    if i > 1 then
        local prev = rows[i - 1].b
        for _, d in ipairs(b.dbs) do if not prev.db_at[d.name] then added[#added + 1] = d.name end end
        for _, d in ipairs(prev.dbs) do if not b.db_at[d.name] then removed[#removed + 1] = d.name end end
        mv = moved(names_of(prev.dbs, "name"), names_of(b.dbs, "name"))
    end
    print(string.format("| %s | %d | %s | %s | %s |", r.label, #b.dbs, table.concat(added, ", "),
        table.concat(removed, ", "), table.concat(mv, ", ")))
end
if opt["--full"] then
    for _, r in ipairs(rows) do
        print("\n### " .. r.label .. ": the table\n")
        print("```")
        for _, d in ipairs(r.b.dbs) do
            print(string.format("%3d %-42s %s%s", d.index, d.name, d.can_init ~= "-" and "CanInitialize " or "",
                d.post_read ~= "-" and "PostReadInitInstance" or ""))
        end
        print("```")
    end
end

-- dependencies
local function dep_list(d)
    local out = {}
    for _, x in ipairs(d.deps) do
        out[#out + 1] = x.kind == "db" and x.what or (x.kind .. ": " .. x.what)
    end
    return out
end
local function print_deps(r)
    print("### " .. r.label .. "\n")
    print("```")
    for _, d in ipairs(r.b.dbs) do
        if d.can_init ~= "-" then
            local l = dep_list(d)
            print(wrap(string.format("%-40s <- ", d.name), #l > 0 and l or { "(nothing: CanInitialize returns true)" }, 120))
        end
    end
    print("```\n")
end
print("\n## Dependencies\n")
print("What each database's CanInitialize reads: the databases (their instance), `external:` a class")
print("with a CreateInstance that is not in the table, `other:` any other global.\n")
print_deps(rows[1])
print("Changes (`+`/`-` a dependency; a new database with its dependencies; `CanInitialize` added or")
print("removed):\n")
for i = 2, #rows do
    local prev, b = rows[i - 1].b, rows[i].b
    local lines = {}
    for _, d in ipairs(b.dbs) do
        local o = prev.db_at[d.name]
        if not o then
            if d.can_init ~= "-" then
                local l = dep_list(d)
                lines[#lines + 1] = wrap(string.format("  new %s <- ", d.name), #l > 0 and l or { "(nothing)" }, 120)
            end
        else
            local now, was = set_of(dep_list(d)), set_of(dep_list(o))
            local plus, minus = {}, {}
            for _, x in ipairs(dep_list(d)) do if not was[x] then plus[#plus + 1] = "+" .. x end end
            for _, x in ipairs(dep_list(o)) do if not now[x] then minus[#minus + 1] = "-" .. x end end
            local ci = ""
            if (o.can_init == "-") ~= (d.can_init == "-") then
                ci = d.can_init == "-" and " (CanInitialize removed)" or " (CanInitialize added)"
            end
            if #plus + #minus > 0 or ci ~= "" then
                local l = {}
                for _, x in ipairs(plus) do l[#l + 1] = x end
                for _, x in ipairs(minus) do l[#l + 1] = x end
                lines[#lines + 1] = wrap(string.format("  %s%s%s", d.name, ci, #l > 0 and ": " or ""), l, 120)
            end
        end
    end
    if #lines > 0 then
        print("- " .. rows[i - 1].label .. " -> " .. rows[i].label .. ":")
        print("```")
        print(table.concat(lines, "\n"))
        print("```")
    end
end
if opt["--full"] then
    print("")
    for i = 2, #rows do print_deps(rows[i]) end
end

-- the order
print("\n## The order of initialization\n")
print("The game's loop simulated: the first database left whose dependencies are done, the search")
print("starting again from the first. A database waits when it is initialized after one that comes")
print("later in the table. `moved`: the databases whose place among the others changed since the row")
print("before (not in the longest common subsequence of the two orders).\n")
for i, r in ipairs(rows) do
    local b = r.b
    local w = waited(b)
    if i == 1 or i == #rows or opt["--full"] then
        print(wrap(string.format("- %s: %d of %d wait: ", r.label, #w, #b.dbs), w, 120))
    else
        local was, now = set_of(waited(rows[i - 1].b)), set_of(w)
        local l = {}
        for _, x in ipairs(w) do if not was[x] then l[#l + 1] = "+" .. x end end
        for _, x in ipairs(waited(rows[i - 1].b)) do if not now[x] then l[#l + 1] = "-" .. x end end
        print(wrap(string.format("- %s: %d of %d wait%s", r.label, #w, #b.dbs, #l > 0 and ": " or ""), l, 120))
    end
    if #b.stuck > 0 then
        print(wrap("  never ready: ", b.stuck, 120))
    end
    if i > 1 then
        local mv = moved(rows[i - 1].b.order, b.order)
        if #mv > 0 then
            print(wrap(string.format("  moved (%d): ", #mv), mv, 120))
        end
    end
end
