-- pdxmath.lua : the game's inline math (`@[ expr ]` in script) of every Stellaris version, in plain
-- Lua (5.1 to 5.4, LuaJIT): the token the reader makes of an expression, with the same text, the
-- same internal value and the same log messages, overflows and odd corners included.
--
--   local pdxmath = require("pdxmath")
--   local profile = pdxmath.profile("3.12.5")       -- how that version computes
--   local text, raw, diagnostics, id = pdxmath.evaluate(" x * 2 + 1 ", profile, lookup)
--   -- text "9", raw "900000" (the CFixedPoint, in decimal), diagnostics {}, id 13
--
-- expr is the expression as the reader puts it together (CReader::ParseAdvancedStatement-
-- WithVariables): the token's text after "@[" (without a final "]" when the token ends in one),
-- followed, when it does not, by what CTextLexer::ReadUntilCharacter(']') read after the token
-- (pdxlexer: lex:read_until). `a = @[ 1 + 2 ]` gives " 1 + 2 " less the blank that ended the token
-- "@[", that is "1 + 2 ".
--
-- lookup(name) -> text [, id] resolves the scripted variables (`@x = 4` makes x): the value token's
-- text and id as the reader holds them, nil when there is no such variable. Without an id the
-- lexer's rule decides whether the value is a NUMBER (12): it starts with a digit or '-', or has
-- only digits, '.' and '-'. Which variables a version sees is the caller's business: 2.x looks in
-- the reader's own list (the file's variables), 3.x on in the list the statement is read with and
-- then in the global list (CReader::s_GlobalVariables).
--
-- Every rule here was measured: the game's own functions (NMathParser::SolveExpression<CFixedPoint>,
-- CToken::CToken(CFixedPoint const&), the statement reader) were run in an emulator on random
-- expressions and compared with this (tools/oracle_mathfuzz.lua, oracle/math.md).

local floor, ceil, huge, log = math.floor, math.ceil, math.huge, math.log
local byte, char, sub, format, rep = string.byte, string.char, string.sub, string.format, string.rep
local concat = table.concat

local pdxmath = {}

pdxmath.NUMBER = 12  -- the id of a failed expression's "0", and of a variable usable in math
pdxmath.RESULT = 13  -- the id of a result (CToken::CToken(CFixedPoint const&))

-- The profiles: how each version computes, from the first version measured to compute so.
--   math        false: there is no inline math, `@[` is a word like any other (1.x)
--   bits, scale the CFixedPoint: a 32-bit integer of thousandths (2.x) or a 64-bit integer of
--               hundred-thousandths (3.x on)
--   percent     '%' is a valid character and the remainder operator (3.x on); before, it is an
--               invalid character (logged and dropped: `7 % 3` is 73)
--   arithmetic  "int32": the 2.x operators on 32-bit values; "wrap": a product or a quotient's
--               dividend times the scale wraps around 64 bits; "split": the operands are split so
--               that the scale does not overflow (4.3.3 on)
--   divisor     ("split") how a divisor of -2^63 (a literal too large for 64 bits) is taken:
--               "small" goes the way of divisors below 1e10, "large" the way of the others
--   not_number  what "Variable %s is not a number." names: the variable ("name", 2.x) or its
--               value ("value")
pdxmath.PROFILES = {
    { version = "1.0.0", math = false },
    { version = "2.3.0", math = true, bits = 32, scale = 1000, percent = false, arithmetic = "int32",
        not_number = "name" },
    { version = "3.12.5", math = true, bits = 64, scale = 100000, percent = true, arithmetic = "wrap",
        not_number = "value" },
    { version = "4.3.3", math = true, bits = 64, scale = 100000, percent = true, arithmetic = "split",
        divisor = "small", not_number = "value" },
    { version = "4.5.1", math = true, bits = 64, scale = 100000, percent = true, arithmetic = "split",
        divisor = "large", not_number = "value" },
}

-- the versions whose math was measured; between two ranges the profile is the earlier one's,
-- marked uncertain (the change is somewhere in the gap)
pdxmath.MEASURED = {
    { "1.0.0", "1.2.5" }, { "2.3.0", "2.5.0" }, { "3.12.5", "4.5.2" },
}

