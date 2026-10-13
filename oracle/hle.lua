-- oracle/hle.lua : the shared libraries a game executable calls, in Lua ("high level emulation").
-- Each import is a function(m, name) that reads its arguments with m:arg(i) and returns its
-- result (a number, true/false, nil for 0), "noreturn" after setting m.fault, or what
-- m:redirect returns.
--
-- Only what the lexer, the readers and the startup code reach is here. The character classes are
-- those of glibc 2.35 in the "C" locale, measured (iswspace of a signed char is true for HT, LF,
-- VT, FF, CR and space only, in every locale; tolower of -128..-2 is c + 256): what the game's
-- code does with them is then the game's own behaviour on Linux.

local ffi = require("ffi")
local bit = require("bit")

local hle = {}
local L = {}  -- linux (glibc, libstdc++, tbb)
hle.linux = L

local function noreturn(m, kind)
    m.fault = m.fault or { kind = kind, pc = m:ptr(m:sp()) }
    m.engine:stop()
    return "noreturn"
end

-- memory --------------------------------------------------------------------------------------------

local function malloc(m) return m:alloc(m:arg(1)) end
local function free(m) m:free(m:arg(1)) end
local function new(m) return m:alloc(m:arg(1)) end
local function new_aligned(m) return m:alloc(m:arg(1), m:arg(2)) end
local function delete(m) m:free(m:arg(1)) end

L.malloc, L.free, L.cfree = malloc, free, free
L.calloc = function(m) return m:alloc(m:arg(1) * m:arg(2)) end
L.realloc = function(m)
    local p, n = m:arg(1), m:arg(2)
    local a = m:alloc(n)
    if p ~= 0 then
        local old = m:block_size(p) or 0
        local k = math.min(old, n)
        if k > 0 then
            m:write(a, m:read(p, k), k)
        end
        m:free(p)
    end
    return a
end
L.memalign = function(m) return m:alloc(m:arg(2), m:arg(1)) end
L.aligned_alloc = L.memalign
L.posix_memalign = function(m)
    m:set_ptr(m:arg(1), m:alloc(m:arg(3), m:arg(2)))
    return 0
end
L.malloc_usable_size = function(m) return m:block_size(m:arg(1)) or 0 end
L.scalable_malloc, L.scalable_free, L.scalable_realloc, L.scalable_calloc = malloc, free, L.realloc, L.calloc
L.scalable_aligned_malloc = function(m) return m:alloc(m:arg(1), m:arg(2)) end
L.scalable_aligned_free = free
L.scalable_msize = L.malloc_usable_size

for _, n in ipairs({ "_Znwm", "_Znam", "_Znwj", "_Znaj", "_ZnwmRKSt9nothrow_t", "_ZnamRKSt9nothrow_t",
    "_ZnwjRKSt9nothrow_t", "_ZnajRKSt9nothrow_t" }) do
    L[n] = new
end
for _, n in ipairs({ "_ZnwmSt11align_val_t", "_ZnamSt11align_val_t", "_ZnwjSt11align_val_t",
    "_ZnajSt11align_val_t" }) do
    L[n] = new_aligned
end
for _, n in ipairs({ "_ZdlPv", "_ZdaPv", "_ZdlPvm", "_ZdaPvm", "_ZdlPvj", "_ZdaPvj",
    "_ZdlPvSt11align_val_t", "_ZdaPvSt11align_val_t", "_ZdlPvmSt11align_val_t",
    "_ZdlPvjSt11align_val_t", "_ZdlPvRKSt9nothrow_t", "_ZdaPvRKSt9nothrow_t" }) do
    L[n] = delete
end

-- strings and bytes ---------------------------------------------------------------------------------

L.memcpy = function(m)
    local d, s, n = m:arg(1), m:arg(2), m:arg(3)
    if n > 0 then
        m:write(d, m:read(s, n), n)
    end
    return d
end
L.memmove, L.__memcpy_chk = L.memcpy, L.memcpy
L.memset = function(m)
    local d, c, n = m:arg(1), m:arg(2) % 256, m:arg(3)
    if n > 0 then
        m:write(d, ffi.new("uint8_t[?]", n, c), n)
    end
    return d
