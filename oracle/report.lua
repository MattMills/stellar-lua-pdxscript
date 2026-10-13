-- oracle/report.lua : what builds did with the same cases, grouped. Reads the .tsv files of the
-- runners (tools/oracle_lexrun.lua, tools/oracle_readrun.lua: a case name, a tab, its result),
-- orders the builds by version, and for every case gives the distinct results with the version
-- ranges that have each.
--
--   local report = require("oracle.report")
--   local builds = report.load(dir)                    -- sorted by version
--   local same, differ = report.group(builds, case_names, normalize)
--   report.print(builds, same, differ, print_result)

local report = {}

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

-- report.load(dir) -> builds: { name, version, key, results = { case = rest of line }, layout,
-- error }, sorted by version
function report.load(dir)
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
    for i, b in ipairs(builds) do
        b.index = i
    end
    return builds
end

-- report.ranges(list) -> "1.0.0..1.2.5, 2.3.0": the version ranges of builds (consecutive in the
-- order of all builds)
function report.ranges(list)
    table.sort(list, function(a, b) return a.index < b.index end)
    local out, start, prev = {}, nil, nil
    local function close()
        if start then
            out[#out + 1] = start == prev and start.version or (start.version .. ".." .. prev.version)
        end
    end
    for _, b in ipairs(list) do
        if prev and b.index == prev.index + 1 then
            prev = b
        else
            close()
            start, prev = b, b
        end
    end
    close()
    return table.concat(out, ", ")
end

-- report.group(builds, case_names, normalize) -> same, differ: the cases with one result in every
-- build that ran, and the others as { case, order = { result, ... }, groups = { result = builds } }
function report.group(builds, case_names, normalize)
    local same, differ = {}, {}
    for _, case in ipairs(case_names) do
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
        if #order <= 1 then
            same[#same + 1] = case
        else
            differ[#differ + 1] = { case = case, groups = groups, order = order }
        end
    end
    return same, differ
end

-- report.print(builds, same, differ, show): the summary, then each case that differs with its
-- results (show(result) prints one), then the cases that are the same
function report.print(builds, same, differ, show)
    local errors = {}
    for _, b in ipairs(builds) do
        if b.error then
            errors[#errors + 1] = b.version .. ": " .. b.error
        end
    end
    print(string.format("%d builds, %s to %s; %d could not be run", #builds, builds[1] and builds[1].version or "-",
        builds[#builds] and builds[#builds].version or "-", #errors))
    for _, e in ipairs(errors) do
        print("  " .. e)
    end
    print(string.format("\n%d cases behave the same in every build; %d differ:\n", #same, #differ))
    for _, d in ipairs(differ) do
        print("== " .. d.case)
        for _, r in ipairs(d.order) do
            print("   [" .. report.ranges(d.groups[r]) .. "]")
            show(r)
        end
    end
    print("\nthe same everywhere: " .. table.concat(same, " "))
end

-- the token ids that are the same in every version: punctuation, NUMBER (12), STRING (15), the
-- end of the file (19), the comparisons
report.FIXED = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true,
    [8] = true, [9] = true, [12] = true, [13] = true, [15] = true, [19] = true, [467] = true,
    [468] = true, [971] = true, [972] = true, [1062] = true, [1063] = true }

return report
