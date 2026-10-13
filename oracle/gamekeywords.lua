-- oracle/gamekeywords.lua : the keywords compiled into a build: the static lexer's token table
-- (GetTokenArray, GetNoOfTokenTypes, GetTokenType(i)), the words every trigger, effect, modifier
-- and member of the game's script are read as. Each entry is a CToken (its id and its text), read
-- with the layout gamelexer probed.
--
--   local keywords = require("oracle.gamekeywords").read(gl)   -- gl: an oracle.gamelexer
--   keywords[i] = { id = 431, name = "a" }   (in the table's order)

local gamekeywords = {}

-- gamekeywords.read(gl) -> list: the token table of gl's machine
function gamekeywords.read(gl)
    local m = gl.m
    local count_fn = m:has("_Z17GetNoOfTokenTypesv")
    local type_fn = m:has("_Z12GetTokenTypei")
    if not count_fn or not type_fn then
        error("gamekeywords: GetNoOfTokenTypes / GetTokenType not found in " .. tostring(m.image.path))
    end
    -- 1.x keeps the table in a global its translation unit's static initializer fills
    -- (2.x on, GetTokenArray fills it the first time)
    if not gl.tokens_static_init then
        m:static_init("_GLOBAL__sub_I_tokens%.cpp")
        gl.tokens_static_init = true
    end
    local count = m:call(count_fn) % 2 ^ 32
    local list = {}
    for i = 0, count - 1 do
        local entry = m:call(type_fn, i)
        local ok, name = pcall(gl.token_text, gl, entry, true)
        list[#list + 1] = { id = m:i32(entry + gl.token_layout.id), name = ok and name or nil }
    end
    return list
end

return gamekeywords
