-- tools/oracle_mathfuzz.lua : random inline math run in a game build (the oracle) and in pdxmath.lua,
-- compared. Two paths:
--   direct  NMathParser::SolveExpression<CFixedPoint>(CString const&, CFixedPoint&) and
--           CToken::CToken(CFixedPoint const&) called on an expression (oracle/gamemath.lua),
--           against pdxmath.solve and pdxmath.text: the value, the text, success, crashes
--   reader  `eN = @[ expr ]` statements read by the game's statement reader after a header of
--           scripted variables (oracle/gamereader.lua), against pdxmath.evaluate: the value
--           token's text and id, and the messages logged for the statement's line
--
--   luajit tools/oracle_mathfuzz.lua <executable> [--version V] [--count N] [--reader N]
--          [--seed S] [--show N] [--batch N]
--
-- --count: direct expressions (default 20000); --reader: reader expressions (default 4000);
-- --show: mismatches printed (default 20). The version is taken from the path ("/v3.12.5 ...")
-- unless given. The last line is a summary: "summary <version> direct <n> <mismatches> reader <n>
-- <mismatches> crashes <n> seed <s>".
--
--   luajit tools/oracle_mathfuzz.lua <executable> --eval '1/3' [--eval ...]
--
-- prints, for each expression, what the game and pdxmath make of it on both paths (the header's
-- variables are defined for the reader path: see VARIABLES).

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local elf = require("oracle.elf")
local machine = require("oracle.machine")
local gamelexer = require("oracle.gamelexer")
local gamereader = require("oracle.gamereader")
local gamemath = require("oracle.gamemath")
local pdxmath = require("pdxmath")

