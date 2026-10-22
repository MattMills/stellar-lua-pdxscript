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
--
-- The image is an ELF executable (oracle/elf.lua: the System V ABI, glibc's thread pointer) or a
-- Windows one (oracle/pe.lua, image.abi "win64" or "win32": the Microsoft calling conventions, a
-- TEB with the executable's TLS block, the imports of oracle/hle_msvc.lua). m:call, m:arg and
-- m:set_return follow the image's ABI; on i386 Windows each function's convention (__thiscall,
-- __stdcall, __cdecl) and what it pops come from its decorated name (oracle/msvc.lua).

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
    local windows = image.format == "pe"
    local base = windows and image.base or (image.pie and L.pie_base or 0)
    local imports = windows and require("oracle.hle_msvc").windows or hle.linux
    local m = setmetatable({ image = image, engine = e, bits = bits, layout = L,
        word = bits / 8, base = base, stubs = {}, stub_names = {},
        stub_count = 1, data_imports = {}, lenient = options.lenient,
        abi = image.abi or (bits == 64 and "sysv" or "i386"), windows = windows,
        platform = options.platform or (windows and "windows" or "linux"),
        hle = setmetatable(options.hle or {}, { __index = imports }), stub_conv = {},
        recent = {}, recent_n = 0, unimplemented = {}, enter_hooks = {}, stdout = {},
        heap_top = L.heap, heap_mapped = L.heap, free_lists = {}, calls = 0 }, Machine)
    m.buf8 = ffi.new("uint8_t[8]")

    -- the image
    local mapped = {}
    for _, seg in ipairs(image.segments) do
        local start = page_down(m.base + seg.vaddr)
        local stop = page_up(m.base + seg.vaddr + seg.memsz)
        -- (PE sections are page-aligned; a page already mapped is not mapped again)
        local a = start
        while a < stop do
            if not mapped[a] then
                local b = a
                while b < stop and not mapped[b] do
                    mapped[b] = true
                    b = b + PAGE
                end
                e:map(a, b - a)
                a = b
            else
                a = a + PAGE
            end
        end
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
    if windows then
        m:setup_teb()
    elseif bits == 64 then
        e:set_reg("fs_base", m.tp)
    else
        e:map(L.gdt, PAGE)
        e:setup_gdt(L.gdt, 6, m.tp)
    end
    if not windows then
        m:set_ptr(m.tp, m.tp)                         -- tcb->tcb (fs:0 / gs:0)
        m:set_ptr(m.tp + (bits == 64 and 0x28 or 0x14), bits == 64 and 0x1d3a91c6e5b047 or 0x91c6e5b0) -- stack guard
    end
    if image.tls and not windows then
        local t = image.tls
        local size = t.memsz + (t.align - t.memsz % t.align) % t.align
        m.tls_block = m.tp - size
        if t.filesz > 0 then
            e:write(m.tls_block, ffi.cast("const uint8_t *", image.data) + t.offset, t.filesz)
        end
        m.tls_block_size = size
    end
    m.errno = m:alloc(16)

    if windows then
        m:bind_imports()
    else
        m:relocate()
    end

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
    if windows and not options.no_crt_init then
        m:crt_init()
    end
    return m
end

-- Windows: the statically linked C runtime initialized as WinMainCRTStartup does before anything
-- else (__security_init_cookie, then __scrt_initialize_crt: the processor's features, vcruntime's
-- and the UCRT's state: its heap, locks, per-thread data, the encoded pointers of its Windows API
-- thunks, stdio, the locale), then the C initializers (__xi_a to __xi_z: the command line, the
-- environment, on i386 the functions of the thread-safe statics). Without it the runtime decodes
-- pointers that were never encoded. The C++ initializers (the game's globals) are not run.
function Machine:crt_init()
    local u = self.bits == 32 and "_" or ""
    local results = {}
    local function run(name, address, ...)
        local ok, r = pcall(self.call, self, address, ...)
        results[#results + 1] = { name = name, ok = ok, result = ok and r or nil, error = not ok and r or nil }
    end
    for _, step in ipairs({ { "__security_init_cookie" }, { "__scrt_initialize_crt", 1 } }) do
        local a = self:has(u .. step[1])
        if a then
            run(step[1], a, step[2])
        else
            results[#results + 1] = { name = step[1], ok = false, error = "not found" }
        end
    end
    local a, z = self:has(u .. "__xi_a"), self:has(u .. "__xi_z")
    if not (a and z) then
        a, z = self:find_initterm_e()
    end
    if a and z then
        for p = a, z - self.word, self.word do
            local fn = self:ptr(p)
            if fn ~= 0 then
                run(self:where(fn), fn)
            end
        end
    end
    self.crt_init_results = results
    return results
end

-- __xi_a and __xi_z where they have no symbol (x86-64 builds with labels only): the two tables
-- __scrt_common_main_seh gives _initterm_e, `lea rcx, [__xi_a]; lea rdx, [__xi_z]; call _initterm_e`
-- (__scrt_common_main_seh found from its label, or as where WinMainCRTStartup jumps)
function Machine:find_initterm_e()
    if self.bits ~= 64 then return nil end
    local initterm_e = self:has("_initterm_e")
    if not initterm_e then return nil end
    local function i32(s, i)
        local v = s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 + s:byte(i + 3) * 16777216
        return v >= 2 ^ 31 and v - 2 ^ 32 or v
    end
    local main = self:has("__scrt_common_main_seh")
    if not main then
        local start = self:has("WinMainCRTStartup")
        if not start then return nil end
        local code = self:read(start, 32)
        for i = 1, 28 do
            if code:byte(i) == 0xe9 then
                main = start + i - 1 + 5 + i32(code, i + 1)
                break
            end
        end
        if not main then return nil end
    end
    local code = self:read(main, 0x300)
    for i = 1, #code - 4 do
        if code:byte(i) == 0xe8 and main + i - 1 + 5 + i32(code, i + 1) == initterm_e then
            local a, z
            for j = math.max(1, i - 24), i - 7 do
                if code:byte(j) == 0x48 and code:byte(j + 1) == 0x8d then
                    local reg = code:byte(j + 2)
                    local target = main + j - 1 + 7 + i32(code, j + 3)
                    if reg == 0x0d then a = target elseif reg == 0x15 then z = target end
                end
            end
            if a and z then
                return a, z
            end
        end
    end
    return nil
end

-- m:close(): the emulator and the process's memory freed at once (a machine holds hundreds of MB;
-- the garbage collector would free it only later)
function Machine:close()
    self.engine:close()
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

-- the stub for an imported function. like: on i386 Windows, the address of a function of the game
-- whose calling convention the stub has (a Lua function standing in for it), or a convention
-- { kind = "thiscall" | "stdcall" | "cdecl" | "fastcall", pops = n }
function Machine:stub(name, like)
    local s = self.stubs[name]
    if not s then
        s = self.layout.stub + 16 * self.stub_count
        self.stub_count = self.stub_count + 1
        assert(self.stub_count * 16 < self.layout.stub_size / 2, "too many imports")
        self.stubs[name] = s
        self.stub_names[s] = name
    end
    if like and self.windows and self.bits == 32 then
        self.stub_conv[s] = type(like) == "table" and like or self:convention_at(like) or false
    end
    return s
end

-- the calling convention of the game's function at address (i386 Windows: from its decorated
-- name), or nil
function Machine:convention_at(address)
    if not (self.windows and self.bits == 32) or not self.image.convention then
        return nil
    end
    local sig = self.image:convention(address - self.base)
    if sig and sig.kind == "function" then
        return { kind = sig.convention, pops = sig.pops or 0 }
    end
    return nil
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
    -- a COPY relocation: the shared library's object copied into the executable, which reads it
    -- there; the ones whose contents matter are written by hle.copy (1.x's tr1 __prime_list)
    local function copy(r, at)
        local f = self.hle.copy and r.name and self.hle.copy[(r.name:gsub("@.*", ""))]
        if f then f(self, at) end
    end
    for _, r in ipairs(image.relocs) do
        local at = base + r.offset
        if bits == 64 then
            local t = r.type
            if t == R64.COPY then
                copy(r, at)
            elseif t == R64.RELATIVE then
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
            if t == R32.COPY then
                copy(r, at)
            elseif t == R32.RELATIVE then
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

-- Windows ----------------------------------------------------------------------------------------

-- the thread environment block: x86-64 gs, i386 fs. Its self pointer, the stack's base and limit
-- (__chkstk compares with the limit), the thread id, the process environment block (its
-- ProcessHeap), and ThreadLocalStoragePointer: an array whose slot _tls_index (0) is a copy of the
-- executable's TLS template (thread-safe statics keep their epoch there)
function Machine:setup_teb()
    local L, e, w = self.layout, self.engine, self.word
    local teb = L.tls
    local x64 = self.bits == 64
    self.teb = teb
    self.peb = L.tls + 0x3000
    self.tls_array = L.tls + 0x2000
    if x64 then
        e:set_reg("gs_base", teb)
    else
        e:map(L.gdt, PAGE)
        e:setup_gdt(L.gdt, 6, teb, "fs")
    end
    local o = x64 and { stack_base = 0x8, stack_limit = 0x10, self = 0x30, pid = 0x40, tid = 0x48,
        tls = 0x58, peb = 0x60, last_error = 0x68 } or { stack_base = 0x4, stack_limit = 0x8,
        self = 0x18, pid = 0x20, tid = 0x24, tls = 0x2c, peb = 0x30, last_error = 0x34 }
    self.teb_offsets = o
    if not x64 then
        self:set_u32(teb, 0xffffffff)  -- the end of the SEH chain
    end
    self:set_ptr(teb + o.stack_base, L.stack_top)
    self:set_ptr(teb + o.stack_limit, L.stack_top - L.stack_size)
    self:set_ptr(teb + o.self, teb)
    self:set_ptr(teb + o.pid, 0x1000)
    self:set_ptr(teb + o.tid, 0x1004)
    self:set_ptr(teb + o.tls, self.tls_array)
    self:set_ptr(teb + o.peb, self.peb)
    self.process_heap = 0x50000
    self:set_ptr(self.peb + (x64 and 0x10 or 0x8), self.base)          -- ImageBaseAddress
    self:set_ptr(self.peb + (x64 and 0x30 or 0x18), self.process_heap)  -- ProcessHeap
    local t = self.image.tls
    if t then
        local block = L.tls + 0x4000
        local size = t.stop - t.start
        if size > 0 then
            self:write(block, self:read(t.start, size), size)
        end
        self.tls_block = block
        self.tls_block_size = size + t.zero_fill
        assert(self.tls_block_size < L.tls_size - 0x4000, "TLS template too large")
        self:set_ptr(self.tls_array, block)   -- slot 0
        self:set_u32(t.index, 0)              -- _tls_index
    end
end

-- the convention of an import on i386 Windows: a C++ name has its own (oracle/msvc.lua); a C
-- name of a C runtime DLL is __cdecl, of any other DLL (the Windows API) __stdcall, its argument
-- count from the implementation's table (hle_msvc: arity)
local CRT_DLL = { ["ucrtbase.dll"] = true, ["vcruntime140.dll"] = true, ["msvcrt.dll"] = true,
    ["msvcp140.dll"] = true }
function Machine:import_convention(dll, name)
    if self.bits == 64 then
        return nil
    end
    if name and name:sub(1, 1) == "?" then
        local sig = require("oracle.msvc").signature(name, 32)
        if sig and sig.kind == "function" then
            return { kind = sig.convention, pops = sig.pops or 0 }
        end
        return nil
    end
    local d = (dll or ""):lower()
    if CRT_DLL[d] or d:find("^api%-ms%-win%-crt") then
        return { kind = "cdecl", pops = 0 }
    end
    return { kind = "stdcall", stdcall_import = true }
end

-- a PE's imports: each IAT slot gets the stub of its function (a C++ variable: a block of data)
function Machine:bind_imports()
    local msvc = require("oracle.msvc")
    for _, imp in ipairs(self.image.imports) do
        local name = imp.name or string.format("%s!#%d", imp.dll, imp.ordinal)
        local at = self.base + imp.iat
        local sig = imp.name and imp.name:sub(1, 1) == "?" and msvc.signature(imp.name, self.bits)
        if sig and sig.kind == "variable" then
            self:set_ptr(at, self:data_import(name))
        else
            local s = self:stub(name)
            self.stub_dll = self.stub_dll or {}
            self.stub_dll[s] = imp.dll
            if self.stub_conv[s] == nil then
                self.stub_conv[s] = self:import_convention(imp.dll, imp.name) or false
            end
            self:set_ptr(at, s)
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
-- The largest block one allocation may take (m.max_alloc): a size read from garbage (a loop the
-- game's code is lost in) would map heap until the host runs out, inside a hook, where the call's
-- time limit cannot stop it (4.3.1's CBitmapFont::ReadMember: 6 GB in 80 minutes).
Machine.max_alloc = 1024 * 1024 * 1024

function Machine:alloc(n, align)
    n = math.max(n, 1)
    if n > self.max_alloc then
        error(string.format("allocation of %.0f bytes (more than m.max_alloc)", n))
    end
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
local ARGWIN64 = { "rcx", "rdx", "r8", "r9" }

-- the i-th integer argument (1-based) of the import being called (at its stub), or of the
-- function entered (in an m:on_enter hook). On x86-64 Windows: rcx, rdx, r8, r9, then the stack
-- above the 32 bytes of shadow space. On i386 Windows the convention of the stub or function:
-- __thiscall has `this` (argument 1) in ecx, __fastcall the first two in ecx and edx.
function Machine:arg(i)
    local e = self.engine
    if self.bits == 64 then
        if self.abi == "win64" then
            if i <= 4 then
                return tonumber(e:reg(ARGWIN64[i]))
            end
            return self:u64(self:sp() + 8 * i)
        end
        if i <= 6 then
            return tonumber(e:reg(ARG64[i]))
        end
        return self:u64(self:sp() + 8 * (i - 6))
    end
    local conv = self.cur_conv
    if conv then
        if conv.kind == "thiscall" then
            if i == 1 then return tonumber(e:reg("ecx")) end
            return self:u32(self:sp() + 4 * (i - 1))
        elseif conv.kind == "fastcall" then
            if i == 1 then return tonumber(e:reg("ecx")) end
            if i == 2 then return tonumber(e:reg("edx")) end
            return self:u32(self:sp() + 4 * (i - 2))
        end
    end
    return self:u32(self:sp() + 4 * i)
end

-- the i-th argument as a 32-bit unsigned or signed integer (an int, a DWORD: on x86-64 the upper
-- half of its register or stack slot is not set by the caller)
function Machine:arg32(i)
    return self:arg(i) % 2 ^ 32
end

function Machine:sarg32(i)
    local v = self:arg(i) % 2 ^ 32
    return v >= 2 ^ 31 and v - 2 ^ 32 or v
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
    local conv = self.stub_conv[address]
    if f == nil then
        self.unimplemented[name] = (self.unimplemented[name] or 0) + 1
        if self.lenient and not (conv and conv.stdcall_import) then
            self:set_return(0)
            return
        end
        self.fault = { kind = "import not implemented: " .. name, pc = self:ptr(self:sp()) }
        self.engine:stop()
        return
    end
    local was = self.cur_conv
    self.cur_conv = conv or nil
    local ok, r = pcall(f, self, name)
    self.cur_conv = was
    if not ok then
        self.fault = self.fault or { kind = "import " .. name .. " failed: " .. tostring(r),
            pc = self:ptr(self:sp()) }
        self.engine:stop()
        return
    end
    if type(r) ~= "string" then
        self:set_return(r)
    end
    -- i386 Windows: a __stdcall or __thiscall function removes its arguments (`ret n`); for an
    -- import of the Windows API the count of arguments is the implementation's (hle_msvc: arity)
    if conv and r ~= "noreturn" and r ~= "redirected" then
        local pops = conv.pops
        if conv.stdcall_import then
            local n = self.hle.arity and self.hle.arity[name]
            if not n then
                self.fault = self.fault or { kind = "import " .. name .. ": its count of arguments is not known",
                    pc = self:ptr(self:sp()) }
                self.engine:stop()
                return
            end
            pops = 4 * n
        end
        if pops and pops > 0 then
            self:pop_arguments(pops)
        end
    end
end

-- removes n bytes of arguments above the return address (the stub's `ret` then returns)
function Machine:pop_arguments(n)
    local sp = self:sp()
    local r = self:u32(sp)
    self:set_u32(sp + n, r)
    self.engine:set_reg("esp", sp + n)
end

function Machine:mem_fault(t, address, size, value)
    self.fault = self.fault or { kind = (uc.MEM_TYPES[t] or tostring(t)) .. " access",
        address = tonumber(address), size = size, pc = self:pc() }
    return false
end

-- m:callee_pops(n) inside an import: on i386 a function that returns a struct through a hidden
-- pointer removes that pointer from the stack itself (`ret 4`); the stub only has `ret`, so the
-- return address is moved up by n bytes first
-- (on Windows the caller removes it: MSVC's __cdecl; a __thiscall function's pops come from its
-- name, so this does nothing there)
function Machine:callee_pops(n)
    if self.bits == 32 and not self.windows then
        self:pop_arguments(n)
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
-- pointer arguments (SysV x86-64, or cdecl on i386 where `this` is the first argument). It may be
-- called from inside a hook or an import (a nested emulation): the registers are kept around it,
-- and its stack is below the one in use.
function Machine:call(address, ...)
    local e = self.engine
    local args = { ... }
    local L = self.layout
    local depth = self.depth or 0
    local saved, sp
    if depth > 0 then
        saved = e:save()
        sp = self:sp() - 0x400
    else
        sp = L.stack_top - 0x10000
    end
    if self.abi == "win64" then
        -- rcx, rdx, r8, r9, then the stack above 32 bytes of shadow space
        local extra = math.max(#args, 4)
        sp = sp - 8 * extra
        sp = sp - sp % 16 - 8  -- at entry, rsp + 8 is 16-aligned
        self:set_u64(sp, self.exit)
        for i = 1, #args do
            local v = args[i]
            if type(v) == "boolean" then v = v and 1 or 0 end
            if v < 0 then v = ffi.cast("uint64_t", ffi.cast("int64_t", v)) end
            if i <= 4 then
                e:set_reg(ARGWIN64[i], v)
            else
                self:set_u64(sp + 8 * i, v)
            end
        end
        e:set_reg("rsp", sp)
        e:set_reg("rbp", 0)
    elseif self.bits == 64 then
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
        -- i386: on the stack (cdecl, stdcall); __thiscall has `this` in ecx, __fastcall the
        -- first two in ecx and edx (i386 Windows: the function's decorated name says which)
        local conv = self.windows and self:convention_at(address)
        local regs = {}
        if conv and conv.kind == "thiscall" then
            regs = { "ecx" }
        elseif conv and conv.kind == "fastcall" then
            regs = { "ecx", "edx" }
        end
        local stack = {}
        for i = 1, #args do
            local v = args[i]
            if type(v) == "boolean" then v = v and 1 or 0 end
            if v < 0 then v = v + 2 ^ 32 end
            if regs[i] then
                e:set_reg(regs[i], v)
            else
                stack[#stack + 1] = v
            end
        end
        sp = sp - 4 * #stack
        sp = sp - sp % 16 - 4
        self:set_u32(sp, self.exit)
        for i = 1, #stack do
            self:set_u32(sp + 4 * i, stack[i])
        end
        e:set_reg("esp", sp)
        e:set_reg("ebp", 0)
    end
    self.fault = nil
    self.calls = self.calls + 1
    self.depth = depth + 1
    -- a call from Lua has a time limit (m.timeout, seconds): the game's code can loop forever on
    -- text it never expected (ReadUntilCharacter reads past the end of the file)
    local err = e:start(address, self.exit, 0, depth == 0 and (self.timeout or 30) * 1e6 or 0)
    self.depth = depth
    local stopped = self.stop_reason
    self.stop_reason = nil
    if not err and not stopped and self:pc() ~= self.exit then
        -- stopped before returning, by no fault and no m:stop: the time limit (Unicorn's timer
        -- stops whichever emulation runs, a nested one too; the call that set it is then
        -- stopped through the error this raises in the hook)
        err = string.format("timed out after %ds", self.timeout or 30)
    end
    self.last_stop = stopped
    local result = tonumber(e:reg(self.bits == 64 and "rax" or "eax"))
    if saved then
        e:restore(saved)
    end
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
    return result
end

-- m:stop([reason]) from a hook: ends the current m:call, which then returns normally (its result is
-- whatever is in rax / eax) with m.last_stop = reason
function Machine:stop(reason)
    self.stop_reason = reason or "stopped"
    self.engine:stop()
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
-- function like an import's (oracle/hle.lua). For what belongs to the environment, not to what is
-- observed (the profiler, the thread checks, the logger). The code is not changed: a hook on the
-- function's first instruction runs fn and returns to the caller (a patched jump would overwrite
-- the next function when this one is shorter than the jump).
function Machine:replace(address, fn, name)
    name = name or ("<replaced " .. self:where(address) .. ">")
    -- one hook per address: two names of one function (a C1 and C2 constructor) are one replacement
    -- (i386 Windows: with the function's convention, for its arguments and what it pops)
    self.replacements = self.replacements or {}
    local first = self.replacements[address] == nil
    self.replacements[address] = { fn = fn, name = name, conv = self:convention_at(address) }
    if first then
        self.engine:hook("code", function()
            local r = self.replacements[address]
            self:run_replacement(r.name, r.fn, r.conv)
        end, address, address)
    end
    self.replaced = self.replaced or {}
    self.replaced[#self.replaced + 1] = name
end

function Machine:run_replacement(name, fn, conv)
    self.recent_n = self.recent_n + 1
    self.recent[(self.recent_n - 1) % 16 + 1] = name
    local was = self.cur_conv
    self.cur_conv = conv
    local ok, r = pcall(fn, self, name)
    self.cur_conv = was
    if not ok then
        self.fault = self.fault or { kind = name .. " failed: " .. tostring(r), pc = self:ptr(self:sp()) }
        self.engine:stop()
        return
    end
    if r == "noreturn" then
        return
    end
    if type(r) ~= "string" then
        self:set_return(r)
    end
    -- return: pop the return address (moved by m:callee_pops, or pushed by m:redirect) into the pc
    -- (i386 Windows: a __thiscall or __stdcall function also removes its arguments)
    local sp = self:sp()
    local ret = self:ptr(sp)
    local pops = r ~= "redirected" and conv and conv.pops or 0
    self.engine:set_reg(self.bits == 64 and "rsp" or "esp", sp + self.word + pops)
    self.engine:set_reg(self.bits == 64 and "rip" or "eip", ret)
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
    if self.windows then
        -- MSVC: the C initializers (__xi_a to __xi_z, run by _initterm_e) then the C++ ones
        -- (__xc_a to __xc_z, _initterm): tables of function pointers, null entries skipped. On
        -- i386 the C names have a leading underscore.
        local u = self.bits == 32 and "_" or ""
        for _, t in ipairs({ "xi", "xc" }) do
            local a = image:symbol(u .. "__" .. t .. "_a")
            local z = image:symbol(u .. "__" .. t .. "_z")
            if a and z then
                for p = self.base + a, self.base + z - w, w do
                    add(self:ptr(p))
                end
            end
        end
        return out
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

-- m:on_enter(address, fn): fn(m) each time the game's code reaches address (a function's entry);
-- inside fn, m:arg(i) is the function's i-th argument
function Machine:on_enter(address, fn)
    local conv = self:convention_at(address)
    return self.engine:hook("code", function()
        local was = self.cur_conv
        self.cur_conv = conv
        fn(self)
        self.cur_conv = was
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
