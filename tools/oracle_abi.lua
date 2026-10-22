-- tools/oracle_abi.lua : the keys every class of a build reads from script (oracle/gameabi.lua),
-- one line per key, for one shard of the classes.
--
--   luajit tools/oracle_abi.lua <executable> <out.tsv> [shard/shards] [class pattern]
--
-- out.tsv: `#class` lines (class, ReadMember, parent, tokens, paths, keys, constructed, seconds),
-- then per key: class, key, token id, reader (the first function its value goes to), the class of
-- the object a member that is one is read into, the databases whose instance the call read (a key
-- into one, a trigger or effect block), the next calls, result, the failure if the call failed,
-- the first line it logged. Shards split the classes
-- (sorted) by index: run shards 1/n .. n/n in parallel and concatenate.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamereader = require("oracle.gamereader")
local gameabi = require("oracle.gameabi")

local exe, out_path, shard, pattern = arg[1], arg[2], arg[3] or "1/1", arg[4]
local k, n = shard:match("^(%d+)/(%d+)$")
k, n = tonumber(k) or 1, tonumber(n) or 1

local out = assert(io.open(out_path, "wb"))
local t0 = os.clock()
local m = machine.new(elf.load(exe))
local gl = gamelexer.new(m)
local gr = gamereader.new(gl)
local symbols = gameabi.symbols(exe)
local abi = gameabi.new(gr, symbols)
local ran, init_failed = abi:static_init()
local created, failed = abi:create_databases()
out:write("#build\t", exe, "\t", #abi.tokens, " tokens\t", ran, " static initializers (", #init_failed,
    " failed)\t", #created, " databases created\n")
for _, f in ipairs(init_failed) do out:write("#init-failed\t", f, "\n") end
for _, f in ipairs(failed) do out:write("#database-failed\t", f, "\n") end

-- `keywords` instead of a shard: each trigger's and effect's class, one per line: kind, keyword,
-- token id, class, the classes it derives from (RTTI, nearest first, " > " between)
if shard == "keywords" then
    local f = abi:factories()
    local names = f.names
    for _, t in ipairs(abi.tokens) do names[t.id] = names[t.id] or t.name end
    for _, kind in ipairs({ "trigger", "effect" }) do
        if f[kind .. "_error"] then out:write("#error\t", kind, "\t", f[kind .. "_error"], "\n") end
        local ids = {}
        for id in pairs(f[kind] or {}) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b) return (names[a] or "") < (names[b] or "") end)
        for _, id in ipairs(ids) do
            local class = f[kind][id]
            -- the classes it derives from (RTTI), nearest first
            local ok, bases = pcall(abi.bases, abi, class)
            out:write(kind, "\t", names[id] or "?", "\t", id, "\t", class, "\t",
                ok and table.concat(bases, " > ") or "", "\n")
        end
    end
    out:write(string.format("#done\t%.0f s\n", os.clock() - t0))
    out:close()
    return
end

local classes = {}
for i, c in ipairs(abi:classes()) do
    if (i - 1) % n == k - 1 and (not pattern or c:find(pattern)) then
        classes[#classes + 1] = c
    end
end
local function clean(s) return (tostring(s or ""):gsub("[\r\n\t]", " ")) end
for _, c in ipairs(classes) do
    local ok, r = pcall(abi.trace, abi, c)
    if not ok then
        out:write("#error\t", c, "\t", clean(r), "\n")
    else
        out:write(string.format("#class\t%s\t%x\t%s\t%d\t%d\t%d\t%s\t%.1f\n", c, r.read_member,
            r.parent or "-", r.tokens, r.paths, #r.keys, tostring(r.constructed), r.seconds))
        for _, key in ipairs(r.keys) do
            local rest = {}
            for i = 2, #key.calls do rest[#rest + 1] = key.calls[i] end
            out:write(table.concat({ c, key.name, tostring(key.id), clean(key.reader), clean(key.nested),
                clean(table.concat(key.databases or {}, " ")),
                clean(table.concat(rest, " > ")), tostring(key.rc), clean(key.failed),
                clean(key.log) }, "\t"), "\n")
        end
    end
    out:flush()
end
out:write(string.format("#done\t%d classes in %.0f s\n", #classes, os.clock() - t0))
out:close()
