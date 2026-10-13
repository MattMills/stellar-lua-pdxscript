-- oracle/gamelexer.lua : the game's own text lexer (CTextLexer::GetTok), run in the emulator on
-- any text, for any build whose symbols name it.
--
--   local gamelexer = require("oracle.gamelexer")
--   local gl = gamelexer.new(m)                  -- m: an oracle.machine
--   local calls = gl:tokenize("a = { b }")
--   calls[i] = { rc = 1, id = 15, text = "a", quoted = false, line = 1, pos = 2, last = 32, unget = false }
--
-- Nothing about the layout of the game's objects is written here: the lexer and its file are
-- made by the game's own constructors, and where a token keeps its id, text, size and quoted flag,
-- and where the file keeps its last byte and put-back flag, are found by running the game's own
-- small functions on probes (see probe_token and probe_file) and looking where the values went.

local gamelexer = {}

local NAMES = {
    gettok = { "_ZN10CTextLexer6GetTokEv" },
    lexer_ctor = { "_ZN10CTextLexerC2EP5CFileb", "_ZN10CTextLexerC1EP5CFileb" },
    file_ctor = { "_ZN11CMemoryFileC2EPhi9EFileType9EFileModeb",
        "_ZN11CMemoryFileC1EPhi9EFileType9EFileModeb" },
    tok = { "_ZN6CLexer3TokEv" },
    line = { "_ZNK6CLexer10LineNumberEv" },
    pos = { "_ZNK11CMemoryFile11GetPositionEv" },
    unget = { "_ZN5CFile5UnGetEc" },
    token_ctor = { "_ZN6CTokenC2EiPKc", "_ZN6CTokenC1EiPKc" },
    token_ctor_cstring = { "_ZN6CTokenC2EiRK7CString", "_ZN6CTokenC1EiRK7CString" },
    cstring_ctor = { "_ZN7CStringC2EPKc", "_ZN7CStringC1EPKc" },
    init_tokens = { "_ZN12CStaticLexer10InitTokensEv", "_ZN6CLexer10InitTokensEv" },
    static_lexer = { "_ZN12CStaticLexer17AccessStaticLexerEv", "_ZN12CStaticLexer14GetStaticLexerEv" },
    read_until = { "_ZN10CTextLexer18ReadUntilCharacterEc", "_ZN6CLexer18ReadUntilCharacterEc" },
}

-- The game's own functions that belong to its environment, not to reading script: replaced
-- before anything runs (machine.lua: m:replace). 1.x profiles InitTokens, and the profiler asks
-- tbb's thread-local storage which thread it is on.
local function nothing() end
gamelexer.ENVIRONMENT = {
    ThreadIsMainThread = function() return 1 end,
    _ZN13CProfileScopeC1EPKc = nothing,
    _ZN13CProfileScopeC2EPKc = nothing,
    _ZN13CProfileScopeD1Ev = nothing,
    _ZN13CProfileScopeD2Ev = nothing,
}

