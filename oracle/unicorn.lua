-- oracle/unicorn.lua : the Unicorn CPU emulator (2.x) through the LuaJIT FFI.
--
--   local uc = require("oracle.unicorn")
--   local engine = uc.open(64)                    -- or 32
--   engine:map(0x10000, 0x1000)
--   engine:write(0x10000, "\x48\xc7\xc0\x2a\x00\x00\x00")   -- mov rax, 42
--   engine:start(0x10000, 0x10007)
--   print(engine:reg("rax"))                      -- 42ULL
--
-- The library is found with PDXORACLE_UNICORN (a path), else as "unicorn" on the system's library
-- path. Constants are those of unicorn 2.1 (include/unicorn/unicorn.h, x86.h), printed by a C
-- program against the headers: the enums are implicit, so they are listed here as numbers.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[
typedef struct uc_struct uc_engine;
typedef size_t uc_hook;
typedef int uc_err;
uc_err uc_open(int arch, int mode, uc_engine **uc);
uc_err uc_close(uc_engine *uc);
const char *uc_strerror(uc_err code);
uc_err uc_reg_write(uc_engine *uc, int regid, const void *value);
uc_err uc_reg_read(uc_engine *uc, int regid, void *value);
uc_err uc_mem_write(uc_engine *uc, uint64_t address, const void *bytes, size_t size);
uc_err uc_mem_read(uc_engine *uc, uint64_t address, void *bytes, size_t size);
uc_err uc_emu_start(uc_engine *uc, uint64_t begin, uint64_t until, uint64_t timeout, size_t count);
uc_err uc_emu_stop(uc_engine *uc);
uc_err uc_hook_add(uc_engine *uc, uc_hook *hh, int type, void *callback, void *user_data,
                   uint64_t begin, uint64_t end, ...);
uc_err uc_hook_del(uc_engine *uc, uc_hook hh);
uc_err uc_mem_map(uc_engine *uc, uint64_t address, size_t size, uint32_t perms);
uc_err uc_mem_unmap(uc_engine *uc, uint64_t address, size_t size);
uc_err uc_mem_protect(uc_engine *uc, uint64_t address, size_t size, uint32_t perms);
uc_err uc_ctl(uc_engine *uc, int control, ...);
typedef struct uc_context uc_context;
uc_err uc_context_alloc(uc_engine *uc, uc_context **context);
uc_err uc_context_save(uc_engine *uc, uc_context *context);
uc_err uc_context_restore(uc_engine *uc, uc_context *context);
uc_err uc_context_free(uc_context *context);

typedef void (*uc_cb_hookcode_t)(uc_engine *uc, uint64_t address, uint32_t size, void *user_data);
typedef bool (*uc_cb_eventmem_t)(uc_engine *uc, int type, uint64_t address, int size,
                                 int64_t value, void *user_data);
typedef void (*uc_cb_hookmem_t)(uc_engine *uc, int type, uint64_t address, int size,
                                int64_t value, void *user_data);
typedef void (*uc_cb_hookintr_t)(uc_engine *uc, uint32_t intno, void *user_data);
typedef bool (*uc_cb_hookinsn_invalid_t)(uc_engine *uc, void *user_data);

typedef struct uc_x86_mmr { uint16_t selector; uint64_t base; uint32_t limit; uint32_t flags; } uc_x86_mmr;
]])

local uc = {}

uc.ARCH_X86 = 4
uc.MODE_32, uc.MODE_64 = 4, 8
uc.PROT_READ, uc.PROT_WRITE, uc.PROT_EXEC, uc.PROT_ALL = 1, 2, 4, 7
uc.HOOK_INTR, uc.HOOK_CODE, uc.HOOK_BLOCK = 1, 4, 8
uc.HOOK_MEM_UNMAPPED, uc.HOOK_MEM_INVALID = 112, 1008
uc.HOOK_MEM_READ, uc.HOOK_MEM_WRITE, uc.HOOK_INSN_INVALID = 1024, 2048, 16384
uc.MEM_READ, uc.MEM_WRITE, uc.MEM_FETCH = 16, 17, 18
uc.MEM_READ_UNMAPPED, uc.MEM_WRITE_UNMAPPED, uc.MEM_FETCH_UNMAPPED = 19, 20, 21
uc.MEM_TYPES = { [16] = "read", [17] = "write", [18] = "fetch", [19] = "read unmapped",
    [20] = "write unmapped", [21] = "fetch unmapped", [22] = "write protected",
    [23] = "read protected", [24] = "fetch protected", [25] = "read after" }

