-- oracle/gameinit.lua : what the game does when it starts, read from its own code. The steps of
-- CGameApplication::InitGame, the table of databases it builds (inline in InitGame up to 4.0,
-- in NNullObjAndDatabaseInitUtil::SetupDatabases from 4.1), what each database's CanInitialize
-- waits for, and the order the game's loop then initializes them in.
--
--   local gameinit = require("oracle.gameinit")
--   local r = gameinit.extract(m)          -- m: an oracle.machine
--   r.steps[i]     = { kind = "call", name = "_ZN9CModifier15InitDefinitionsEv", site = 0x... }
--   r.static[i]    = { kind = "call", name = ..., site = 0x..., reached = true }
--   r.program[i]   = { site, kind, names, reached, count }: both, one entry per call site
--   r.databases[i] = { name = "CNamedColorDatabase", create = 0x..., can_init = 0x... or 0, ... }
--   r.databases[i].deps[k] = { kind = "db" | "external" | "other", db = index, symbol = ... }
--   r.order[k]     = index into r.databases (the order the game's loop initializes them in)
--
-- Addresses in the results are the image's (before the load base); m.base + address is the
-- process's.
--
-- Nothing runs the way the game runs it. A function is run alone ("isolated"): its own code runs,
-- and every other function of the game it reaches returns at once, recorded, with a pointer to a
-- page of pointers to itself (the null object: a field of it is that pointer, a virtual function
-- of it is another call that returns at once). Imports run (oracle/hle.lua), the unknown ones
-- return 0. So InitGame's own code gives the order of its calls on one path: every test of what a
-- callee returned sees 0 in the low 32 bits and a valid pointer in the 64 (on i386: a non-zero
-- pointer). The calls not on that path come from the code's bytes (static_calls: every call rel32
-- and jmp rel32 that lands on a function's start), and the indirect ones only from the run.
--
-- The table of databases is found in the memory of the isolated run, not decoded from the code:
-- at each call the stack is searched for an array of records whose fields point to functions
-- named ...::CreateInstance(); the record size, the name field (a pointer to a C string) and the
-- role of each field (by the symbol names the field points to) follow from it. So the layouts of
-- 1.x (name, Create, CanInitialize, Init, PostRead: 20 bytes), 2.x (the same, 40 bytes) and 3.x to
-- 4.x (with Destroy: 48 bytes) need no description here.
--
-- The dependencies are read: each CanInitialize runs with a read hook on the executable's
-- writable segments, and each global it reads that is zero is set (to the null object, or 1) and
-- the function run again, until it reads nothing new. The globals are named by the symbol table,
-- and a global is a database's when its name has that database's class (TGameDatabase<CFoo>::
-- _pInstance, CFoo::_pFoo, a local static of CFoo::GetInstance()).

local ffi = require("ffi")

local gameinit = {}

gameinit.INIT_GAME = "_ZN16CGameApplication8InitGameEv"
gameinit.SETUP_DATABASES = "^_ZN27NNullObjAndDatabaseInitUtil14SetupDatabases"

-- the role of a database's function, by the method name that ends its mangled symbol (the longer
-- names first: PostReadInitInstance ends like InitInstance)
gameinit.ROLES = {
    { "create", "14CreateInstanceEv$" },
    { "destroy", "15DestroyInstanceEv$" },
    { "can_init", "13CanInitializeEv$" },
    { "post_read", "20PostReadInitInstanceEv$" },
    { "init", "12InitInstanceEv$" },
}
gameinit.FIELDS = { "create", "destroy", "can_init", "init", "post_read" }

local STT_FUNC = 2
local PF_W = 2

-- per image and per machine state, kept with them
local index_cache = setmetatable({}, { __mode = "k" })
local machine_state = setmetatable({}, { __mode = "k" })

local function i32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    local v = a + b * 256 + c * 65536 + d * 16777216
    return v >= 2 ^ 31 and v - 2 ^ 32 or v
end

-- the bytes of the image at a virtual address (from the file: code and initialized data)
local function vread(image, vaddr, n)
    for _, seg in ipairs(image.segments) do
        if vaddr >= seg.vaddr and vaddr + n <= seg.vaddr + seg.filesz then
            local o = seg.offset + vaddr - seg.vaddr
            return image.data:sub(o + 1, o + n)
        end
    end
