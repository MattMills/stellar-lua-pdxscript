-- tools/oracle_check_lexer.lua : a Lua lexer that imitates GetTok, checked against what a build's
-- own lexer did with the cases (a file of tools/oracle_lexrun.lua): every call, every field.
--
--   luajit tools/oracle_check_lexer.lua <lexer.lua> <oracle .tsv> [profile]
--
-- The lexer module is loaded from the path given; it must have tokenize(text, start, lookup)
-- returning the calls as stellarstellaris-win's lua/stellar/script/lexer.lua does (rc, type,
-- quoted, text, line, pos, last, ungot; a word the static lexer decides has type nil and a
-- fallback), or tokenize(text, profile) for pdxlexer. Keyword ids are not compared: a word is a
-- word whether the static lexer knows it or not.

local here = arg[0]:match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local lexer_path, oracle_path, profile = arg[1], arg[2], arg[3]
local dir = lexer_path:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
-- stellarstellaris-win's lexer requires "stellar" only to log failures of its fast scan
package.preload["stellar"] = package.preload["stellar"] or function() return { log = print } end
local lexer = dofile(lexer_path)

local cases = {}
for _, c in ipairs(require("oracle.cases")) do
    cases[c.name] = c.text
end

local FIXED = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true,
    [8] = true, [9] = true, [12] = true, [15] = true, [19] = true, [467] = true, [468] = true,
    [971] = true, [972] = true, [1062] = true, [1063] = true }

-- the keywords whose id is that of punctuation (NOT is `!` from 3.x on)
local SHARED = { ["not"] = 1062 }

local function kind(id, quoted)
    if id == nil then return "W" end
    if not FIXED[id] then return "W" end
    if id == 15 and not quoted then return "W" end
    return tostring(id)
end

local function q(s)
    return (string.format("%q", s):gsub("\n", "n"))
end

-- the empty quoted string: from 2.x the game's _Val holds a NUL of size 2, which the oracle reads
-- as "\0" (1.x: ""); both sides compare it as ""
local EMPTY_QUOTED = string.format("%q", "\0")

-- the oracle's calls of a case, as written by oracle_lexrun (without the log)
local function oracle_calls(s)
    local out = {}
    for call in (s .. " | "):gmatch("(.-) | ") do
        if call:sub(1, 6) == "ERROR " then
            out.error = call
        else
            local rc, id, quoted, line, pos, last, unget, text = call:match(
                "^(%d+),(%-?%d+),(%d),(%-?%d+),(%-?%d+),(%-?%d+),(%d),(\".-\")%f[ %z]")
            if quoted == "1" and text == EMPTY_QUOTED then text = [[""]] end
            out[#out + 1] = string.format("%s,%s,%s,%s,%s,%s,%s", rc, kind(tonumber(id), quoted == "1"),
                quoted, line, pos, last, unget) .. "," .. text
        end
    end
    return out
end

local function lexer_calls(text)
    local calls
    if lexer.profile then
        calls = lexer.tokenize(text, lexer.profile(profile))
    else
        calls = lexer.tokenize(text)
    end
    local out = {}
    for _, c in ipairs(calls) do
        local id = c.type
        if id == nil and c.key then
            -- a word the static lexer decides: what it gives when it has no token of that name
            -- (NUMBER for digits, dots and minus signs), unless the word is one of SHARED
            local shared = not (lexer.profile and lexer.profile(profile).bang ~= "token") and SHARED[c.key]
            id = shared or (c.fallback == 12 and 12 or nil)
        end
        out[#out + 1] = string.format("%d,%s,%d,%d,%d,%d,%d", c.rc, kind(id, c.quoted), c.quoted and 1 or 0,
            c.line, c.pos, c.last, (c.ungot or c.unget) and 1 or 0) .. "," .. q(c.text)
    end
    return out
end

local checked, mismatched = 0, 0
for line in io.lines(oracle_path) do
    local case, rest = line:match("^([^\t#][^\t]*)\t(.*)$")
    if case and cases[case] then
        checked = checked + 1
        local want = oracle_calls(rest)
        local ok, got = pcall(lexer_calls, cases[case])
        if not ok then got = { "ERROR " .. tostring(got) } end
        local same = #want == #got
        for i = 1, math.max(#want, #got) do
            if want[i] ~= got[i] then same = false end
        end
        if not same then
            mismatched = mismatched + 1
            print("== " .. case)
            for i = 1, math.max(#want, #got) do
                local mark = want[i] == got[i] and "  " or "! "
                print(string.format("  %s game  %s", mark, want[i] or "-"))
                if want[i] ~= got[i] then
                    print(string.format("  %s ours  %s", mark, got[i] or "-"))
                end
            end
        end
    end
end
print(string.format("%d cases checked, %d differ", checked, mismatched))
os.exit(mismatched == 0 and 0 or 1)