uc.REG = {
    rax = 35, rbx = 37, rcx = 38, rdx = 40, rsi = 43, rdi = 39, rbp = 36, rsp = 44, rip = 41,
    r8 = 106, r9 = 107, r10 = 108, r11 = 109, r12 = 110, r13 = 111, r14 = 112, r15 = 113,
    eax = 19, ebx = 21, ecx = 22, edx = 24, esi = 29, edi = 23, ebp = 20, esp = 30, eip = 26,
    eflags = 25, fs_base = 250, gs_base = 251, fs = 32, gs = 33, cs = 11, ss = 49, ds = 17,
    es = 28, gdtr = 243, xmm0 = 122, xmm1 = 123, st0 = 114, mxcsr = 249,
}

local lib
local function load()
    if lib then
        return lib
    end
    local path = os.getenv("PDXORACLE_UNICORN")
    local ok, l = pcall(ffi.load, path or "unicorn")
    if not ok then
        error("oracle.unicorn: cannot load the unicorn library (" .. tostring(l) ..
            "); set PDXORACLE_UNICORN to the path of libunicorn.so / unicorn.dll", 2)
    end
    lib = l
    return lib
end

local Engine = {}
Engine.__index = Engine

local function check(err, what)
    if err ~= 0 then
        error(string.format("unicorn: %s: %s (%d)", what, ffi.string(lib.uc_strerror(err)), err), 3)
    end
end

-- uc.open(bits) -> engine: an x86 engine in 32 or 64 bit mode
function uc.open(bits)
    load()
    local p = ffi.new("uc_engine *[1]")
    check(lib.uc_open(uc.ARCH_X86, bits == 32 and uc.MODE_32 or uc.MODE_64, p), "uc_open")
    -- the engine closes when the handle (this very cdata object) is collected
    local handle = ffi.gc(p[0], lib.uc_close)
    -- a Haswell: the default CPU (qemu64) has no SSE4.1, which the game's builds use (roundss);
    -- UC_CTL_WRITE(UC_CTL_CPU_MODEL, 1), UC_CPU_X86_HASWELL
    check(lib.uc_ctl(handle, 0x44000007, ffi.cast("int", 19)), "uc_ctl cpu model")
    return setmetatable({ handle = handle, bits = bits, hooks = {}, callbacks = {},
        u64 = ffi.new("uint64_t[1]") }, Engine)
end

function Engine:map(address, size, perms)
    check(lib.uc_mem_map(self.handle, address, size, perms or uc.PROT_ALL),
        string.format("map 0x%x +0x%x", tonumber(address), tonumber(size)))
end

function Engine:protect(address, size, perms)
    check(lib.uc_mem_protect(self.handle, address, size, perms), "protect")
end