end

-- the identifiers of a mangled name, in order: _ZN13TGameDatabaseI19CNamedColorDatabaseE9_pInstanceE
-- -> TGameDatabase, CNamedColorDatabase, _pInstance. Digits that are not lengths (template
-- literals) give identifiers that match nothing.
function gameinit.identifiers(mangled)
    local ids = {}
    local i, n = 1, #mangled
    while i <= n do
        local d = mangled:match("^%d+", i)
        if d and i > 1 then
            local len = tonumber(d)
            ids[#ids + 1] = mangled:sub(i + #d, i + #d + len - 1)
            i = i + #d + len
        else
            i = i + 1
        end
    end
    return ids
end

-- the class a CreateInstance belongs to: the identifier before the method's (CFoo::CreateInstance
-- and TGameDatabase<CFoo>::CreateInstance are both CFoo's)
local function owner_class(mangled)
    local ids = gameinit.identifiers(mangled)
    return ids[#ids - 1]
end

-- gameinit.index(image) -> ix: the functions by address (ix.funcs, ix.size), the role of each
-- database function (ix.roles), the import each PLT entry jumps to (ix.plt), the PLT sections
-- (ix.plt_ranges), the classes that have a CreateInstance (ix.classes)
function gameinit.index(image)
    local ix = index_cache[image]
    if ix then
        return ix
    end
    ix = { funcs = {}, size = {}, roles = {}, plt = {}, plt_ranges = {}, classes = {} }
    for name, s in pairs(image.symbols) do
        if s.type == STT_FUNC and s.value ~= 0 then
            -- several names at one address (C1/C2 constructors): the shortest, then the first
            local old = ix.funcs[s.value]
            if not old or #name < #old or (#name == #old and name < old) then
                ix.funcs[s.value] = name
                ix.size[s.value] = s.size
            end
            for _, r in ipairs(gameinit.ROLES) do
                if name:find(r[2]) then
                    ix.roles[s.value] = r[1]
                    if r[1] == "create" then
                        local c = owner_class(name)
                        if c then ix.classes[c] = s.value end
                    end
                    break
                end
            end
        end
    end
    -- the PLT: each entry jumps through a GOT slot (ff 25: rip-relative on x86-64, absolute on
    -- i386; ff a3: i386 position independent, relative to .got.plt in ebx), and the slot's
    -- relocation names the import
    local slot_name = {}
    for _, r in ipairs(image.relocs) do
        if r.name and r.name ~= "" then
            slot_name[r.offset] = r.name
        end
    end
    local gotplt = image.sections[".got.plt"]
    for _, sname in ipairs({ ".plt", ".plt.sec", ".plt.got" }) do
        local s = image.sections[sname]
        if s and s.size > 0 then
            ix.plt_ranges[#ix.plt_ranges + 1] = { s.addr, s.addr + s.size }
            local bytes = image.data:sub(s.offset + 1, s.offset + s.size)
            local step = sname == ".plt.got" and 8 or 16
            for e = 0, s.size - step, step do
                for k = 0, step - 6 do
                    local b1, b2 = bytes:byte(e + k + 1, e + k + 2)
                    if b1 == 0xff and (b2 == 0x25 or b2 == 0xa3) then
                        local d = i32(bytes, e + k + 2)
                        local slot
                        if image.bits == 64 then
                            slot = s.addr + e + k + 6 + d
                        elseif b2 == 0x25 then
                            slot = d % 2 ^ 32
                        elseif gotplt then
                            slot = gotplt.addr + d
                        end
                        if slot and slot_name[slot] then
                            ix.plt[s.addr + e] = slot_name[slot]
                        end
                        break
                    end
                end
            end
        end
    end
    index_cache[image] = ix
    return ix
end

local function in_plt(ix, v)
    for _, r in ipairs(ix.plt_ranges) do
        if v >= r[1] and v < r[2] then return true end
    end
    return false
end

-- gameinit.function_range(image, name_or_pattern) -> vaddr, size, mangled name (nil if absent)
function gameinit.function_range(image, name)
    local s = image.symbols[name]
    if not s and name:find("^%^") then
        s = image:find(name)[1]
    end
    if s then
        return s.value, s.size, s.name
    end
end

-- static calls ------------------------------------------------------------------------------------

-- gameinit.static_calls(image, name) -> { { site, target, kind = "call" | "jmp", name, import }, ... }
-- in address order: every call rel32 (e8) and jmp rel32 (e9) in the function's bytes whose target
-- is the start of another function or a PLT entry. A byte scan, not a disassembly: an e8 inside
-- another instruction is taken only when the 4 bytes after it land exactly on a function's start,
-- and indirect calls (through a register, a vtable, a table on the stack) are not seen.
function gameinit.static_calls(image, name)
    local start, size = gameinit.function_range(image, name)
    if not start then
        return nil
    end
    local ix = gameinit.index(image)
    local bytes = vread(image, start, size)
    local out = {}
    local i = 0
    local wrap = 2 ^ image.bits
    while i <= size - 5 do
        local op = bytes:byte(i + 1)
        local taken = false
        if op == 0xe8 or op == 0xe9 then
            local target = (start + i + 5 + i32(bytes, i + 1)) % wrap
            local import = ix.plt[target]
            local callee = ix.funcs[target]
            if (callee or import) and not (target >= start and target < start + size) then
                out[#out + 1] = { site = start + i, target = target, kind = op == 0xe8 and "call" or "jmp",
                    name = import or callee, import = import ~= nil }
                taken = true
            end
        end
        i = i + (taken and 5 or 1)
    end
    return out
end

-- the machine's environment for isolated runs ------------------------------------------------------

-- gameinit.null_object(m) -> P: a page (64 KB) at P whose every word is P. A function that returns
-- at once returns P: as a pointer it is an object, its fields are P, its vtable is P and the
-- vtable's entries are P (a call there returns at once too); as a 32-bit integer or bool on
-- x86-64 it is 0 (P = 2^32).
function gameinit.null_object(m)
    local st = machine_state[m]
    if not st then
        st = {}
        machine_state[m] = st
    end
    if st.null_object then
        return st.null_object
    end
    local P = m.bits == 64 and 0x100000000 or 0x100000
    local size = 0x10000
    m.engine:map(P, size)
    local w = m.word
    local fill = ffi.new(w == 8 and "uint64_t[?]" or "uint32_t[?]", size / w)
    for i = 0, size / w - 1 do
        fill[i] = P
    end
    m.engine:write(P, fill, size)
    st.null_object = P
    st.fill = fill
    return P
end

-- gameinit.zero_page(m): the first 64 KB of the address space mapped and filled like the null
-- object, so that a field read through a null pointer (a global that the game's start would have
-- set) reads the null object instead of faulting
function gameinit.zero_page(m)
    gameinit.null_object(m)
    local st = machine_state[m]
    if not st.zero_page then
        m.engine:map(0, 0x10000)
        m.engine:write(0, st.fill, 0x10000)
        st.zero_page = true
    end
end

-- the stack below where m:call starts, cleared, so that nothing an earlier run left there is
-- found by a later one
local function clear_stack(m)
    local top = m.layout.stack_top - 0x10000
    local n = 0x100000
    m:write(top - n, ffi.new("uint8_t[?]", n), n)
    return top
end

local function is_direct_call(m, ret, target)
    local ok, s = pcall(m.read, m, ret - 5, 5)
    if not ok or s:byte(1) ~= 0xe8 then
        return false
    end
    return (ret + i32(s, 1)) % 2 ^ m.bits == target
end

-- gameinit.isolate(m, address, args [, options]) -> run: calls the game's function at address
-- (process address) with args; its own code runs, every other function of the game it reaches
-- returns at once. run.calls[i] = { kind, name, target, site } in the order reached:
--   call    a direct call (site: the call instruction)
--   icall   an indirect call (site: the return address)
--   tail    a jump to another function's start (a tail call: it returns to the caller's caller)
--   jump    a jump into the middle of another function
--   import  a call of a PLT entry (it runs: oracle/hle.lua)
-- options: value (what the functions return, default the null object), budget (basic blocks,
-- default 4e6), on_call(call, run) -> nil, a number (the return value), or "stop" (ends the run).
-- run.error is the message when the run failed, run.stopped why it was ended.
function gameinit.isolate(m, address, args, options)
    options = options or {}
    local ix = gameinit.index(m.image)
    local base, word, e = m.base, m.word, m.engine
    local vstart = address - base
    local size = ix.size[vstart] or (m.image.symbols[ix.funcs[vstart] or ""] or {}).size
    assert(size and size > 0, string.format("gameinit.isolate: no function at 0x%x", address))
    local lo, hi = address, address + size
    local stub_lo, stub_hi = m.layout.stub, m.layout.stub + m.layout.stub_size
    local value = options.value or gameinit.null_object(m)
    local budget = options.budget or 4e6
    local sp_reg = m.bits == 64 and "rsp" or "esp"
    local pc_reg = m.bits == 64 and "rip" or "eip"
    local ret_reg = m.bits == 64 and "rax" or "eax"
    local run = { calls = {}, blocks = 0 }
    local blocks = 0
    local h = e:hook("block", function(a)
        blocks = blocks + 1
        if blocks > budget then
            m:stop("budget")
            return
        end
        if (a >= lo and a < hi) or (a >= stub_lo and a < stub_hi) then
            return
        end
        local v = a - base
        local sp = m:sp()
        local ret = m:ptr(sp)
        local import = ix.plt[v]
        if import then
            local site
            if ret >= lo and ret < hi then
                site = is_direct_call(m, ret, a) and ret - 5 - base or ret - base
            end
            run.calls[#run.calls + 1] = { kind = "import", name = import, target = v, site = site }
            return
        end
        if in_plt(ix, v) then
            return
        end
        -- another function of the game, or a virtual function of the null object
        local name = ix.funcs[v]
        local call = { target = v, name = name or m.image:name_at(v) or string.format("0x%x", v) }
        if a >= value and a < value + 0x10000 then
            call.target, call.name = nil, "(null object)"
        end
        if ret >= lo and ret < hi then
            if is_direct_call(m, ret, a) then
                call.kind, call.site = "call", ret - 5 - base
            else
                call.kind, call.site = "icall", ret - base
            end
        else
            call.kind = name and "tail" or "jump"
        end
        local r = options.on_call and options.on_call(call, run)
        if r == "stop" then
            m:stop("stopped")
            return
        end
        run.calls[#run.calls + 1] = call
        -- it returns at once
        e:set_reg(ret_reg, type(r) == "number" and r or value)
        e:set_reg(sp_reg, sp + word)
        e:set_reg(pc_reg, ret)
    end, 1, 0)
    local lenient = m.lenient
    m.lenient = true
    local ok, result = pcall(m.call, m, address, unpack(args or {}))
    m.lenient = lenient
    e:unhook(h)
    run.blocks = blocks
    if ok then
        run.result = result
        run.stopped = m.last_stop
    else
        run.error = tostring(result)
    end
    return run
end

-- the table of databases ---------------------------------------------------------------------------

local function printable(m, p)
    local ok, s = pcall(m.cstring, m, p, 160)
    if not ok or #s == 0 or #s >= 160 then
        return nil
    end
    if s:find("[^%w_%-%.:/ <>]") then
        return nil
    end
    return s
end

-- gameinit.find_table(m, from, to) -> table or nil: the longest array of database records in the
-- process memory [from, to): table.records[i] = { name, raw = { field values }, <role> = vaddr },
-- table.stride (bytes), table.fields (role of each field), table.at (address of the first record)
function gameinit.find_table(m, from, to)
    local ix = gameinit.index(m.image)
    local w = m.word
    from = from - from % w
    local n = math.floor((to - from) / w)
    if n <= 0 then
        return nil
    end
    local bytes = m:read(from, n * w)
    local p = ffi.cast(w == 8 and "const uint64_t *" or "const uint32_t *", bytes)
    local base = m.base
    local function word(i)
        if i < 0 or i >= n then return nil end
        return tonumber(p[i])
    end
    -- the words that point to a CreateInstance
    local hits = {}
    for i = 0, n - 1 do
        local v = tonumber(p[i]) - base
        if ix.roles[v] == "create" then
            hits[#hits + 1] = i
        end
    end
    if #hits < 2 then
        return nil
    end
    -- runs of hits at one stride (3 to 12 words)
    local best
    local i = 1
    while i < #hits do
        local stride = hits[i + 1] - hits[i]
        local j = i + 1
        if stride >= 3 and stride <= 12 then
            while j < #hits and hits[j + 1] - hits[j] == stride do
                j = j + 1
            end
            if not best or j - i + 1 > best.count then
                best = { first = i, last = j, stride = stride, count = j - i + 1 }
            end
        end
        i = j
    end
    if not best or best.count < 3 then
        return nil
    end
    local stride = best.stride
    -- the name field: the nearest word before (or after) Create that points to a C string in every
    -- record
    local name_off
    for _, o in ipairs({ -1, -2, -3, -4, -5, 1, 2, 3, 4, 5 }) do
        if o > -stride and o < stride then
            local all = true
            for k = best.first, best.last do
                local v = word(hits[k] + o)
                if not v or v == 0 or not printable(m, v) then
                    all = false
                    break
                end
            end
            if all then
                name_off = o
                break
            end
        end
    end
    if not name_off then
        return nil
    end
    -- the records, from the name field; a name seen twice ends the table (two copies side by side)
    local records, seen = {}, {}
    for k = best.first, best.last do
        local at = hits[k] + name_off
        local name = printable(m, word(at))
        if seen[name] then
            break
        end
        seen[name] = true
        local raw = {}
        for f = 0, stride - 1 do
            local v = word(at + f) or 0
            raw[f + 1] = v ~= 0 and v - base or 0
        end
        records[#records + 1] = { name = name, raw = raw, at = from + at * w }
    end
    -- the role of each field: what the symbols it points to are named, most often
    local fields = { "name" }
    local taken = {}
    for f = 2, stride do
        local count = {}
        for _, r in ipairs(records) do
            local role = ix.roles[r.raw[f]]
            if role then count[role] = (count[role] or 0) + 1 end
        end
        local role, most = nil, 0
        for k, c in pairs(count) do
            if c > most or (c == most and role and k < role) then role, most = k, c end
        end
        if role and not taken[role] then
            fields[f] = role
            taken[role] = true
        else
            fields[f] = "field" .. (f - 1)
        end
    end
    for _, r in ipairs(records) do
        for f = 2, stride do
            r[fields[f]] = r.raw[f]
        end
        for _, role in ipairs(gameinit.FIELDS) do
            r[role] = r[role] or 0
        end
    end
    return { records = records, stride = stride * w, fields = fields, at = records[1].at }
end

-- gameinit.databases(m) -> table, info: the table of databases, read from the stack while the
-- function that builds it runs isolated (SetupDatabases where there is one, else InitGame), at
-- the first call of another function after the table is complete. info = { fn, run }.
function gameinit.databases(m)
    local image = m.image
    local fn_start, _, fn_name = gameinit.function_range(image, gameinit.SETUP_DATABASES)
    local args
    if fn_start then
        -- (CPdxArray& table, CPdxArray& done, std::function const& progress): empty ones
        args = { m:alloc(0x100), m:alloc(0x100), m:alloc(0x100) }
    else
        fn_start, _, fn_name = gameinit.function_range(image, gameinit.INIT_GAME)
        if not fn_start then
            return nil, { error = "no SetupDatabases and no CGameApplication::InitGame" }
        end
        args = { m:alloc(0x10000) }
    end
    local top = clear_stack(m)
    local found
    local run = gameinit.isolate(m, m.base + fn_start, args, {
        on_call = function()
            local t = gameinit.find_table(m, m:sp(), top)
            if t then
                found = t
                return "stop"
            end
        end,
    })
    return found, { fn = fn_name, run = run }
end

-- dependencies -------------------------------------------------------------------------------------

-- names that are not a database's state: vtables, typeinfo, the GOT
local function ignored_object(name)
    return name:find("^_ZT[VIS]") or name:find("^_GLOBAL_OFFSET_TABLE_") or name:find("^_DYNAMIC")
end

-- gameinit.dependencies(m, records [, options]): sets records[i].deps (what the record's
-- CanInitialize reads) and records[i].can_init_result. options.iterations (default 40),
-- options.budget (basic blocks per call, default 2e5)
function gameinit.dependencies(m, records, options)
    options = options or {}
    local image, base, e = m.image, m.base, m.engine
    local P = gameinit.null_object(m)
    -- the classes of the table, and the classes that have a CreateInstance but are not in it
    local ix = gameinit.index(image)
    local by_class = {}
    for i, r in ipairs(records) do
        local create = ix.funcs[r.create]
        local c = create and owner_class(create)
        if c then by_class[c] = by_class[c] or i end
        by_class[r.name] = by_class[r.name] or i
        r.class = c or r.name
    end
    local function classify(symbol)
        local ids = gameinit.identifiers(symbol)
        for _, id in ipairs(ids) do
            if by_class[id] then return "db", by_class[id] end
        end
        for _, id in ipairs(ids) do
            if ix.classes[id] then return "external", nil, id end
        end
        return "other"
    end
    -- the read hooks: the writable segments (reads[a] = size, reads_in_order: the addresses as
    -- first read)
    local reads, reads_in_order
    local hooks = {}
    for _, seg in ipairs(image.segments) do
        if seg.flags % 4 >= PF_W then
            hooks[#hooks + 1] = e:hook("read", function(a, size)
                if reads and not reads[a] then
                    reads[a] = size
                    reads_in_order[#reads_in_order + 1] = a
                end
            end, base + seg.vaddr, base + seg.vaddr + seg.memsz - 1)
        end
    end
    local budget = options.budget or 2e5
    local blocks = 0
    local bh = e:hook("block", function()
        blocks = blocks + 1
        if blocks > budget then
            m:stop("budget")
        end
    end, 1, 0)
    local lenient = m.lenient
    m.lenient = true
    local word = m.word
    for _, r in ipairs(records) do
        r.deps = {}
        if r.can_init ~= 0 then
            local all, order = {}, {}
            for _ = 1, options.iterations or 40 do
                reads, reads_in_order, blocks = {}, {}, 0
                local ok, rc = pcall(m.call, m, base + r.can_init)
                if ok and m.last_stop then
                    r.can_init_error = m.last_stop  -- the budget
                elseif ok then
                    r.can_init_result = rc % 256
                    r.can_init_error = nil
                else
                    r.can_init_error = tostring(rc)
                end
                local changed = false
                for _, a in ipairs(reads_in_order) do
                    local size = reads[a]
                    if not all[a] then
                        all[a] = size
                        order[#order + 1] = a
                    end
                    -- a word read as zero is set, so that the test that stopped there goes on
                    local zero
                    if size == word then
                        zero = m:ptr(a) == 0
                        if zero then m:set_ptr(a, P) end
                    elseif size == 4 then
                        zero = m:u32(a) == 0
                        if zero then m:set_u32(a, 1) end
                    elseif size == 1 then
                        zero = m:u8(a) == 0
                        if zero then m:set_u8(a, 1) end
                    end
                    changed = changed or zero
                end
                if not changed then break end
            end
            reads = nil
            -- the globals read, named, first read first
            local seen = {}
            for _, a in ipairs(order) do
                local s = image:object_at(a - base)
                local symbol = s and s.name
                if symbol and not ignored_object(symbol) and not seen[symbol] then
                    seen[symbol] = true
                    local kind, db, class = classify(symbol)
                    if not (kind == "db" and records[db] == r) then
                        r.deps[#r.deps + 1] = { kind = kind, db = db, class = class, symbol = symbol }
                    end
                end
            end
        end
    end
    m.lenient = lenient
    e:unhook(bh)
    for _, h in ipairs(hooks) do e:unhook(h) end
end

-- gameinit.simulate(records) -> order, stuck: the game's loop, with each CanInitialize true once
-- the databases it reads are done: the first database left whose dependencies are done is
-- initialized, and the search starts again from the first. stuck: those never ready.
function gameinit.simulate(records)
    local done, order, remaining = {}, {}, {}
    for i = 1, #records do remaining[i] = i end
    while #remaining > 0 do
        local pick
        for k, i in ipairs(remaining) do
            local ready = true
            for _, d in ipairs(records[i].deps or {}) do
                if d.kind == "db" and not done[d.db] then
                    ready = false
                    break
                end
            end
            if ready then
                pick = k
                break
            end
        end
        if not pick then break end
        local i = table.remove(remaining, pick)
        done[i] = true
        order[#order + 1] = i
    end
    return order, remaining
end

-- InitGame -----------------------------------------------------------------------------------------

-- gameinit.init_game_steps(m) -> steps, static, run: InitGame's calls in the order reached
-- (isolated, `this` an object of zeros) and its static calls (address order), each marked
-- `reached` when the run made it
function gameinit.init_game_steps(m)
    local start = gameinit.function_range(m.image, gameinit.INIT_GAME)
    if not start then
        return nil, nil, { error = "no CGameApplication::InitGame" }
    end
    local static = gameinit.static_calls(m.image, gameinit.INIT_GAME)
    clear_stack(m)
    gameinit.zero_page(m)
    local this = m:alloc(0x10000)
    local run = gameinit.isolate(m, m.base + start, { this })
    local sites, targets = {}, {}
    for _, c in ipairs(run.calls) do
        if c.site then sites[c.site] = true end
        if c.kind == "tail" then targets[c.target] = true end
    end
    for _, s in ipairs(static) do
        s.reached = sites[s.site] or (s.kind == "jmp" and targets[s.target]) or false
    end
    return run.calls, static, run
end

-- gameinit.program(static, steps) -> list: one entry per call site, in address order (the order of
-- the source, near enough): every static call or jump, reached or not, and every site of an
-- indirect call the run made. entry = { site, kind, name, import, reached, count, names } where
-- count is how many times the run passed there and names the targets of an indirect call (all
-- different: a loop over a table of functions is one site with many targets).
function gameinit.program(static, steps)
    local out, by_site = {}, {}
    for _, s in ipairs(static or {}) do
        local e = { site = s.site, kind = s.kind, name = s.name, import = s.import, reached = s.reached,
            count = 0, names = { s.name } }
        out[#out + 1] = e
        by_site[s.site] = e
    end
    for _, c in ipairs(steps or {}) do
        local e = c.site and by_site[c.site]
        if not e and (c.kind == "icall" or c.kind == "tail" or c.kind == "jump") then
            e = { site = c.site, kind = c.kind, name = c.name, reached = true, count = 0, names = {},
                seen = {} }
            if c.site then
                by_site[c.site] = e
            end
            out[#out + 1] = e
        end
        if e then
            e.count = e.count + 1
            if e.seen and not e.seen[c.name] then
                e.seen[c.name] = true
                e.names[#e.names + 1] = c.name
                if c.db then e.db = true end
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.site or math.huge) < (b.site or math.huge)
    end)
    for _, e in ipairs(out) do e.seen = nil end
    return out
end

-- everything --------------------------------------------------------------------------------------

-- gameinit.extract(m) -> result: { databases, table, order, stuck, steps, static, errors, info }
function gameinit.extract(m)
    local result = { errors = {}, info = {} }
    local ok, t, info = pcall(gameinit.databases, m)
    if not ok then
        result.errors[#result.errors + 1] = "databases: " .. tostring(t)
    elseif not t then
        local why = info and (info.error or (info.run and (info.run.error or info.run.stopped))) or "?"
        result.errors[#result.errors + 1] = "databases: no table found (" .. tostring(why) .. ")"
        result.info.table_fn = info and info.fn
    else
        result.table = t
        result.databases = t.records
        result.info.table_fn = info.fn
        result.info.table_run_error = info.run.error
    end
    local steps, static, run
    ok, steps, static, run = pcall(gameinit.init_game_steps, m)
    if not ok then
        result.errors[#result.errors + 1] = "InitGame: " .. tostring(steps)
    else
        result.steps, result.static = steps, static
        result.info.init_game_error = run.error
        result.info.init_game_stopped = run.stopped
        result.info.init_game_blocks = run.blocks
    end
    if result.databases then
        -- the steps that are a database's function (the loop, inline before 4.1)
        local role_of = {}
        for i, r in ipairs(result.databases) do
            for _, role in ipairs(gameinit.FIELDS) do
                if r[role] ~= 0 then role_of[r[role]] = { db = i, role = role } end
            end
        end
        for _, s in ipairs(result.steps or {}) do
            local d = s.target and role_of[s.target]
            if d then s.db, s.role = d.db, d.role end
        end
        ok, t = pcall(gameinit.dependencies, m, result.databases)
        if not ok then
            result.errors[#result.errors + 1] = "dependencies: " .. tostring(t)
        else
            result.order, result.stuck = gameinit.simulate(result.databases)
        end
    end
    result.program = gameinit.program(result.static, result.steps)
    return result
end

return gameinit
