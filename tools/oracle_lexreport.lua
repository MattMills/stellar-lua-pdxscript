-- tools/oracle_lexreport.lua : what the builds' lexers did with each case (the files of
-- tools/oracle_lexrun.lua), grouped: for every case, the distinct behaviours and the versions that
-- have each.
--
--   luajit tools/oracle_lexreport.lua <dir of .tsv> [--raw | --logic] [--case <pattern>]
--
-- By default token ids are compared by kind: the ids of punctuation and of NUMBER (12), STRING
-- (15) are kept, any other id is a keyword of the static lexer, "K" (keyword ids are numbered
-- differently in every version). --raw compares the ids themselves; --logic also counts keywords
-- and other words (15) as one kind, W, leaving only what the lexer itself does differently.

local dir = arg[1]
local raw, logic, only = false, false, nil
for i = 2, #arg do
    if arg[i] == "--raw" then raw = true end
    if arg[i] == "--logic" then logic = true end
    if arg[i] == "--case" then only = arg[i + 1] end
end

local FIXED = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true,
    [8] = true, [9] = true, [12] = true, [15] = true, [19] = true, [467] = true, [468] = true,
    [971] = true, [972] = true, [1062] = true, [1063] = true }

-- a result file is v<version>_<anything>.tsv; a Windows build's is v<version>_W_<store>...: its
-- label is w<version> (the version as its directory names it, 2.2.4-bed463fd)
local function version_key(name)
    local v = name:match("^v([%d%.]+)")
    local key = {}
    for n in (v or "0"):gmatch("%d+") do
        key[#key + 1] = tonumber(n)
    end
    local label = v or name
    local win = name:match("^v([^_]+)_W_")
    if win then
        label = "w" .. win
    end
    return key, label
end

local function before(a, b)
    for i = 1, math.max(#a.key, #b.key) do
        local x, y = a.key[i] or -1, b.key[i] or -1
        if x ~= y then return x < y end
    end
    return a.name < b.name
end

local builds = {}
local p = io.popen('ls "' .. dir .. '"/*.tsv')
for path in p:lines() do
    local name = path:match("([^/]+)%.tsv$")
    local key, version = version_key(name)
    local b = { name = name, key = key, version = version, results = {} }
    for line in io.lines(path) do
        local case, rest = line:match("^([^\t]+)\t(.*)$")
        if case == "#build" then
            b.layout = rest:match("\t(.*)$")
        elseif case == "#error" then
            b.error = rest
        elseif case then
            b.results[case] = rest
        end
    end
    builds[#builds + 1] = b
end
p:close()
table.sort(builds, before)

-- each call is rc,id,quoted,...: the id is replaced by its kind. With --logic, a word is a word
-- (W) whether the static lexer knows it or not, so that what remains is the lexer's own logic.
local function normalize(s)
    if raw then return s end
    local calls = {}
    for call in (s .. " | "):gmatch("(.-) | ") do
        call = call:gsub("^(%d+),(%-?%d+),(%d),", function(rc, id, quoted)
            id = tonumber(id)
            local kind = (FIXED[id] or id < 0) and tostring(id) or "K"
            if logic and quoted == "0" and (kind == "K" or kind == "15") then
                kind = "W"
            end
            return rc .. "," .. kind .. "," .. quoted .. ","
        end)
        calls[#calls + 1] = call
    end
    return table.concat(calls, " | ")
end

-- version ranges of a list of builds (in order): "1.0.0..1.2.5, 2.3.0"
local index = {}
for i, b in ipairs(builds) do index[b] = i end
local function ranges(list)
    table.sort(list, function(a, b) return index[a] < index[b] end)
    local out, start, prev = {}, nil, nil
    for _, b in ipairs(list) do
        if prev and index[b] == index[prev] + 1 then
            prev = b
        else
            if start then
                out[#out + 1] = start == prev and start.version or (start.version .. ".." .. prev.version)
            end
            start, prev = b, b
        end
    end
    if start then
        out[#out + 1] = start == prev and start.version or (start.version .. ".." .. prev.version)
    end
    return table.concat(out, ", ")
end

local case_names = {}
do
    local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
    package.path = here .. "/?.lua;" .. package.path
    for _, c in ipairs(require("oracle.cases")) do
        case_names[#case_names + 1] = c.name
    end
end

local errors = {}
for _, b in ipairs(builds) do
    if b.error then errors[#errors + 1] = b.version .. ": " .. b.error end
end
print(string.format("%d builds, %s to %s; %d could not be run", #builds, builds[1].version,
    builds[#builds].version, #errors))
for _, e in ipairs(errors) do print("  " .. e) end

local same, differ = {}, {}
for _, case in ipairs(case_names) do
    if not only or case:find(only) then
        local groups, order = {}, {}
        for _, b in ipairs(builds) do
            if not b.error then
                local r = normalize(b.results[case] or "<missing>")
                if not groups[r] then
                    groups[r] = {}
                    order[#order + 1] = r
                end
                table.insert(groups[r], b)
            end
        end
        if #order == 1 then
            same[#same + 1] = case
        else
            differ[#differ + 1] = { case = case, groups = groups, order = order }
        end
    end
end

print(string.format("\n%d cases behave the same in every build; %d differ:\n", #same, #differ))
for _, d in ipairs(differ) do
    print("== " .. d.case)
    for _, r in ipairs(d.order) do
        print("   [" .. ranges(d.groups[r]) .. "]")
        for call in (r .. " | "):gmatch("(.-) | ") do
            print("      " .. call)
        end
    end
end
print("\nthe same everywhere: " .. table.concat(same, " "))
