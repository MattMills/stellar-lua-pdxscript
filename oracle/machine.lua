-- oracle/machine.lua : a process for one game executable, in an emulator. The executable's code
-- runs unchanged; the shared libraries it calls (libc, libstdc++, tbb) are Lua functions
-- (oracle/hle.lua) behind a stub per imported name. Nothing of the program runs unless it is
-- called: no entry point, no static constructors.
--
--   local machine = require("oracle.machine")
--   local m = machine.new(require("oracle.elf").load(path))
--   local text = m:string("a = b")              -- allocated in the process, NUL-terminated
--   local rc = m:call(m:sym("_ZN10CTextLexer6GetTokEv"), lexer)
--   m:u32(address), m:ptr(address), m:read(address, n), m:cstring(address)
--   m:on_enter(address, fn)                     -- observe a function of the game being called
--
-- Errors raised by m:call name what happened: the address that faulted, the function it was in,
-- the import that is not implemented, and the last imports called.

local ffi = require("ffi")
local bit = require("bit")
local uc = require("oracle.unicorn")
local hle = require("oracle.hle")

local machine = {}

local Machine = {}
Machine.__index = Machine

local LAYOUT = {
    [64] = { stub = 0x7f0000000000, stub_size = 0x100000, heap = 0x7e0000000000,
        heap_chunk = 0x4000000, stack_top = 0x7ff000000000, stack_size = 0x800000,
        tls = 0x7fe000000000, tls_size = 0x100000, pie_base = 0x200000000 },
    [32] = { stub = 0xf0000000, stub_size = 0x100000, heap = 0x40000000, heap_chunk = 0x1000000,
        stack_top = 0xe0000000, stack_size = 0x800000, tls = 0xd0000000, tls_size = 0x100000,
        gdt = 0xd0200000, pie_base = 0x10000000 },
}

local PAGE = 0x1000
local function page_down(a) return a - a % PAGE end
local function page_up(a) return a + (PAGE - a % PAGE) % PAGE end

-- x86-64 and i386 relocation types the loader handles
local R64 = { NONE = 0, ["64"] = 1, PC32 = 2, COPY = 5, GLOB_DAT = 6, JUMP_SLOT = 7, RELATIVE = 8,
    DTPMOD64 = 16, DTPOFF64 = 17, TPOFF64 = 18, IRELATIVE = 37 }
local R32 = { NONE = 0, ["32"] = 1, PC32 = 2, COPY = 5, GLOB_DAT = 6, JMP_SLOT = 7, RELATIVE = 8,
    TLS_TPOFF = 14, TLS_DTPMOD32 = 35, TLS_DTPOFF32 = 36, TLS_TPOFF32 = 37, IRELATIVE = 42 }

