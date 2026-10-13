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

-- Each function by its Itanium names (Linux), then its MSVC decorated names (Windows x86-64, i386);
-- a name starting with ^ is a Lua pattern that one symbol must match (the MSVC names of
-- RegisterVariableInList and CreateInlineScriptReader spell template arguments that change with
-- the version). The Windows builds have no vtable of CPersistent itself: one of a class derived
-- from it stands in (persistent_vtable).
local NAMES = {
    reader_ctor = { "_ZN7CReaderC2EP6CLexerb", "_ZN7CReaderC1EP6CLexerb", "??0CReader@@QEAA@PEAVCLexer@@_N@Z",
        "??0CReader@@QAE@PAVCLexer@@_N@Z" },
    read_simple = { "_ZN7CReader19ReadSimpleStatementEv", "?ReadSimpleStatement@CReader@@QEAAXXZ",
        "?ReadSimpleStatement@CReader@@QAEXXZ" },
    persistent_read = { "_ZN11CPersistent4ReadER7CReader", "?Read@CPersistent@@UEAAXAEAVCReader@@@Z",
        "?Read@CPersistent@@UAEXAAVCReader@@@Z" },
    read_member = { "_ZN11CPersistent10ReadMemberER7CReaderi", "?ReadMember@CPersistent@@UEAAXAEAVCReader@@H@Z",
        "?ReadMember@CPersistent@@UAEXAAVCReader@@H@Z" },
    vtable = { "_ZTV11CPersistent" },
    -- (its list is a CArray in 2.x, a CPdxArray from 3.x: a pattern)
    register_variable = { "^_ZN7CReader22RegisterVariableInListER", "^%?RegisterVariableInList@CReader@@" },
    register_variable_global = { "_ZN7CReader16RegisterVariableEv", "^%?RegisterVariable@CReader@@" },
    inline_script = { "_Z24CreateInlineScriptReaderR7CReader", "^%?CreateInlineScriptReader@@YA" },
}
gamereader.NAMES = NAMES

local SENTINEL = -0x4f52  -- an id no token has: "this field was not set by the statement"

local Reader = {}
Reader.__index = Reader

-- the functions of NAMES in the image: a name is a mangled name, or a Lua pattern (starting with
-- ^) that exactly one symbol must match
local function locate(m)
    local f = {}
    for key, names in pairs(NAMES) do
        for _, n in ipairs(names) do
            local a
            if n:sub(1, 1) == "^" then
                local found = m.image:find(n)
                a = #found == 1 and m.base + found[1].value or nil
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
    if not f.vtable then
        f.vtable_slots = gamereader.persistent_vtable(m, f)
    end
    for _, need in ipairs({ "reader_ctor", "read_simple", "persistent_read", "read_member" }) do
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
    -- (Itanium: after the offset to top and the type info; MSVC: the vtable symbol is its first slot)
    local table_start = self.f.vtable and self.f.vtable + 2 * w or self.f.vtable_slots
    if not table_start then
        error("gamereader: no vtable of CPersistent in " .. tostring(m.image.path))
    end
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
    m:set_ptr(vt + member_slot * w, m:stub(stub_name, self.f.read_member))
    self.vtable, self.member_slot = vt, member_slot
end

-- gamereader.persistent_vtable(m, f) -> the address of the first slot of a vtable whose slots are
-- CPersistent's own functions, as many as can be found (Windows, where CPersistent has none; the
-- builds have no RTTI, so vtables follow each other with nothing between them): the words of the
-- read-only data that hold CPersistent::ReadMember are slots of the vtables of the classes that do
-- not override it. Each such vtable starts at the nearest vtable symbol (??_7) before it and ends
-- at the next one, or, without vtable symbols (a build with labels only), ReadMember is taken to be
-- its slot 4 of 7 (destructor, Write, WriteMembers, Read, ReadMember, InitPostRead(CString const&,
-- int, int), InitPostRead(): CPersistent's order in every Windows build with a PDB). The vtable
-- with the most slots that are CPersistent's own functions is taken.
function gamereader.persistent_vtable(m, f)
    local image = m.image
    if image.format ~= "pe" or not f.read_member then
        return nil
    end
    local w = m.word
    local text = image.sections[".text"]
    local function code(v)
        return v >= m.base + text.addr and v < m.base + text.addr + text.size
    end
    local function word(s, o)
        local v = 0
        for k = w, 1, -1 do
            v = v * 256 + s:byte(o + k)
        end
        return v
    end
    local function pack(v)
        local t = {}
        for k = 1, w do
            t[k] = string.char(v % 256)
            v = math.floor(v / 256)
        end
        return table.concat(t)
    end
    local function persistent(v)
        local name = image:name_at(v - m.base)
        return name and not name:find("+0x", 1, true) and
            (name:find("@CPersistent@@", 1, true) or name:find("^CPersistent::")) and true or false
    end
    -- the vtable symbols, by address
    local starts = {}
    for _, s in ipairs(image:find("^%?%?_7")) do
        starts[#starts + 1] = s.value
    end
    table.sort(starts)
    local function vtable_of(rva)
        local lo, hi = 1, #starts
        if hi == 0 or rva < starts[1] then return nil end
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if starts[mid] <= rva then lo = mid else hi = mid - 1 end
        end
        return starts[lo], starts[lo + 1]
    end
    local best, best_score
    for _, sec in ipairs(image.section_list) do
        if sec.name == ".rdata" then
            local data = image.data:sub(sec.offset + 1, sec.offset + sec.rawsize)
            local needle = pack(f.read_member)
            local at = 1
            while true do
                local i = data:find(needle, at, true)
                if not i then break end
                at = i + 1
                local o = i - 1
                if o % w == 0 then
                    local first, stop
                    if #starts > 0 then
                        local s0, s1 = vtable_of(sec.addr + o)
                        if s0 then
                            first = s0 - sec.addr
                            stop = s1 and math.min(s1 - sec.addr, first + 64 * w) or first + 64 * w
                        end
                    else
                        first, stop = o - 4 * w, o + 3 * w
                    end
                    if first and first >= 0 then
                        local score = 0
                        local k = first
                        while k < stop and k + w <= #data and code(word(data, k)) do
                            if persistent(word(data, k)) then score = score + 1 end
                            k = k + w
                        end
                        if not best_score or score > best_score then
                            best, best_score = m.base + sec.addr + first, score
                        end
                    end
                end
            end
        end
    end
    return best
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
        local reader = mm:arg(1)
        mm:set_u32(reader + self.layout.op + self.gl.token_layout.id, SENTINEL % 2 ^ 32)
        mm:set_u32(reader + self.layout.value + self.gl.token_layout.id, SENTINEL % 2 ^ 32)
        self.statement_line = nil
    end)
    -- the scripted variables registered: RegisterVariableInList (2.x on, a statement's local list)
    -- or RegisterVariable (every version); one calls the other in some versions, so a variable is
    -- recorded once per place in the text
    local function registered(mm)
        -- the lexer's token is the variable's name (`@x`); its value comes after
        local reader = mm:arg(1)
        self.variables = self.variables or {}
        local name = self:current(reader)
        -- the place: the file's read position (CMemoryFile::GetPosition, nested), else the lexer
        local lexer = mm:ptr(reader + self.reader_lexer)
        local file = mm:ptr(lexer + self.word)
        local place = self.gl.f.pos and mm:call(self.gl.f.pos, file) or lexer
        local at = (name and name.text or "?") .. "@" .. tostring(place)
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
    entry.line = self.gl:line(m:ptr(reader + self.reader_lexer))
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
