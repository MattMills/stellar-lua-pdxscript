-- tools/oracle_readfuzz.lua : random texts read by a build's own statement reader (in the
-- emulator) and by pdxreader with that build's profile; each text read differently is made as
-- small as it stays different, and printed.
--
--   luajit tools/oracle_readfuzz.lua <executable> <version> [count [seed]] [--math]
--
-- The texts are made of the pieces script is made of: words, numbers, quoted strings, every
-- operator, braces, comments, brackets, parentheses, scripted variable definitions and uses (and,
-- with --math, inline math). Keyword ids are compared as W, as in the reports.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamereader = require("oracle.gamereader")
local report = require("oracle.report")
local pdxreader = require("pdxreader")

local exe, version = arg[1], arg[2]
local count, seed, with_math = 1000, 1, false
local positional = {}
for i = 3, #arg do
    if arg[i] == "--math" then
        with_math = true
    else
        positional[#positional + 1] = tonumber(arg[i])
    end
end
count = positional[1] or count
seed = positional[2] or seed
math.randomseed(seed)
local profile = pdxreader.profile(version)

local PIECES = {
    "a", "b", "c", "key", "x1", "yes", "no", "NOT", "owner?", "event_target:x", "root.owner",
    "1", "-2", "3.5", "2200.01.01", "\"q\"", "\"s t\"", "\"\"", "\"@x\"",
    "=", "=", "=", "=", ">", "<", ">=", "<=", "!=", "==", "?=", "!", "= =",
    "{", "{", "{", "}", "}", "}", "{ }",
    "# c\n", ";", "\n", "\n", "(", ")", ",", "[", "]", "[[P]", "$P$",
    "@x = 5", "@y = w", "@z = @x", "@x", "@y", "@z", "@1 = 2", "@_a = 3", "@x =", "@nope",
}
local MATH = { "@[ 1 + 2 ]", "@[ x * 2 ]", "@[1+2]", "@[ 7 / 2 ]", "@\\[ 3 - 4 ]", "@[ nope ]" }

local function random_text()
    local n = math.random(1, 14)
    local parts = {}
    for i = 1, n do
        local p
        if with_math and math.random() < 0.15 then
            p = MATH[math.random(#MATH)]
        else
            p = PIECES[math.random(#PIECES)]
        end
        parts[i] = p
    end
    return parts
end

local function join(parts)
    -- a statement after everything: inline math at the very end of a file hangs the game's reader
    return table.concat(parts, " ") .. "\nzz = zz\n"
end

local function q(s)
    return (string.format("%q", s):gsub("\n", "n"))
end

local function tok(t)
    if not t then return "-" end
    local id = t.id
    local kind
    if t.quoted then
        kind = "Q:" .. tostring(id or 15)
    elseif id == nil or id == 15 or not report.FIXED[id] then
        kind = "W"
    else
        kind = tostring(id)
    end
    return kind .. ":" .. q(t.text)
end

local function shape(block)
    local out = {}
    for _, e in ipairs(block) do
        local s = tok(e.key) .. "," .. tok(e.op) .. "," .. tok(e.value)
        if not e.op then
            s = s .. "~" .. tok(e.next)
        end
        if e.block then
            s = s .. "{" .. shape(e.block) .. "}"
        end
        out[#out + 1] = s
    end
    return table.concat(out, " ")
end

local function describe(tree)
    local logs = {}
    for _, l in ipairs(tree.log or {}) do
        logs[#logs + 1] = (l:gsub("\n$", ""))
    end
    return shape(tree) .. " | vars " .. table.concat(tree.variables or {}, ",") .. " | log " .. table.concat(logs, " / ")
end

local image = elf.load(exe)
local m, gr
local function make()
    if m then m:close() end
    m = machine.new(image)
    gr = gamereader.new(gamelexer.new(m))
    m.timeout = 5
end
make()

-- the game's reading of a text, or nil when its code failed (the machine is then made again)
local function game(text)
    local tree = gr:read(text)
    if tree.error then
        make()
        return nil, tree.error
    end
    return describe(tree)
end

local function ours(text)
    return describe(pdxreader.read(text, profile))
end

local function differs(parts)
    local text = join(parts)
    local g = game(text)
    if not g then
        return false
    end
    return g ~= ours(text), g
end

-- the smallest list of pieces (removing one at a time) that is still read differently
local function minimize(parts)
    local changed = true
    while changed do
        changed = false
        for i = #parts, 1, -1 do
            local fewer = {}
            for j = 1, #parts do
                if j ~= i then fewer[#fewer + 1] = parts[j] end
            end
            if #fewer > 0 and differs(fewer) then
                parts = fewer
                changed = true
            end
        end
    end
    return parts
end

local mismatches, failures, seen = 0, 0, {}
for _ = 1, count do
    local parts = random_text()
    local text = join(parts)
    local g, err = game(text)
    if not g then
        failures = failures + 1
    elseif g ~= ours(text) then
        local small = minimize(parts)
        local key = join(small)
        if not seen[key] then
            seen[key] = true
            mismatches = mismatches + 1
            print("== " .. q(key))
            print("   game  " .. (game(key) or "?"))
            print("   ours  " .. ours(key))
        end
    end
end
print(string.format("%s: %d texts, %d read differently (%d distinct after minimizing), %d the game failed on",
    version, count, mismatches > 0 and mismatches or 0, mismatches, failures))