function Engine:write(address, data, size)
    check(lib.uc_mem_write(self.handle, address, data, size or #data),
        string.format("write 0x%x", tonumber(address)))
end

-- engine:read(address, size) -> string, or nil and a message
function Engine:read(address, size)
    local buf = ffi.new("uint8_t[?]", size)
    local err = lib.uc_mem_read(self.handle, address, buf, size)
    if err ~= 0 then
        return nil, ffi.string(lib.uc_strerror(err))
    end
    return ffi.string(buf, size)
end

-- engine:read_into(address, buffer, size) -> true or false: a read into a cdata buffer
function Engine:read_into(address, buffer, size)
    return lib.uc_mem_read(self.handle, address, buffer, size) == 0
end

function Engine:reg(name)
    local id = uc.REG[name]
    self.u64[0] = 0
    check(lib.uc_reg_read(self.handle, id, self.u64), "reg_read " .. name)
    return self.u64[0]
end

function Engine:set_reg(name, value)
    self.u64[0] = value
    check(lib.uc_reg_write(self.handle, uc.REG[name], self.u64), "reg_write " .. name)
end

function Engine:read_reg_raw(name, cdata)
    check(lib.uc_reg_read(self.handle, uc.REG[name], cdata), "reg_read " .. name)
end

function Engine:set_reg_raw(name, cdata)
    check(lib.uc_reg_write(self.handle, uc.REG[name], cdata), "reg_write " .. name)
end

-- engine:start(begin, until [, count [, timeout_us]]) -> nil or the error message: runs until the
-- address `until` is reached, uc_emu_stop is called, the count of instructions or the time runs
-- out, or something fails
function Engine:start(begin, stop, count, timeout_us)
    local err = lib.uc_emu_start(self.handle, begin, stop, timeout_us or 0, count or 0)
    if err ~= 0 then
        return ffi.string(lib.uc_strerror(err))
    end
end

-- Callbacks (hooks) run Lua from inside uc_emu_start: the call must not be JIT-compiled.
jit.off(Engine.start)

function Engine:stop()
    lib.uc_emu_stop(self.handle)
end

-- engine:hook(kind, fn, begin, end) -> hook handle. kind: "code" and "block" (fn(address, size)),
-- "mem" (invalid accesses: fn(type, address, size, value) -> true to retry), "read" and "write"
-- (valid accesses in [begin, end]: fn(address, size, value); value is what is written),
-- "intr" (fn(intno)), "insn_invalid" (fn() -> handled). The callbacks are kept from the garbage collector with the
-- engine. Emulation must not be started from JIT-compiled code (see machine.lua).
function Engine:hook(kind, fn, begin, stop)
    load()
    local cb, htype
    if kind == "code" then
        cb = ffi.cast("uc_cb_hookcode_t", function(_, address, size)
            fn(tonumber(address), size)
        end)
        htype = uc.HOOK_CODE
    elseif kind == "block" then
        cb = ffi.cast("uc_cb_hookcode_t", function(_, address, size)
            fn(tonumber(address), size)
        end)
        htype = uc.HOOK_BLOCK
    elseif kind == "mem" then
        cb = ffi.cast("uc_cb_eventmem_t", function(_, t, address, size, value)
            return fn(t, tonumber(address), size, tonumber(value)) and true or false
        end)
        htype = uc.HOOK_MEM_INVALID
    elseif kind == "read" or kind == "write" then
        cb = ffi.cast("uc_cb_hookmem_t", function(_, _, address, size, value)
            fn(tonumber(address), size, tonumber(value))
        end)
        htype = kind == "read" and uc.HOOK_MEM_READ or uc.HOOK_MEM_WRITE
    elseif kind == "intr" then
        cb = ffi.cast("uc_cb_hookintr_t", function(_, intno)
            fn(intno)
        end)
        htype = uc.HOOK_INTR
    elseif kind == "insn_invalid" then
        cb = ffi.cast("uc_cb_hookinsn_invalid_t", function()
            return fn() and true or false
        end)
        htype = uc.HOOK_INSN_INVALID
    else
        error("unknown hook kind " .. tostring(kind))
    end
    local h = ffi.new("uc_hook[1]")
    check(lib.uc_hook_add(self.handle, h, htype, cb, nil, ffi.cast("uint64_t", begin or 1),
        ffi.cast("uint64_t", stop or 0)), "hook_add " .. kind)
    self.callbacks[#self.callbacks + 1] = cb
    self.hooks[#self.hooks + 1] = h[0]
    if htype == uc.HOOK_CODE or htype == uc.HOOK_BLOCK then
        -- code translated before the hook was added would not call it
        lib.uc_ctl(self.handle, 0x4000000a)
    end
    return h[0]
end

function Engine:unhook(h)
    lib.uc_hook_del(self.handle, h)
end

-- engine:save() -> context, engine:restore(context): the CPU's registers, around a nested
-- emulation (a hook that runs more of the game's code)
-- (the context is freed by restore: not left to the garbage collector, which could free it after
-- the engine)
function Engine:save()
    local p = ffi.new("uc_context *[1]")
    check(lib.uc_context_alloc(self.handle, p), "uc_context_alloc")
    local ctx = p[0]
    check(lib.uc_context_save(self.handle, ctx), "uc_context_save")
    return ctx
end

function Engine:restore(ctx)
    local err = lib.uc_context_restore(self.handle, ctx)
    lib.uc_context_free(ctx)
    check(err, "uc_context_restore")
end

-- engine:flush(): drop the translated code, after code was patched
function Engine:flush()
    lib.uc_ctl(self.handle, 0x4000000a)  -- UC_CTL_WRITE(UC_CTL_TB_FLUSH, 0)
end

-- 32-bit mode: a flat GDT whose entry `index` has base `base`, for %gs (glibc's thread pointer)
function Engine:setup_gdt(gdt_address, tls_index, tls_base)
    local words = ffi.new("uint32_t[32]")  -- 16 descriptors of two words
    local function descriptor(i, base, limit, access, flags)
        words[2 * i] = bit.bor(bit.band(limit, 0xffff), bit.lshift(bit.band(base, 0xffff), 16))
        words[2 * i + 1] = bit.bor(bit.band(bit.rshift(base, 16), 0xff), bit.lshift(access, 8),
            bit.lshift(bit.band(bit.rshift(limit, 16), 0xf), 16), bit.lshift(flags, 20),
            bit.lshift(bit.band(bit.rshift(base, 24), 0xff), 24))
    end
    -- 1: code, 2: data (ring 3), 3: ring 0 data for ss, tls_index: %gs
    descriptor(1, 0, 0xfffff, 0xfb, 0xc)
    descriptor(2, 0, 0xfffff, 0xf3, 0xc)
    descriptor(3, 0, 0xfffff, 0x93, 0xc)
    descriptor(tls_index, tls_base, 0xfffff, 0xf3, 0xc)
    self:write(gdt_address, words, ffi.sizeof(words))
    local mmr = ffi.new("uc_x86_mmr")
    mmr.base, mmr.limit = gdt_address, 16 * 8 - 1
    self:set_reg_raw("gdtr", mmr)
    self:set_reg("gs", tls_index * 8 + 3)
    self:set_reg("ds", 2 * 8 + 3)
    self:set_reg("es", 2 * 8 + 3)
    self:set_reg("ss", 3 * 8)
end

return uc