local function version_parts(v)
    local t = {}
    for n in tostring(v):gmatch("%d+") do
        t[#t + 1] = tonumber(n)
    end
    return t
end

-- pdxmath.compare_versions(a, b) -> -1, 0, 1 (by numbers: "3.12.5" > "3.9.1")
function pdxmath.compare_versions(a, b)
    local x, y = version_parts(a), version_parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then
            return p < q and -1 or 1
        end
    end
    return 0
end
local cmpv = pdxmath.compare_versions

-- pdxmath.profile(version) -> profile, or nil and why: the math of that version (the latest
-- profile at or before it); uncertain = true when the version was not measured and a profile
-- changes in the gap it is in. pdxmath.profile() is the latest. Versions without inline math
-- (1.x) give nil.
function pdxmath.profile(version)
    local chosen = pdxmath.PROFILES[#pdxmath.PROFILES]
    if version then
        chosen = pdxmath.PROFILES[1]
        for _, p in ipairs(pdxmath.PROFILES) do
            if cmpv(p.version, version) <= 0 then
                chosen = p
            end
        end
    end
    local profile = {}
    for k, v in pairs(chosen) do
        profile[k] = v
    end
    profile.for_version = version
    if version then
        local inside = false
        for _, r in ipairs(pdxmath.MEASURED) do
            if cmpv(r[1], version) <= 0 and cmpv(version, r[2]) <= 0 then
                inside = true
            end
        end
        if not inside then
            local before, after
            for _, r in ipairs(pdxmath.MEASURED) do
                if cmpv(r[2], version) < 0 then before = r[2] end
                if not after and cmpv(r[1], version) > 0 then after = r[1] end
            end
            for _, p in ipairs(pdxmath.PROFILES) do
                if (not before or cmpv(p.version, before) > 0) and (not after or cmpv(p.version, after) <= 0) then
                    profile.uncertain = true
                end
            end
        end
    end
    if not profile.math then
        return nil, "no inline math in " .. tostring(version) .. (profile.uncertain and
            " (uncertain: inline math appears between 1.2.5 and 2.3.0)" or "")
    end
    return profile
end

-- 64-bit integers in doubles ---------------------------------------------------------------------
-- { high, low }: two unsigned 32-bit halves; negative when high >= 2^31 (two's complement). Every
-- operation wraps around 64 bits as the game's do.

local TWO32, TWO31, TWO16, TWO20 = 4294967296, 2147483648, 65536, 1048576

local function I(n)  -- an integer of a double (exact below 2^63) as an int64
    local h = floor(n / TWO32)
    return { h % TWO32, n - h * TWO32 }
end
local MIN64, MINUS1, ZERO = { TWO31, 0 }, { TWO32 - 1, TWO32 - 1 }, { 0, 0 }
local MAX64, MIN64P1 = { TWO31 - 1, TWO32 - 1 }, { TWO31, 1 }

local function isneg(a) return a[1] >= TWO31 end
local function iszero(a) return a[1] == 0 and a[2] == 0 end
local function eq(a, b) return a[1] == b[1] and a[2] == b[2] end

local function neg(a)
    local h, l = a[1], a[2]
    if l == 0 then
        return { (TWO32 - h) % TWO32, 0 }
    end
    return { TWO32 - 1 - h, TWO32 - l }
end

local function add(a, b)
    local l, c = a[2] + b[2], 0
    if l >= TWO32 then
        l, c = l - TWO32, 1
    end
    return { (a[1] + b[1] + c) % TWO32, l }
end

local function subtract(a, b)
    return add(a, neg(b))
end

-- the value as a double (exact when below 2^53)
local function tonum(a)
    local h = a[1]
    if h >= TWO31 then h = h - TWO32 end
    return h * TWO32 + a[2]
end

-- signed a < b
local function lt(a, b)
    local x, y = a[1], b[1]
    if x >= TWO31 then x = x - TWO32 end
    if y >= TWO31 then y = y - TWO32 end
    if x ~= y then
        return x < y
    end
    return a[2] < b[2]
end

-- the low 64 bits of a * b (imul), in 16-bit pieces so that every partial sum is exact
local function mul(a, b)
    local a0, a1 = a[2] % TWO16, floor(a[2] / TWO16)
    local a2, a3 = a[1] % TWO16, floor(a[1] / TWO16)
    local b0, b1 = b[2] % TWO16, floor(b[2] / TWO16)
    local b2, b3 = b[1] % TWO16, floor(b[1] / TWO16)
    local r0 = a0 * b0
    local r1 = a0 * b1 + a1 * b0
    local r2 = a0 * b2 + a1 * b1 + a2 * b0
    local r3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
    local low = r0 + (r1 % TWO16) * TWO16
    local lo = low % TWO32
    local hi = (floor(low / TWO32) + floor(r1 / TWO16) + r2 + (r3 % TWO16) * TWO16) % TWO32
    return { hi, lo }
end

-- unsigned n / d (d not 0) -> quotient, remainder
local function udivmod(n, d)
    local nh, nl, dh, dl = n[1], n[2], d[1], d[2]
    if dh == 0 and dl < TWO20 then
        -- a small divisor: two steps of base 2^32, each exact in a double
        local qh = floor(nh / dl)
        local r = nh - qh * dl
        if r < 0 then qh, r = qh - 1, r + dl elseif r >= dl then qh, r = qh + 1, r - dl end
        local x = r * TWO32 + nl
        local ql = floor(x / dl)
        r = x - ql * dl
        if r < 0 then ql, r = ql - 1, r + dl elseif r >= dl then ql, r = ql + 1, r - dl end
        return { qh, ql }, { 0, r }
    end
    if nh < TWO20 and dh < TWO20 then
        -- both below 2^52: in doubles
        local x, y = nh * TWO32 + nl, dh * TWO32 + dl
        local q = floor(x / y)
        local r = x - q * y
        while r < 0 do q, r = q - 1, r + y end
        while r >= y do q, r = q + 1, r - y end
        return I(q), I(r)
    end
    -- long division, a bit at a time
    local qh, ql, rh, rl = 0, 0, 0, 0
    for i = 63, 0, -1 do
        local bit
        if i >= 32 then
            bit = floor(nh / 2 ^ (i - 32)) % 2
        else
            bit = floor(nl / 2 ^ i) % 2
        end
        local t = rl * 2 + bit
        local carry = t >= TWO32 and 1 or 0
        rl = t - carry * TWO32
        rh = rh * 2 + carry
        if rh > dh or (rh == dh and rl >= dl) then
            rl = rl - dl
            local borrow = 0
            if rl < 0 then rl, borrow = rl + TWO32, 1 end
            rh = rh - dh - borrow
            if i >= 32 then qh = qh + 2 ^ (i - 32) else ql = ql + 2 ^ i end
        end
    end
    return { qh, ql }, { rh, rl }
end

-- the game's process dies (SIGFPE): an error carrying why, caught by pdxmath.solve
local CRASH = {}
local function crash(why)
    error({ [CRASH] = why }, 0)
end

-- signed a / b truncated (idiv) -> quotient, remainder (with a's sign); b = 0 and -2^63 / -1
-- fault, as idiv does
local function idivmod(a, b)
    if iszero(b) then
        crash("integer division by zero")
    end
    if eq(a, MIN64) and eq(b, MINUS1) then
        crash("integer division overflow (-2^63 / -1)")
    end
    local na, nb = isneg(a), isneg(b)
    local q, r = udivmod(na and neg(a) or a, nb and neg(b) or b)
    if na ~= nb then q = neg(q) end
    if na then r = neg(r) end
    return q, r
end

-- the decimal text of an int64
local BILLION = { 0, 1000000000 }
local function decimal(a)
    local v = tonum(a)
    if v > -2 ^ 53 and v < 2 ^ 53 then
        return format("%.0f", v)
    end
    local negative = isneg(a)
    local q, r = udivmod(negative and neg(a) or a, BILLION)
    return (negative and "-" or "") .. format("%.0f%09d", q[1] * TWO32 + q[2], r[2])
end

-- an int64 of a decimal text ("-123")
local TEN = I(10)
local function from_decimal(s)
    local negative, digits = s:match("^%s*(%-?)(%d+)%s*$")
    if not digits then
        error("pdxmath: not an integer: " .. tostring(s), 3)
    end
    local v = ZERO
    for i = 1, #digits do
        v = add(mul(v, TEN), I(byte(digits, i) - 48))
    end
    return negative == "-" and neg(v) or v
end

-- single precision ----------------------------------------------------------------------------------

local LOG2 = log(2)

-- the double nearest x in single precision (ties to even), as cvtsd2ss, mulss and addss round
local function fround(x)
    if x == 0 or x ~= x or x == huge or x == -huge then
        return x
    end
    local a = x < 0 and -x or x
    if a <= 2 ^ -150 then
        return 0 * x  -- below half the least subnormal: zero (of x's sign)
    end
    local e = floor(log(a) / LOG2) + 1
    while 2 ^ (e - 1) > a do e = e - 1 end
    while 2 ^ e <= a do e = e + 1 end
    -- 24 significant bits, or the subnormals' fixed step of 2^-149
    local qe = e - 24
    if qe < -149 then qe = -149 end
    local q = 2 ^ qe
    local n = a / q
    local fl = floor(n)
    local fr = n - fl
    if fr > 0.5 or (fr == 0.5 and fl % 2 == 1) then
        fl = fl + 1
    end
    local r = fl * q
    if r >= 2 ^ 128 then
        r = huge
    end
    return x < 0 and -r or r
end
pdxmath.fround = fround

-- strtod on a number's text, which is an optional '-' and digits and dots: the longest prefix
-- that is a decimal number ("1.2.3" is 1.2), 0 when there is none
local function strtod(text)
    local sign, int, rest = text:match("^(%-?)(%d*)(.*)$")
    local frac = rest:match("^%.(%d*)") or ""
    if int == "" and frac == "" then
        return 0
    end
    local v = tonumber((int == "" and "0" or int) .. (frac ~= "" and ("." .. frac) or "")) * 1.0
    return sign == "-" and -v or v
end

-- the arithmetic of each profile -------------------------------------------------------------------
-- lit(text) the value of a number (SMathToken<CFixedPoint>(char const*)); add, sub, mul, div, mod,
-- abs; text(value) the result's token text (CToken::CToken(CFixedPoint const&)); show(value) the
-- value in decimal.

local ARITHMETIC = {}

-- a literal: strtod, to single precision, times the scale and plus 0.5 in single precision, floored
-- when the number is negative, truncated to an integer of `bits` bits (the most negative one when
-- it does not fit: cvttss2si's "integer indefinite")
local function literal_number(text, scale, bits)
    local f = fround(strtod(text))
    local x = fround(fround(f * scale) + 0.5)
    if not (f >= 0) then
        x = floor(x)
    end
    local limit = 2 ^ (bits - 1)
    if x ~= x or x >= limit or x < -limit then
        return -limit
    end
    return x >= 0 and floor(x) or ceil(x)
end

-- 2.x: 32-bit thousandths
local function wrap32(x)
    return (x + TWO31) % TWO32 - TWO31
end
-- x / y truncated, for integers in doubles whose quotient times y is exact
local function tdiv(x, y)
    local q = x / y
    q = q >= 0 and floor(q) or ceil(q)
    local r = x - q * y
    -- the double quotient may be one off: the remainder takes x's sign and is below |y|
    local ay = y < 0 and -y or y
    if x >= 0 then
        while r < 0 do q = q - (y > 0 and 1 or -1); r = x - q * y end
        while r >= ay do q = q + (y > 0 and 1 or -1); r = x - q * y end
    else
        while r > 0 do q = q + (y > 0 and 1 or -1); r = x - q * y end
        while -r >= ay do q = q - (y > 0 and 1 or -1); r = x - q * y end
    end
    return q
end
local THOUSAND64 = I(1000)
ARITHMETIC.int32 = {
    lit = function(text) return literal_number(text, 1000, 32) end,
    add = function(a, b) return wrap32(a + b) end,
    sub = function(a, b) return wrap32(a - b) end,
    -- the product in 64 bits, divided by 1000, the low 32 bits kept
    mul = function(a, b)
        local q = idivmod(mul(I(a), I(b)), THOUSAND64)
        return wrap32(tonum(q))
    end,
    -- b = 0 gives -1 (-0.001); else a * 1000 / b in 64 bits, the low 32 bits kept
    div = function(a, b)
        if b == 0 then
            return -1
        end
        return wrap32(tdiv(a * 1000, b))
    end,
    abs = function(a) return a < 0 and wrap32(-a) or a end,
    -- "%d.%03d" of the quotient and the remainder by 1000; "-0.%03d" between -0.999 and -0.001
    text = function(v)
        local q = tdiv(v, 1000)
        local r = v - q * 1000
        if r >= 0 then
            return format("%d.%03d", q, r)
        elseif v >= -999 then
            return format("-%d.%03d", q, -r)
        end
        return format("%d.%03d", q, -r)
    end,
    show = function(v) return format("%d", v) end,
    parse = function(s) return tonumber(s) end,
}

-- 3.x on: 64-bit hundred-thousandths
local SCALE64 = I(100000)
local FFFFFFFF = { 0, TWO32 - 1 }  -- what a division by zero gives: 42949.67295

local function lit64(text)
    return I(literal_number(text, 100000, 64))
end
local function abs64(a)
    return isneg(a) and neg(a) or a
end
local function mod64(a, b)
    local _, r = idivmod(a, b)
    return r
end
local function text64(v)
    local q, r = idivmod(v, SCALE64)
    local digits = ""
    if not iszero(r) then
        digits = "." .. (format("%05d", tonum(abs64(r))):gsub("0+$", ""))
    end
    return (isneg(v) and "-" or "") .. format("%.0f", tonum(abs64(q))) .. digits
end

-- 3.12.5 to 4.3.2: a * b wraps around 64 bits before it is divided by the scale; a / b is
-- a * 100000 (wrapping) / b, and 0xffffffff when b is 0 or a is one of -2^63, -2^63 + 1, 2^63 - 1
ARITHMETIC.wrap = {
    lit = lit64,
    add = add,
    sub = subtract,
    mul = function(a, b) return (idivmod(mul(a, b), SCALE64)) end,
    div = function(a, b)
        if iszero(b) or eq(a, MIN64) or eq(a, MIN64P1) or eq(a, MAX64) then
            return FFFFFFFF
        end
        return (idivmod(mul(a, SCALE64), b))
    end,
    mod = mod64,
    abs = abs64,
    text = text64,
    show = decimal,
    parse = from_decimal,
}

-- 4.3.3 on: operands that would overflow are split by the scale
local SQRT_LIMIT = I(3037000499)        -- floor(sqrt(2^63)): products of two smaller ones fit
local DIV_LIMIT = I(92233720368547)     -- floor(2^63 / 100000): a * 100000 fits
local SMALL_DIVISOR = I(10000000000)    -- 1e10
local function within(a, limit)
    return not lt(limit, a) and not lt(a, neg(limit))
end
local function split_arithmetic(divisor)
    return {
        lit = lit64,
        add = add,
        sub = subtract,
        -- both within +-3037000499: a * b / 100000; else the larger (signed) one is split into
        -- q * 100000 + r: q * smaller + r * smaller / 100000 (each wrapping)
        mul = function(a, b)
            if within(a, SQRT_LIMIT) and within(b, SQRT_LIMIT) then
                return (idivmod(mul(a, b), SCALE64))
            end
            local big, small = a, b
            if lt(a, b) then big, small = b, a end
            local q, r = idivmod(big, SCALE64)
            return add((idivmod(mul(r, small), SCALE64)), mul(q, small))
        end,
        -- b = 0: 0xffffffff. a within +-92233720368547: a * 100000 / b. Else, a divisor below
        -- 1e10 (in absolute value): a = q * 100000 + r, and q * 100000 / b = quot, rem gives
        -- quot * 100000 + rem * 100000 / b + r * 100000 / b; a larger one: a / (b / 100000)
        div = function(a, b)
            if iszero(b) then
                return FFFFFFFF
            end
            if within(a, DIV_LIMIT) then
                return (idivmod(mul(a, SCALE64), b))
            end
            local small
            if eq(b, MIN64) then
                small = divisor == "small"  -- |b| is still -2^63: below 1e10 if compared signed
            else
                small = lt(abs64(b), SMALL_DIVISOR)
            end
            if small then
                local q = idivmod(a, SCALE64)
                local x = mul(q, SCALE64)
                local quot, rem = idivmod(x, b)
                local r = subtract(a, x)
                local t1 = idivmod(mul(rem, SCALE64), b)
                local t2 = idivmod(mul(r, SCALE64), b)
                return add(add(t1, mul(quot, SCALE64)), t2)
            end
            return (idivmod(a, (idivmod(b, SCALE64))))
        end,
        mod = mod64,
        abs = abs64,
        text = text64,
        show = decimal,
        parse = from_decimal,
    }
end
ARITHMETIC.split_small = split_arithmetic("small")
ARITHMETIC.split_large = split_arithmetic("large")

local function arithmetic_of(profile)
    local a = profile.arithmetic
    if a == "split" then
        return profile.divisor == "large" and ARITHMETIC.split_large or ARITHMETIC.split_small
    end
    local found = ARITHMETIC[a]
    if not found then
        error("pdxmath: a profile without math (or an unknown arithmetic): " .. tostring(a), 3)
    end
    return found
end

-- SolveExpression ------------------------------------------------------------------------------------

-- token kinds; the operators' precedence (anything else on the operator stack counts as 0)
local NUM, ADD, SUB, MUL, DIV, MOD, LP, RP, ABS_OPEN, ABS_CLOSE = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
local PREC = { [ADD] = 2, [SUB] = 2, [MUL] = 3, [DIV] = 3, [MOD] = 3 }
local OPERATOR_NAME = { [ADD] = "add", [SUB] = "sub", [MUL] = "mul", [DIV] = "div", [MOD] = "mod" }
-- a '-' after these is a subtraction; anywhere else it is the sign of a number
local AFTER_VALUE = { [NUM] = true, [RP] = true, [ABS_CLOSE] = true }

-- the tokens of SolveExpression's own scan. A number is an optional '-' and the digits and dots
-- after it; a '-' that no digit or dot follows also swallows the byte after it, and any other
-- byte is skipped. '|' opens an absolute value unless the innermost open one was opened at the
-- same parenthesis depth (it closes it then; at a deeper one it is ignored); the depth is a byte.
local function tokenize(s, profile, A)
    local tokens = {}
    local depth, opened = 0, {}
    local n = #s
    local i = 1
    while i <= n do
        local c = byte(s, i)
        if c == 37 and profile.percent then
            tokens[#tokens + 1] = { MOD }
        elseif c == 40 then
            tokens[#tokens + 1] = { LP }
            depth = (depth + 1) % 256
        elseif c == 41 then
            tokens[#tokens + 1] = { RP }
            depth = (depth + 255) % 256
        elseif c == 42 then
            tokens[#tokens + 1] = { MUL }
        elseif c == 43 then
            tokens[#tokens + 1] = { ADD }
        elseif c == 47 then
            tokens[#tokens + 1] = { DIV }
        elseif c == 124 then
            local top = opened[#opened]
            if top ~= nil and top >= depth then
                if top == depth then
                    tokens[#tokens + 1] = { ABS_CLOSE }
                    opened[#opened] = nil
                end
            else
                tokens[#tokens + 1] = { ABS_OPEN }
                opened[#opened + 1] = depth
            end
        elseif c == 45 and #tokens > 0 and AFTER_VALUE[tokens[#tokens][1]] then
            tokens[#tokens + 1] = { SUB }
        else
            local sign = ""
            if c == 45 then
                sign = "-"
                i = i + 1
            end
            if i <= n then
                local k = i
                while k <= n do
                    local d = byte(s, k)
                    if (d >= 48 and d <= 57) or d == 46 then
                        k = k + 1
                    else
                        break
                    end
                end
                if k > i then
                    tokens[#tokens + 1] = { NUM, A.lit(sign .. sub(s, i, k - 1)) }
                    i = k - 1
                end
            end
        end
        i = i + 1
    end
    return tokens
end

-- the shunting-yard and the evaluation of its output, as the game does them: left associative,
-- '*' '/' '%' before '+' '-'. A ')' pops operators to the matching '(' (or all of them), a closing
-- '|' to its opening one, which becomes the absolute value; what is left on the stack at the end
-- (an unclosed '(' or '|' too) goes to the output. Evaluated: an absolute value needs one value,
-- anything else two (a left-over '(' just drops the top value). The result is the one value left.
local function evaluate_tokens(tokens, A)
    local stack, out = {}, {}
    for _, t in ipairs(tokens) do
        local k = t[1]
        if k == NUM then
            out[#out + 1] = t
        elseif PREC[k] then
            while #stack > 0 and (PREC[stack[#stack][1]] or 0) >= PREC[k] do
                out[#out + 1] = stack[#stack]
                stack[#stack] = nil
            end
            stack[#stack + 1] = t
        elseif k == LP or k == ABS_OPEN then
            stack[#stack + 1] = t
        elseif k == RP then
            while #stack > 0 do
                local top = stack[#stack]
                stack[#stack] = nil
                if top[1] == LP then
                    break
                end
                out[#out + 1] = top
            end
        elseif k == ABS_CLOSE then
            while #stack > 0 do
                local top = stack[#stack]
                stack[#stack] = nil
                if top[1] == ABS_OPEN then
                    out[#out + 1] = top
                    break
                end
                out[#out + 1] = top
            end
        end
    end
    for j = #stack, 1, -1 do
        out[#out + 1] = stack[j]
    end
    local values = {}
    for _, t in ipairs(out) do
        local k = t[1]
        local n = #values
        if k == NUM then
            values[n + 1] = t[2]
        elseif k == ABS_OPEN then
            if n < 1 then
                return false
            end
            values[n] = A.abs(values[n])
        else
            if n < 2 then
                return false
            end
            if PREC[k] then
                values[n - 1] = A[OPERATOR_NAME[k]](values[n - 1], values[n])
            end
            values[n] = nil
        end
    end
    if #values ~= 1 then
        return false
    end
    return true, values[1]
end

-- pdxmath.solve(s, profile) -> ok, raw [, crash]: NMathParser::SolveExpression<CFixedPoint> on the
-- expression the reader made (variables substituted, blanks and invalid characters gone): whether
-- it gave a value, and the value (the CFixedPoint's integer, in decimal). crash: the game's process
-- would die there (a division fault in '%' or '/'): why.
function pdxmath.solve(s, profile)
    local A = arithmetic_of(profile)
    local ok, done, value = pcall(function()
        return evaluate_tokens(tokenize(s, profile, A), A)
    end)
    if not ok then
        if type(done) == "table" and done[CRASH] then
            return false, nil, done[CRASH]
        end
        error(done, 0)
    end
    if not done then
        return false
    end
    return true, A.show(value)
end

-- pdxmath.literal(text, profile) -> raw: the value SMathToken<CFixedPoint>(char const*) makes of a
-- number's text (in decimal)
function pdxmath.literal(text, profile)
    local A = arithmetic_of(profile)
    return A.show(A.lit(text))
end

-- pdxmath.text(raw, profile) -> the text of the token of a value (CToken::CToken(CFixedPoint
-- const&)): "3", "3.5", "-0.00001" (3.x on: up to five decimals, trailing zeros dropped); "3.000",
-- "-0.001" (2.x: three decimals)
function pdxmath.text(raw, profile)
    local A = arithmetic_of(profile)
    return A.text(A.parse(raw))
end

-- the reader's layer ---------------------------------------------------------------------------------

-- the bytes IsValidCharacter accepts: digits, ( ) * + - . / | and, from 3.x, %
local function valid_set(profile)
    local v = {}
    for b = 48, 57 do v[b] = true end
    for _, b in ipairs({ 40, 41, 42, 43, 45, 46, 47, 124 }) do v[b] = true end
    if profile.percent then v[37] = true end
    return v
end
-- iswspace of a signed char: HT, LF, VT, FF, CR, space (a byte >= 0x80 is negative: never)
local SPACE = { [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [32] = true }

local function is_letter(c)
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end
local function is_name_char(c)
    return is_letter(c) or c == 95 or (c >= 48 and c <= 57)
end

-- a text as a C string: up to its first NUL byte
local function cstring(s)
    local z = s:find("\0", 1, true)
    return z and sub(s, 1, z - 1) or s
end

-- the id a value text has when lookup gives none (pdxlexer's rule for an unquoted word)
local function number_id(text)
    if text ~= "" and (text:find("^[%d%-]") or text:find("^[%d%.%-]*$")) then
        return pdxmath.NUMBER
    end
    return 15
end

-- pdxmath.substitute(expr, profile [, lookup [, where]]) -> s, diagnostics: the expression the
-- reader hands to SolveExpression. A name (a letter, then letters, digits, '_') is replaced by its
-- variable's value when that is a NUMBER, by "0" when it is something else ("Variable %s is not a
-- number."), and by nothing when there is no such variable ("unknown variable [%s]."). Valid
-- characters stay, blanks go, anything else goes with "Invalid character '%c' in advanced
-- statement at". where: the location the game appends (CReader::GetFileLocationDescription, e.g.
-- " file: common/x.txt line: 3"); "" by default.
function pdxmath.substitute(expr, profile, lookup, where)
    where = where or ""
    local valid = profile.valid_set
    if not valid then
        valid = valid_set(profile)
        profile.valid_set = valid
    end
    local out, diagnostics = {}, {}
    local n = #expr
    local i = 1
    while i <= n do
        local c = byte(expr, i)
        if is_letter(c) then
            local j = i
            while j < n and is_name_char(byte(expr, j + 1)) do
                j = j + 1
            end
            local name = sub(expr, i, j)
            local value, id
            if lookup then
                value, id = lookup(name)
            end
            if value ~= nil then
                value = tostring(value)
                id = id or number_id(value)
                if id == pdxmath.NUMBER then
                    -- the token's text as a C string
                    out[#out + 1] = cstring(value)
                else
                    diagnostics[#diagnostics + 1] = format("Variable %s is not a number. %s",
                        profile.not_number == "name" and name or cstring(value), where)
                    out[#out + 1] = "0"
                end
            else
                diagnostics[#diagnostics + 1] = format("unknown variable [%s]. %s", name, where)
            end
            i = j + 1
        else
            if valid[c] then
                out[#out + 1] = char(c)
            elseif not SPACE[c] then
                diagnostics[#diagnostics + 1] = "Invalid character '" .. char(c) ..
                    "' in advanced statement at " .. where
            end
            i = i + 1
        end
    end
    -- the expression is passed on as a C string
    return cstring(concat(out)), diagnostics
end

-- pdxmath.evaluate(expr, profile [, lookup [, where]]) -> text, raw, diagnostics, id [, crash]:
-- the token the reader makes of `@[ expr ]`. A value: its text, the CFixedPoint's integer (in
-- decimal), id 13. An expression SolveExpression rejects: "0", nil, id 12, with "Failed to parse
-- advanced statement at". An empty expr (the token "@[]"): nil: the reader keeps the token as it
-- is. crash: the game's process would die (an integer division fault): text and id are nil.
-- diagnostics: the messages the game logs, in order.
function pdxmath.evaluate(expr, profile, lookup, where)
    if not profile then
        error("pdxmath.evaluate: no profile (pdxmath.profile gives none for versions without inline math)", 2)
    end
    if expr == "" then
        return nil, nil, {}, nil
    end
    local s, diagnostics = pdxmath.substitute(expr, profile, lookup, where)
    local ok, raw, crashed = pdxmath.solve(s, profile)
    if crashed then
        return nil, nil, diagnostics, nil, crashed
    end
    if not ok then
        diagnostics[#diagnostics + 1] = "Failed to parse advanced statement at " .. (where or "")
        return "0", nil, diagnostics, pdxmath.NUMBER
    end
    return pdxmath.text(raw, profile), raw, diagnostics, pdxmath.RESULT
end

-- exposed for the tests
pdxmath.int64 = { I = I, add = add, sub = subtract, mul = mul, idivmod = idivmod, neg = neg,
    decimal = decimal, from_decimal = from_decimal, udivmod = udivmod }
pdxmath.strtod = strtod

return pdxmath
