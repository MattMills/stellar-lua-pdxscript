-- tools/oracle_abidocs.lua : the script ABI (tools/oracle_abijson.lua) against the game's own
-- documentation of its triggers and effects (`script_docs`: logs/script_documentation/triggers.log
-- and effects.log).
--
--   luajit tools/oracle_abidocs.lua <abi.json> <triggers.log> <effects.log> [--list]
--
-- A documented keyword's keys are the words at the first level of its usage block followed by an
-- operator (`count = <num>`, `limit = { ... }`, `min_steps = 2`); the placeholders (`<triggers>`,
-- `<text used for fails>`) are not keys. For each: documented keys the ABI has not (what the trace
-- missed, or the docs' mistakes), and keys the ABI has the docs do not mention.

local abi_path, trig_path, eff_path = arg[1], arg[2], arg[3]
local list = arg[4] == "--list"

-- the JSON: only the keyword tables are needed, each `"name": { ... "keys": [...] ... }`
local text = assert(io.open(abi_path, "rb")):read("*a")
local function keywords(section)
    local out = {}
    local s = text:find('\n  "' .. section .. '": {', 1, true)
    if not s then return out end
    local e = text:find("\n  }", s, true)
    local body = text:sub(s, e)
    for name, entry in body:gmatch('\n    "([^"]+)": (%b{})') do
        local keys = {}
        local k = entry:match('"keys": (%b[])')
        for key in (k or ""):gmatch('"([^"]+)"') do keys[key] = true end
        out[name] = { keys = keys, traced = not entry:find('"traced": false', 1, true),
            statements = entry:match('"statements": "(%a+)"') }
    end
    return out
end

-- the docs: `name - description`, the usage lines, `Supported Scopes: ...`
local function docs(path)
    local out, cur = {}, nil
    for line in io.lines(path) do
        local name = line:match("^([%w_:%.@]+) %- ")
        if name and not cur then
            cur = { name = name, usage = {} }
        elseif cur and line:match("^Supported Scopes:") then
            out[cur.name] = cur
            cur = nil
        elseif cur then
            cur.usage[#cur.usage + 1] = line
        end
    end
    -- its keys: words at depth 1 followed by an operator
    for _, d in pairs(out) do
        local u = table.concat(d.usage, "\n"):gsub("%b<>", " ")
        local keys, depth, last = {}, 0, nil
        local i = 1
        while i <= #u do
            local c = u:sub(i, i)
            if c == "{" then
                depth, last, i = depth + 1, nil, i + 1
            elseif c == "}" then
                depth, last, i = depth - 1, nil, i + 1
            elseif u:match("^[<>!=]=?", i) then
                local op = u:match("^[<>!=]=?", i)
                if depth == 1 and last then keys[last] = true end
                last, i = nil, i + #op
            elseif c:match("[%w_@]") then
                local w = u:match("^[%w_@:%.]+", i)
                last, i = w, i + #w
            else
                if not c:match("%s") then last = nil end
                i = i + 1
            end
        end
        d.keys = keys
    end
    return out
end

local totals = { documented = 0, keyed = 0, doc_keys = 0, found = 0, missing = 0, extra = 0, absent = 0 }
local missing_by_key = {}
for _, kind in ipairs({ { "triggers", trig_path }, { "effects", eff_path } }) do
    local abi = keywords(kind[1])
    for name, d in pairs(docs(kind[2])) do
        totals.documented = totals.documented + 1
        local a = abi[name]
        if not a then
            totals.absent = totals.absent + 1
            if list then print("absent", kind[1], name) end
        elseif next(d.keys) then
            totals.keyed = totals.keyed + 1
            local miss, extra = {}, {}
            for k in pairs(d.keys) do
                totals.doc_keys = totals.doc_keys + 1
                if a.keys[k] then
                    totals.found = totals.found + 1
                else
                    miss[#miss + 1] = k
                    missing_by_key[k] = (missing_by_key[k] or 0) + 1
                end
            end
            for k in pairs(a.keys) do
                if not d.keys[k] then extra[#extra + 1] = k end
            end
            totals.missing = totals.missing + #miss
            totals.extra = totals.extra + #extra
            table.sort(miss)
            table.sort(extra)
            if list and (#miss > 0 or #extra > 0) then
                print(kind[1], name, a.traced and "" or "(untraced)",
                    "missing: " .. table.concat(miss, " "), "undocumented: " .. table.concat(extra, " "))
            end
        end
    end
end
print(string.format("%d documented keywords (%d not in the ABI), %d with keys: %d documented keys, %d in the ABI, %d not; %d ABI keys the docs do not mention",
    totals.documented, totals.absent, totals.keyed, totals.doc_keys, totals.found, totals.missing, totals.extra))
local top = {}
for k, n in pairs(missing_by_key) do top[#top + 1] = { k, n } end
table.sort(top, function(a, b) return a[2] > b[2] end)
local parts = {}
for i = 1, math.min(20, #top) do parts[#parts + 1] = top[i][1] .. " " .. top[i][2] end
print("missing most often: " .. table.concat(parts, ", "))