local exe = arg[1]
local opts = { count = 20000, reader = 4000, seed = os.time(), show = 20, batch = 100 }
local evals = {}
local i = 2
while i <= #arg do
    local k = arg[i]:match("^%-%-(.*)$")
    if not k then
        error("unknown argument " .. arg[i])
    end
    if k == "eval" then
        evals[#evals + 1] = arg[i + 1]
    else
        opts[k] = arg[i + 1]
    end
    i = i + 2
end
for _, k in ipairs({ "count", "reader", "seed", "show", "batch" }) do
    opts[k] = tonumber(opts[k])
end
if not exe then
    io.stderr:write("usage: luajit tools/oracle_mathfuzz.lua <executable> [--version V] [--count N] [--reader N] [--seed S]\n")
    os.exit(2)
end
local version = opts.version or exe:match("/v(%d+%.%d+%.?%d*)[^/]*/[^/]*$") or exe:match("v(%d+%.%d+%.?%d*)")
local profile, why = pdxmath.profile(version)
if not profile then
    print("summary " .. tostring(version) .. " unsupported: " .. tostring(why))
    os.exit(0)
end
math.randomseed(opts.seed)
local random = math.random

-- the generator -----------------------------------------------------------------------------------------

local function pick(list)
    return list[random(#list)]
end

local function digits(n, first_nonzero)
    local t = {}
    for k = 1, n do
        t[k] = tostring(random(k == 1 and first_nonzero and 1 or 0, 9))
    end
    return table.concat(t)
end

local SPECIAL = { "0", "1", "1000000", "3037000499", "3037000500", "92233720368547", "92233720368548",
    "922337203.68547", "922337203.68548", "99999999999999999999", "100000000000000000000",
    "0.000005", "0.0000049", "0.0000051", "0.000015", "0.5", "2147483", "2147484", "2147483.647",
    "4294967295", "42949.67295", "1.23456", "0.1", "0.2", "0.3", "16777216", "16777217", "8388607.5",
    "0.00001", "0.001", "0.0005", "0.0015", "9223372036854775807", "1e5", "1.2.3", "..5", ".5", "5.",
    "0000001", "1." .. string.rep("9", 12), "33554431", "2147483648", "21474836.48", "1000000000" }

-- values at the edges of the arithmetic's paths (3037000499 and 92233720368547 raw, 1e10 raw,
-- -2^63, the 32-bit limits of 2.x)
local BOUNDARY = { "30370.00499", "30370.005", "30370.00498", "922337203.68547", "922337203.68548",
    "99999.99999", "100000", "100000.00001", "99999999999999999999", "92233720368547.75807",
    "92233720368547.75808", "2882303761517.11744", "0.00001", "1000000000", "10000000000",
    "2147483.647", "2147483.648", "1610.611", "2147.482", "2147.483", "46340.95", "2147483",
    "4294967.296", "1.5", "0.0000049", "0.000005", "65536", "4096", "1e5", "16777216.5" }

local function number()
    local r = random()
    if r < 0.08 then
        return pick(BOUNDARY)
    elseif r < 0.30 then
        return tostring(random(0, 100))
    elseif r < 0.55 then
        return tostring(random(0, 999)) .. "." .. digits(random(1, 6))
    elseif r < 0.62 then
        return digits(random(1, 10), true)
    elseif r < 0.66 then
        return digits(random(11, 25), true)
    elseif r < 0.70 then
        return tostring(random(0, 99)) .. "." .. digits(random(7, 12))
    elseif r < 0.74 then
        return random() < 0.5 and ("." .. digits(random(1, 6))) or (tostring(random(0, 99)) .. ".")
    elseif r < 0.78 then
        return tostring(random(0, 9)) .. "." .. digits(random(1, 3)) .. "." .. digits(random(1, 3))
    elseif r < 0.82 then
        return "0"
    end
    return pick(SPECIAL)
end

-- scripted variables: the header defines them; the names include undefined ones and a keyword
local VARIABLES = {
    { "x", "4" }, { "y", "-2.5" }, { "z", "0.001" }, { "big", "1000000" },
    { "huge", "99999999999999999999" }, { "neg", "-7" }, { "frac", ".5" }, { "w", "abc", 15 },
    { "q", '"3"', 15, "3" }, { "n1e", "1e5" }, { "k", "1a" }, { "dot", "1.2.3" }, { "m", "-" },
    { "yes", "7" }, { "a_b", "12.75" }, { "v9", "0.00001" }, { "minus", "-0.5" },
}
local NAMES = { "nope", "X", "x2", "Yes", "a_c", "min", "max", "abs" }
for _, v in ipairs(VARIABLES) do NAMES[#NAMES + 1] = v[1] end
local BY_NAME = {}
for _, v in ipairs(VARIABLES) do BY_NAME[v[1]] = v end
local function lookup(name)
    local v = BY_NAME[name]
    if v then
        return v[4] or v[2], v[3]
    end
end

local function ws(reader)
    local r = random()
    if r < 0.55 then return "" end
    if r < 0.85 then return " " end
    if r < 0.92 then return "  " end
    if r < 0.96 then return "\t" end
    if r < 0.98 then return "\r" end
    return reader and " " or "\n"
end

local OPS = { "+", "-", "*", "/", "%", "+", "-", "*", "/" }

local gen
local function term(depth, reader)
    local r = random()
    if r < 0.5 or depth > 4 then
        return (random() < 0.15 and "-" or "") .. number()
    elseif r < 0.62 then
        return pick(NAMES)
    elseif r < 0.80 then
        return "(" .. ws(reader) .. gen(depth + 1, reader) .. ws(reader) .. ")"
    elseif r < 0.90 then
        return "|" .. ws(reader) .. gen(depth + 1, reader) .. ws(reader) .. "|"
    end
    return "-" .. ws(reader) .. term(depth + 1, reader)
end
function gen(depth, reader)
    local parts = {}
    local n = 1 + random(0, depth > 2 and 1 or 3)
    for k = 1, n do
        if k > 1 then
            local op = pick(OPS)
            if random() < 0.05 then op = op .. pick(OPS) end
            parts[#parts + 1] = ws(reader) .. op .. ws(reader)
        end
        parts[#parts + 1] = term(depth, reader)
    end
    return table.concat(parts)
end

local JUNK = "abcxyzXQ_0123456789()|+-*/%.,@&'#!$^~=<>?:;\"[{}\\ \t"
local function mutate(s, reader)
    local n = random(1, 3)
    for _ = 1, n do
        local r = random()
        local p = random(1, #s + 1)
        if r < 0.4 and #s > 0 then
            s = s:sub(1, p - 1) .. s:sub(p + 1)
        elseif r < 0.8 then
            local c = random(1, #JUNK)
            s = s:sub(1, p - 1) .. JUNK:sub(c, c) .. s:sub(p)
        elseif r < 0.9 then
            s = s:sub(1, p - 1) .. string.char(random(128, 255)) .. s:sub(p)
        else
            s = s:sub(1, p - 1) .. pick({ "(", ")", "|", "-", "--", "||" }) .. s:sub(p)
        end
    end
    return s
end

-- two edge values and an operator, sometimes grouped with a third
local function pair()
    local function v()
        local s = random() < 0.6 and pick(BOUNDARY) or number()
        if random() < 0.3 then s = "-" .. s end
        if random() < 0.15 then s = "(" .. s .. pick(OPS) .. number() .. ")" end
        return s
    end
    local s = v() .. pick(OPS) .. v()
    if random() < 0.3 then
        s = "(" .. s .. ")" .. pick(OPS) .. v()
    end
    return s
end

local function expression(reader)
    local s = random() < 0.12 and pair() or gen(0, reader)
    if random() < 0.25 then
        s = mutate(s, reader)
    end
    if reader then
        s = s:gsub("[%]%z]", "")
    else
        s = s:gsub("%z", "")
    end
    return s
end

-- the oracle ------------------------------------------------------------------------------------------

local m = machine.new(elf.load(exe))
m.timeout = 600  -- the static lexer's token table takes a while on a busy machine
local gl = gamelexer.new(m)
local gm = gamemath.new(gl)
local gr = gamereader.new(gl)
m.timeout = 60

local shown, crashes = 0, 0
local function show(kind, what, expected, got)
    if shown < opts.show then
        print(string.format("MISMATCH %s %q\n  game:    %s\n  pdxmath: %s", kind, what, expected, got))
    end
    shown = shown + 1
end

-- the direct path: the game's and pdxmath's results as comparable texts
local function direct(s)
    local r = gm:solve(s)
    local ok, raw, crashed = pdxmath.solve(s, profile)
    local text = ok and pdxmath.text(raw, profile) or nil
    local game, ours
    if r.crash then
        game = "crash"
    else
        game = string.format("%s %s %s", tostring(r.ok), tostring(r.raw), tostring(r.text))
    end
    if crashed then
        ours = "crash"
    else
        ours = string.format("%s %s %s", tostring(ok), tostring(raw), tostring(text))
    end
    return game, ours, r.crash, crashed
end

-- the reader path: a header of variables, then a statement per line
local header = {}
for _, v in ipairs(VARIABLES) do
    header[#header + 1] = "@" .. v[1] .. " = " .. v[2]
end
local header_text = table.concat(header, "\n") .. "\n"
local header_lines = #VARIABLES

local function location(line)
    return " file:  line: " .. line
end

-- the game's statements and logs for a list of expressions: { { text, id, logs } ... } or nil, error
local function read_batch(list)
    local parts, lines, line = { header_text }, {}, header_lines + 1
    for k, e in ipairs(list) do
        parts[#parts + 1] = "e" .. k .. " = @[ " .. e .. " ]\n"
        local _, nl = e:gsub("\n", "")
        lines[k] = line + nl
        line = line + nl + 1
    end
    parts[#parts + 1] = "z = z\n"
    local tree = gr:read(table.concat(parts))
    if tree.error then
        return nil, tree.error
    end
    local by_line = {}
    for _, l in ipairs(tree.log) do
        l = l:gsub("\n$", "")
        local msg, n = l:match("^(.*) file:  line: (%d+)$")
        if msg then
            n = tonumber(n)
            by_line[n] = by_line[n] or {}
            table.insert(by_line[n], l)
        end
    end
    local out = {}
    for _, entry in ipairs(tree) do
        local k = entry.key and tonumber(entry.key.text:match("^e(%d+)$"))
        if k and entry.value then
            out[k] = { text = entry.value.text, id = entry.value.id, logs = by_line[lines[k]] or {} }
        end
    end
    return out, nil, lines
end

-- the reader path's results as comparable texts: the token's text(id) and the messages
local function reader_texts(e, game, line)
    local text, _, diagnostics, id, crashed = pdxmath.evaluate(e .. " ", profile, lookup, location(line))
    local ours
    if crashed then
        ours = "crash"
    else
        ours = string.format("%s(%s) | %s", tostring(text), tostring(id), table.concat(diagnostics, " | "))
    end
    local theirs
    if game == "crash" then
        theirs = "crash"
    else
        theirs = string.format("%s(%s) | %s", tostring(game.text), tostring(game.id), table.concat(game.logs, " | "))
    end
    return theirs, ours
end

local reader_n, reader_bad = 0, 0
local function compare_reader(e, game, line)
    local theirs, ours = reader_texts(e, game, line)
    reader_n = reader_n + 1
    if ours ~= theirs then
        reader_bad = reader_bad + 1
        show("reader", e, theirs, ours)
    end
end

-- --eval: the given expressions, shown
if #evals > 0 then
    for _, e in ipairs(evals) do
        local game, ours, why = direct(e)
        print(string.format("%q\n  direct  game:    %s%s\n          pdxmath: %s", e, game,
            why and (" (" .. why:sub(1, 100) .. ")") or "", ours))
        local r, _, lines = read_batch({ e })
        local theirs, ours2 = reader_texts(e, r and (r[1] or { text = "<no statement>", id = -1, logs = {} })
            or "crash", lines and lines[1] or header_lines + 1)
        print(string.format("  reader  game:    %s\n          pdxmath: %s", theirs, ours2))
        print(string.format("  literal game:    %s   pdxmath: %s", tostring(gm:literal(e)),
            tostring(pdxmath.literal(e, profile))))
    end
    os.exit(0)
end

-- the direct path, random expressions: 70% as the reader would pass them (variables substituted,
-- blanks and invalid characters gone), 30% raw
local direct_n, direct_bad = 0, 0
local t0 = os.clock()
for _ = 1, opts.count do
    local e = expression(false)
    local s = e
    if random() < 0.7 then
        s = pdxmath.substitute(e, profile, lookup)
    end
    local game, ours, game_crash, our_crash = direct(s)
    if game_crash then
        crashes = crashes + 1
    end
    direct_n = direct_n + 1
    if game ~= ours then
        direct_bad = direct_bad + 1
        show("direct", s, game .. (game_crash and (" (" .. game_crash:sub(1, 120) .. ")") or ""), ours ..
            (our_crash and (" (" .. our_crash .. ")") or ""))
    end
end
local t_direct = os.clock() - t0

-- the reader path, random expressions in batches
local t1 = os.clock()
local remaining = opts.reader
while remaining > 0 do
    local list = {}
    local n = math.min(opts.batch, remaining)
    for k = 1, n do
        list[k] = expression(true)
    end
    remaining = remaining - n
    -- expressions that pdxmath says crash the game are read alone (a crash ends the read)
    local together, alone = {}, {}
    for _, e in ipairs(list) do
        local _, _, _, _, crashed = pdxmath.evaluate(e .. " ", profile, lookup)
        if crashed then alone[#alone + 1] = e else together[#together + 1] = e end
    end
    local results, err, lines = read_batch(together)
    if not results then
        -- one of them crashed after all: each alone
        for _, e in ipairs(together) do alone[#alone + 1] = e end
        together = {}
    else
        for k, e in ipairs(together) do
            compare_reader(e, results[k] or { text = "<no statement>", id = -1, logs = {} }, lines[k])
        end
    end
    for _, e in ipairs(alone) do
        local r, err1, l1 = read_batch({ e })
        if r then
            compare_reader(e, r[1] or { text = "<no statement>", id = -1, logs = {} }, l1[1])
        else
            crashes = crashes + 1
            compare_reader(e, "crash", header_lines + 1)
        end
    end
end
local t_reader = os.clock() - t1

io.stderr:write(string.format("direct %.1fs, reader %.1fs\n", t_direct, t_reader))
print(string.format("summary %s direct %d %d reader %d %d crashes %d seed %d", version, direct_n,
    direct_bad, reader_n, reader_bad, crashes, opts.seed))
