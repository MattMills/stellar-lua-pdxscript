-- tools/oracle_check_reader.lua : pdxreader checked against what a build's own statement reader
-- did with the reader cases (a file of tools/oracle_readrun.lua): the statements, the variables
-- and the messages of every case.
--
--   luajit tools/oracle_check_reader.lua <oracle .tsv> <version> [--case <pattern>]
--
-- Keyword ids are not compared: a word is a word whether the static lexer knows it or not (W).
-- Without pdxmath the math cases are skipped. A case where the game's code did not finish (the
-- math_at_end hang) is compared on what it read before.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local pdxreader = require("pdxreader")
local report = require("oracle.report")
local has_math = pcall(require, "pdxmath")

local oracle_path, version = arg[1], arg[2]
local only
for i = 3, #arg do
    if arg[i] == "--case" then only = arg[i + 1] end
end
local profile = pdxreader.profile(version)

local cases = {}
for _, c in ipairs(require("oracle.reader_cases")) do
    cases[c.name] = c.text
end

local function q(s)
    return (string.format("%q", s):gsub("\n", "n"))
end

local function kind(id, quoted)
    if quoted then
        return "Q:" .. tostring(id or 15)
    end
    if id == nil or id == 15 or not report.FIXED[id] then
        return "W"
    end
    return tostring(id)
end

local function tok(t)
    if not t then return "-" end
    return kind(t.id, t.quoted) .. ":" .. q(t.text)
end

local function serialize(block)
    local parts = {}
    for _, e in ipairs(block) do
        local s = tok(e.key) .. "," .. tok(e.op) .. "," .. tok(e.value)
        if not e.op then
            s = s .. "~" .. tok(e.next)
        end
        if e.block then
            s = s .. "{" .. serialize(e.block) .. "}"
        end
        parts[#parts + 1] = s
    end
    return table.concat(parts, " ")
end

-- the oracle's fields, normalized like ours: tree, vars=, log= (inline= and error= set aside)
local function oracle_fields(rest)
    local fields = {}
    for f in (rest .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = f
    end
    local tree = (fields[1] or ""):gsub('(Q?:?)(%-?%d+):(")', function(qq, id, quote)
        if qq == "Q:" then return qq .. id .. ":" .. quote end
        id = tonumber(id)
        if not report.FIXED[id] or id == 15 then return "W:" .. quote end
        return id .. ":" .. quote
    end)
    local out = { tree = tree, vars = "", logs = {} }
    for i = 2, #fields do
        local k, v = fields[i]:match("^(%a+)=(.*)$")
        if k == "vars" then
            out.vars = v
        elseif k == "log" then
            out.logs[#out.logs + 1] = v
        elseif k == "error" then
            out.error = v
        end
    end
    return out
end

local function ours(text)
    local tree = pdxreader.read(text, profile)
    local logs = {}
    for _, l in ipairs(tree.log) do
        logs[#logs + 1] = q((l:gsub("\n$", "")))
    end
    return { tree = serialize(tree), vars = table.concat(tree.variables, ","), logs = logs, bugs = tree.bugs }
end

local checked, differ, skipped = 0, 0, 0
for line in io.lines(oracle_path) do
    local case, rest = line:match("^([^\t#][^\t]*)\t(.*)$")
    if case and cases[case] and (not only or case:find(only)) then
        if case:find("math") and not has_math then
            skipped = skipped + 1
        else
            checked = checked + 1
            local want = oracle_fields(rest)
            local ok, got = pcall(ours, cases[case])
            if not ok then
                got = { tree = "ERROR " .. tostring(got), vars = "", logs = {} }
            end
            local same = want.tree == got.tree and want.vars == got.vars and
                table.concat(want.logs, "|") == table.concat(got.logs, "|")
            if not same then
                differ = differ + 1
                print("== " .. case .. (want.error and ("   (the game: " .. want.error:sub(1, 60) .. ")") or ""))
                print("   game  " .. want.tree)
                print("   ours  " .. got.tree)
                if want.vars ~= got.vars then
                    print("   vars  game " .. want.vars .. "  ours " .. got.vars)
                end
                if table.concat(want.logs, "|") ~= table.concat(got.logs, "|") then
                    print("   log   game " .. table.concat(want.logs, " | "))
                    print("   log   ours " .. table.concat(got.logs, " | "))
                end
            end
        end
    end
end
print(string.format("%d cases checked, %d differ%s", checked, differ,
    skipped > 0 and string.format(" (%d math cases skipped: no pdxmath)", skipped) or ""))
os.exit(differ == 0 and 0 or 1)
