-- oracle/gamereader.lua : the game's own statement reader (CReader with CPersistent) on any text,
-- for any build whose symbols name it: what the game reads as statements, keys, operators and
-- values, how it reads scripted variables (@x = 5, @x, @[ math ]) and what it reports.
--
--   local gr = require("oracle.gamereader").new(gl)   -- gl: an oracle.gamelexer
--   local tree = gr:read("a = { b >= 1 } @x = 2 c = @x")
--   tree = { { key = tok, op = tok, value = tok | { block } , line = n }, ..., variables = {...},
--            log = { "..." } }       tok = { id = n, text = "...", quoted = true | nil }
--   gamereader.show(tree)            -- "a={b>=1} c=2"
--
-- How: every game object reads its block with CPersistent::Read, a loop of
-- CReader::ReadSimpleStatement (the key, the operator if there is one, and the value token,
-- with @variables registered and @[ math ] evaluated on the way) and the object's virtual
-- ReadMember, which reads the member's value. Here the object is a CPersistent whose vtable is
-- the game's own with ReadMember replaced by Lua: it records the statement the reader holds, and
-- when the value is `{` it reads the block as every member that is an object does, with
-- CReader::Read(CPersistent&) on another such object (a nested emulation). Where the reader keeps
-- the key, operator and value tokens is found by probing (probe_reader).
--
-- What a real member does with a value is its own business (a list member reads `{ a b c }` with
-- other readers); this reads every block as statements, which is what the statement grammar is.

local gamereader = {}

local NAMES = {
    reader_ctor = { "_ZN7CReaderC2EP6CLexerb", "_ZN7CReaderC1EP6CLexerb" },
    read_simple = { "_ZN7CReader19ReadSimpleStatementEv" },
    persistent_read = { "_ZN11CPersistent4ReadER7CReader" },
    read_member = { "_ZN11CPersistent10ReadMemberER7CReaderi" },
    vtable = { "_ZTV11CPersistent" },
    -- (its list is a CArray in 2.x, a CPdxArray from 3.x: a pattern)
    register_variable = { "^_ZN7CReader22RegisterVariableInListER" },
    register_variable_global = { "_ZN7CReader16RegisterVariableEv" },
    inline_script = { "_Z24CreateInlineScriptReaderR7CReader" },
}

local SENTINEL = -0x4f52  -- an id no token has: "this field was not set by the statement"

local Reader = {}
Reader.__index = Reader

-- the functions of NAMES in the image: a name is a mangled name, or a Lua pattern (starting with
-- ^) for the first symbol that matches
local function locate(m)
    local f = {}
    for key, names in pairs(NAMES) do
        for _, n in ipairs(names) do
            local a
            if n:sub(1, 1) == "^" then
                local found = m.image:find(n)
                a = found[1] and m.base + found[1].value
            else
                a = m:has(n)
            end
            if a then
                f[key] = a
                break
            end
        end
    end
    return f
end

-- gamereader.new(gl) -> gr
function gamereader.new(gl)
    local m = gl.m
    local f = locate(m)
    for _, need in ipairs({ "reader_ctor", "read_simple", "persistent_read", "read_member", "vtable" }) do
        if not f[need] then
            error("gamereader: " .. need .. " not found in " .. tostring(m.image.path))
        end
    end
    local gr = setmetatable({ gl = gl, m = m, f = f, blocks = {}, word = m.word }, Reader)
    gr:make_vtable()
    gr:probe_reader()
    if f.inline_script then
        -- an inline script would be read from the game's files: recorded, and read as nothing
        -- (it returns a unique_ptr<CReader> through a hidden pointer, set to null)
        m:replace(f.inline_script, function(mm)
            local out = mm:arg(1)
            mm:set_ptr(out, 0)
            gr.inline_scripts = (gr.inline_scripts or 0) + 1
            mm:callee_pops(4)
            return out
        end, "<CreateInlineScriptReader>")
    end
    return gr
