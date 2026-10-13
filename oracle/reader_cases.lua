-- oracle/reader_cases.lua : texts that probe the corners of the game's statement reader
-- (CReader::ReadSimpleStatement in CPersistent::Read: keys, operators, values, blocks, scripted
-- variables, inline math), for comparing the builds with each other and with our readers. Each
-- case is { name, text }; the names are stable. Every text ends in a line feed, as script files do
-- (a word the end of the file ends is dropped by the lexer: lexer cases cover that).

local cases = {}

local function add(name, text)
    cases[#cases + 1] = { name = name, text = text .. "\n" }
end

-- inline math is followed by a statement: when it is the last value in a file, the reader reads
-- past the end of the file for a ']' that never comes (see bug.math_last)
local function math_case(name, text)
    add(name, text .. " z = z")
end

-- statements
add("st.assign", "a = b")
add("st.block", "a = { b = c }")
add("st.nested", "a = { b = { c = { d = e } } }")
add("st.many", "a = b c = d\ne = f")
add("st.quoted_key", "\"a b\" = c")
add("st.quoted_value", "a = \"b c\"")
add("st.number_key", "1 = a 2.5 = b -3 = c")
add("st.empty_block", "a = { }")
add("st.block_in_list", "a = { { b = c } { d = e } }")
add("st.list", "a = { b c d }")
add("st.typed", "color = rgb { 1 2 3 }")
add("st.typed_hsv", "color = hsv { 0.1 0.2 0.3 }")

-- operators
add("op.gt", "a > 1")
add("op.lt", "a < 1")
add("op.ge", "a >= 1")
add("op.le", "a <= 1")
add("op.ne", "a != 1")
add("op.eqeq", "a == 1")
add("op.qeq", "a ?= b")
add("op.q_key", "owner? = { a = b }")
add("op.ge_split", "a > = 1")
add("op.missing", "a { b = c }")
add("op.missing_value", "a b")
add("op.value_block_ge", "a >= { b = c }")

-- the end of a block or the file
add("end.extra_close", "a = b } c = d")
add("end.missing_close", "a = { b = c")
add("end.op_at_close", "a = { b = }")
add("end.value_close", "a = }")
add("end.op_eof", "a =")

-- scripted variables
add("var.define_use", "@x = 5 a = @x")
add("var.define_string", "@x = \"s t\" a = @x")
add("var.define_word", "@x = word a = @x")
add("var.chain", "@x = 5 @y = @x a = @y")
add("var.redefine", "@x = 5 @x = 6 a = @x")
add("var.undefined", "a = @nope")
add("var.in_block", "a = { @x = 7 b = @x } c = @x")
add("var.as_key", "@x = 5 @x = 6")
add("var.key_use", "@x = k @x = v")
add("var.no_value", "@x a = b")
add("var.block_value", "@x = { 1 2 } a = @x")
add("var.in_list", "@x = 5 a = { @x @x }")
add("var.case", "@X = 5 a = @x")
add("var.number_name", "@1 = 5 a = @1")

-- inline math
math_case("math.int", "a = @[ 1 + 2 ]")
math_case("math.precedence", "a = @[ 1 + 2 * 3 ]")
math_case("math.parens", "a = @[ ( 1 + 2 ) * 3 ]")
math_case("math.div", "a = @[ 7 / 2 ]")
math_case("math.div_int", "a = @[ 8 / 2 ]")
math_case("math.float", "a = @[ 0.1 + 0.2 ]")
math_case("math.neg", "a = @[ -3 + 1 ]")
math_case("math.unary_minus", "a = @[ 2 * -3 ]")
math_case("math.sub_chain", "a = @[ 10 - 3 - 2 ]")
math_case("math.div_chain", "a = @[ 64 / 4 / 2 ]")
math_case("math.mod", "a = @[ 7 % 3 ]")
math_case("math.abs", "a = @[ | -5 | ]")
math_case("math.var", "@x = 4 a = @[ x * 2 ]")
math_case("math.var_at", "@x = 4 a = @[ @x * 2 ]")
math_case("math.tight", "a = @[1+2]")
math_case("math.spaced_open", "a = @[ 1 + 2]")
math_case("math.escaped", "a = @\\[ 1 + 2 ]")
math_case("math.big", "a = @[ 1000000 * 1000000 ]")
math_case("math.small", "a = @[ 1 / 3 ]")
math_case("math.round", "a = @[ 2 / 3 ]")
math_case("math.many_decimals", "a = @[ 1.23456 + 0 ]")
math_case("math.negative_result", "a = @[ 1 - 5 ]")
math_case("math.zero_div", "a = @[ 1 / 0 ]")
math_case("math.unknown_var", "a = @[ nope + 1 ]")
math_case("math.junk", "a = @[ 1 + ]")
math_case("math.min_max", "a = @[ min(1, 2) ] b = @[ max(1, 2) ]")
math_case("math.as_key", "@[ 1 + 1 ] = a")
math_case("math.newline", "a = @[ 1 +\n2 ]")

-- the game's bugs, kept to see which versions have them
-- inline math as the last value of a file: at the end of the block the token is still "@[", which
-- the reader takes for more math, and ReadUntilCharacter(']') reads past the end forever
add("bug.math_last", "a = @[ 1 + 2 ]")

-- comments and the lexer's choices, as statements
add("cm.hash", "a = b # c = d\ne = f")
add("cm.semicolon", "a = b ; c = d\ne = f")
add("cm.bang", "a = b ! c = d\ne = f")
add("cm.paren", "a = ( b ) c = d")
add("cm.comma", "a = b, c = d")

-- inline scripts (3.x on: read through the game's files, here recorded as nothing)
add("inline.script", "inline_script = some/script a = b")
add("inline.block", "inline_script = { script = some/script P = 1 } a = b")

-- parameter blocks and parameters, as the plain reader sees them (templates are a later stage)
add("param.block", "[[P] a = b ] c = d")
add("param.dollar", "a = $P$ $Q$ = b")

return cases
