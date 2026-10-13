-- tools/oracle_readreport.lua : what the builds' statement readers did with each case (the files
-- of tools/oracle_readrun.lua), grouped by result, with the versions that have each.
--
--   luajit tools/oracle_readreport.lua <dir of .tsv> [--raw] [--case <pattern>]
--
-- Keyword ids (numbered differently in every version) are compared as K, and with them the words
-- the static lexer does not know (15) when not quoted: W. --raw compares the ids themselves.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local report = require("oracle.report")

local dir = arg[1]
local raw, only = false, nil
for i = 2, #arg do
    if arg[i] == "--raw" then raw = true end
    if arg[i] == "--case" then only = arg[i + 1] end
end

-- a token is [Q:]id:"text"
local function normalize(s)
    if raw then return s end
    return (s:gsub('(Q?:?)(%-?%d+):(")', function(q, id, quote)
        if q == "Q:" then return q .. id .. ":" .. quote end
        id = tonumber(id)
        if not report.FIXED[id] or id == 15 then
            return q .. "W:" .. quote
        end
        return q .. id .. ":" .. quote
    end))
end

local names = {}
for _, c in ipairs(require("oracle.reader_cases")) do
    if not only or c.name:find(only) then
        names[#names + 1] = c.name
    end
end

local builds = report.load(dir)
local same, differ = report.group(builds, names, normalize)
report.print(builds, same, differ, function(r)
    local fields = {}
    for f in (r .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = f
    end
    print("      " .. fields[1])
    for i = 2, #fields do
        print("      " .. fields[i])
    end
end)