end

-- the vtable of our objects: CPersistent's, with ReadMember (found by its address) replaced
function Reader:make_vtable()
    local m, w = self.m, self.word
    local table_start = self.f.vtable + 2 * w  -- after the offset to top and the type info
    local slots, member_slot = 24, nil
    local vt = m:alloc(slots * w + 16)
    for i = 0, slots - 1 do
        local fn = m:ptr(table_start + i * w)
        m:set_ptr(vt + i * w, fn)
        if fn == self.f.read_member and not member_slot then
            member_slot = i
        end
    end
    if not member_slot then
        error("gamereader: ReadMember is not in CPersistent's vtable")
    end
    local stub_name = "<oracle ReadMember>"
    rawset(m.hle, stub_name, function(mm)
        return self:read_member(mm)
    end)
    m:set_ptr(vt + member_slot * w, m:stub(stub_name))
    self.vtable, self.member_slot = vt, member_slot
end

-- a new object of ours, reading into a new block
function Reader:object(block)
    local o = self.m:alloc(64)
    self.m:set_ptr(o, self.vtable)
    self.blocks[o] = block
    return o
end

-- the token at address (a CToken embedded in the reader), with the lexer's layout
function Reader:token(address)
    local m, gl = self.m, self.gl
    local id = m:i32(address + gl.token_layout.id)
    if id == SENTINEL then
        return nil
    end
    -- the reader's tokens are copies (CToken::operator=, the result of @[ math ]) whose size field
    -- is not always kept: their text is read as the C string the reader uses
    local ok, text = pcall(gl.token_text, gl, address, true)
    local t = { id = id, text = ok and text or "<?>" }
    local q = gl.token_layout.quoted
    if q and m:u8(address + q) ~= 0 then
        t.quoted = true
    end
    return t
end

-- a reader of text: a CMemoryFile, a CTextLexer and a CReader made by the game
function Reader:open(text)
    local s = self.gl:open(text)
    local m = self.m
    s.reader = m:alloc(0x2000)
    m:call(self.f.reader_ctor, s.reader, s.lexer, false)
    if not s.token then
        s.token = s.lexer + 0x18
    end
    self.token_offset = s.token - s.lexer
    -- the reader's CLexer*: the word of the reader that is the lexer it was given
    if not self.reader_lexer then
        for o = 0, 0x100 - self.word, self.word do
            if m:ptr(s.reader + o) == s.lexer then
                self.reader_lexer = o
                break
            end
        end
    end
    return s
end