-- gamelexer.locate(m) -> { name = address }, missing: the functions above that the image has
function gamelexer.locate(m)
    local found, missing = {}, {}
    for key, names in pairs(NAMES) do
        for _, n in ipairs(names) do
            local a = m:has(n)
            if a then
                found[key] = a
                break
            end
        end
        if not found[key] then
            missing[#missing + 1] = key
        end
    end
    table.sort(missing)
    return found, missing
end

local Lexer = {}
Lexer.__index = Lexer

local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function word_at(s, o, bits)
    if bits == 64 then
        return u32(s, o) + u32(s, o + 4) * 2 ^ 32
    end
    return u32(s, o)
end

-- gamelexer.new(m [, options]) -> gl. options: init_tokens (default true: the static lexer's
-- token table is built first, as the game does at startup, so that keywords get their ids),
-- file_type (EFileType given to CMemoryFile, default 1), lexer_flag (the bool of
-- CTextLexer(CFile*, bool), default false)
function gamelexer.new(m, options)
    options = options or {}
    local f, missing = gamelexer.locate(m)
    if not f.token_ctor and f.token_ctor_cstring and f.cstring_ctor then
        f.token_ctor = false  -- CToken(int, CString const&) instead (1.x)
    end
    for _, need in ipairs({ "gettok", "lexer_ctor", "file_ctor" }) do
        if not f[need] then
            error("gamelexer: " .. need .. " not found in " .. tostring(m.image.path) ..
                " (missing: " .. table.concat(missing, ", ") .. ")")
        end
    end
    local gl = setmetatable({ m = m, f = f, missing = missing, file_type = options.file_type or 1,
        lexer_flag = options.lexer_flag or false, object_size = 0x400 }, Lexer)
    if f.token_ctor == nil then
        error("gamelexer: no CToken constructor to probe the token with in " .. tostring(m.image.path))
    end
    for name, fn in pairs(gamelexer.ENVIRONMENT) do
        m:replace_symbol(name, fn)
    end
    -- the game's log, captured (GetTok warns about escapes it does not know)
    require("oracle.gamelog").install(m)
    -- the lexer's static initializers (1.x keeps its token table in globals they construct)
    gl.static_init = m:static_init("_GLOBAL__sub_I_[Ll]exer")
    if options.init_tokens ~= false and f.init_tokens then
        -- InitTokens is a method of the static lexer (a function-local static) where there is one
        m:call(f.init_tokens, f.static_lexer and m:call(f.static_lexer) or 0)
        gl.tokens_initialized = true
    end
    gl:probe_token()
    gl:probe_file()
    gl:probe_quoted()
    return gl
end

-- where CToken keeps its id, its text and the text's size: tokens made by the game's CToken
-- constructor with known ids and texts, short and long, then looked at. The text is either behind
-- a pointer (4.x: a CPdxHybridArray's data pointer, inline or not), behind a pointer to a pointer
-- (a string object), or in the token itself while it is short and behind a pointer when it is not
-- (1.x: a 256-byte buffer and an overflow block).
local PROBES = {
    { id = 0x5a5a1234, text = "oracleprobe" },
    { id = 0x0a1b2c3d, text = "ab" },
    { id = 0x01020304, text = string.rep("Q", 300) .. "probe" },
    { id = 0x7e6d5c4b, text = string.rep("R", 280) .. "xy" },
}

function Lexer:probe_token()
    local m = self.m
    local bits = m.bits
    local w = bits / 8
    local span = 0x200
    local tokens = {}
    for i, p in ipairs(PROBES) do
        local t = m:alloc(self.object_size)
        if self.f.token_ctor then
            m:call(self.f.token_ctor, t, p.id, m:string(p.text))
        else
            local cs = m:alloc(0x100)
            m:call(self.f.cstring_ctor, cs, m:string(p.text))
            m:call(self.f.token_ctor_cstring, t, p.id, cs)
        end
        tokens[i] = { address = t, bytes = m:read(t, span), text = p.text, id = p.id }
    end
    local function reads(p, text)
        if p == 0 then return false end
        local ok, s = pcall(m.cstring, m, p, #text + 1)
        return ok and s == text
    end
    -- the offsets (from `from` to `to`) where test holds for every probe in `which`
    local function common(which, step, test)
        for o = 0, span - 8, step do
            local all = true
            for _, i in ipairs(which) do
                if not test(tokens[i], o) then
                    all = false
                    break
                end
            end
            if all then
                return o
            end
        end
    end
    local layout = {}
    layout.id = common({ 1, 2, 3, 4 }, 4, function(t, o) return u32(t.bytes, o) == t.id end)
    layout.size = common({ 1, 2, 3, 4 }, 4, function(t, o) return u32(t.bytes, o) == #t.text + 1 end)
    local function ptr1(t, o) return reads(word_at(t.bytes, o, bits), t.text) end
    local ptr = common({ 1, 2, 3, 4 }, w, ptr1)
    if ptr then
        layout.text_ptr = ptr
    else
        -- a pointer to a string object: try each word of the object behind each pointer
        for o = 0, span - w, w do
            local o2 = nil
            for k = 0, 0x40 - w, w do
                local all = true
                for i = 1, 4 do
                    local t = tokens[i]
                    local p = word_at(t.bytes, o, bits)
                    local ok, q = pcall(m.ptr, m, p + k)
                    if p == 0 or not ok or not reads(q, t.text) then
                        all = false
                        break
                    end
                end
                if all then
                    o2 = k
                    break
                end
            end
            if o2 then
                layout.text_ptr, layout.text_ptr2 = o, o2
                break
            end
        end
    end
    if not layout.text_ptr then
        -- short texts in the token, long ones behind a pointer
        local inline = common({ 1, 2 }, 1, function(t, o)
            return t.bytes:sub(o + 1, o + #t.text + 1) == t.text .. "\0"
        end)
        local long = common({ 3, 4 }, w, ptr1)
        if inline and long then
            layout.text_inline, layout.text_ptr = inline, long
            -- the overflow block is a vector (1.x: std::vector<char>): its end pointer says
            -- whether it is in use, since a short text leaves it empty but allocated
            layout.text_end = common({ 3, 4 }, w, function(t, o)
                local d = word_at(t.bytes, o, bits) - word_at(t.bytes, long, bits)
                return o ~= long and d > #t.text and d <= #t.text + 2
            end)
        elseif inline then
            layout.text_inline = inline
        end
    end
    if not layout.id or not (layout.text_ptr or layout.text_inline) then
        error(string.format("gamelexer: the token layout was not found (id %s, text %s/%s)",
            tostring(layout.id), tostring(layout.text_ptr), tostring(layout.text_inline)))
    end
    self.token_layout = layout
    for _, t in ipairs(tokens) do
        m:free(t.address)
    end
end

-- the text of the token at address
function Lexer:token_text(token)
    local m, L = self.m, self.token_layout
    local p = 0
    if L.text_ptr then
        p = m:ptr(token + L.text_ptr)
        if L.text_ptr2 and p ~= 0 then
            p = m:ptr(p + L.text_ptr2)
        end
        if L.text_end and m:ptr(token + L.text_end) == p then
            p = 0  -- an empty overflow vector: the text is in the token
        end
    end
    if p == 0 and L.text_inline then
        p = token + L.text_inline
    end
    local size = L.size and m:u32(token + L.size)
    if size and size > 0 and size < 2 ^ 24 then
        return m:read(p, size - 1), size
    end
    return m:cstring(p)
end

-- where CFile keeps its line, last byte and put-back flag: CFile::UnGet on a block of line feeds
-- sets the flag (a byte 0x0a -> 0x01) and lowers the line (0x0a0a0a0a -> 0x0a0a0a09); then, on a
-- block of zeros, the byte that UnGet reads as the last byte is the one that makes it lower the line
function Lexer:probe_file()
    local m = self.m
    if not self.f.unget then
        return
    end
    local size = 0x60
    local a = m:alloc(size)
    m:write(a, string.rep("\10", size))
    m:call(self.f.unget, a, 120)
    local after = m:read(a, size)
    local layout = {}
    for o = 0, size - 1 do
        if after:byte(o + 1) == 1 then
            layout.unget = o
        end
    end
    for o = 0, size - 4, 4 do
        if u32(after, o) == 0x0a0a0a09 then
            layout.line = o
        end
    end
    if layout.line and layout.unget then
        for o = 0, size - 1 do
            if o ~= layout.unget and (o < layout.line or o >= layout.line + 4) then
                m:write(a, string.rep("\0", size))
                m:set_u32(a + layout.line, 100)
                m:set_u8(a + o, 10)
                m:call(self.f.unget, a, 120)
                if m:u32(a + layout.line) == 99 then
                    layout.last = o
                    break
                end
            end
        end
    end
    self.file_layout = layout
    m:free(a)
end

-- the quoted flag: the byte of the token that GetTok sets for "x" and not for y
function Lexer:probe_quoted()
    local q = self:snapshot('"x"')
    local w = self:snapshot("y")
    local L = self.token_layout
    local cands = {}
    for o = 0, #q - 1 do
        local skip = (o >= L.id and o < L.id + 4) or (L.size and o >= L.size and o < L.size + 4) or
            (L.text_ptr and o >= L.text_ptr and o < L.text_ptr + self.m.bits / 8) or
            (L.text_inline and o >= L.text_inline and o < L.text_inline + 2)
        if not skip and q:byte(o + 1) == 1 and w:byte(o + 1) == 0 then
            cands[#cands + 1] = o
        end
    end
    self.token_layout.quoted = cands[1]
    self.token_layout.quoted_candidates = cands
end

-- a new CMemoryFile over a copy of text, and a CTextLexer reading it
function Lexer:open(text)
    local m = self.m
    local buf = m:alloc(#text + 1)
    if #text > 0 then
        m:write(buf, text, #text)
    end
    local file = m:alloc(self.object_size)
    m:call(self.f.file_ctor, file, buf, #text, self.file_type, 0, 0)
    local lexer = m:alloc(self.object_size)
    m:call(self.f.lexer_ctor, lexer, file, self.lexer_flag)
    local token = self.f.tok and m:call(self.f.tok, lexer) or nil
    return { buf = buf, file = file, lexer = lexer, token = token }
end

function Lexer:snapshot(text)
    local s = self:open(text)
    self.m:call(self.f.gettok, s.lexer)
    local token = s.token or s.lexer + 0x18
    return self.m:read(token, 0x120)
end

-- the token GetTok left in the lexer, and the file's state
function Lexer:read_state(s, call)
    local m, L, F = self.m, self.token_layout, self.file_layout or {}
    local token = s.token
    call.id = m:i32(token + L.id)
    call.text, call.size = self:token_text(token)
    if L.quoted then
        call.quoted = m:u8(token + L.quoted) ~= 0
    end
    if self.f.line then
        call.line = m:call(self.f.line, s.lexer)
    elseif F.line then
        call.line = m:u32(s.file + F.line)
    end
    if self.f.pos then
        call.pos = m:call(self.f.pos, s.file) % 2 ^ 32
    end
    if F.last then
        call.last = m:u8(s.file + F.last)
    end
    if F.unget then
        call.unget = m:u8(s.file + F.unget) ~= 0
    end
    return call
end

-- gl:tokenize(text [, max]) -> calls: every GetTok call until one returns 0 (that one included),
-- each { rc, id, text, size, quoted, line, pos, last, unget }; calls.error when the game's code
-- failed (the message) after the calls it made
function Lexer:tokenize(text, max)
    local m = self.m
    local s = self:open(text)
    if not s.token then
        s.token = s.lexer + 0x18
    end
    local calls = {}
    max = max or (#text * 2 + 16)
    for _ = 1, max do
        local logged = #m.log
        local ok, rc = pcall(m.call, m, self.f.gettok, s.lexer)
        if not ok then
            calls.error = rc
            break
        end
        local call = self:read_state(s, { rc = rc })
        if #m.log > logged then
            call.log = {}
            for i = logged + 1, #m.log do
                call.log[#call.log + 1] = m.log[i].text
            end
        end
        calls[#calls + 1] = call
        if rc == 0 then
            break
        end
    end
    return calls
end

-- gl:describe() -> a line: what was located and the layout found
function Lexer:describe()
    local L, F = self.token_layout, self.file_layout or {}
    local function hex(v) return v and string.format("0x%x", v) or "-" end
    local text = (L.text_inline and ("inline " .. hex(L.text_inline) .. (L.text_ptr and " or " or "")) or "") ..
        (L.text_ptr and ("*" .. hex(L.text_ptr) .. (L.text_ptr2 and ("->" .. hex(L.text_ptr2)) or "")) or "")
    return string.format("token: id %s, text %s, size %s, quoted %s; file: line %s, last %s, unget %s; missing: %s",
        hex(L.id), text, hex(L.size), hex(L.quoted),
        hex(F.line), hex(F.last), hex(F.unget), table.concat(self.missing, ","))
end

return gamelexer
