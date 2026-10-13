-- test_pdxlexer.lua : targeted tests of pdxlexer.lua. The expected calls are those the game's own
-- lexers gave in the emulator (oracle/README.md); tools/oracle_check_lexer.lua checks the whole set
-- of cases against every build.
--
-- Usage: luajit tests/test_pdxlexer.lua
-- Prints each failure and a count; exits with 0 only if every test passed.

local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = here .. "/../?.lua;" .. package.path
local pdxlexer = require("pdxlexer")

local passed, failed = 0, 0

local function check(ok, what, level)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        local info = debug.getinfo((level or 1) + 1, "l")
        print(string.format("FAIL line %d: %s", info and info.currentline or 0, what))
    end
end

local function eq(got, want, what)
    check(got == want, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)), 2)
end

-- the calls of text in a version, as "rc:type:text" (type W for a word the static lexer decides,
-- with no lookup given), joined with spaces
local function calls(version, text)
    local out = {}
    for _, c in ipairs(pdxlexer.tokenize(text, pdxlexer.profile(version))) do
        out[#out + 1] = string.format("%d:%s:%s", c.rc, c.type == nil and "W" or tostring(c.type), c.text)
    end
    return table.concat(out, " ")
end

-- the state after each call, as "line,pos,last,ungot"
local function states(version, text)
    local out = {}
    for _, c in ipairs(pdxlexer.tokenize(text, pdxlexer.profile(version))) do
        out[#out + 1] = string.format("%d,%d,%d,%d", c.line, c.pos, c.last, c.ungot and 1 or 0)
    end
    return table.concat(out, " ")
end

-- profiles ------------------------------------------------------------------------------------------

eq(pdxlexer.profile("1.0.2").long_token, "overflow", "1.0.x overflows long tokens")
eq(pdxlexer.profile("1.1.0").long_token, nil, "1.1.0 does not")
eq(pdxlexer.profile("1.2.5").comparisons, false, "1.2.5: no >=")
eq(pdxlexer.profile("2.4.1").comparisons, true, "2.4.1: >=")
eq(pdxlexer.profile("2.5.0").bang, "comment", "2.5.0: ! is a comment")
eq(pdxlexer.profile("3.12.5").bang, "token", "3.12.5: ! is a token")
eq(pdxlexer.profile().bang, "token", "the latest")
eq(pdxlexer.profile("4.5.2").uncertain, nil, "measured")
eq(pdxlexer.profile("4.6.0").uncertain, nil, "after the last measured: the latest profile")
eq(pdxlexer.profile("1.5.0").uncertain, true, "1.5.0: the >= change is in the gap 1.2.5 to 2.3.0")
eq(pdxlexer.profile("3.0.1").uncertain, true, "3.0.1: the ! change is in the gap 2.5.0 to 3.12.5")
eq(pdxlexer.profile("3.0.1").bang, "comment", "a gap takes the earlier profile")
eq(pdxlexer.compare_versions("3.12.5", "3.9.1"), 1, "versions compare by numbers")
eq(pdxlexer.compare_versions("2.2", "2.2.0"), 0, "missing parts are 0")

-- comparisons -----------------------------------------------------------------------------------------

eq(calls("1.2.5", "a >= b"), "1:W:a 1:467:> 1:1:= 0:W:b", "1.x: >= is two tokens")
eq(calls("2.3.0", "a >= b"), "1:W:a 1:971:>= 0:W:b", "2.x: >= is one")
eq(calls("4.5.2", "a<=b"), "1:W:a 1:972:<= 0:W:b", "<=")
eq(calls("4.5.2", "a > = b"), "1:W:a 1:467:> 1:1:= 0:W:b", "> = is two")
eq(calls("4.5.2", "a == b"), "1:W:a 1:1:= 1:1:= 0:W:b", "== is two =")
eq(calls("4.5.2", "a ?= b"), "1:W:a 1:W:? 1:1:= 0:W:b", "?= is the word ? and =")
eq(calls("4.5.2", "owner?={ }"), "1:W:owner? 1:1:= 1:3:{ 1:4:} 0:4:}", "owner?= is owner? and =")
-- after > the next byte is read and put back (2.x); 1.x does not look
eq(states("1.2.5", "a > b"), "1,2,32,0 1,3,62,0 1,6,255,0", "1.x: > alone")
eq(states("2.3.0", "a > b"), "1,2,32,0 1,4,32,1 1,6,255,0", "2.x: > reads the space and puts it back")
-- a line feed put back lowers the line until it is read again
eq(states("4.5.2", "a >\n= b"), "1,2,32,0 0,4,10,1 2,5,61,0 2,8,255,0", "> then a line feed")

-- ! -----------------------------------------------------------------------------------------------------

eq(calls("2.5.0", "a != b\nc"), "1:W:a 0:W:c", "2.5.0: ! starts a comment")
eq(calls("2.5.0", "a !"), "1:W:a 0:9:!", "a comment to the end of the file")
eq(calls("3.12.5", "a != b"), "1:W:a 1:1063:!= 0:W:b", "3.x: != is a token")
eq(calls("3.12.5", "!a"), "1:1062:! 0:W:a", "3.x: ! is a token")
eq(calls("3.12.5", "[[!P] b ]"), "1:W:[[ 1:1062:! 1:W:P] 1:W:b 0:W:]", "[[!P] in tokens")

-- comments ---------------------------------------------------------------------------------------------

eq(calls("4.5.2", "a # c\nb"), "1:W:a 0:W:b", "# to the end of the line")
eq(calls("4.5.2", "a;b\nc"), "1:W:a 0:W:c", "; too")
eq(calls("4.5.2", "a = \"x # y\""), "1:W:a 1:1:= 1:15:x # y 0:15:x # y", "not in a string")
eq(calls("4.5.2", "# only"), "0:9:#", "only a comment: the token holds it")

-- quoted strings -----------------------------------------------------------------------------------------

eq(calls("4.5.2", "\"a\\\"b\""), "1:15:a\"b 0:15:a\"b", "\\\" loses its backslash")
eq(calls("4.5.2", "\"a\\\\b\""), "1:15:a\\b 0:15:a\\b", "\\\\ too")
do
    local c = pdxlexer.tokenize("\"a\\nb\"", pdxlexer.profile("4.5.2"))
    eq(c[1].text, "a\\nb", "any other backslash stays")
    eq(#c.warnings, 1, "and is warned about")
end
eq(calls("4.5.2", "\"a\nb\" c"), "1:15:a\nb 0:W:c", "strings span lines")
eq(calls("4.5.2", "a = \"abc"), "1:W:a 1:1:= 1:15:abc 0:15:abc", "the end of the file ends a string")
eq(calls("4.5.2", "a\"b\"c"), "1:W:a 1:15:b 0:W:c", "a quote ends a word")
do
    local c = pdxlexer.tokenize("\"\"", pdxlexer.profile("4.5.2"))
    eq(c[1].text, "", "the empty string")
    eq(c[1].size, 2, "of size 2")
end

-- words, numbers, NUL ------------------------------------------------------------------------------------

eq(calls("4.5.2", "1 -1 -a 1a .5 2200.01.01"), "1:12:1 1:12:-1 1:12:-a 1:12:1a 1:12:.5 0:12:2200.01.01",
    "numbers: a digit or - first, or only digits, dots and minus signs")
eq(calls("4.5.2", "a,b(c)"), "1:W:a 1:8:, 1:W:b 1:5:( 1:W:c 1:6:) 0:6:)",
    "( ) , are tokens; at the end the token is the last one")
eq(calls("4.5.2", "@[x+1]"), "0:W:@[x+1]", "inline math is a word")
eq(calls("4.5.2", "a b"), "1:W:a 0:W:b", "a word the end of the file ends: rc 0")
eq(calls("1.1.0", "a\0b c"), "1:W:a 0:W:c", "1.x: a NUL ends the text")
eq(calls("2.3.0", "a\0b c"), "1:W:a\0b 0:W:c", "2.x: the text keeps it")
eq(calls("1.1.0", "a \0 b"), "1:W:a 1:0: 0:W:b", "1.x: an empty word is id 0")
eq(calls("2.3.0", "a \0 b"), "1:W:a 1:12:\0 0:W:b", "2.x: a NUMBER")
eq(calls("4.5.2", "a\255b"), "0:W:a\255b", "a byte >= 0x80 is part of a word")
eq(calls("4.5.2", "a\28b"), "0:W:a\28b", "0x1c is not a blank")
eq(states("4.5.2", "a\r\nb"), "1,2,13,0 2,5,255,0", "CR is a blank, LF counts")

-- keywords through a lookup
do
    local function lookup(key) return ({ yes = 16376, ["not"] = 1062 })[key] end
    local c = pdxlexer.tokenize("YES Not maybe", pdxlexer.profile("4.5.2"), lookup)
    eq(c[1].type, 16376, "the static lexer is asked in lower case")
    eq(c[2].type, 1062, "NOT")
    eq(c[3].type, 15, "an unknown word is STRING")
end

-- peek and read_until
do
    local lex = pdxlexer.new("a @[ x + 1 ] b", pdxlexer.profile("4.5.2"))
    eq(lex:next(), 1, "a")
    eq(lex:peek(), nil, "peek: @[ is a word the static lexer decides")
    eq(lex:next(), 1, "the peeked call")
    eq(lex.text, "@[", "@[")
    eq(lex:read_until("]"), "x + 1 ", "ReadUntilCharacter: after the blank that ended @[")
    eq(lex:next(), 0, "b ends the file")
    eq(lex.text, "b", "b")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