-- where the reader keeps the statement's key, operator and value: ReadSimpleStatement on
-- "zzkey = zzval", then the tokens embedded in the reader are looked for
function Reader:probe_reader()
    local m = self.m
    local s = self:open("zzkey = zzval")
    m:call(self.f.read_simple, s.reader)
    local found = {}
    for o = 0, 0x1000 - 4, 4 do
        local ok, text = pcall(self.gl.token_text, self.gl, s.reader + o)
        if ok and (text == "zzkey" or text == "=" or text == "zzval") and not found[text] then
            local id = m:i32(s.reader + o + self.gl.token_layout.id)
            if (text == "=" and id == 1) or (text ~= "=" and id ~= 0) then
                found[text] = o
            end
        end
    end
    if not (found.zzkey and found["="] and found.zzval) then
        error(string.format("gamereader: the reader's tokens were not found (key %s, op %s, value %s)",
            tostring(found.zzkey), tostring(found["="]), tostring(found.zzval)))
    end
    self.layout = { key = found.zzkey, op = found["="], value = found.zzval }
    -- before each statement, the operator and value are marked unset: a statement without an
    -- operator leaves them so
    m:on_enter(self.f.read_simple, function(mm)
        local reader = mm.bits == 64 and tonumber(mm.engine:reg("rdi")) or mm:u32(mm:sp() + 4)
        mm:set_u32(reader + self.layout.op + self.gl.token_layout.id, SENTINEL % 2 ^ 32)
        mm:set_u32(reader + self.layout.value + self.gl.token_layout.id, SENTINEL % 2 ^ 32)
        self.statement_line = nil
    end)
    -- the scripted variables registered: RegisterVariableInList (2.x on, a statement's local list)
    -- or RegisterVariable (every version); one calls the other in some versions, so a variable is
    -- recorded once per place in the text
    local function registered(mm)
        -- the lexer's token is the variable's name (`@x`); its value comes after
        local reader = mm.bits == 64 and tonumber(mm.engine:reg("rdi")) or mm:u32(mm:sp() + 4)
        self.variables = self.variables or {}
        local name = self:current(reader)
        local lexer = mm:ptr(reader + self.reader_lexer)
        local at = (name and name.text or "?") .. "@" .. tostring(mm:ptr(lexer + self.word))
        if at ~= self.last_variable_at then
            self.variables[#self.variables + 1] = name and name.text or "?"
            self.last_variable_at = at
        end
    end
    for _, key in ipairs({ "register_variable", "register_variable_global" }) do
        if self.f[key] then
            m:on_enter(self.f[key], registered)
        end
    end
end

-- the lexer's current token, for a reader
function Reader:current(reader)
    local lexer = self.m:ptr(reader + self.reader_lexer)
    return self:token(lexer + self.token_offset)
end

-- ReadMember(CReader&, int) of our objects: the statement the reader holds
function Reader:read_member(m)
    local this, reader, id = m:arg(1), m:arg(2), m:arg(3)
    local block = self.blocks[this]
    if not block then
        return 0
    end
    local L = self.layout
    local entry = { key = self:token(reader + L.key), op = self:token(reader + L.op),
        value = self:token(reader + L.value), id = id % 2 ^ 32 }
    if self.gl.f.line then
        entry.line = m:call(self.gl.f.line, m:ptr(reader + self.reader_lexer))
    end
    block[#block + 1] = entry
    local open = entry.value and entry.value.id == 3 and not entry.value.quoted
    if not entry.op then
        -- no operator: the token after the key was read (it is the lexer's current token)
        entry.next = self:current(reader)
        open = entry.next and entry.next.id == 3 and not entry.next.quoted
    end
    if open then
        local child = { line = entry.line }
        entry.block = child
        m:call(self.f.persistent_read, self:object(child), reader)
    end
    return 0
end

-- gr:read(text) -> tree: the statements the game reads from text (see the top of the file);
-- tree.error when the game's code failed
function Reader:read(text)
    local m = self.m
    local s = self:open(text)
    self.variables = {}
    self.last_variable_at = nil
    self.inline_scripts = 0
    local tree = {}
    local logged = #(m.log or {})
    local ok, err = pcall(m.call, m, self.f.persistent_read, self:object(tree), s.reader)
    if not ok then
        tree.error = err
    end
    tree.variables = self.variables
    tree.inline_scripts = self.inline_scripts
    tree.log = {}
    for i = logged + 1, #(m.log or {}) do
        tree.log[#tree.log + 1] = m.log[i].text
    end
    self.blocks = {}
    return tree
end

-- gamereader.show(tree) -> text: a compact picture of a tree: key op value, blocks in { },
-- a statement without an operator as key followed by what came after it in < >
function gamereader.show(tree)
    local parts = {}
    local function tok(t)
        if not t then return "?" end
        return t.quoted and ('"' .. t.text .. '"') or t.text
    end
    for _, e in ipairs(tree) do
        local s
        if e.op then
            s = tok(e.key) .. e.op.text .. (e.block and ("{" .. gamereader.show(e.block) .. "}") or tok(e.value))
        else
            s = tok(e.key) .. "<" .. tok(e.next) .. ">" .. (e.block and ("{" .. gamereader.show(e.block) .. "}") or "")
        end
        parts[#parts + 1] = s
    end
    return table.concat(parts, " ")
end

return gamereader