-- machine.new(image [, options]) -> m. options: lenient (unknown imports return 0 instead of
-- stopping), platform ("linux", the default), hle (a table of extra or replacing implementations)
function machine.new(image, options)
    options = options or {}
    local bits = image.bits
    local L = LAYOUT[bits]
    local e = uc.open(bits)
    local m = setmetatable({ image = image, engine = e, bits = bits, layout = L,
        word = bits / 8, base = image.pie and L.pie_base or 0, stubs = {}, stub_names = {},
        stub_count = 1, data_imports = {}, lenient = options.lenient,
        platform = options.platform or "linux", hle = setmetatable(options.hle or {}, { __index = hle.linux }),
        recent = {}, recent_n = 0, unimplemented = {}, enter_hooks = {}, stdout = {},
        heap_top = L.heap, heap_mapped = L.heap, free_lists = {}, calls = 0 }, Machine)
    m.buf8 = ffi.new("uint8_t[8]")

    -- the image
    for _, seg in ipairs(image.segments) do
        local start = page_down(m.base + seg.vaddr)
        local stop = page_up(m.base + seg.vaddr + seg.memsz)
        e:map(start, stop - start)
        if seg.filesz > 0 then
            e:write(m.base + seg.vaddr, ffi.cast("const uint8_t *", image.data) + seg.offset, seg.filesz)
        end
    end
    -- stubs: one `ret` per import, 16 bytes apart; the first is where call() returns to
    e:map(L.stub, L.stub_size)
    local fill = ffi.new("uint8_t[?]", L.stub_size, 0xc3)
    e:write(L.stub, fill, L.stub_size)
    m.exit = L.stub
    -- native imports (oracle/hle.lua: hle.native) in the second half, which no hook watches
    local native = hle.native[bits]
    local code = native.code:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
    m.native_base = L.stub + L.stub_size / 2
    e:write(m.native_base, code)
    m.native = {}
    for name, offset in pairs(native.entries) do
        m.native[name] = m.native_base + offset
    end
    for alias, name in pairs(hle.native.alias) do
        m.native[alias] = m.native[name]
    end
    if options.no_native then
        m.native = {}
    end
    if bits == 32 then
        -- i386 floating point results: an import returns through `mov eax, scratch; fld tword
        -- [eax]; ret` with the 80-bit value in scratch, so that it is pushed on the x87 stack
        m.fld_scratch = m.native_base + 0x7f00
        m.fld_return = m.native_base + 0x7e00
        local a = m.fld_scratch
        e:write(m.fld_return, string.char(0xb8, a % 256, math.floor(a / 256) % 256,
            math.floor(a / 65536) % 256, math.floor(a / 16777216) % 256, 0xdb, 0x28, 0xc3))
    end
    -- stack, thread pointer (and the executable's TLS block below it)
    e:map(L.stack_top - L.stack_size, L.stack_size)
    e:map(L.tls, L.tls_size)
    m.tp = L.tls + L.tls_size / 2
    if bits == 64 then
        e:set_reg("fs_base", m.tp)
    else
        e:map(L.gdt, PAGE)
        e:setup_gdt(L.gdt, 6, m.tp)
    end
    m:set_ptr(m.tp, m.tp)                         -- tcb->tcb (fs:0 / gs:0)
    m:set_ptr(m.tp + (bits == 64 and 0x28 or 0x14), bits == 64 and 0x1d3a91c6e5b047 or 0x91c6e5b0) -- stack guard
    if image.tls then
        local t = image.tls
        local size = t.memsz + (t.align - t.memsz % t.align) % t.align
        m.tls_block = m.tp - size
        if t.filesz > 0 then
            e:write(m.tls_block, ffi.cast("const uint8_t *", image.data) + t.offset, t.filesz)
        end
        m.tls_block_size = size
    end
    m.errno = m:alloc(16)

    m:relocate()

    -- hooks: the stubs, and the faults
    e:hook("code", function(address)
        m:stub_hit(address)
    end, L.stub, L.stub + L.stub_size / 2 - 1)
    e:hook("mem", function(t, address, size, value)
        return m:mem_fault(t, address, size, value)
    end)
    e:hook("insn_invalid", function()
        m.fault = m.fault or { kind = "invalid instruction", pc = m:pc() }
        return false
    end)
    e:hook("intr", function(intno)
        m.fault = m.fault or { kind = "interrupt " .. intno, pc = m:pc() }
        e:stop()
    end)
    return m
end

function Machine:pc()
    return tonumber(self.engine:reg(self.bits == 64 and "rip" or "eip"))
end

function Machine:sp()
    return tonumber(self.engine:reg(self.bits == 64 and "rsp" or "esp"))
end

-- the symbol of an address in the image (or of a stub), for messages
function Machine:where(address)
    if address == nil then
        return "?"
    end
    local L = self.layout
    if address >= L.stub and address < L.stub + L.stub_size then
        local name = self.stub_names[address]
        return name and ("<import " .. name .. ">") or (address == self.exit and "<exit>" or "<stub>")
    end
    local name = self.image:name_at(address - self.base)
    if name then
        return string.format("0x%x %s", address, name)
    end
    return string.format("0x%x", address)
end

-- the stub for an imported function
function Machine:stub(name)
    local s = self.stubs[name]
    if not s then
        s = self.layout.stub + 16 * self.stub_count
        self.stub_count = self.stub_count + 1
        assert(self.stub_count * 16 < self.layout.stub_size / 2, "too many imports")
        self.stubs[name] = s
        self.stub_names[s] = name
    end
    return s
end

-- the storage for an imported data object (an empty block)
function Machine:data_import(name, size)
    local d = self.data_imports[name]
    if not d then
        d = self:alloc(math.max(size or 0, 256))
        self.data_imports[name] = d
    end
    return d
end

function Machine:relocate()
    local image, base = self.image, self.base
    local bits = self.bits
    local function target(r)
        if r.defined then
            return base + r.value
        end
        if r.name == nil or r.name == "" then
            return 0
        end
        if self.native[r.name] and not rawget(self.hle, r.name) then
            return self.native[r.name]
        end
        local h = self.hle.data and self.hle.data[r.name]
        if h then
            return h(self, r.name)
        end
        if r.symtype == 1 then  -- STT_OBJECT
            return self:data_import(r.name)
        elseif r.symtype == 0 and not self.hle[r.name] then
            -- weak undefined (__gmon_start__, _ITM_*): absent
            return 0
        end
        return self:stub(r.name)
    end
    for _, r in ipairs(image.relocs) do
        local at = base + r.offset
        if bits == 64 then
            local t = r.type
            if t == R64.RELATIVE then
                self:set_u64(at, base + r.addend)
            elseif t == R64.JUMP_SLOT or t == R64.GLOB_DAT then
                self:set_u64(at, target(r) + (t == R64.GLOB_DAT and r.addend or 0))
            elseif t == R64["64"] then
                self:set_u64(at, target(r) + r.addend)
            elseif t == R64.TPOFF64 then
                self:set_u64(at, (r.value or 0) + r.addend - (self.tls_block_size or 0))
            elseif t == R64.DTPMOD64 then
                self:set_u64(at, 1)
            elseif t == R64.DTPOFF64 then
                self:set_u64(at, (r.value or 0) + r.addend)
            elseif t == R64.IRELATIVE then
                self.irelative = (self.irelative or 0) + 1
            end
        else
            local t = r.type
            local a = r.addend or self:u32(at)
            if t == R32.RELATIVE then
                self:set_u32(at, (base + a) % 2 ^ 32)
            elseif t == R32.JMP_SLOT or t == R32.GLOB_DAT then
                self:set_u32(at, target(r))
            elseif t == R32["32"] then
                self:set_u32(at, (target(r) + a) % 2 ^ 32)
            elseif t == R32.PC32 then
                self:set_u32(at, (target(r) + a - at) % 2 ^ 32)
            elseif t == R32.TLS_TPOFF then
                self:set_u32(at, ((r.value or 0) + a - (self.tls_block_size or 0)) % 2 ^ 32)
            elseif t == R32.TLS_TPOFF32 then
                self:set_u32(at, ((self.tls_block_size or 0) - (r.value or 0) - a) % 2 ^ 32)
            elseif t == R32.TLS_DTPMOD32 then
                self:set_u32(at, 1)
            elseif t == R32.TLS_DTPOFF32 then
                self:set_u32(at, ((r.value or 0) + a) % 2 ^ 32)
            end
        end
    end
end

-- memory -----------------------------------------------------------------------------------------

function Machine:read(address, n)
    local s, err = self.engine:read(address, n)
    if not s then
        error(string.format("read of %d bytes at 0x%x: %s", n, address, err), 2)
    end
    return s
end

function Machine:write(address, s, n)
    self.engine:write(address, s, n)
end

function Machine:u8(a)
    assert(self.engine:read_into(a, self.buf8, 1), "unmapped read")
    return self.buf8[0]
end
function Machine:u16(a)
    assert(self.engine:read_into(a, self.buf8, 2), "unmapped read")
    return ffi.cast("uint16_t *", self.buf8)[0]
end
function Machine:u32(a)
    assert(self.engine:read_into(a, self.buf8, 4), string.format("unmapped read at 0x%x", a))
    return ffi.cast("uint32_t *", self.buf8)[0]
end
function Machine:i32(a)
    assert(self.engine:read_into(a, self.buf8, 4), "unmapped read")
    return ffi.cast("int32_t *", self.buf8)[0]
end
function Machine:u64(a)
    assert(self.engine:read_into(a, self.buf8, 8), "unmapped read")
    return tonumber(ffi.cast("uint64_t *", self.buf8)[0])
end
function Machine:ptr(a)
    if self.bits == 64 then
        return self:u64(a)
    end
    return self:u32(a)
end
function Machine:set_u8(a, v)
    self.buf8[0] = v
    self.engine:write(a, self.buf8, 1)
end
function Machine:set_u32(a, v)
    ffi.cast("uint32_t *", self.buf8)[0] = v
    self.engine:write(a, self.buf8, 4)
end
function Machine:set_u64(a, v)
    ffi.cast("uint64_t *", self.buf8)[0] = v
    self.engine:write(a, self.buf8, 8)
end
function Machine:set_ptr(a, v)
    if self.bits == 64 then
        self:set_u64(a, v)
    else
        self:set_u32(a, v)
    end
end

-- m:cstring(address [, max]) -> the NUL-terminated string there
function Machine:cstring(address, max)
    max = max or 2 ^ 20
    local parts, n, total = {}, 0, 0
    while total < max do
        local chunk = self.engine:read(address + total, 64)
        if not chunk then
            -- near the end of a mapping: byte by byte
            chunk = ""
            for i = 0, 63 do
                local ok = self.engine:read_into(address + total + i, self.buf8, 1)
                if not ok then
                    break
                end
                chunk = chunk .. string.char(self.buf8[0])
                if self.buf8[0] == 0 then
                    break
                end
            end
            if chunk == "" then
                break
            end
        end
        local z = chunk:find("\0", 1, true)
        if z then
            n = n + 1
            parts[n] = chunk:sub(1, z - 1)
            break
        end
        n = n + 1
        parts[n] = chunk
        total = total + #chunk
    end
    return table.concat(parts)
end

-- the heap: 16-byte aligned blocks with their size in the 16 bytes before them, free lists by size
function Machine:alloc(n, align)
    n = math.max(n, 1)
    local size = n + (16 - n % 16) % 16
    align = align or 16
    if align <= 16 then
        local list = self.free_lists[size]
        if list and #list > 0 then
            local a = table.remove(list)
            self:write(a, ffi.new("uint8_t[?]", size), size)
            return a
        end
    end
    local a = self.heap_top + 16
    if align > 16 then
        a = a + (align - a % align) % align
    end
    local top = a + size
    while top > self.heap_mapped do
        self.engine:map(self.heap_mapped, self.layout.heap_chunk)
        self.heap_mapped = self.heap_mapped + self.layout.heap_chunk
    end
    self.heap_top = top
    self:set_u64(a - 16, size)
    return a
end

function Machine:block_size(a)
    if a == 0 or a < self.layout.heap or a >= self.heap_top then
        return nil
    end
    return self:u64(a - 16)
end

function Machine:free(a)
    local size = self:block_size(a)
    if not size then
        return
    end
    local list = self.free_lists[size]
    if not list then
        list = {}
        self.free_lists[size] = list
    end
    list[#list + 1] = a
end

-- m:string(s) -> address of a NUL-terminated copy of s in the process
function Machine:string(s)
    local a = self:alloc(#s + 1)
    self:write(a, s .. "\0", #s + 1)
    return a
end

-- calls ------------------------------------------------------------------------------------------

local ARG64 = { "rdi", "rsi", "rdx", "rcx", "r8", "r9" }

-- the i-th integer argument (1-based) of the import being called (at its stub)
function Machine:arg(i)
    local e = self.engine
    if self.bits == 64 then
        if i <= 6 then
            return tonumber(e:reg(ARG64[i]))
        end
        return self:u64(self:sp() + 8 * (i - 6))
    end
    return self:u32(self:sp() + 4 * i)
end

function Machine:sarg(i)
    local v = self:arg(i)
    if self.bits == 64 then
        if v >= 2 ^ 63 then v = v - 2 ^ 64 end
    elseif v >= 2 ^ 31 then
        v = v - 2 ^ 32
    end
    return v
end

function Machine:set_return(v)
    v = v or 0
    if v == true then v = 1 elseif v == false then v = 0 end
    if self.bits == 64 then
        if v < 0 then v = ffi.cast("uint64_t", ffi.cast("int64_t", v)) end
        self.engine:set_reg("rax", v)
    else
        self.engine:set_reg("eax", v % 2 ^ 32)
        self.engine:set_reg("edx", math.floor(v / 2 ^ 32) % 2 ^ 32)
    end
end

function Machine:stub_hit(address)
    if address == self.exit then
        return
    end
    local name = self.stub_names[address]
    if not name then
        self.fault = { kind = "call of an unknown stub", pc = address }
        self.engine:stop()
        return
    end
    self.recent_n = self.recent_n + 1
    self.recent[(self.recent_n - 1) % 16 + 1] = name
    local f = self.hle[name]
    if f == nil then
        self.unimplemented[name] = (self.unimplemented[name] or 0) + 1
        if self.lenient then
            self:set_return(0)
            return
        end
        self.fault = { kind = "import not implemented: " .. name, pc = self:ptr(self:sp()) }
        self.engine:stop()
        return
    end
    local ok, r = pcall(f, self, name)
    if not ok then
        self.fault = self.fault or { kind = "import " .. name .. " failed: " .. tostring(r),
            pc = self:ptr(self:sp()) }
        self.engine:stop()
        return
    end
    if type(r) ~= "string" then
        self:set_return(r)
    end
end

function Machine:mem_fault(t, address, size, value)
    self.fault = self.fault or { kind = (uc.MEM_TYPES[t] or tostring(t)) .. " access",
        address = tonumber(address), size = size, pc = self:pc() }
    return false
end

-- m:callee_pops(n) inside an import: on i386 a function that returns a struct through a hidden
-- pointer removes that pointer from the stack itself (`ret 4`); the stub only has `ret`, so the
-- return address is moved up by n bytes first
function Machine:callee_pops(n)
    if self.bits == 32 then
        local sp = self:sp()
        local r = self:u32(sp)
        self:set_u32(sp + n, r)
        self.engine:set_reg("esp", sp + n)
    end
end

-- m:redirect(fn) inside an import: the import returns into fn (with the import's own return
-- address as fn's), as if the import had tail-called it. Arguments are left as they are.
function Machine:redirect(fn)
    local sp = self:sp() - self.word
    self:set_ptr(sp, fn)
    self.engine:set_reg(self.bits == 64 and "rsp" or "esp", sp)
    return "redirected"
end

-- m:call(address, ...) -> the integer return value: calls a function of the game with integer or
-- pointer arguments (SysV x86-64, or cdecl on i386 where `this` is the first argument)
function Machine:call(address, ...)
    local e = self.engine
    local args = { ... }
    local L = self.layout
    local sp = L.stack_top - 0x10000
    if self.bits == 64 then
        local extra = math.max(#args - 6, 0)
        sp = sp - 8 * extra
        sp = sp - sp % 16 - 8  -- at entry, rsp + 8 is 16-aligned
        self:set_u64(sp, self.exit)
        for i = 1, #args do
            local v = args[i]
            if type(v) == "boolean" then v = v and 1 or 0 end
            if v < 0 then v = ffi.cast("uint64_t", ffi.cast("int64_t", v)) end
            if i <= 6 then
                e:set_reg(ARG64[i], v)
            else
                self:set_u64(sp + 8 * (i - 6), v)
            end
        end
        e:set_reg("rsp", sp)
        e:set_reg("rbp", 0)
    else
        sp = sp - 4 * #args
        sp = sp - sp % 16 - 4
        self:set_u32(sp, self.exit)
        for i = 1, #args do
            local v = args[i]
            if type(v) == "boolean" then v = v and 1 or 0 end
            if v < 0 then v = v + 2 ^ 32 end
            self:set_u32(sp + 4 * i, v)
        end
        e:set_reg("esp", sp)
        e:set_reg("ebp", 0)
    end
    self.fault = nil
    self.calls = self.calls + 1
    local err = e:start(address, self.exit)
    if self.fault or err then
        local f = self.fault or { kind = err, pc = self:pc() }
        local recent = {}
        for i = math.max(1, self.recent_n - 7), self.recent_n do
            recent[#recent + 1] = self.recent[(i - 1) % 16 + 1]
        end
        local msg = string.format("%s in %s%s; at %s; recent imports: %s", f.kind,
            self:where(address), f.address and string.format(" (address 0x%x)", f.address) or "",
            self:where(f.pc), table.concat(recent, ", "))
        if self.ring then
            msg = msg .. "\n  trace: " .. table.concat(self:trace_lines(), "\n         ")
        end
        self.fault = nil
        error(msg, 2)
    end
    if self.bits == 64 then
        return tonumber(e:reg("rax"))
    end
    return tonumber(e:reg("eax"))
end

-- m:sym(name) -> the address of a symbol of the image in the process (raises if absent)
function Machine:sym(name)
    local v = self.image:symbol(name)
    if not v then
        error("no symbol " .. name .. " in " .. tostring(self.image.path), 2)
    end
    return self.base + v
end

function Machine:has(name)
    local v = self.image:symbol(name)
    return v and self.base + v
end

-- m:replace(address, fn [, name]): the game's function at address is replaced by fn, a Lua
-- function like an import's (oracle/hle.lua): its entry is patched with a jump to a stub. For what
-- belongs to the environment, not to what is observed (the profiler, the thread checks).
function Machine:replace(address, fn, name)
    name = name or ("<replaced " .. self:where(address) .. ">")
    rawset(self.hle, name, fn)
    local stub = self:stub(name)
    local code
    if self.bits == 64 then
        -- jmp [rip + 0]; the stub's address
        local lo, hi = stub % 2 ^ 32, math.floor(stub / 2 ^ 32)
        code = string.char(0xff, 0x25, 0, 0, 0, 0) .. string.char(lo % 256, math.floor(lo / 256) % 256,
            math.floor(lo / 65536) % 256, math.floor(lo / 16777216) % 256, hi % 256,
            math.floor(hi / 256) % 256, math.floor(hi / 65536) % 256, math.floor(hi / 16777216) % 256)
    else
        local rel = (stub - (address + 5)) % 2 ^ 32
        code = string.char(0xe9, rel % 256, math.floor(rel / 256) % 256, math.floor(rel / 65536) % 256,
            math.floor(rel / 16777216) % 256)
    end
    self:write(address, code)
    self.engine:flush()
    self.replaced = self.replaced or {}
    self.replaced[#self.replaced + 1] = name
end

-- m:replace_symbol(mangled, fn) -> true if the image has the symbol (and it was replaced)
function Machine:replace_symbol(mangled, fn)
    local a = self:has(mangled)
    if a then
        self:replace(a, fn, "<replaced " .. mangled .. ">")
        return true
    end
    return false
end

-- m:initializers() -> { {address, name}, ... }: the static initializers, in the order the C
-- runtime runs them (.preinit_array, .init_array, then .ctors backwards)
function Machine:initializers()
    local image, w = self.image, self.word
    local out = {}
    local function add(v)
        if v ~= 0 and v ~= 2 ^ (8 * w) - 1 then
            out[#out + 1] = { address = v, name = image:name_at(v - self.base) or string.format("0x%x", v) }
        end
    end
    for _, name in ipairs({ ".preinit_array", ".init_array" }) do
        local s = image.sections[name]
        if s and s.size > 0 then
            for i = 0, s.size / w - 1 do
                add(self:ptr(self.base + s.addr + i * w))
            end
        end
    end
    local ctors = image.sections[".ctors"]
    if ctors and ctors.size > 0 then
        for i = ctors.size / w - 1, 0, -1 do
            add(self:ptr(self.base + ctors.addr + i * w))
        end
    end
    return out
end

-- m:static_init([filter [, lenient]]) -> results: runs the static initializers (all, or those whose
-- name matches the Lua pattern), in order, each { name, ok, error }; with lenient, imports that
-- are not implemented return 0 instead of failing the initializer
function Machine:static_init(filter, lenient)
    local results = {}
    local was = self.lenient
    self.lenient = lenient or was
    for _, init in ipairs(self:initializers()) do
        if not filter or init.name:find(filter) then
            local ok, err = pcall(self.call, self, init.address)
            results[#results + 1] = { name = init.name, ok = ok, error = not ok and err or nil }
        end
    end
    self.lenient = was
    return results
end

-- m:on_enter(address, fn): fn(m) each time the game's code reaches address (a function's entry)
function Machine:on_enter(address, fn)
    return self.engine:hook("code", function()
        fn(self)
    end, address, address)
end

-- m:trace(n): keep the last n basic blocks executed in the image; errors of m:call then end with
-- the functions they were in (m:trace(0) stops)
function Machine:trace(n)
    if self.trace_hook then
        self.engine:unhook(self.trace_hook)
        self.trace_hook = nil
    end
    if not n or n == 0 then
        self.ring = nil
        return
    end
    local ring, i = {}, 0
    self.ring, self.ring_size = ring, n
    self.ring_pos = function() return i end
    self.trace_hook = self.engine:hook("block", function(address)
        i = i + 1
        ring[(i - 1) % n + 1] = address
    end, 1, 0)
end

-- the functions of the traced blocks, oldest first, consecutive repeats folded
function Machine:trace_lines()
    if not self.ring then return {} end
    local i, n = self.ring_pos(), self.ring_size
    local out, last = {}, nil
    for k = math.max(1, i - n + 1), i do
        local a = self.ring[(k - 1) % n + 1]
        local w = self:where(a):gsub("%+0x%x+$", "")
        if w ~= last then
            out[#out + 1] = w
            last = w
        end
    end
    return out
end

-- m:coverage(begin, stop) -> set: the basic blocks executed in [begin, stop], from now on
function Machine:coverage(begin, stop)
    local set = {}
    local h = self.engine:hook("block", function(address)
        set[tonumber(address)] = true
    end, begin, stop)
    return set, h
end

function Machine:unhook(h)
    self.engine:unhook(h)
end

return machine
