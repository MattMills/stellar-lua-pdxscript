-- test_pdxast.lua : targeted tests of pdxast.lua (the corpus checks are tools/ast_check.lua).
--
-- Usage: luajit tests/test_pdxast.lua
-- Prints each failure and a count; exits with 0 only if every test passed.

local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
package.path = here .. "/../?.lua;" .. package.path
local pdxast = require("pdxast")
local pdxscript = require("pdxscript")

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

local function codes(ast)
    local out = {}
    for _, d in ipairs(ast.diagnostics) do
        if d.code ~= "uncertain_version" then
            out[#out + 1] = d.code
        end
    end
    return table.concat(out, " ")
end

-- lossless --------------------------------------------------------------------------------------------

for _, text in ipairs({
    "",
    "   \n\n",
    "# only a comment",
    "a = b",
    "\239\187\191a = b # with a BOM\r\n",
    "a=b\tc   =   { d\n\n\te }  # c\n; d = e\n",
    "x = \"a \\\" b\" y = @[ 1 + 2 ] z = { rgb { 1 2 3 } }",
    "e = {\n\t[[P]\n\t\tx = $P$\n\t]\n\t[[!Q] y = z ]\n}\n",
    "a = { b = c",
    "a = b } } c = d",
    "a = \"unclosed",
    "f(x), y; z",
}) do
    local ast = pdxast.parse(text)
    eq(pdxast.print(ast), text, "prints back " .. string.format("%q", text))
end

-- an edit of a token is printed
do
    local ast = pdxast.parse("a = 1 # one\nb = 2\n")
    ast.entries[2].value.token.text = "3"
    eq(pdxast.print(ast), "a = 1 # one\nb = 3\n", "an edited token")
end

-- positions -------------------------------------------------------------------------------------------

do
    local ast = pdxast.parse("a = {\n\tb = c\n}\n")
    local st = ast.entries[1]
    eq(st.kind, "statement", "a statement")
    eq(st.from, 1, "from")
    eq(st.to, 14, "to: the '}'")
    local inner = st.value.entries[1]
    eq(inner.key.token.line, 2, "line")
    eq(inner.key.token.col, 2, "column (a tab is one)")
    eq(st.value.close.line, 3, "the close")
end

-- values ----------------------------------------------------------------------------------------------

do
    local ast = pdxast.parse([[
a = "s \" t"
b = 12
c = -1.5
d = 2200.01.01
e = yes
f = @var
g = $PARAM|default$_x
h = event_target:x.owner?
i = @[ ( 1 + 2 ) * -x ]
j = word
]])
    local v = {}
    for _, e in ipairs(ast.entries) do
        v[e.key.token.text] = e.value
    end
    eq(v.a.type, "string", "string")
    eq(v.a.value, 's " t', "string unescaped")
    eq(v.b.type, "number", "integer")
    eq(v.b.integer, true, "integer flag")
    eq(v.c.value, -1.5, "float")
    eq(v.d.type, "date", "date")
    eq(v.e.value, true, "bool")
    eq(v.f.type, "variable", "variable")
    eq(v.f.name, "var", "variable name")
    eq(v.g.type, "parameter", "parameter")
    eq(v.g.params[1], "PARAM", "parameter name")
    eq(v.h.type, "scope", "scope chain")
    eq(#v.h.links, 2, "two links")
    eq(v.h.links[1].prefix, "event_target", "link prefix")
    eq(v.h.links[1].name, "x", "link name")
    eq(v.h.links[2].nullable, true, "owner?")
    eq(v.i.type, "math", "math")
    local e = v.i.expression or {}
    eq(e.op, "*", "math: * at the top")
    eq(e.left and e.left.op, "+", "math: the parentheses")
    eq(e.right and e.right.op, "neg", "math: unary minus")
    eq(e.right and e.right.operand and e.right.operand.name, "x", "math: a variable")
    eq(v.j.type, "word", "word")
end

do
    local e = pdxast.parse_math("1 + 2 * 3 - 4 / 2")
    eq(e.op, "-", "precedence: - last")
    eq(e.left.op, "+", "left associative")
    eq(e.left.right.op, "*", "* before +")
    local _, err = pdxast.parse_math("1 +")
    check(err ~= nil, "an incomplete expression is an error")
    e = pdxast.parse_math("| 1 - $X$ | / 2")
    eq(e.left.op, "abs", "absolute value")
    eq(e.left.operand.right.name, "X", "a parameter")
end

-- the game's lexing -----------------------------------------------------------------------------------

do
    local ast = pdxast.parse("a ?= b")
    eq(#ast.entries, 2, "?= is the word ? and =")
    eq(ast.entries[2].key.token.text, "?", "the key ?")
    eq(codes(ast), "question_operator", "?= warned")
    ast = pdxast.parse("owner?= { }")
    eq(ast.entries[1].key.token.text, "owner?", "owner?= is owner? =")
    eq(codes(ast), "", "and not warned")
    ast = pdxast.parse("a = b ; c = d\ne = f")
    eq(#ast.entries, 2, "; starts a comment")
    ast = pdxast.parse("a = f(x)")
    eq(ast.entries[1].value.token.text, "f", "( is a token of its own")
end

-- versions --------------------------------------------------------------------------------------------

do
    local ast = pdxast.parse("a != b\nc = d", { version = "2.5.0" })
    eq(#ast.entries, 2, "2.5.0: ! starts a comment")
    eq(ast.entries[1].kind, "value", "a is left alone")
    eq(codes(ast), "bang_comment", "warned")
    ast = pdxast.parse("a != b", { version = "4.5.2" })
    eq(ast.entries[1].op.text, "!=", "4.5.2: != is an operator")
    ast = pdxast.parse("a >= 1", { version = "1.2.5" })
    eq(codes(ast), "two_token_comparison", "1.2.5: >= is two tokens")
    ast = pdxast.parse("a = @[ 1 + 2 ]\nz = z", { version = "1.2.5" })
    eq(codes(ast), "no_inline_math", "1.2.5: no inline math")
    ast = pdxast.parse("@a = @[ 1 + 2 ] @b = 5 c = @b", { version = "4.5.2" })
    check(codes(ast):find("variable_value_eats", 1, true) ~= nil, "a variable from math skips the next token (the game's reading)")
    ast = pdxast.parse("a = b\n@x = 5\n", { version = "4.5.2" })
    check(codes(ast):find("stale_key", 1, true) ~= nil, "a variable at the end: the previous key again")
    ast = pdxast.parse("@x = 5\n@y = 6\n", { version = "4.5.2" })
    eq(codes(ast), "", "a file of variables only")
end

-- tolerances and errors --------------------------------------------------------------------------------

do
    local ast = pdxast.parse("key { a = b }")
    eq(codes(ast), "missing_operator", "missing operator")
    eq(ast.entries[1].missing_operator, true, "read as =")
    ast = pdxast.parse("a = { b = c")
    eq(codes(ast), "missing_close", "missing close")
    ast = pdxast.parse("a = b } c = d")
    eq(codes(ast), "extra_close", "extra close")
    eq(#ast.entries, 3, "an error node and the statements around it")
    ast = pdxast.parse("ion_cannon = { = { a } }")
    eq(codes(ast), "stray_operator", "stray operator")
    ast = pdxast.parse("a = = b")
    eq(codes(ast), "no_value stray_operator", "two operators")
end

-- the pdxscript tree -----------------------------------------------------------------------------------

do
    local text = "@v = 3\na = { b = \"c d\" e = { 1 2 3 } f = hsv { 0.1 0.2 0.3 } }\ng >= @[ v * 2 ]\n" ..
        "list = { x \"y\" { 1 } rgb { 1 2 3 } }\ns = {\n\toptimize_memory\n\t[[P]\n\t\tk = $P$\n\t]\n}\n"
    local want = pdxscript.parse(text)
    local got = pdxast.tree(pdxast.parse(text))
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do
            if k ~= "warnings" and k ~= "name" and not same(v, b[k]) then return false end
        end
        for k in pairs(b) do
            if k ~= "warnings" and k ~= "name" and a[k] == nil then return false end
        end
        return true
    end
    check(same(want, got), "pdxast.tree is pdxscript.parse's tree")
end

-- walk
do
    local ast = pdxast.parse("a = { b = c d }")
    local kinds = {}
    pdxast.walk(ast, function(node) kinds[#kinds + 1] = node.kind end)
    eq(table.concat(kinds, " "), "file statement value block statement value value value", "walk order")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
