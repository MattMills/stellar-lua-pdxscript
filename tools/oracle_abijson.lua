-- tools/oracle_abijson.lua : a build's script ABI as one JSON file, from tools/oracle_abi.lua's
-- outputs: the keywords file (`keywords` mode) and the class shards.
--
--   luajit tools/oracle_abijson.lua <out.json> <keywords.tsv> <shard.tsv>...
--
-- {
--   "build": "...", "tokens": n,
--   "triggers": { "<keyword>": { "id": n, "class": "C...", "bases": [ "C...", ... ],
--                  "keys": [ "<key>", ... ], "statements": "triggers" | "effects" | null,
--                  "traced": false | null }, ... },
--   "effects":  { ... the same ... },
--   "classes":  { "<class>": { "parent": "C..." | null, "read_member": "0x...", "constructed": b,
--                  "statements": "triggers" | "effects" | null, "any_key": "<reader>" | null,
--                  "ignores_unknown": true | null,
--                  "keys": { "<key>": { "id": n, "reader": "...", "object": "C..." | null,
--                            "databases": [...], "failed": true | null } } } }
-- }
--
-- A keyword's keys are its class's and those of the classes it derives from (RTTI, `bases`).
-- `traced: false`: none of them has a ReadMember of its own (a keyword whose value is not a block:
-- `always = yes`, `num_pops > 3`; its form is in `bases`).
-- `failed`: the class reads the key (its path is not the default's) but its value could not be
-- read in the emulator (a key into a database, which is empty there, most often).

local out_path, kw_path = arg[1], arg[2]
local shards = {}
for i = 3, #arg do shards[#shards + 1] = arg[i] end

-- JSON ---------------------------------------------------------------------------------------------
local function quote(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
        return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end
local function encode(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "table" then
        local inner = indent .. "  "
        if #v > 0 or next(v) == nil then
            if next(v) == nil then return v.__object and "{}" or "[]" end
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = encode(x, inner) end
            return "[" .. table.concat(parts, ", ") .. "]"
        end
        local keys = {}
        for k in pairs(v) do if k ~= "__object" then keys[#keys + 1] = k end end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = inner .. quote(k) .. ": " .. encode(v[k], inner)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    elseif t == "string" then
        return quote(v)
    elseif v == nil then
        return "null"
    else
        return tostring(v)
    end
end

-- the classes ---------------------------------------------------------------------------------------
local abi = { triggers = { __object = true }, effects = { __object = true }, classes = { __object = true } }
local function split(line)
    local f = {}
    for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
    return f
end
for _, path in ipairs(shards) do
    for line in io.lines(path) do
        local f = split(line)
        if f[1] == "#build" then
            abi.build = f[2]
            abi.tokens = tonumber((f[3] or ""):match("^(%d+)"))
        elseif f[1] == "#class" then
            abi.classes[f[2]] = { parent = f[4] ~= "-" and f[4] or nil, read_member = "0x" .. f[3],
                keys = { __object = true }, constructed = f[8] == "true" }
        elseif f[1]:sub(1, 1) ~= "#" and #f >= 4 then
            local c = abi.classes[f[1]]
            if c then
                -- class, key, id, reader, object, databases, calls, result, failure, log
                local dbs = {}
                for d in (f[6] or ""):gmatch("%S+") do
                    if d ~= "CLogger" and d ~= "CGraphics" then dbs[#dbs + 1] = d end
                end
                c.keys[f[2]] = { id = tonumber(f[3]), reader = f[4] ~= "-" and f[4] or nil,
                    object = (f[5] ~= "" and f[5] ~= "?") and f[5] or nil,
                    databases = #dbs > 0 and dbs or nil,
                    failed = (f[9] or "") ~= "" or nil }
            end
        end
    end
end

-- A block of statements (CAndTrigger, an effect's `limit`, ...) reads every trigger or effect as a
-- key: those keys become `"statements": "triggers"` / `"effects"`, and the class keeps the others
-- (a trigger's own `count`, `limit` ...). A class is one when it reads 100 keywords of a kind or
-- more (not all of them: a statement whose path the emulator cannot tell from a token the block
-- does not read, one that is read and returns as the default does, is not a key). A class that
-- reads 1000 tokens or more with one reader reads any key with it (a map of names, a list of
-- flags): `"any_key": "<reader>"`, without those keys.
local keyword_kind = {}
for line in io.lines(kw_path) do
    local f = split(line)
    if f[1] == "trigger" or f[1] == "effect" then
        keyword_kind[f[1]] = keyword_kind[f[1]] or {}
        keyword_kind[f[1]][f[2]] = true
    end
end
for _, c in pairs(abi.classes) do
    if type(c) == "table" then
        for _, kind in ipairs({ "trigger", "effect" }) do
            -- the statements' reader: the one most keywords of the kind go to; a keyword the class
            -- reads with another (custom_tooltip's `text`, also a trigger) stays a key
            local names, n, readers = keyword_kind[kind] or {}, 0, {}
            for k, v in pairs(c.keys) do
                if names[k] and type(v) == "table" then
                    n = n + 1
                    local r = v.reader or "-"
                    readers[r] = (readers[r] or 0) + 1
                end
            end
            if n >= 100 then
                local reader, most = nil, 0
                for r, m in pairs(readers) do
                    if m > most then reader, most = r, m end
                end
                c.statements = kind .. "s"
                -- (an effect block makes each statement with its own CEffectEntry<C...>::Create)
                for k in pairs(names) do
                    local v = c.keys[k]
                    local r = type(v) == "table" and (v.reader or "-")
                    if r and (r == reader or r:match("^C%a+Entry<.*>::Create")) then c.keys[k] = nil end
                end
            end
        end
        -- a token handed to the parent's ReadMember is the parent's key (its default is not
        -- ReportUnexpected: CSettings to CSystemSettings)
        local to_parent = c.parent and c.parent .. "::ReadMember("
        local by_reader = {}
        for k, v in pairs(c.keys) do
            if type(v) == "table" then
                if to_parent and v.reader and v.reader:sub(1, #to_parent) == to_parent then
                    c.keys[k] = nil
                elseif not v.failed then
                    local r = v.reader or "-"
                    by_reader[r] = (by_reader[r] or 0) + 1
                end
            end
        end
        -- 1000 tokens or more down one path: with a reader, the class reads any key with it; with
        -- none (no call), it ignores a token it does not read, and its path is split by the
        -- switch's comparisons and its result (a void ReadMember's) is noise: not keys
        for reader, n in pairs(by_reader) do
            if n >= 1000 then
                if reader == "-" then c.ignores_unknown = true else c.any_key = reader end
                for k, v in pairs(c.keys) do
                    if type(v) == "table" and not v.failed and (v.reader or "-") == reader then
                        c.keys[k] = nil
                    end
                end
            end
        end
    end
end

-- the keywords ---------------------------------------------------------------------------------------
-- A keyword's class and the classes it derives from (RTTI, nearest first: the keywords file's
-- fifth column). Its keys are those of the ReadMembers that run for it, and the bases also say
-- its form: CBoolTrigger `= yes/no`, CIntTrigger a comparison, CAndTrigger a block of statements.
local missing_class = 0
for line in io.lines(kw_path) do
    local f = split(line)
    if f[1] == "trigger" or f[1] == "effect" then
        local bases = {}
        for b in ((f[5] or "") .. " > "):gmatch("(.-) > ") do
            if b ~= "" then bases[#bases + 1] = b end
        end
        local entry = { id = tonumber(f[3]), class = f[4], bases = bases }
        local keys, from = {}, {}
        -- the ReadMembers that run: the class's own, or the nearest base's that has one, then each
        -- one a token it does not read goes to (`parent`: a base's, or a helper's, CCreateSpecies
        -- to CSpecies)
        local chain, seen = {}, {}
        local start = abi.classes[f[4]] and f[4]
        for _, b in ipairs(bases) do
            if not start and abi.classes[b] then start = b end
        end
        local c = start
        while c and abi.classes[c] and not seen[c] do
            seen[c] = true
            chain[#chain + 1] = c
            c = abi.classes[c].parent
        end
        local traced = false
        for _, c in ipairs(chain) do
            if abi.classes[c] then
                traced = true
                entry.statements = entry.statements or abi.classes[c].statements
                for k in pairs(abi.classes[c].keys) do
                    if k ~= "__object" and not from[k] then
                        from[k] = c
                        keys[#keys + 1] = k
                    end
                end
            end
        end
        table.sort(keys)
        entry.keys = keys
        if not traced then
            entry.traced = false
            missing_class = missing_class + 1
        end
        abi[f[1] .. "s"][f[2]] = entry
    end
end
for _, c in pairs(abi.classes) do
    if type(c) == "table" then
        for k, v in pairs(c.keys) do
            if type(v) == "table" then v.from = nil end
        end
    end
end

local f = assert(io.open(out_path, "wb"))
f:write(encode(abi), "\n")
f:close()
local n = { classes = 0, keys = 0, failed = 0, triggers = 0, effects = 0 }
for name, c in pairs(abi.classes) do
    if name ~= "__object" then
        n.classes = n.classes + 1
        for k, v in pairs(c.keys) do
            if k ~= "__object" then
                n.keys = n.keys + 1
                if v.failed then n.failed = n.failed + 1 end
            end
        end
    end
end
for _ in pairs(abi.triggers) do n.triggers = n.triggers + 1 end
for _ in pairs(abi.effects) do n.effects = n.effects + 1 end
print(string.format("%s: %d classes, %d keys (%d whose value failed), %d triggers, %d effects (%d keywords whose class has no ReadMember of its own traced)",
    out_path, n.classes, n.keys, n.failed, n.triggers - 1, n.effects - 1, missing_class))
