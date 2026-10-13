-- oracle/gamemath.lua : the game's own inline math (`@[ ... ]`) on any expression, in the emulator:
-- NMathParser::SolveExpression<CFixedPoint>(CString const&, CFixedPoint&) (the tokenizer, the
-- shunting-yard and the arithmetic) and CToken::CToken(CFixedPoint const&) (the text of the result),
-- called directly, for every build whose symbols name them (2.3.0 on; 1.x has no inline math).
--
--   local gm = require("oracle.gamemath").new(gl)       -- gl: an oracle.gamelexer
--   local r = gm:solve("(1+2)*3")
--   r = { ok = true, raw = "900000", text = "9", id = 13 }   -- raw: the CFixedPoint, in decimal
--   r = { ok = false }                                      -- SolveExpression returned false
--   r = { crash = "interrupt 0 ..." }                       -- the game's code faulted (an idiv)
--   gm:literal("1.23456")  -> "123456"   (SMathToken<CFixedPoint>(char const*): one number)
--   gm:valid_characters()  -> the bytes NMathParser::IsValidCharacter accepts, as a string
--   gm.width, gm.scale     -> the CFixedPoint: 4 bytes and 1000 (2.x), 8 bytes and 100000 (3.x on)
--
-- The reader's layer around it (variables substituted, invalid characters dropped and logged,
-- "Failed to parse advanced statement") is CReader::ParseAdvancedStatementWithVariables, which
-- runs when the statement reader (oracle/gamereader.lua) reads `a = @[ ... ]`.

local ffi = require("ffi")

local gamemath = {}

local NAMES = {
    solve = { "_ZN11NMathParser15SolveExpressionI11CFixedPointEEbRK7CStringRT_" },
    literal = { "_ZN11NMathParser10SMathTokenI11CFixedPointEC2EPKc",
        "_ZN11NMathParser10SMathTokenI11CFixedPointEC1EPKc" },
    valid = { "_ZN11NMathParser16IsValidCharacterEc" },
    token_fixed = { "_ZN6CTokenC2ERK11CFixedPoint", "_ZN6CTokenC1ERK11CFixedPoint" },
    token_dtor = { "_ZN6CTokenD2Ev", "_ZN6CTokenD1Ev" },
    cstring_ctor = { "_ZN7CStringC2EPKc", "_ZN7CStringC1EPKc" },
    cstring_dtor = { "_ZN7CStringD2Ev", "_ZN7CStringD1Ev" },
}

local Math = {}
Math.__index = Math

-- a signed integer of `width` bytes at address, as a decimal string (exact for 64 bits)
local function signed_text(m, address, width)
    if width == 4 then
        return tostring(m:i32(address))
    end
    local s = m:read(address, 8)
    local v = ffi.new("int64_t[1]")
    ffi.copy(v, s, 8)
    return (tostring(v[0]):gsub("LL$", ""))
end
gamemath.signed_text = signed_text

-- gamemath.new(gl) -> gm
function gamemath.new(gl)
    local m = gl.m
    local f = {}
    for key, names in pairs(NAMES) do
        for _, n in ipairs(names) do
            local a = m:has(n)
            if a then
                f[key] = a
                break
            end
        end
    end
    for _, need in ipairs({ "solve", "token_fixed", "cstring_ctor" }) do
        if not f[need] then
            error("gamemath: " .. need .. " not found in " .. tostring(m.image.path))
        end
    end
    local gm = setmetatable({ gl = gl, m = m, f = f }, Math)
    gm.string = m:alloc(0x100)   -- the CString (its storage is the game's)
    gm.out = m:alloc(16)         -- the CFixedPoint
    gm.token = m:alloc(0x400)    -- the result's CToken
    gm:probe()
    return gm
end

-- the CFixedPoint's width and scale: SolveExpression("1") into a block of 0xff bytes
function Math:probe()
    local m = self.m
    m:write(self.out, string.rep("\255", 16), 16)
    m:call(self.f.cstring_ctor, self.string, m:string("1"))
    local ok = m:call(self.f.solve, self.string, self.out) % 256 ~= 0
    assert(ok, "gamemath: SolveExpression(\"1\") failed")
    if m:u32(self.out + 4) == 0xffffffff then
        self.width = 4
    else
        self.width = 8
    end
    self.scale = tonumber(signed_text(m, self.out, self.width))
end

-- gm:solve(expr) -> { ok, raw, text, id } or { ok = false } or { crash = message }
function Math:solve(expr)
    local m = self.m
    local text = m:string(expr)
    m:write(self.out, string.rep("\0", 16), 16)
    local ok, r = pcall(function()
        m:call(self.f.cstring_ctor, self.string, text)
        return m:call(self.f.solve, self.string, self.out) % 256 ~= 0
    end)
    m:free(text)
    if not ok then
        return { crash = tostring(r) }
    end
    if self.f.cstring_dtor then
        pcall(m.call, m, self.f.cstring_dtor, self.string)
    end
    if not r then
        return { ok = false }
    end
    local result = { ok = true, raw = signed_text(m, self.out, self.width) }
    m:call(self.f.token_fixed, self.token, self.out)
    result.id = m:i32(self.token + self.gl.token_layout.id)
    result.text = self.gl:token_text(self.token, true)
    if self.f.token_dtor then
        pcall(m.call, m, self.f.token_dtor, self.token)
    end
    return result
end

-- gm:literal(text) -> the raw value SMathToken<CFixedPoint>(char const*) makes of text
function Math:literal(text)
    local m = self.m
    if not self.f.literal then
        return nil
    end
    local s = m:string(text)
    local t = m:alloc(32)
    m:call(self.f.literal, t, s)
    -- the value follows the token type: at +4 (2.x, 32 bits) or +8 (64 bits)
    local v = signed_text(m, t + (self.width == 4 and 4 or 8), self.width)
    m:free(s)
    m:free(t)
    return v
end

-- gm:valid_characters() -> the bytes (0..255, as a char) IsValidCharacter accepts, in order
function Math:valid_characters()
    local out = {}
    if not self.f.valid then
        return nil
    end
    for b = 0, 255 do
        -- a char argument is passed sign-extended, as the game's callers do (movsx)
        local c = b >= 128 and b - 256 or b
        if self.m:call(self.f.valid, c) % 256 ~= 0 then
            out[#out + 1] = string.char(b)
        end
    end
    return table.concat(out)
end

return gamemath