end
L.__memset_chk = L.memset
L.memcmp = function(m)
    local a, b, n = m:read(m:arg(1), m:arg(3)), m:read(m:arg(2), m:arg(3)), m:arg(3)
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then
            return x - y
        end
    end
    return 0
end
L.bcmp = L.memcmp
L.memchr = function(m)
    local p, c, n = m:arg(1), m:arg(2) % 256, m:arg(3)
    local s = m:read(p, n)
    local i = s:find(string.char(c), 1, true)
    return i and p + i - 1 or 0
end
L.strlen = function(m) return #m:cstring(m:arg(1)) end
L.strnlen = function(m) return math.min(#m:cstring(m:arg(1), m:arg(2)), m:arg(2)) end
local function cmp(a, b)
    if a == b then return 0 end
    return a < b and -1 or 1
end
L.strcmp = function(m) return cmp(m:cstring(m:arg(1)), m:cstring(m:arg(2))) end
L.strncmp = function(m)
    local n = m:arg(3)
    return cmp(m:cstring(m:arg(1), n):sub(1, n), m:cstring(m:arg(2), n):sub(1, n))
end
L.strcoll = L.strcmp
L.strcasecmp = function(m) return cmp(m:cstring(m:arg(1)):lower(), m:cstring(m:arg(2)):lower()) end
L.strncasecmp = function(m)
    local n = m:arg(3)
    return cmp(m:cstring(m:arg(1), n):sub(1, n):lower(), m:cstring(m:arg(2), n):sub(1, n):lower())
end
L.strcpy = function(m)
    local s = m:cstring(m:arg(2))
    m:write(m:arg(1), s .. "\0", #s + 1)
    return m:arg(1)
end
L.strncpy = function(m)
    local n = m:arg(3)
    local s = m:cstring(m:arg(2), n):sub(1, n)
    s = s .. string.rep("\0", n - #s)
    m:write(m:arg(1), s, n)
    return m:arg(1)
end
L.strcat = function(m)
    local d = m:arg(1)
    local s = m:cstring(m:arg(2))
    m:write(d + #m:cstring(d), s .. "\0", #s + 1)
    return d
end
L.strchr = function(m)
    local p, c = m:arg(1), m:arg(2) % 256
    local s = m:cstring(p)
    if c == 0 then
        return p + #s
    end
    local i = s:find(string.char(c), 1, true)
    return i and p + i - 1 or 0
end
L.strrchr = function(m)
    local p, c = m:arg(1), m:arg(2) % 256
    local s = m:cstring(p)
    if c == 0 then
        return p + #s
    end
    local last
    for i = #s, 1, -1 do
        if s:byte(i) == c then
            last = i
            break
        end
    end
    return last and p + last - 1 or 0
end
L.strstr = function(m)
    local p = m:arg(1)
    local i = m:cstring(p):find(m:cstring(m:arg(2)), 1, true)
    return i and p + i - 1 or 0
end
L.strdup = function(m) return m:string(m:cstring(m:arg(1))) end

-- character classes (glibc, "C" locale) ----------------------------------------------------------------

local function c_space(c) return c == 32 or (c >= 9 and c <= 13) end
local function c_upper(c) return c >= 65 and c <= 90 end
local function c_lower(c) return c >= 97 and c <= 122 end
local function c_digit(c) return c >= 48 and c <= 57 end
local function c_alpha(c) return c_upper(c) or c_lower(c) end
local function c_xdigit(c) return c_digit(c) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102) end
local function c_print(c) return c >= 32 and c <= 126 end
local function c_cntrl(c) return (c >= 0 and c < 32) or c == 127 end
local function c_punct(c) return c_print(c) and c ~= 32 and not c_alpha(c) and not c_digit(c) end

-- the argument as glibc's ctype functions take it: an int (a char passed sign-extended)
local function int_arg(m)
    local v = m:arg(1) % 2 ^ 32
    if v >= 2 ^ 31 then
        v = v - 2 ^ 32
    end
    return v
end

L.isspace = function(m) return c_space(int_arg(m)) and 8192 or 0 end
L.isdigit = function(m) return c_digit(int_arg(m)) and 2048 or 0 end
L.isalpha = function(m) return c_alpha(int_arg(m)) and 1024 or 0 end
L.isalnum = function(m) local c = int_arg(m) return (c_alpha(c) or c_digit(c)) and 8 or 0 end
L.isupper = function(m) return c_upper(int_arg(m)) and 256 or 0 end
L.islower = function(m) return c_lower(int_arg(m)) and 512 or 0 end
L.isxdigit = function(m) return c_xdigit(int_arg(m)) and 4096 or 0 end
L.isprint = function(m) return c_print(int_arg(m)) and 16384 or 0 end
L.ispunct = function(m) return c_punct(int_arg(m)) and 4 or 0 end
L.iscntrl = function(m) return c_cntrl(int_arg(m)) and 2 or 0 end
local function tolower(c)
    if c_upper(c) then return c + 32 end
    if c >= -128 and c <= -2 then return c + 256 end
    return c
end
local function toupper(c)
    if c_lower(c) then return c - 32 end
    if c >= -128 and c <= -2 then return c + 256 end
    return c
end
L.tolower = function(m) return tolower(int_arg(m)) end
L.toupper = function(m) return toupper(int_arg(m)) end
-- wide: wint_t is unsigned 32 bits; a sign-extended char is >= 0xffffff80 and in no class
local UNICODE_SPACE = { [0x1680] = true, [0x2000] = true, [0x2001] = true, [0x2002] = true,
    [0x2003] = true, [0x2004] = true, [0x2005] = true, [0x2006] = true, [0x2008] = true,
    [0x2009] = true, [0x200a] = true, [0x2028] = true, [0x2029] = true, [0x205f] = true, [0x3000] = true }
local function wint(m) return m:arg(1) % 2 ^ 32 end
L.iswspace = function(m)
    local c = wint(m)
    return (c_space(c) or (m.locale_utf8 and UNICODE_SPACE[c])) and 1 or 0
end
L.iswdigit = function(m) return c_digit(wint(m)) and 1 or 0 end
L.iswalpha = function(m) local c = wint(m) return (c_alpha(c) or c >= 0xaa and c < 0xffffff80) and 1 or 0 end
L.iswalnum = function(m) local c = wint(m) return (c_alpha(c) or c_digit(c)) and 1 or 0 end
L.towlower = function(m) local c = wint(m) return c_upper(c) and c + 32 or c end
L.towupper = function(m) local c = wint(m) return c_lower(c) and c - 32 or c end

-- glibc's ctype tables, indexed -128..255 (the pointer points at index 0)
local tables = {}
local function ctype_table(m, kind)
    local t = tables[m]
    if not t then
        t = {}
        tables[m] = t
        local b = ffi.new("uint16_t[384]")
        local lo, up = ffi.new("int32_t[384]"), ffi.new("int32_t[384]")
        for c = -128, 255 do

            local f = 0
            if c >= 0 and c < 128 then
                if c_upper(c) then f = f + 0x100 end
                if c_lower(c) then f = f + 0x200 end
                if c_alpha(c) then f = f + 0x400 end
                if c_digit(c) then f = f + 0x800 end
                if c_xdigit(c) then f = f + 0x1000 end
                if c_space(c) then f = f + 0x2000 end
                if c_print(c) then f = f + 0x4000 end
                if c_print(c) and c ~= 32 then f = f + 0x8000 end
                if c == 32 or c == 9 then f = f + 0x1 end
                if c_cntrl(c) then f = f + 0x2 end
                if c_punct(c) then f = f + 0x4 end
                if c_alpha(c) or c_digit(c) then f = f + 0x8 end
            end
            b[c + 128] = f
            lo[c + 128] = c == -1 and -1 or tolower(c)
            up[c + 128] = c == -1 and -1 or toupper(c)

        end
        local ab = m:alloc(ffi.sizeof(b))
        m:write(ab, b, ffi.sizeof(b))
        local al = m:alloc(ffi.sizeof(lo))
        m:write(al, lo, ffi.sizeof(lo))
        local au = m:alloc(ffi.sizeof(up))
        m:write(au, up, ffi.sizeof(up))
        t.b, t.lower, t.upper = m:alloc(16), m:alloc(16), m:alloc(16)
        m:set_ptr(t.b, ab + 128 * 2)
        m:set_ptr(t.lower, al + 128 * 4)
        m:set_ptr(t.upper, au + 128 * 4)
    end
    return t[kind]
end
L.__ctype_b_loc = function(m) return ctype_table(m, "b") end
L.__ctype_tolower_loc = function(m) return ctype_table(m, "lower") end
L.__ctype_toupper_loc = function(m) return ctype_table(m, "upper") end

-- numbers ---------------------------------------------------------------------------------------------

L.atoi = function(m)
    local s = m:cstring(m:arg(1))
    local n = s:match("^%s*([%+%-]?%d+)")
    return n and tonumber(n) or 0
end
L.atol, L.atoll = L.atoi, L.atoi
local function strtol(m)
    local p = m:arg(1)
    local s = m:cstring(p)
    local base = m:arg(3)
    local lead, sign, digits
    if base == 16 or base == 0 then
        lead, sign, digits = s:match("^(%s*)([%+%-]?)0[xX](%x+)")
        if digits then
            base = 16
            lead = lead .. "00"
        end
    end
    if not digits then
        lead, sign, digits = s:match("^(%s*)([%+%-]?)(%d+)")
        base = (base == 0) and 10 or base
    end
    local endp = m:arg(2)
    if not digits then
        if endp ~= 0 then m:set_ptr(endp, p) end
        return 0
    end
    if endp ~= 0 then
        m:set_ptr(endp, p + #lead + #sign + #digits)
    end
    local v = tonumber(digits, base) or 0
    return sign == "-" and -v or v
end
L.strtol, L.strtoul, L.strtoll, L.strtoull = strtol, strtol, strtol, strtol
L.__isoc23_strtol, L.__isoc23_strtoul, L.__isoc23_strtoll, L.__isoc23_strtoull = strtol, strtol, strtol, strtol

-- floating point results go to xmm0 (x86-64) or st0 (i386)
local function return_double(m, v)
    if m.bits == 64 then
        local x = ffi.new("double[2]", v, 0)
        m.engine:set_reg_raw("xmm0", x)
    else
        -- an 80-bit extended value: mantissa with the explicit integer bit, then sign and exponent
        local f80 = ffi.new("uint8_t[10]")
        if v ~= 0 then
            local sign = v < 0 and 1 or 0
            local a = math.abs(v)
            local mant, exp = math.frexp(a) -- a = mant * 2^exp, 0.5 <= mant < 1
            local e = exp - 1 + 16383
            local q = mant * 2 -- 1 <= q < 2
            local mbits = ffi.cast("uint64_t", q * 2 ^ 52) * 2 ^ 11
            ffi.cast("uint64_t *", f80)[0] = mbits
            ffi.cast("uint16_t *", f80 + 8)[0] = e + sign * 32768
        end
        -- a value returned in st0 is pushed on the x87 stack: the import returns through a
        -- `fld` of it (machine.lua: m.fld_return)
        m:write(m.fld_scratch, f80, 10)
        return m:redirect(m.fld_return)
    end
    return "float"
end
local function strtod(m)
    local p = m:arg(1)
    local s = m:cstring(p)
    local lead, num = s:match("^(%s*)([%+%-]?%d*%.?%d*[eE]?[%+%-]?%d*)")
    local v = tonumber(num or "")
    if not v and num then
        -- the longest prefix that is a number
        for i = #num, 1, -1 do
            v = tonumber(num:sub(1, i))
            if v then
                num = num:sub(1, i)
                break
            end
        end
    end
    local endp = m:arg(2)
    if endp ~= 0 then
        m:set_ptr(endp, v and (p + #lead + #num) or p)
    end
    return return_double(m, v or 0)
end
L.strtod, L.strtof = strtod, strtod
L.atof = function(m)
    local s = m:cstring(m:arg(1))
    return return_double(m, tonumber(s:match("^%s*([%+%-]?%d*%.?%d*[eE]?[%+%-]?%d*)") or "") or 0)
end

-- C++ runtime -------------------------------------------------------------------------------------------

L.__cxa_guard_acquire = function(m)
    return m:u8(m:arg(1)) == 0 and 1 or 0
end
L.__cxa_guard_release = function(m) m:set_u8(m:arg(1), 1) end
L.__cxa_guard_abort = function() end
L.__cxa_atexit = function() return 0 end
L.atexit = L.__cxa_atexit
L.__cxa_finalize = function() end
L.__stack_chk_fail = function(m) return noreturn(m, "stack smashing detected") end
L.__cxa_pure_virtual = function(m) return noreturn(m, "pure virtual call") end
L.abort = function(m) return noreturn(m, "abort()") end
L.exit = function(m) return noreturn(m, "exit(" .. m:arg(1) .. ")") end
L._exit = L.exit
L.__assert_fail = function(m)
    return noreturn(m, "assertion failed: " .. m:cstring(m:arg(1)) .. " (" .. m:cstring(m:arg(2)) .. ")")
end
L.__cxa_allocate_exception = function(m) return m:alloc(m:arg(1) + 128) + 128 end
L.__cxa_free_exception = function() end
L.__cxa_throw = function(m)
    local tinfo = m:arg(2)
    local name = "?"
    local ok, s = pcall(function() return m:cstring(m:ptr(tinfo + m.word), 256) end)
    if ok then name = s end
    return noreturn(m, "C++ exception thrown: " .. name)
end
L.__cxa_rethrow = function(m) return noreturn(m, "C++ exception rethrown") end
L._Unwind_Resume = function(m) return noreturn(m, "C++ unwinding (_Unwind_Resume)") end
L.__cxa_begin_catch = function(m) return m:arg(1) end
L.__cxa_end_catch = function() end
L.__errno_location = function(m) return m.errno end
L.__tls_get_addr = function(m)
    -- tls_index { module, offset }: the executable's own block is module 1
    local ti = m:arg(1)
    return (m.tls_block or m.tp) + m:ptr(ti + m.word)
end

-- threads: one thread, nothing contends ---------------------------------------------------------------

for _, n in ipairs({ "pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_trylock",
    "pthread_mutex_init", "pthread_mutex_destroy", "pthread_mutexattr_init",
    "pthread_mutexattr_settype", "pthread_mutexattr_destroy", "pthread_rwlock_rdlock",
    "pthread_rwlock_wrlock", "pthread_rwlock_unlock", "pthread_rwlock_init",
    "pthread_rwlock_destroy", "pthread_cond_signal", "pthread_cond_broadcast",
    "pthread_cond_init", "pthread_cond_destroy", "pthread_spin_lock", "pthread_spin_unlock",
    "pthread_spin_init", "pthread_attr_init", "pthread_attr_destroy", "sched_yield" }) do
    L[n] = function() return 0 end
end
L.pthread_self = function() return 1 end
L.pthread_equal = function(m) return m:arg(1) == m:arg(2) and 1 or 0 end
L.pthread_once = function(m)
    local once, fn = m:arg(1), m:arg(2)
    if m:u32(once) ~= 0 then
        return 0
    end
    m:set_u32(once, 2)
    return m:redirect(fn)
end
local keys = {}
L.pthread_key_create = function(m)
    keys[m] = keys[m] or { n = 0 }
    local k = keys[m]
    k.n = k.n + 1
    m:set_u32(m:arg(1), k.n)
    return 0
end
L.pthread_getspecific = function(m)
    local k = keys[m]
    return k and k[m:arg(1)] or 0
end
L.pthread_setspecific = function(m)
    keys[m] = keys[m] or { n = 0 }
    keys[m][m:arg(1)] = m:arg(2)
    return 0
end
L.__libc_single_threaded = nil

-- the environment ---------------------------------------------------------------------------------------

L.getenv = function() return 0 end
L.secure_getenv = L.getenv
L.time = function(m)
    local t = 1700000000
    if m:arg(1) ~= 0 then m:set_ptr(m:arg(1), t) end
    return t
end
L.clock_gettime = function(m)
    m:set_ptr(m:arg(2), 1700000000)
    m:set_ptr(m:arg(2) + m.word, 0)
    return 0
end
L.gettimeofday = function(m)
    m:set_ptr(m:arg(1), 1700000000)
    m:set_ptr(m:arg(1) + m.word, 0)
    return 0
end
L.clock = function() return 0 end

-- output: kept in m.stdout
local function out(m, s)
    m.stdout[#m.stdout + 1] = s
    return #s
end
L.puts = function(m) return out(m, m:cstring(m:arg(1)) .. "\n") end
L.fputs = function(m) return out(m, m:cstring(m:arg(1))) end
L.fwrite = function(m)
    local n = m:arg(2) * m:arg(3)
    out(m, m:read(m:arg(1), n))
    return m:arg(3)
end
L.fflush = function() return 0 end

-- printf and its v- forms. The arguments come from a source: the call's own (integers in
-- registers then on the stack, doubles in xmm registers on x86-64), or a va_list (x86-64: a
-- { gp_offset, fp_offset, overflow_arg_area, reg_save_area } record; i386: a pointer into the
-- stack).
local function call_args(m, first)
    local i, fp = first, 0
    local src = {}
    function src.int(wide)
        local v
        if m.bits == 32 and wide then
            v = m:u32(m:sp() + 4 * i) + m:u32(m:sp() + 4 * (i + 1)) * 2 ^ 32
            i = i + 2
            return v
        end
        v = m:arg(i)
        i = i + 1
        return v
    end
    function src.double()
        if m.bits == 64 then
            local x = ffi.new("double[2]")
            m.engine:read_reg_raw("xmm" .. fp, x)
            fp = fp + 1
            return x[0]
        end
        local d = ffi.cast("const double *", m:read(m:sp() + 4 * i, 8))[0]
        i = i + 2
        return d
    end
    return src
end

local function va_args(m, va)
    local src = {}
    if m.bits == 64 then
        function src.int()
            local gp = m:u32(va)
            local v
            if gp < 48 then
                v = m:u64(m:u64(va + 16) + gp)
                m:set_u32(va, gp + 8)
            else
                local o = m:u64(va + 8)
                v = m:u64(o)
                m:set_u64(va + 8, o + 8)
            end
            return v
        end
        function src.double()
            local fpo = m:u32(va + 4)
            local at
            if fpo < 176 then
                at = m:u64(va + 16) + fpo
                m:set_u32(va + 4, fpo + 16)
            else
                at = m:u64(va + 8)
                m:set_u64(va + 8, at + 8)
            end
            return ffi.cast("const double *", m:read(at, 8))[0]
        end
    else
        local p = va
        function src.int(wide)
            local v = m:u32(p)
            if wide then
                v = v + m:u32(p + 4) * 2 ^ 32
                p = p + 4
            end
            p = p + 4
            return v
        end
        function src.double()
            local d = ffi.cast("const double *", m:read(p, 8))[0]
            p = p + 8
            return d
        end
    end
    return src
end

-- %d %i %u %x %X %o %s %c %p %f %g %e %% with h, l, ll, z, j, t, width and precision
local function format(m, fmt, src)
    if type(src) == "number" then
        src = call_args(m, src)
    end
    return (fmt:gsub("%%([%-%+ #0]*)(%*?%d*)%.?(%*?%d*)([hlLqzjt]*)([diuoxXscpfFgGeEaA%%])", function(flags, width, prec, len, conv)
        if conv == "%" then
            return "%"
        end
        if width == "*" then width = tostring(src.int() % 2 ^ 32) end
        if prec == "*" then prec = tostring(src.int() % 2 ^ 32) end
        local spec = "%" .. flags .. width .. (prec ~= "" and ("." .. prec) or "")
        if conv == "s" then
            return string.format(spec .. "s", m:cstring(src.int()))
        elseif conv == "c" then
            return string.char(src.int() % 256)
        elseif conv == "p" then
            return string.format("0x%x", src.int())
        elseif conv:find("[fFgGeEaA]") then
            local v = src.double()
            if conv == "F" then conv = "f" end
            if conv == "a" or conv == "A" then conv = "e" end
            return string.format(spec .. conv, v)
        end
        local wide = len == "ll" or len == "q" or len == "j" or (m.bits == 64 and (len == "l" or len == "z" or len == "t"))
        local v = src.int(wide and m.bits == 32)
        if not wide then
            v = v % 2 ^ 32
            if (conv == "d" or conv == "i") and v >= 2 ^ 31 then
                v = v - 2 ^ 32
            end
            if len == "h" then
                v = v % 65536
                if (conv == "d" or conv == "i") and v >= 32768 then v = v - 65536 end
            elseif len == "hh" then
                v = v % 256
            end
        elseif (conv == "d" or conv == "i") and v >= 2 ^ 63 then
            v = v - 2 ^ 64
        end
        if conv == "u" or conv == "i" then conv = "d" end
        return string.format(spec .. conv, v)
    end))
end

local function put(m, buf, n, s)
    if n > 0 then
        local w = s:sub(1, n - 1) .. "\0"
        m:write(buf, w, #w)
    end
    return #s
end

L.printf = function(m) return out(m, format(m, m:cstring(m:arg(1)), 2)) end
L.fprintf = function(m) return out(m, format(m, m:cstring(m:arg(2)), 3)) end
L.sprintf = function(m) local s = format(m, m:cstring(m:arg(2)), 3) return put(m, m:arg(1), #s + 1, s) end
L.snprintf = function(m) return put(m, m:arg(1), m:arg(2), format(m, m:cstring(m:arg(3)), 4)) end
L.__sprintf_chk = function(m) local s = format(m, m:cstring(m:arg(4)), 5) return put(m, m:arg(1), #s + 1, s) end
L.__snprintf_chk = function(m) return put(m, m:arg(1), m:arg(2), format(m, m:cstring(m:arg(5)), 6)) end
L.vprintf = function(m) return out(m, format(m, m:cstring(m:arg(1)), va_args(m, m:arg(2)))) end
L.vfprintf = function(m) return out(m, format(m, m:cstring(m:arg(2)), va_args(m, m:arg(3)))) end
L.vsprintf = function(m)
    local s = format(m, m:cstring(m:arg(2)), va_args(m, m:arg(3)))
    return put(m, m:arg(1), #s + 1, s)
end
L.vsnprintf = function(m)
    return put(m, m:arg(1), m:arg(2), format(m, m:cstring(m:arg(3)), va_args(m, m:arg(4))))
end
L.__vsnprintf_chk = function(m)
    return put(m, m:arg(1), m:arg(2), format(m, m:cstring(m:arg(5)), va_args(m, m:arg(6))))
end
L.__vsprintf_chk = function(m)
    local s = format(m, m:cstring(m:arg(4)), va_args(m, m:arg(5)))
    return put(m, m:arg(1), #s + 1, s)
end
L.__printf_chk = function(m) return out(m, format(m, m:cstring(m:arg(2)), 3)) end
L.__fprintf_chk = function(m) return out(m, format(m, m:cstring(m:arg(3)), 4)) end

hle.format = format
hle.return_double = return_double

-- data imports with a value ----------------------------------------------------------------------------

L.data = {}

require("oracle.hle_string").install(L)
require("oracle.hle_cowstring").install(L)
require("oracle.hle_tree").install(L)
require("oracle.gamelog").install_imports(L)

-- tbb: one thread
L._ZN3tbb8internal16thread_get_id_v3Ev = function() return 1 end
L._ZN3tbb8internal23allocate_via_handler_v3Ej = function(m) return m:alloc(m:arg(1)) end
L._ZN3tbb8internal23allocate_via_handler_v3Em = L._ZN3tbb8internal23allocate_via_handler_v3Ej
L._ZN3tbb8internal25deallocate_via_handler_v3EPv = function(m) m:free(m:arg(1)) end

-- iostreams are never used: their static initializer object does nothing
L._ZNSt8ios_base4InitC1Ev = function() end
L._ZNSt8ios_base4InitD1Ev = function() end

-- libm: the argument in xmm0 (x86-64) or on the stack (i386), the result in xmm0 or st0
local function float_arg(m, double)
    if m.bits == 64 then
        local x = ffi.new("uint8_t[16]")
        m.engine:read_reg_raw("xmm0", x)
        return double and ffi.cast("double *", x)[0] or ffi.cast("float *", x)[0]
    end
    local s = m:read(m:sp() + 4, double and 8 or 4)
    return double and ffi.cast("const double *", s)[0] or ffi.cast("const float *", s)[0]
end
local function return_float(m, v, double)
    if m.bits == 64 then
        local x = ffi.new("uint8_t[16]")
        if double then ffi.cast("double *", x)[0] = v else ffi.cast("float *", x)[0] = v end
        m.engine:set_reg_raw("xmm0", x)
        return "float"
    end
    return return_double(m, v)
end
for name, f in pairs({ fabs = math.abs, exp = math.exp, log = math.log, sin = math.sin, cos = math.cos,
    round = function(x) return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5) end }) do
    L[name] = function(m) return return_float(m, f(float_arg(m, true)), true) end
    L[name .. "f"] = function(m) return return_float(m, f(float_arg(m, false)), false) end
end
L._ZN3tbb8internal15NFS_AllocateEjjPv = function(m) return m:alloc(m:arg(1) * m:arg(2), 128) end
L._ZN3tbb8internal15NFS_AllocateEmmPv = L._ZN3tbb8internal15NFS_AllocateEjjPv
L._ZN3tbb8internal8NFS_FreeEPv = function(m) m:free(m:arg(1)) end
L._ZN3tbb8internal18cache_aligned_allocateEj = function(m) return m:alloc(m:arg(1), 128) end

-- native imports: the hottest functions as x86 code that runs inside the emulator, with no Lua
-- callback (building the static lexer's token table calls memcmp 28 million times). Assembled
-- with GNU as from the source below; same results as the Lua versions above (tolower and toupper
-- with glibc's -128..-2 -> c + 256).
--
--   memcpy:  rep movsb                       memmove: backwards (std) when the ranges overlap
--   memset:  rep stosb                       memcmp:  bytewise, returns the difference
--   strlen, strcmp: bytewise                 tolower, toupper: A-Z / a-z, and -128..-2 + 256
hle.native = {
    [64] = {
        code = "4889f84889d1f3a4c34889f84889d14839f776184c8d04164c39c7730f488d7416ff488d7c17fffdf3a4fcc3" ..
            "f3a4c34989f889f04889d1f3aa4c89c0c331c04885d274150fb6070fb60e29c8750b48ffc748ffc648ffca75" ..
            "ebc34889f8803800740548ffc0ebf64829f8c30fb6070fb60e29c8750c85c9740848ffc748ffc6ebeac389f8" ..
            "8d4fbf83f919770483c020c38d8f8000000083f97e77050500010000c389f88d4f9f83f919770483e820c38d" ..
            "8f8000000083f97e77050500010000c3" ..
            -- ceilf, ceil, floorf, floor (SSE4.1 roundss/roundsd), sqrtf, sqrt
            "660f3a0ac00ac3660f3a0bc00ac3660f3a0ac009c3660f3a0bc009c3f30f51c0c3f20f51c0c3",
        entries = { memcpy = 0x0, memmove = 0x9, memset = 0x2f, memcmp = 0x3d, strlen = 0x5a,
            strcmp = 0x6b, tolower = 0x82, toupper = 0xa1, ceilf = 0xc0, ceil = 0xc7, floorf = 0xce,
            floor = 0xd5, sqrtf = 0xdc, sqrt = 0xe1 },
    },
    [32] = {
        code = "57568b7c240c8b7424108b4c241489f8f3a45e5fc357568b7c240c8b7424108b4c241489f839f776168d140e" ..
            "39d7730f8d740eff8d7c0ffffdf3a4fc5e5fc3f3a45e5fc3578b7c24088b44240c8b4c241089faf3aa89d05f" ..
            "c356578b74240c8b7c24108b4c241431c085c9740f0fb6060fb61729d0750546474975f15f5ec38b542404" ..
            "89d0803800740340ebf829d0c3568b5424088b74240c0fb6020fb60e29c8750885c974044246ebee5ec38b44" ..
            "24048d48bf83f919770483c020c38d888000000083f97e77050500010000c38b4424048d489f83f9197704" ..
            "83e820c38d888000000083f97e77050500010000c3" ..
            -- ceilf, ceil, floorf, floor (x87 frndint with the rounding mode set), sqrtf, sqrt
            "d944240466b80008eb1cdd44240466b80008eb12d944240466b80004eb08dd44240466b8000483ec08d93c24" ..
            "668b14246681e2fff36609c26689542402d96c2402d9fcd92c2483c408c3d9442404d9fac3dd442404d9fac3",
        entries = { memcpy = 0x0, memmove = 0x15, memset = 0x44, memcmp = 0x59, strlen = 0x7f,
            strcmp = 0x90, tolower = 0xad, toupper = 0xce, ceilf = 0xef, ceil = 0xf9, floorf = 0x103,
            floor = 0x10d, sqrtf = 0x139, sqrt = 0x140 },
    },
    -- other names for the same functions
    alias = { __memcpy_chk = "memcpy", __memmove_chk = "memmove", __memset_chk = "memset",
        bcmp = "memcmp" },
}

return hle
