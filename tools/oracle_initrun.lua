-- tools/oracle_initrun.lua : the start of one build, read from its own code (oracle/gameinit.lua):
-- CGameApplication::InitGame's calls, the table of databases, what each database's
-- CanInitialize reads, and the order the game's loop initializes them in. One line per fact,
-- tab-separated:
--
--   #build  <path> <bits> <table built in> <record size> <fields>
--   #info   <key> <value>                       how the runs went
--   #error  <message>
--   step    <n> <kind> <site> <reached> <count> <key> <name> <db>
--                          InitGame's call sites in address order: the static calls and jumps and
--                          the indirect calls the isolated run made; reached 1 if the run passed
--                          there; key is the name without its parameters or return type (long
--                          template arguments folded), name the full one; db is "db" for a site of
--                          the database loop (a database's function, or the table's array)
--   run     <n> <kind> <site> <count> <name>    the isolated run in order (repeats at one site
--                                               folded, imports left out)
--   db      <i> <name> <create> <destroy> <can_init> <init> <post_read> <can_init result>
--   dep     <db> <kind> <what> <symbol>         kind: db (what: the database), external (a class
--                                               with a CreateInstance outside the table), other
--   order   <k> <db> <table index>              the game's loop, simulated
--   stuck   <db>                                never ready
--
--   luajit tools/oracle_initrun.lua <executable> <out file>
--
-- Names are demangled with c++filt when it is on the path.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gameinit = require("oracle.gameinit")

local exe, out_path = arg[1], arg[2]
if not exe or not out_path then
    io.stderr:write("usage: luajit tools/oracle_initrun.lua <executable> <out file>\n")
    os.exit(2)
end
local out = assert(io.open(out_path, "wb"))

local function clean(s)
    return (tostring(s):gsub("[\r\n\t]", " "))
end

local function fail(message)
    out:write("#error\t", clean(message), "\n")
    out:close()
    os.exit(1)
end

local ok, image = pcall(elf.load, exe)
if not ok then fail(image) end
local m
ok, m = pcall(machine.new, image, { lenient = true })
if not ok then fail(m) end
local r
ok, r = pcall(gameinit.extract, m)
if not ok then fail(r) end

-- demangling: every name through one c++filt
local mangled = {}
local function want(n)
    if n then mangled[n] = true end
end
for _, e in ipairs(r.program or {}) do
    for _, n in ipairs(e.names) do want(n) end
    want(e.name)
end
for _, s in ipairs(r.steps or {}) do want(s.name) end
want(r.info.table_fn)
local ix = gameinit.index(image)
for _, d in ipairs(r.databases or {}) do
    for _, f in ipairs(gameinit.FIELDS) do want(ix.funcs[d[f]]) end
    for _, dep in ipairs(d.deps or {}) do want(dep.symbol) end
