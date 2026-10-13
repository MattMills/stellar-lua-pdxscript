-- tools/oracle_keywordreport.lua : the keywords compiled into each build (the files of
-- tools/oracle_keywords.lua), compared: how many each version has, which come and go between
-- consecutive versions, and, with --data <file>, a table of every keyword and the versions that
-- know it (data/keywords.tsv, read by pdxversions.lua).
--
--   luajit tools/oracle_keywordreport.lua <dir of .tsv> [--data <out file>] [--names]
--
-- Keywords are compared by name in lower case, as the static lexer looks them up. --names lists
-- the names that come and go, not only their numbers.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local report = require("oracle.report")

local dir = arg[1]
local data_path, names = nil, false
for i = 2, #arg do
    if arg[i] == "--data" then data_path = arg[i + 1] end
    if arg[i] == "--names" then names = true end
end

-- the builds, and per build its set of keywords
local builds = {}
local p = io.popen('ls "' .. dir .. '"/*.tsv')
for path in p:lines() do
    local name = path:match("([^/]+)%.tsv$")
    local b = { name = name, set = {}, count = 0 }
    for line in io.lines(path) do
        if line:sub(1, 1) ~= "#" then
            local word = line:match("^%-?%d+\t(.*)$")
            if word and word ~= "" and word ~= "?" then
                word = word:lower()
                if not b.set[word] then
                    b.set[word] = true
                    b.count = b.count + 1
                end
            end
        elseif line:find("^#error") then
            b.error = line
        end
    end
    builds[#builds + 1] = b
end
p:close()
-- versions in order (report.load's ordering: by the version in the file name)
local function key_of(name)
    local key = {}
    for n in (name:match("^v([%d%.]+)") or "0"):gmatch("%d+") do key[#key + 1] = tonumber(n) end
    return key
end
for _, b in ipairs(builds) do
    b.key = key_of(b.name)
    b.version = b.name:match("^v([%d%.]+)") or b.name
end
table.sort(builds, function(a, b)
    for i = 1, math.max(#a.key, #b.key) do
        local x, y = a.key[i] or -1, b.key[i] or -1
        if x ~= y then return x < y end
    end
    return a.name < b.name
end)

-- one build per version (the last of a version: the patch players got)
local versions, last = {}, nil
for _, b in ipairs(builds) do
    if not b.error then
        if last and last.version == b.version then
            versions[#versions] = b
        else
            versions[#versions + 1] = b
        end
        last = b
    end
end

print(string.format("%d builds, %d versions, %s to %s", #builds, #versions, versions[1].version,
    versions[#versions].version))
print("\n| version | keywords | added | removed |")
print("|---|---|---|---|")
local prev
for _, b in ipairs(versions) do
    local added, removed = {}, {}
    if prev then
        for w in pairs(b.set) do
            if not prev.set[w] then added[#added + 1] = w end
        end
        for w in pairs(prev.set) do
            if not b.set[w] then removed[#removed + 1] = w end
        end
    end
    table.sort(added)
    table.sort(removed)
    print(string.format("| %s | %d | %s | %s |", b.version, b.count, prev and #added or "", prev and #removed or ""))
    if names and prev and (#added > 0 or #removed > 0) then
        if #added > 0 then print("  + " .. table.concat(added, " ")) end
        if #removed > 0 then print("  - " .. table.concat(removed, " ")) end
    end
    prev = b
end

-- the data: keyword TAB the version ranges that know it (consecutive measured versions joined)
if data_path then
    local all = {}
    for _, b in ipairs(versions) do
        for w in pairs(b.set) do all[w] = true end
    end
    local words = {}
    for w in pairs(all) do words[#words + 1] = w end
    table.sort(words)
    local out = assert(io.open(data_path, "wb"))
    out:write("# keyword\tversions that have it compiled in (ranges of measured versions; ",
        "between two ranges it is absent from every measured version)\n")
    out:write("# measured: ")
    local vs = {}
    for _, b in ipairs(versions) do vs[#vs + 1] = b.version end
    out:write(table.concat(vs, " "), "\n")
    for _, w in ipairs(words) do
        local ranges, start, stop = {}, nil, nil
        for _, b in ipairs(versions) do
            if b.set[w] then
                start = start or b.version
                stop = b.version
            elseif start then
                ranges[#ranges + 1] = start == stop and start or (start .. ".." .. stop)
                start, stop = nil, nil
            end
        end
        if start then
            ranges[#ranges + 1] = start == stop and start or (start .. ".." .. stop)
        end
        out:write(w, "\t", table.concat(ranges, ","), "\n")
    end
    out:close()
    print(string.format("\n%d keywords written to %s", #words, data_path))
end
