-- test_pdxscript.lua : targeted tests of pdxscript.lua.
--
-- Usage: luajit tests/test_pdxscript.lua
-- Prints each failure and a count; exits with 0 only if every test passed.

local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = here .. "/../?.lua;" .. package.path
local pdxscript = require("pdxscript")

local passed, failed = 0, 0

-- level: how many calls up the test is (1: the caller of check)
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

-- parse, and fail the test (returning an empty tree) on an error
local function parse(text, name)
    local tree, message = pdxscript.parse(text, name or "t.txt")
    check(tree ~= nil, "parse: " .. tostring(message))
    return tree or { warnings = {} }
end

-- the error message of text that must not parse
local function parse_error(text)
    local tree, message = pdxscript.parse(text, "t.txt")
    check(tree == nil, "expected an error for " .. string.format("%q", text))
    return message
end

-- A compact picture of a block, to compare whole trees: statements as key op value, tokens
-- quoted with "" when they were, blocks as { ... } (type{...} when typed), conditions as
-- [[NAME] ... ].
local function show(b)
    local parts = {}
    local function tok(t)
        return t.quoted and ('"' .. t.text .. '"') or t.text
    end
    local function value(v)
        if v.text then
            return tok(v)
        end
        return (v.type or "") .. "{" .. show(v) .. "}"
    end
    for _, e in ipairs(b) do
        if e.op then
            parts[#parts + 1] = tok(e.key) .. e.op .. value(e.value)
        elseif e.param then
            parts[#parts + 1] = "[[" .. (e.negated and "!" or "") .. e.param .. "]" .. show(e) .. "]"
        else
            parts[#parts + 1] = value(e)
        end
    end
    return table.concat(parts, " ")
end

-- every operator
do
    local t = parse("a = 1 b == 2 c != 3 d < 4 e > 5 f <= 6 g >= 7 h ?= 8")
    eq(show(t), "a=1 b==2 c!=3 d<4 e>5 f<=6 g>=7 h?=8", "operators")
    local ops = {}
    for i, e in ipairs(t) do
        ops[i] = e.op
    end
    eq(table.concat(ops, " "), "= == != < > <= >= ?=", "operator fields")
    -- no blanks needed around operators
    eq(show(parse("a=1 b==2 c!=3 d<4 e>5 f<=6 g>=7")), "a=1 b==2 c!=3 d<4 e>5 f<=6 g>=7", "operators without blanks")
    eq(show(parse("x={y=z}")), "x={y=z}", "braces without blanks")
end

-- `?` belongs to the word (Stellaris' `owner? = { }`); `?=` is an operator when it starts a token
do
    eq(show(parse("owner? = { is_ai = no }")), "owner?={is_ai=no}", "owner? = {}")
    eq(show(parse("owner?={ }")), "owner?={}", "owner?={")
    eq(show(parse("owner ?= { }")), "owner?={}", "owner ?= {")
    local t = parse("owner ?= { }")
    eq(t[1].key.text, "owner", "?= key")
    eq(t[1].op, "?=", "?= op")
    t = parse("owner?={ }")
    eq(t[1].key.text, "owner?", "owner? key")
    eq(t[1].op, "=", "owner? op")
end

-- statements, tokens, lines
do
    local t = parse("a = b\n\nc = { d = e }\n")
    eq(#t, 2, "two statements")
    eq(t[1].key.text, "a", "key text")
    eq(t[1].value.text, "b", "value text")
    eq(t[1].key.quoted, nil, "bare key")
    eq(t[1].line, 1, "statement line")
    eq(t[2].line, 3, "statement line after a blank line")
    eq(t[2].value.line, 3, "block line")
    eq(t[2].value[1].key.line, 3, "nested key line")
    eq(t.line, 1, "tree line")
    eq(t[2].value.last, 3, "block last line, '}' on the same line")
    eq(t.last, nil, "the tree has no last line")
    eq(t.name, "t.txt", "tree name")
    eq(#t.warnings, 0, "no warnings")
end
do
    -- last: the line of the '}' (or ']') that closes a block, or of the end of the file
    local t = parse("a = {\n  b = 1\n\n}\nc = { d = {\n} }\n[[P]\n x = 1\n]\ne = {\n")
    eq(t[1].value.last, 4, "last of a block closed lines later")
    eq(t[2].value.last, 6, "last of the outer block")
    eq(t[2].value[1].value.last, 6, "last of the inner block")
    eq(t[3].last, 9, "last of a parameter block")
    eq(t[4].value.last, 11, "last of a block the end of the file closes")
end

-- duplicates and order are kept
do
    local t = parse("a = 1 a = 2 b = 3 a = 1")
    eq(show(t), "a=1 a=2 b=3 a=1", "duplicates in order")
end

-- words: everything the corpus puts in them
do
    local words = {
        "event_target:foo", "value:my_value|PARAM|5|", "root.owner.capital_scope", "scope:x", "@my_var",
        "$PARAM$", "$PARAM|default$", "$PARAM$_flag", "-1.5", "+0.05", "2200.01.01", "trait/icon_element/tier_$TIER$",
        "Ni'amh", "X'u-an", "100%", "255.000,alpha_fade", "30\194\167", "\195\169t\195\169", "a;b", "f(x)*2",
    }
    local t = parse("list = { " .. table.concat(words, " ") .. " }")
    local list = t[1] and t[1].value or {}
    eq(#list, #words, "word count")
    for i, w in ipairs(words) do
        eq(list[i] and list[i].text, w, "word " .. i)
    end
    t = parse("event_target:x.owner = { exists = owner } check_variable = { which = v value >= value:sv|A|1| }")
    eq(show(t), "event_target:x.owner={exists=owner} check_variable={which=v value>=value:sv|A|1|}", "words as keys")
end

-- quoted strings: escapes, # inside, multiple lines, empty
do
    local t = parse('a = "x # not a comment" # a comment\nb = "say \\"hi\\" \\\\[Root.GetName]"\nc = ""\n"key" = value')
    eq(show(t), 'a="x # not a comment" b="say \\"hi\\" \\\\[Root.GetName]" c="" "key"=value', "strings")
    eq(t[1].value.quoted, true, "quoted value")
    eq(t[1].value.text, "x # not a comment", "# inside a string")
    eq(t[2].value.text, 'say \\"hi\\" \\\\[Root.GetName]', "escapes kept as written")
    eq(pdxscript.unescape(t[2].value.text), 'say "hi" \\[Root.GetName]', "unescape")
    eq(pdxscript.unescape("plain"), "plain", "unescape without escapes")
    eq(t[3].value.text, "", "empty string")
    eq(t[4].key.quoted, true, "quoted key")
    eq(t[4].line, 4, "line after strings")
    -- a string over several lines (vanilla passes triggers to inline scripts so)
    t = parse('inline_script = {\n\tTRIGGER = "owner? = {\n\t\thas_x = no\n\t}"\n\tAMOUNT = 1.5\n}\nnext = 1')
    local block = t[1].value
    eq(block[1].value.text, "owner? = {\n\t\thas_x = no\n\t}", "multi-line string")
    eq(block[2].line, 5, "line after a multi-line string")
    eq(t[2].line, 7, "line after the block")
    -- an escaped quote does not end the string, an escaped backslash does not escape the quote
    t = parse('a = "\\\\" b = c')
    eq(show(t), 'a="\\\\" b=c', "string ending in an escaped backslash")
end

-- comments
do
    local t = parse("# header\na = b # trailing { not a block\n#c = d\ne = f#tight\n# last line without newline")
    eq(show(t), "a=b e=f", "comments")
    eq(t[2].line, 4, "line after comments")
    eq(#parse("# only a comment"), 0, "file of comments")
    eq(#parse(""), 0, "empty file")
    eq(#parse("\n\n  \t\n"), 0, "blank file")
end

-- inline math, one token with its brackets
do
    local t = parse("count = @[ count * 2 ]\nv = @\\[ ( $P$ + 1 ) / | 2 - $Q|3$ | ]\n\"CHANCE\" = @\\[($A$+1)]\nw = 1")
    eq(t[1].value.text, "@[ count * 2 ]", "@[ ]")
    eq(t[2].value.text, "@\\[ ( $P$ + 1 ) / | 2 - $Q|3$ | ]", "@\\[ ]")
    eq(t[3].key.quoted, true, "math with a quoted key")
    eq(t[3].value.text, "@\\[($A$+1)]", "math without blanks")
    eq(t[4].line, 4, "line after math")
    t = parse("x = @[ a +\n b ] y = 1")
    eq(t[1].value.text, "@[ a +\n b ]", "math over two lines")
    eq(t[2].line, 2, "line after multi-line math")
    eq(t[1].value.quoted, nil, "math is not quoted")
end

-- scripted variables
do
    local t = parse("@tier1cost = 100\n@x = -1.5\nkey = { cost = @tier1cost }")
    eq(show(t), "@tier1cost=100 @x=-1.5 key={cost=@tier1cost}", "scripted variables")
end

-- parameter blocks of scripted triggers and effects
do
    local t = parse([=[
effect = {
	optimize_memory
	[[ENERGY]
		add_resource = { energy = $ENERGY$ }
	]
	[[!ENERGY] add_resource = { minerals = 100 } ]
	[[A]
		[[!B]
			x = y
		]
	]
}]=])
    eq(show(t), "effect={optimize_memory [[ENERGY]add_resource={energy=$ENERGY$}] [[!ENERGY]add_resource={minerals=100}] [[A][[!B]x=y]]}",
        "parameter blocks")
    local block = t[1] and t[1].value or {}
    local c = block[2] or {}
    eq(c.param, "ENERGY", "condition param")
    eq(c.negated, nil, "condition not negated")
    eq(c.line, 3, "condition line")
    eq(c[1] and c[1].key.text, "add_resource", "condition entry")
    eq(block[3] and block[3].negated, true, "negated condition")
    eq(block[3] and block[3].param, "ENERGY", "negated condition param")
    eq(block[4] and block[4][1] and block[4][1].param, "B", "nested condition")
    -- `]` right after a word ends it
    t = parse("[[P] a = $P$]")
    eq(show(t), "[[P]a=$P$]", "] after a word")
end

-- typed blocks: colours
do
    local t = parse("color = hsv { 0.5 0.2 0.8 }\nmap = rgb{ 1 2 3 }\nc = hsv360 { 360 50 50 }\nh = hex { aabbcc }")
    eq(show(t), "color=hsv{0.5 0.2 0.8} map=rgb{1 2 3} c=hsv360{360 50 50} h=hex{aabbcc}", "typed values")
    eq(t[1].value.type, "hsv", "type tag")
    eq(#t[1].value, 3, "typed block entries")
    eq(t[1].value[2].text, "0.2", "typed block value")
    eq(t[1].value.line, 1, "typed block line")
    -- in a list (common/colors)
    t = parse("colors = {\n\trgb { 142 188 241 }\n\thsv { 0.1 0.2 0.3 }\n}")
    eq(show(t), "colors={rgb{142 188 241} hsv{0.1 0.2 0.3}}", "typed blocks in a list")
    eq(t[1].value[1].type, "rgb", "typed block in a list")
    eq(#t.warnings, 0, "typed blocks in a list are not warned about")
    -- a quoted value before a block is a value, then a block
    t = parse('a = "hsv" { 1 }')
    eq(show(t), 'a="hsv" {1}', "quoted word before a block")
end

-- nested lists and mixed blocks
do
    local t = parse("a = { { 1 2 } { { 3 } { 4 } } {} }\nprerequisites = { tech_a OR = { tech_b tech_c } \"tech_d\" }")
    eq(show(t), 'a={{1 2} {{3} {4}} {}} prerequisites={tech_a OR={tech_b tech_c} "tech_d"}', "nested and mixed")
    eq(#t.warnings, 0, "nested and mixed: no warnings")
    local list = t[1].value
    eq(#list, 3, "list of blocks")
    eq(list[1].op, nil, "a block in a list is not a statement")
    eq(list[1].text, nil, "a block in a list is not a token")
    eq(list[1][2].text, "2", "token in a nested list")
    eq(list[2][2][1].text, "4", "deeper nesting")
    eq(#list[3], 0, "empty block")
    local mixed = t[2].value
    eq(mixed[1].text, "tech_a", "bare value in a mixed block")
    eq(mixed[2].op, "=", "statement in a mixed block")
    eq(mixed[3].quoted, true, "quoted bare value")
    -- top-level anonymous blocks (common/gamesetup_settings)
    eq(show(parse("{ a = 1 }\n{ b = 2 }")), "{a=1} {b=2}", "top-level blocks")
end

-- BOM and line ends
do
    local t = parse("\239\187\191a = b\nc = d")
    eq(show(t), "a=b c=d", "BOM")
    eq(t[1].key.text, "a", "BOM is not part of the first key")
    local _, message = pdxscript.parse("\239\187\191a = !", "t.txt")
    eq(message, "t.txt:1:5: '!' that is not part of '!=' or '[[!'", "column after a BOM")
    t = parse("a = b\r\nc = \"x\"\r\n\r\nd = { e }\r\n")
    eq(show(t), 'a=b c="x" d={e}', "CRLF")
    eq(t[1].value.text, "b", "no CR in words")
    eq(t[3].line, 4, "CRLF lines")
    t = parse("a = 1\tb = 2\fc = 3\vd = 4")
    eq(show(t), "a=1 b=2 c=3 d=4", "tab, form feed and vertical tab are blanks")
end

-- errors: name, line and column
do
    eq(parse_error("a = {\n\tb = = c\n}"), "t.txt:2:6: expected a value after '='", "two operators")
    eq(parse_error("a = {\n\tb = \"open\n}\n"), "t.txt:2:6: the string is not closed (no '\"')", "unclosed string")
    eq(parse_error("e = {\n\t[[P]\n\t\tx = [y\n\t]\n}"), "t.txt:3:7: '[' inside a parameter block that does not start '[[NAME]' or '@['",
        "lone [ in a parameter block")
    eq(parse_error("a = { b ! c }"), "t.txt:1:9: '!' that is not part of '!=' or '[[!'", "lone !")
    eq(parse_error("a = @[ 1 + 2"), "t.txt:1:5: inline math is not closed (no ']')", "unclosed math")
    eq(parse_error("a =\n"), "t.txt:2:1: the file ends after '=' (no value)", "no value at the end")
    eq(parse_error("e = {\n\t[[P]\n\t\tx = y\n\t}\n}"), "t.txt:4:2: '}' inside [[P] (line 2), which ']' closes", "} in a parameter block")
    eq(parse_error("[[!P]\n\tx = y\n"), "t.txt:3:1: the file ends inside [[!P] (line 1)", "end inside a parameter block")
    eq(parse_error("a = { b = }"), "t.txt:1:11: expected a value after '='", "key = }")
    local _, message = pdxscript.parse("a = !")
    eq(message, "<text>:1:5: '!' that is not part of '!=' or '[[!'", "default name")
end

-- tolerances, with warnings
do
    local t = parse("trait_bg_council = {\n\tcolor = { 1 2 3 }\n}\ntrait_bg_active_glow {\n\tcolor = { 4 5 6 }\n}")
    eq(show(t), "trait_bg_council={color={1 2 3}} trait_bg_active_glow={color={4 5 6}}", "missing operator")
    eq(t[2].op, "=", "missing operator read as =")
    eq(#t.warnings, 1, "missing operator warned")
    local w = t.warnings[1] or {}
    eq(w.kind, "missing_operator", "missing operator kind")
    eq(w.line, 4, "missing operator line")
    eq(w.col, 1, "missing operator column")

    t = parse("objectTypes = {\n\tpdxmesh = {\n\t\tname = x\n\t}\n")
    eq(show(t), "objectTypes={pdxmesh={name=x}}", "missing close")
    eq(#t.warnings, 1, "missing close warned")
    eq(t.warnings[1] and t.warnings[1].kind, "missing_close", "missing close kind")
    t = parse("a = { b = { c = d")
    eq(show(t), "a={b={c=d}}", "two blocks missing their close")
    eq(#t.warnings, 2, "one warning per block left open")

    t = parse("a = { b = c }\n}\nd = e")
    eq(show(t), "a={b=c} d=e", "extra close")
    eq(#t.warnings, 1, "extra close warned")
    w = t.warnings[1] or {}
    eq(w.kind, "extra_close", "extra close kind")
    eq(w.line, 2, "extra close line")

    -- outside parameter blocks [ and ] are bytes of words (2.8's special projects:
    -- `log = [fromfrom.GetName]`)
    t = parse("a = [from.GetName]\nb = x]y\nc = [d] e = f")
    eq(show(t), "a=[from.GetName] b=x]y c=[d] e=f", "brackets in words")
    eq(#t.warnings, 3, "bracket words warned")
    eq(t.warnings[1] and t.warnings[1].kind, "bracket_word", "bracket word kind")
    t = parse("e = {\n\t[[P]\n\t\tx = $P$]\n}")
    eq(show(t), "e={[[P]x=$P$]}", "] after a word still closes a parameter block")

    -- an operator where a key should be (2.2 to 2.5's name lists: `ion_cannon = { = { ... } }`)
    -- is skipped; a } after it is read with it, as the game's reader does
    t = parse("ion_cannon = { = { a b }\n}\nx = 1")
    eq(show(t), "ion_cannon={{a b}} x=1", "stray operator skipped")
    eq(t.warnings[1] and t.warnings[1].kind, "stray_operator", "stray operator kind")
    t = parse("x = 1\n= 2")
    eq(show(t), "x=1 2", "stray operator at the top")
    t = parse("a = { = } b = c }\nd = e")
    eq(show(t), "a={b=c} d=e", "stray operator: the } after it does not close")
    eq(#t.warnings, 2, "both warned")
end

-- write: back to text, and the same tree again
do
    local text = [=[
@v = 3
a = { b = "c d" e = { 1 2 3 } f = hsv { 0.1 0.2 0.3 } }
g >= @[ v * 2 ]
list = { x "y" { 1 } rgb { 1 2 3 } }
s = {
	optimize_memory
	[[P]
		k = $P$
	]
	[[!P] k = 0 ]
}
"quoted key" != "multi
line"
{ anonymous = yes }
]=]
    local t = parse(text)
    local written = pdxscript.write(t)
    local again = parse(written, "written")
    eq(show(again), show(t), "write and parse again")
    eq(written:match("^[^\n]*"), "@v = 3", "first written line")
    check(written:find("f = hsv { 0.1 0.2 0.3 }", 1, true) ~= nil, "typed block written inline")
    check(written:find("[[!P]\n\t\tk = 0\n\t]", 1, true) ~= nil, "condition written")
    eq(pdxscript.write(parse("")), "", "write an empty tree")
end

print(string.format("test_pdxscript: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