end
local demangled = {}
do
    local list = {}
    for n in pairs(mangled) do list[#list + 1] = n end
    table.sort(list)
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if f then
        f:write(table.concat(list, "\n"), "\n")
        f:close()
        local p = io.popen('c++filt < "' .. tmp .. '" 2>/dev/null')
        if p then
            local i = 0
            for line in p:lines() do
                i = i + 1
                if list[i] and line ~= "" then demangled[list[i]] = line end
            end
            p:close()
        end
        os.remove(tmp)
    end
end
local function dm(n)
    return n and (demangled[n] or n) or "-"
end

-- a name without its parameters: "A::B(int) const" -> "A::B" (the last balanced parentheses)
local function bare(name)
    local s = name:gsub("%s+const$", ""):gsub("%s*&+$", "")
    if s:sub(-1) ~= ")" or s:sub(1, 1) == "(" then
        return s
    end
    local depth = 0
    for i = #s, 1, -1 do
        local c = s:sub(i, i)
        if c == ")" then
            depth = depth + 1
        elseif c == "(" then
            depth = depth - 1
            if depth == 0 then
                -- "operator()" keeps its own parentheses
                local head = s:sub(1, i - 1)
                if head:sub(-8) == "operator" then
                    return head .. "()"
                end
                return head
            end
        end
    end
    return s
end

-- a short name: no parameters, no return type (c++filt writes one for a template function), the
-- template arguments folded (TPdxNullObject<CNamedColor>::Allocate -> TPdxNullObject<…>::Allocate);
-- with keep, a short argument list that holds no other stays (CPdxArray<SDatabaseObjectFunctions, int>)
local function short(name, keep)
    if name:sub(1, 1) == "(" then
        return name  -- "(null object)"
    end
    local s, groups = bare(name), {}
    local n = 1
    while n > 0 do
        s, n = s:gsub("<([^<>]*)>", function(inner)
            groups[#groups + 1] = inner
            return "\1" .. #groups .. "\2"
        end)
    end
    s = s:gsub("%(anonymous namespace%)", "(anon)"):gsub("operator ", "operator\3")
    s = s:match("([^ ]+)$") or s
    s = s:gsub("\3", " ")
    return (s:gsub("\1(%d+)\2", function(i)
        local inner = groups[tonumber(i)]
        if keep and #inner <= 40 and not inner:find("\1") then
            return "<" .. inner .. ">"
        end
        return "<…>"
    end))
end

-- the key of a call site: its function, or what its targets have in common
local function key_of(e)
    if #e.names <= 1 then
        return short(dm(e.names[1] or e.name), true)
    end
    local seen, keys = {}, {}
    for _, n in ipairs(e.names) do
        local k = short(dm(n))
        if not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    if #keys > 3 then
        return string.format("(%d targets)", #e.names)
    end
    return table.concat(keys, " | ")
end

local t = r.table
out:write("#build\t", exe, "\t", m.bits, "\t", dm(r.info.table_fn), "\t", t and t.stride or "-", "\t",
    t and table.concat(t.fields, ",") or "-", "\n")
for _, k in ipairs({ "init_game_error", "init_game_stopped", "init_game_blocks", "table_run_error" }) do
    if r.info[k] then
        out:write("#info\t", k, "\t", clean(r.info[k]), "\n")
    end
end
for _, e in ipairs(r.errors) do
    out:write("#error\t", clean(e), "\n")
end

local function hex(v)
    return v and string.format("%x", v) or "-"
end

-- a call site of the database loop: a call of a database's function from the table, or of the
-- table's array (CPdxArray<SDatabaseObjectFunctions>)
local function database_site(e)
    if e.db then
        return true
    end
    for _, n in ipairs(e.names) do
        if n:find("SDatabaseObjectFunctions", 1, true) then
            return true
        end
    end
    return false
end

for i, e in ipairs(r.program or {}) do
    local name = #e.names > 1 and string.format("%s (+%d)", dm(e.names[1]), #e.names - 1) or dm(e.names[1] or e.name)
    out:write("step\t", i, "\t", e.import and "import" or e.kind, "\t", hex(e.site), "\t", e.reached and 1 or 0, "\t",
        e.count, "\t", clean(key_of(e)), "\t", clean(name), "\t", database_site(e) and "db" or "-", "\n")
end

-- the run, imports left out, consecutive calls at one site folded
do
    local n, last = 0, nil
    local function flush()
        if last then
            n = n + 1
            local name = last.count > 1 and #last.names > 1 and
                string.format("%s (+%d)", short(dm(last.names[1])), #last.names - 1) or dm(last.names[1])
            out:write("run\t", n, "\t", last.kind, "\t", hex(last.site), "\t", last.count, "\t", clean(name), "\n")
        end
    end
    for _, s in ipairs(r.steps or {}) do
        if s.kind ~= "import" then
            if last and last.site and last.site == s.site then
                last.count = last.count + 1
                last.names[#last.names + 1] = s.name
            else
                flush()
                last = { kind = s.kind, site = s.site, count = 1, names = { s.name } }
            end
        end
    end
    flush()
end

for i, d in ipairs(r.databases or {}) do
    local f = {}
    for k, role in ipairs(gameinit.FIELDS) do
        f[k] = d[role] ~= 0 and clean(short(dm(ix.funcs[d[role]] or string.format("0x%x", d[role])), true)) or "-"
    end
    out:write("db\t", i, "\t", d.name, "\t", table.concat(f, "\t"), "\t",
        d.can_init == 0 and "-" or (d.can_init_error and ("error: " .. clean(d.can_init_error)) or tostring(d.can_init_result)), "\n")
end
for _, d in ipairs(r.databases or {}) do
    for _, dep in ipairs(d.deps or {}) do
        local what = dep.kind == "db" and r.databases[dep.db].name or dep.kind == "external" and dep.class or
            clean(dm(dep.symbol))
        out:write("dep\t", d.name, "\t", dep.kind, "\t", what, "\t", clean(dm(dep.symbol)), "\n")
    end
end
for k, i in ipairs(r.order or {}) do
    out:write("order\t", k, "\t", r.databases[i].name, "\t", i, "\n")
end
for _, i in ipairs(r.stuck or {}) do
    out:write("stuck\t", r.databases[i].name, "\n")
end
out:close()
