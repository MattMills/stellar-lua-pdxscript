-- oracle/gameabi.lua : the keys every class of a build reads from script, found by running the
-- build's own code: each class's ReadMember(CReader&, int token, ...) is called with every token
-- of the static lexer's table (oracle/gamekeywords.lua), on an object of the class made by its own
-- constructor, after the game's CReader has read `<token> = <value>` (oracle/gamereader.lua).
--
--   local abi = require("oracle.gameabi").new(gr, symbols)   -- gr: an oracle.gamereader
--   local r = abi:trace("CTechnology")
--   r = { class, read_member, parent, tokens, paths, keys = { { id, name, reader, calls, rc,
--         failed } ... }, seconds }
--
-- What a call did is its path: the basic blocks of ReadMember it ran, the functions of the game it
-- entered first (the first is the reader of the key's value: CReader::Read(bool&),
-- NParserUtil::ReadTrigger<CRootTrigger>, a database's ReadKeyReference, ...), its result, and
-- whether it failed. Tokens with one path are one group. The largest is the token the class does
-- not read: ReadMember hands it to the class it derives from (its first call, the class's
-- `parent`), whose own keys the class reads too. The others are the class's keys. A switch over the
-- token ids is compiled as comparisons, so tokens the class does not read can leave it at
-- different places: a group whose first call is the default's and whose result is the default's
-- is not a key either.
--
-- symbols: the build's functions and vtables by demangled name (gameabi.symbols(path): `nm -C`).

local gamekeywords = require("oracle.gamekeywords")

local gameabi = {}
local Abi = {}
Abi.__index = Abi

-- gameabi.symbols(executable) -> { names = { [address] = name }, starts = sorted addresses,
--   read_members = { [class] = { address, name } }, vtables = { [class] = address },
--   ctors = { [class] = address } }: from `nm -C --defined-only`
function gameabi.symbols(path)
    local p = assert(io.popen("nm -C --defined-only '" .. path .. "' 2>/dev/null"))
    local names, starts, read_members, vtables, ctors = {}, {}, {}, {}, {}
    local read_persistent, cstring_ctor
    local keyed_ctors, instance_globals, typeinfos = {}, {}, {}
    for line in p:lines() do
        local a, t, name = line:match("^(%x+) (%a) (.*)$")
        if a then
            local addr = tonumber(a, 16)
            if t == "T" or t == "t" or t == "W" or t == "w" then
                if not names[addr] then
                    names[addr] = name
                    starts[#starts + 1] = addr
                end
                if not name:find("thunk to", 1, true) then
                    local class = name:match("^(.-)::ReadMember%(CReader&, int[,%)]")
                    if class and not read_members[class] then
                        read_members[class] = { address = addr, name = name }
                    end
                    -- constructors: the default one, or a database object's (index, key)
                    local c, args = name:match("^(.-)::[^:]+(%b())$")
                    if c and name == c .. "::" .. c:match("([^:]+)$") .. args then
                        if args == "()" and not ctors[c] then
                            ctors[c] = addr
                        elseif args == "(int, CString const&)" and not keyed_ctors[c] then
                            keyed_ctors[c] = addr
                        end
                    end
                end
            else
                local c = name:match("^vtable for (.*)$")
                if c then vtables[c] = addr end
                local ti = name:match("^typeinfo for (.*)$")
                if ti then typeinfos[ti] = addr end
                -- a database's instance pointer (TGameDatabase<CFoo>::_pInstance, CFoo::_pFoo)
                if (t == "B" or t == "b" or t == "D" or t == "d") and name:find("::_p", 1, true) then
                    instance_globals[#instance_globals + 1] = { name = name, address = addr }
                end
            end
            if name == "CReader::Read(CPersistent&)" then read_persistent = addr end
            if name == "CString::CString(char const*)" and not cstring_ctor then cstring_ctor = addr end
        end
    end
    p:close()
    table.sort(starts)
    -- a vtable's class by the address an object holds (its first virtual function's slot: two
    -- words in, after the offset to top and the type info)
    local vtable_class = {}
    for c, a in pairs(vtables) do vtable_class[a] = c end
    return { names = names, starts = starts, read_members = read_members, vtables = vtables, ctors = ctors,
        keyed_ctors = keyed_ctors, vtable_class = vtable_class, read_persistent = read_persistent,
        cstring_ctor = cstring_ctor, instance_globals = instance_globals, typeinfos = typeinfos }
end

-- the end of the function at address: the next symbol's address
local function function_end(starts, address)
    local lo, hi = 1, #starts
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if starts[mid] <= address then lo = mid + 1 else hi = mid end
    end
    return starts[lo] > address and starts[lo] or address + 0x10000
end

-- gameabi.new(gr, symbols [, options]) -> abi. options: value (the text after `=`, default "1"),
-- object_size (default 0x8000)
function gameabi.new(gr, symbols, options)
    options = options or {}
    local abi = setmetatable({ gr = gr, m = gr.m, gl = gr.gl, sym = symbols,
        value = options.value or "1", object_size = options.object_size or 0x8000 }, Abi)
    abi.tokens = gamekeywords.read(gr.gl)
    -- the first functions entered during a call, and the blocks of the function traced
    local m = abi.m
    abi.hook = m.engine:hook("block", function(address)
        local a = tonumber(address)
        local c = abi.current
        if not c then return end
        if a >= c.F and a < c.F_end then
            c.blocks[a - c.F] = true
        else
            if #c.entered < 4 then
                local n = symbols.names[a - m.base]
                if n then c.entered[#c.entered + 1] = n end
            end
            -- a member that is an object: the class of the object CReader::Read(CPersistent&) gets
            -- (an error raised in a hook cannot be caught: the read of a bad pointer is protected)
            if not c.nested and symbols.read_persistent and a == m.base + symbols.read_persistent then
                local ok, vt = pcall(function()
                    local obj = m:arg(2)
                    return obj ~= 0 and m:ptr(obj) or nil
                end)
                c.nested = ok and vt and symbols.vtable_class[vt - m.base - 2 * m.word] or "?"
            end
        end
    end, 1, 0)
    -- the databases a call reads the instance of: a key into a database (ReadKeyReference, often
    -- inlined), a trigger or effect block. One read hook per instance pointer.
    for _, g in ipairs(symbols.instance_globals) do
        local a = m.base + g.address
        local db = g.name:match("<([^<>]+)>::_p") or g.name:match("^(.-)::_p")
        m.engine:hook("read", function()
            local c = abi.current
            if c and db then c.dbs[db] = true end
        end, a, a + m.word - 1)
    end
    return abi
end

-- abi:static_init() -> ran, failed: every static initializer of the image, in the image's order
-- (leniently: one that fails is skipped). The triggers' and effects' tables are filled there
-- (_GLOBAL__sub_I_trigger_impl.cpp, effect_impl*.cpp: RegisterTriggerEntry, RegisterEffectEntry),
-- and the global CStrings that default constructors pass on are made there.
function Abi:static_init()
    local results = self.m:static_init(nil, true)
    local ran, failed = 0, {}
    for _, r in ipairs(results) do
        if r.ok then ran = ran + 1 else failed[#failed + 1] = r.name end
    end
    return ran, failed
end

-- abi:create_databases() -> created, failed (names): every database of the game's table
-- (oracle/gameinit.lua) made empty by its own CreateInstance, and the trigger and effect databases
-- (made outside the table): a member that is a key into a database (ReadKeyReference), a trigger or
-- an effect block then reads into an empty database instead of a null one. Nothing is loaded.
function Abi:create_databases()
    local m = self.m
    local gameinit = require("oracle.gameinit")
    local tbl = gameinit.databases(m)
    local created, failed = {}, {}
    -- an instance a static initializer already made (the trigger and effect databases, made while
    -- their entries are registered) is kept: CreateInstance would replace it with an empty one
    local function exists(name)
        local class = name:match("^(.-)::CreateInstance") or name
        for _, g in ipairs(self.sym.instance_globals) do
            if g.name:find("<" .. class .. ">::_p", 1, true) or g.name:find(class .. "::_p", 1, true) == 1 then
                if m:ptr(m.base + g.address) ~= 0 then return true end
            end
        end
        return false
    end
    local function create(name, address)
        if exists(name) then
            created[#created + 1] = name .. " (made by static initialization)"
            return
        end
        local ok, err = pcall(m.call, m, m.base + address)
        if ok then
            created[#created + 1] = name
        else
            failed[#failed + 1] = name .. ": " .. tostring(err):gsub("[\r\n\t]", " "):sub(1, 120)
        end
    end
    for _, r in ipairs(tbl and tbl.records or {}) do
        if r.create and r.create ~= 0 then create(r.name, r.create) end
    end
    for _, extra in ipairs({ "CTriggerDatabase::CreateInstance()", "CEffectDatabase::CreateInstance()" }) do
        for a, n in pairs(self.sym.names) do
            if n == extra then create(extra, a) break end
        end
    end
    self.databases = created
    return created, failed
end

-- abi:factories() -> { trigger = { [token id] = class }, effect = { ... }, names = { [id] = text } }:
-- every entry the trigger and effect databases registered (static initialization, and the script
-- lists' registry helpers that make their tokens at run time), and the class of the object each
-- makes (CTriggerDatabase::CreateTrigger(int), CEffectDatabase::CreateEffect(int)). The entries
-- are a std::map<int, entry> in the database (4.5.2 [V]: the trigger database's header at +0x78,
-- the effect database's at +0x20), found in each build (gameabi.entry_map): a header of
-- libstdc++'s _Rb_tree (color, parent, left, right, then the count; a word each) whose root's
-- parent is the header and whose leftmost and rightmost nodes' keys (+4 words) are token ids. The
-- token's text is CStaticLexer::GetString(id)'s (its text pointer at +0x10, +8 on 32-bit).
function gameabi.entry_map(m, db, tokens)
    local w = m.word
    local best, most
    for o = 0, 0x400 - 5 * w, w do
        local ok, n = pcall(function()
            local h = db + o
            local root = m:ptr(h + w)
            if root == 0 or m:ptr(root + w) ~= h then return nil end
            local left, right = m:ptr(h + 2 * w), m:ptr(h + 3 * w)
            local count = m:ptr(h + 4 * w)
            local lo, hi = m:i32(left + 4 * w), m:i32(right + 4 * w)
            -- (ids past the static lexer's: tokens the registry helpers made at run time)
            if count < 2 or count > 100000 or lo < 0 or hi >= tokens * 8 or lo > hi then return nil end
            return count
        end)
        if ok and n and (not most or n > most) then best, most = db + o, n end
    end
    return best
end
function Abi:factories()
    local m, sym = self.m, self.sym
    local function find(name)
        for a, n in pairs(sym.names) do
            if n == name then return a end
        end
    end
    local function global(name)
        local p = assert(io.popen("nm -C '" .. m.image.path .. "' 2>/dev/null | grep -F ' " .. name .. "'"))
        local line = p:read("*l")
        p:close()
        return line and tonumber(line:match("^(%x+)"), 16)
    end
    local get_string = find("CStaticLexer::GetString(int)")
    local out = { names = {} }
    for kind, spec in pairs({
        trigger = { "CTriggerDatabase::CreateTrigger(int) const", "CTriggerDatabase::_pTriggerDatabase" },
        effect = { "CEffectDatabase::CreateEffect(int) const", "CEffectDatabase::_pEffectDatabase" },
    }) do
        local fn, g = find(spec[1]), global(spec[2])
        local db = g and m:ptr(m.base + g)
        local map = {}
        out[kind] = map
        local header = fn and db and db ~= 0 and gameabi.entry_map(m, db, #self.tokens)
        if header then
            -- the registered ids: the map's nodes, in order
            -- and each one's entry (the value, +5 words: CTriggerEntry<C...>, whose class names the
            -- trigger's when the trigger cannot be made here)
            local ids, entry_class = {}, {}
            local w = m.word
            local stack, node = {}, m:ptr(header + w)
            while node ~= 0 or #stack > 0 do
                while node ~= 0 do
                    stack[#stack + 1] = node
                    node = m:ptr(node + 2 * w)
                end
                node = table.remove(stack)
                local id = m:i32(node + 4 * w)
                ids[#ids + 1] = id
                local ok, vt = pcall(function() return m:ptr(m:ptr(node + 5 * w)) end)
                local c = ok and sym.vtable_class[vt - m.base - 2 * w]
                entry_class[id] = c and c:match("^C%a+Entry<(.*)>$")
                node = m:ptr(node + 3 * w)
            end
            for _, id in ipairs(ids) do
                if get_string and not out.names[id] then
                    local ok, t = pcall(m.call, m, m.base + get_string, id)
                    if ok and t ~= 0 then
                        local ok2, text = pcall(m.cstring, m, m:ptr(t + 2 * m.word))
                        out.names[id] = ok2 and text or nil
                    end
                end
                local ok, obj = pcall(m.call, m, m.base + fn, db, id)
                if ok and obj ~= 0 then
                    local vt = m:ptr(obj)
                    map[id] = sym.vtable_class[vt - m.base - 2 * m.word] or string.format("? vtable %x", vt - m.base)
                else
                    map[id] = entry_class[id]
                        or "? " .. (ok and "nothing made" or tostring(obj):gsub("[\r\n\t]", " "):sub(1, 80))
                end
            end
        else
            out[kind .. "_error"] = string.format("function %s, instance %s, entry map %s",
                tostring(fn), tostring(db), tostring(header))
        end
    end
    return out
end

-- abi:bases(class) -> the classes it derives from, nearest first, from the image's RTTI (Itanium
-- ABI: a __si_class_type_info has its base's type_info at +2 words; a __vmi_class_type_info has
-- flags and a base count (32 bits each) at +2 words, then {base, offset_flags} pairs: the first
-- base is followed). The kind of a type_info is told by its contents (its vtable is libstdc++'s,
-- outside the image): a known type_info at +2 words is one base.
function Abi:bases(class)
    local m, sym = self.m, self.sym
    if not self.ti_class then
        self.ti_class = {}
        for c, a in pairs(sym.typeinfos) do self.ti_class[a] = c end
    end
    local out, c, seen = {}, class, {}
    while c and not seen[c] do
        seen[c] = true
        local ti = sym.typeinfos[c]
        if not ti then break end
        local a = m.base + ti
        local base = self.ti_class[m:ptr(a + 2 * m.word) - m.base]
        if not base then
            local count = m:u32(a + 2 * m.word + 4)
            if count >= 1 and count <= 16 then
                base = self.ti_class[m:ptr(a + 3 * m.word) - m.base]
            end
        end
        if base then out[#out + 1] = base end
        c = base
    end
    return out
end

-- abi:classes() -> sorted class names that have a ReadMember
function Abi:classes()
    local list = {}
    for c in pairs(self.sym.read_members) do list[#list + 1] = c end
    table.sort(list)
    return list
end

-- a CString holding text, made by the game's own CString(char const*)
function Abi:cstring(text)
    local m = self.m
    local s = m:alloc(0x80)
    m:write(s, string.rep("\0", 0x80), 0x80)
    m:call(m.base + assert(self.sym.cstring_ctor, "no CString::CString(char const*)"), s, m:string(text))
    return s
end

-- an object of the class: its constructor run on a zeroed block (a database object's
-- (index 0, key "abi_probe") first: a default one often calls it with a global empty CString whose
-- static initializer has not run; else the default one), else the block with the class's vtable
function Abi:object(class)
    local m, size = self.m, self.object_size
    local obj = m:alloc(size)
    m:write(obj, string.rep("\0", size), size)
    local ok = false
    local keyed = self.sym.keyed_ctors[class]
    if keyed then
        self.key_string = self.key_string or self:cstring("abi_probe")
        ok = pcall(m.call, m, m.base + keyed, obj, 0, self.key_string)
    end
    local ctor = self.sym.ctors[class]
    if not ok and ctor then
        m:write(obj, string.rep("\0", size), size)
        ok = pcall(m.call, m, m.base + ctor, obj)
    end
    local vt = self.sym.vtables[class]
    if not ok and vt then
        m:set_ptr(obj, m.base + vt + 2 * m.word)
    end
    return obj, ok
end

local function short(name)
    return (name or ""):gsub("^void ", "")
end

-- abi:trace(class) -> result (see the top of the file)
function Abi:trace(class)
    local m, gr = self.m, self.gr
    local rm = self.sym.read_members[class]
    if not rm then error("no ReadMember for " .. class) end
    local F = m.base + rm.address
    local F_end = m.base + function_end(self.sym.starts, rm.address)
    local groups, order = {}, {}
    local t0 = os.clock()
    local constructed
    for _, tok in ipairs(self.tokens) do
        if tok.name then
            local s = gr:open(tok.name .. " = " .. self.value)
            pcall(m.call, m, gr.f.read_simple, s.reader)
            local obj, ok_ctor = self:object(class)
            if constructed == nil then constructed = ok_ctor end
            local logged = #(m.log or {})
            local c = { F = F, F_end = F_end, blocks = {}, entered = {}, dbs = {} }
            self.current = c
            local ok, rc = pcall(m.call, m, F, obj, s.reader, tok.id, 0, 0)
            self.current = nil
            local list = {}
            for k in pairs(c.blocks) do list[#list + 1] = k end
            table.sort(list)
            local result = ok and (rc % 256) or "failed"
            local key = table.concat(list, ",") .. "|" .. tostring(result) .. "|" .. tostring(c.entered[1])
            local g = groups[key]
            if not g then
                local log = m.log and m.log[logged + 1]
                local dbs = {}
                for d in pairs(c.dbs) do dbs[#dbs + 1] = d end
                table.sort(dbs)
                g = { tokens = {}, entered = c.entered, rc = result, nested = c.nested, dbs = dbs,
                    failed = (not ok) and tostring(rc):gsub("[\r\n\t]", " "):sub(1, 160) or nil,
                    log = log and (log.text or ""):gsub("[\r\n\t]", " "):sub(1, 160) or nil }
                groups[key] = g
                order[#order + 1] = g
            end
            g.tokens[#g.tokens + 1] = tok
            -- the blocks made for this token back to the machine's free lists (the game's own
            -- allocations inside them are not followed)
            m:free(obj)
            m:free(s.reader)
            m:free(s.lexer)
            m:free(s.file)
            m:free(s.buf)
        end
    end
    table.sort(order, function(a, b) return #a.tokens > #b.tokens end)
    local default = order[1]
    local parent_call = default and default.entered[1]
    local parent = parent_call and parent_call:match("^(.-)::ReadMember%(") or nil
    local r = { class = class, read_member = rm.address, parent = parent, tokens = #self.tokens,
        paths = #order, keys = {}, constructed = constructed, seconds = os.clock() - t0 }
    for _, g in ipairs(order) do
        local is_default = g.rc == default.rc and g.entered[1] == parent_call
        if not is_default then
            for _, tok in ipairs(g.tokens) do
                local calls = {}
                for i = 1, #g.entered do calls[i] = short(g.entered[i]) end
                r.keys[#r.keys + 1] = { id = tok.id, name = tok.name, reader = calls[1] or "-", nested = g.nested,
                    databases = g.dbs,
                    calls = calls, rc = g.rc, failed = g.failed, log = g.log, path_size = #g.tokens }
            end
        end
    end
    table.sort(r.keys, function(a, b) return a.name < b.name end)
    return r
end

return gameabi
