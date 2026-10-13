-- oracle/hle_msvc.lua : the Windows API a Windows build of the game calls, in Lua (as oracle/hle.lua
-- is for Linux). The builds link the C and C++ runtimes statically (no ucrtbase, vcruntime or
-- msvcp imports): malloc, memcpy, iswspace, tolower, the thread-safe statics, std::string are the
-- game's own code and run in the emulator with Microsoft's behaviour. What they and the game call
-- from Windows is here: the heap, critical sections, SRW locks, condition variables, TLS and FLS,
-- the time, the processor, the code pages, the character types of GetStringTypeW, and
-- RaiseException (a C++ exception: a fault naming its type).
--
-- On i386 the Windows API is __stdcall: arity[name] is the count of arguments each function
-- removes from the stack (machine.lua pops them after the function).

local ffi = require("ffi")
local bit = require("bit")

local hle_msvc = {}
local W = {}
hle_msvc.windows = W
local A = {}  -- arity (i386: arguments of 4 bytes)
W.arity = A

local function noreturn(m, kind)
    m.fault = m.fault or { kind = kind, pc = m:ptr(m:sp()) }
    m.engine:stop()
    return "noreturn"
end

local function def(name, n, f)
    W[name] = f
    A[name] = n
end

local function zero() return 0 end
local function one() return 1 end

-- the heap -----------------------------------------------------------------------------------------

def("GetProcessHeap", 0, function(m) return m.process_heap end)
def("HeapCreate", 3, function(m) return m.process_heap + 0x100 end)
def("HeapDestroy", 1, one)
def("HeapAlloc", 3, function(m) return m:alloc(math.max(m:arg(3), 1)) end)
def("HeapFree", 3, function(m) m:free(m:arg(3)) return 1 end)
def("HeapSize", 3, function(m) return m:block_size(m:arg(3)) or 2 ^ (m.bits) - 1 end)
def("HeapReAlloc", 4, function(m)
    local p, n = m:arg(3), m:arg(4)
    local a = m:alloc(math.max(n, 1))
    if p ~= 0 then
        local k = math.min(m:block_size(p) or 0, n)
        if k > 0 then
            m:write(a, m:read(p, k), k)
        end
        m:free(p)
    end
    return a
end)
def("HeapValidate", 3, one)
def("HeapSetInformation", 4, one)
def("HeapQueryInformation", 5, zero)
def("VirtualAlloc", 4, function(m)
    local size = m:arg(2)
    return m:alloc(size + (4096 - size % 4096) % 4096, 4096)
end)
def("VirtualFree", 3, function(m) return 1 end)
def("VirtualProtect", 4, function(m)
    if m:arg(4) ~= 0 then m:set_u32(m:arg(4), 4) end
    return 1
end)
def("VirtualQuery", 3, zero)
def("LocalAlloc", 2, function(m) return m:alloc(math.max(m:arg(2), 1)) end)
def("LocalFree", 1, function(m) m:free(m:arg(1)) return 0 end)
def("GlobalAlloc", 2, function(m) return m:alloc(math.max(m:arg(2), 1)) end)
def("GlobalFree", 1, function(m) m:free(m:arg(1)) return 0 end)
def("GlobalLock", 1, function(m) return m:arg(1) end)
def("GlobalUnlock", 1, one)

-- threads: one thread, nothing contends ---------------------------------------------------------------

for name, n in pairs({ EnterCriticalSection = 1, LeaveCriticalSection = 1, DeleteCriticalSection = 1,
    AcquireSRWLockExclusive = 1, AcquireSRWLockShared = 1, ReleaseSRWLockExclusive = 1,
    ReleaseSRWLockShared = 1, InitializeSRWLock = 1, InitializeConditionVariable = 1,
    WakeAllConditionVariable = 1, WakeConditionVariable = 1, InitializeSListHead = 1,
    InitializeCriticalSection = 1 }) do
    def(name, n, function() return 0 end)
end
def("InitializeCriticalSectionAndSpinCount", 2, one)
def("InitializeCriticalSectionEx", 3, one)
def("TryEnterCriticalSection", 1, one)
def("TryAcquireSRWLockExclusive", 1, one)
def("TryAcquireSRWLockShared", 1, one)
def("SleepConditionVariableSRW", 4, function(m) return noreturn(m, "SleepConditionVariableSRW: a wait no other thread can end") end)
def("SleepConditionVariableCS", 3, function(m) return noreturn(m, "SleepConditionVariableCS: a wait no other thread can end") end)
def("Sleep", 1, zero)
def("SleepEx", 2, zero)
def("SwitchToThread", 0, zero)
def("GetCurrentThreadId", 0, function() return 0x1004 end)
def("GetCurrentProcessId", 0, function() return 0x1000 end)
def("GetCurrentThread", 0, function(m) return m.bits == 64 and 2 ^ 64 - 2 or 0xfffffffe end)
def("GetCurrentProcess", 0, function(m) return m.bits == 64 and 2 ^ 64 - 1 or 0xffffffff end)
def("GetThreadId", 1, function() return 0x1004 end)
def("SetThreadPriority", 2, one)
def("GetThreadPriority", 1, zero)
def("SetThreadAffinityMask", 2, one)
def("SetThreadDescription", 2, zero)
def("WaitForSingleObject", 2, zero)
def("WaitForSingleObjectEx", 3, zero)
def("WaitForMultipleObjects", 4, zero)
def("CreateEventW", 4, function() return 0x100 end)
def("CreateEventA", 4, function() return 0x100 end)
def("CreateSemaphoreW", 4, function() return 0x104 end)
def("SetEvent", 1, one)
def("ResetEvent", 1, one)
def("ReleaseSemaphore", 3, one)
def("CloseHandle", 1, one)
def("DuplicateHandle", 7, one)

-- one-time initialization: the callback is called now (InitOnceExecuteOnce), or the caller is
-- told to do it (InitOnceBeginInitialize)
def("InitOnceInitialize", 1, function(m) m:set_ptr(m:arg(1), 0) return 0 end)
def("InitOnceBeginInitialize", 4, function(m)
    local once, pending = m:arg(1), m:arg(3)
    local done = m:ptr(once) == 2
    if pending ~= 0 then m:set_u32(pending, done and 0 or 1) end
    if done and m:arg(4) ~= 0 then m:set_ptr(m:arg(4), 0) end
    return 1
end)
def("InitOnceComplete", 3, function(m) m:set_ptr(m:arg(1), 2) return 1 end)
def("InitOnceExecuteOnce", 4, function(m)
    local once, fn, param, ctx = m:arg(1), m:arg(2), m:arg(3), m:arg(4)
    if m:ptr(once) ~= 2 then
        m:set_ptr(once, 2)
        return m:call(fn, once, param, ctx) ~= 0 and 1 or 0
    end
    return 1
end)

-- thread-local and fiber-local storage: slots of the one thread
local function slots(m)
    m.tls_slots = m.tls_slots or { n = 0, values = {} }
    return m.tls_slots
end
local function slot_alloc(m)
    local s = slots(m)
    s.n = s.n + 1
    return s.n
end
def("TlsAlloc", 0, slot_alloc)
def("TlsFree", 1, one)
def("TlsGetValue", 1, function(m) return slots(m).values[m:arg32(1)] or 0 end)
def("TlsSetValue", 2, function(m) slots(m).values[m:arg32(1)] = m:arg(2) return 1 end)
def("FlsAlloc", 1, slot_alloc)
def("FlsFree", 1, one)
def("FlsGetValue", 1, function(m) return slots(m).values[m:arg32(1)] or 0 end)
def("FlsSetValue", 2, function(m) slots(m).values[m:arg32(1)] = m:arg(2) return 1 end)

-- errors
def("GetLastError", 0, function(m) return m.last_error or 0 end)
def("SetLastError", 1, function(m) m.last_error = m:arg32(1) return 0 end)
def("SetErrorMode", 1, zero)
def("SetUnhandledExceptionFilter", 1, zero)
def("UnhandledExceptionFilter", 1, zero)
def("IsDebuggerPresent", 0, zero)
def("OutputDebugStringA", 1, function(m) m.stdout[#m.stdout + 1] = m:cstring(m:arg(1)) return 0 end)
def("OutputDebugStringW", 1, zero)
def("TerminateProcess", 2, function(m) return noreturn(m, "TerminateProcess") end)
def("ExitProcess", 1, function(m) return noreturn(m, "ExitProcess(" .. m:arg32(1) .. ")") end)
def("FatalExit", 1, function(m) return noreturn(m, "FatalExit") end)

-- a C++ exception (_CxxThrowException raises 0xE06D7363 with the object and its ThrowInfo): a
-- fault that names the type thrown, from the ThrowInfo's first catchable type (x86-64: RVAs from
-- the image base, the fourth parameter)
def("RaiseException", 4, function(m)
    local code, nargs, args = m:arg32(1), m:arg32(3), m:arg(4)
    if code ~= 0xe06d7363 or nargs < 3 or args == 0 then
        return noreturn(m, string.format("exception 0x%08x raised", code))
    end
    local w = m.word
    local ok, name = pcall(function()
        local info = m:ptr(args + 2 * w)
        local base = nargs >= 4 and m:ptr(args + 3 * w) or 0
        local function ref(a)
            if m.bits == 64 then return base + m:u32(a) end
            return m:u32(a)
        end
        local cta = ref(info + 12)
        local ct = ref(cta + 4)
        local td = ref(ct + 4)
        return m:cstring(td + 2 * w, 256)
    end)
    local text = ok and name or "?"
    -- std::exception's what(): the object's second word on MSVC (a pointer to the message)
    local ok2, what = pcall(function() return m:cstring(m:ptr(m:ptr(args + w) + w), 256) end)
    if ok2 and what ~= "" and what:match("^[%g ]+$") then
        text = text .. ": " .. what
    end
    return noreturn(m, "C++ exception thrown: " .. text)
end)
def("RtlCaptureContext", 1, zero)
def("RtlLookupFunctionEntry", 3, zero)
def("RtlCaptureStackBackTrace", 4, zero)
def("RtlPcToFileHeader", 2, function(m) m:set_ptr(m:arg(2), m.base) return m.base end)

-- pointers, modules ----------------------------------------------------------------------------------

def("EncodePointer", 1, function(m) return m:arg(1) end)
def("DecodePointer", 1, function(m) return m:arg(1) end)
local MODULE = 0x7ff10000
def("GetModuleHandleW", 1, function(m) return m:arg(1) == 0 and m.base or MODULE end)
def("GetModuleHandleA", 1, function(m) return m:arg(1) == 0 and m.base or MODULE end)
def("GetModuleHandleExW", 3, function(m)
    if m:arg(3) ~= 0 then m:set_ptr(m:arg(3), m.base) end
    return 1
end)
def("LoadLibraryW", 1, function() return MODULE end)
def("LoadLibraryA", 1, function() return MODULE end)
def("LoadLibraryExW", 3, function() return MODULE end)
def("LoadLibraryExA", 3, function() return MODULE end)
def("FreeLibrary", 1, one)
-- GetProcAddress: a stub for a function implemented here, else none (the caller's fallback)
def("GetProcAddress", 2, function(m)
    local p = m:arg(2)
    if p < 0x10000 then return 0 end
    local name = m:cstring(p, 256)
    if not W[name] then
        m.missing_procs = m.missing_procs or {}
        m.missing_procs[name] = true
        return 0
    end
    local s = m:stub(name, m.bits == 32 and { kind = "stdcall", stdcall_import = true } or nil)
    return s
end)
def("GetModuleFileNameW", 3, function(m)
    local name = "C:\\stellaris\\stellaris.exe"
    local buf, n = m:arg(2), m:arg32(3)
    local s = name:gsub(".", "%0\0") .. "\0\0"
    m:write(buf, s:sub(1, 2 * n), math.min(#s, 2 * n))
    return #name
end)
def("GetModuleFileNameA", 3, function(m)
    local name = "C:\\stellaris\\stellaris.exe"
    local buf, n = m:arg(2), m:arg32(3)
    local s = (name .. "\0"):sub(1, n)
    m:write(buf, s, #s)
    return #name
end)

-- the processor, the time -----------------------------------------------------------------------------

-- PF_XMMI64_INSTRUCTIONS_AVAILABLE (10, SSE2) and the like: the emulated CPU is a Haswell without
-- AVX in unicorn; say yes to SSE2/SSE3, no to the rest
local FEATURES = { [6] = true, [10] = true, [13] = true }
def("IsProcessorFeaturePresent", 1, function(m) return FEATURES[m:arg32(1)] and 1 or 0 end)
def("QueryPerformanceCounter", 1, function(m)
    m.qpc = (m.qpc or 1000000) + 1000
    m:set_u64(m:arg(1), m.qpc)
    return 1
end)
def("QueryPerformanceFrequency", 1, function(m) m:set_u64(m:arg(1), 10000000) return 1 end)
def("GetTickCount", 0, function() return 1000000 end)
def("GetTickCount64", 0, function() return 1000000 end)
def("GetSystemTimeAsFileTime", 1, function(m) m:set_u64(m:arg(1), 133000000000000000) return 0 end)
def("GetSystemTimePreciseAsFileTime", 1, function(m) m:set_u64(m:arg(1), 133000000000000000) return 0 end)
def("GetSystemInfo", 1, function(m)
    local a = m:arg(1)
    m:write(a, string.rep("\0", 48), 48)
    if m.bits == 64 then
        m:set_u32(a + 4, 4096)          -- dwPageSize
        m:set_u64(a + 8, 0x10000)       -- lpMinimumApplicationAddress
        m:set_u64(a + 16, 0x7ffeffff)
        m:set_u64(a + 24, 1)            -- dwActiveProcessorMask
        m:set_u32(a + 32, 1)            -- dwNumberOfProcessors
        m:set_u32(a + 40, 65536)        -- dwAllocationGranularity
    else
        m:set_u32(a + 4, 4096)
        m:set_u32(a + 8, 0x10000)
        m:set_u32(a + 12, 0x7ffeffff)
        m:set_u32(a + 16, 1)
        m:set_u32(a + 20, 1)
        m:set_u32(a + 28, 65536)
    end
    return 0
end)
W.GetNativeSystemInfo = W.GetSystemInfo
A.GetNativeSystemInfo = 1

-- the process: no window, no console, no standard handles, no environment
def("GetStartupInfoW", 1, function(m)
    local size = m.bits == 64 and 104 or 68
    m:write(m:arg(1), string.rep("\0", size), size)
    m:set_u32(m:arg(1), size)
    return 0
end)
W.GetStartupInfoA, A.GetStartupInfoA = W.GetStartupInfoW, 1
def("GetStdHandle", 1, function(m) return m.bits == 64 and 2 ^ 64 - 1 or 0xffffffff end)  -- INVALID_HANDLE_VALUE
def("SetStdHandle", 2, one)
def("GetFileType", 1, zero)  -- FILE_TYPE_UNKNOWN
def("GetConsoleMode", 2, zero)
def("GetConsoleOutputCP", 0, function() return 437 end)
def("SetConsoleCtrlHandler", 2, one)
def("GetEnvironmentStringsW", 0, function(m)
    m.env_w = m.env_w or m:string("\0\0\0")
    return m.env_w
end)
def("FreeEnvironmentStringsW", 1, one)
def("SetThreadExecutionState", 1, zero)

-- the environment: none
def("GetEnvironmentVariableA", 3, zero)
def("GetEnvironmentVariableW", 3, zero)
def("SetEnvironmentVariableA", 2, one)
def("SetEnvironmentVariableW", 2, one)
def("GetCommandLineA", 0, function(m) m.cmdline_a = m.cmdline_a or m:string("stellaris.exe") return m.cmdline_a end)
def("GetCommandLineW", 0, function(m) m.cmdline_w = m.cmdline_w or m:string(("stellaris.exe"):gsub(".", "%0\0") .. "\0") return m.cmdline_w end)

-- code pages and character types ---------------------------------------------------------------------

def("GetACP", 0, function() return 1252 end)
def("GetOEMCP", 0, function() return 437 end)
def("IsValidCodePage", 1, one)
def("GetCPInfo", 2, function(m)
    -- MaxCharSize 1, DefaultChar "?", no lead bytes (1252)
    local a = m:arg(2)
    m:write(a, string.rep("\0", 20), 20)
    m:set_u32(a, 1)
    m:set_u8(a + 4, 63)
    return 1
end)

-- MultiByteToWideChar / WideCharToMultiByte: UTF-8 (65001), Windows-1252 (the ANSI code page
-- here: GetACP), else bytes as code points (Latin-1)
local CHARS = require("oracle.hle_msvc_ctype")
local FROM1252 = {}
for b, u in pairs(CHARS.cp1252) do FROM1252[u] = b end
local function utf8_decode(s)
    local out, i = {}, 1
    while i <= #s do
        local c = s:byte(i)
        local cp, n = c, 1
        if c >= 0xf0 and c < 0xf8 then cp, n = c % 8, 4
        elseif c >= 0xe0 then cp, n = c % 16, 3
        elseif c >= 0xc0 then cp, n = c % 32, 2
        elseif c >= 0x80 then cp, n = 0xfffd, 1 end
        for k = 1, n - 1 do
            local b = s:byte(i + k)
            if not b or b < 0x80 or b >= 0xc0 then cp, n = 0xfffd, k break end
            cp = cp * 64 + b % 64
        end
        out[#out + 1] = cp
        i = i + n
    end
    return out
end
def("MultiByteToWideChar", 6, function(m)
    local cp, src, n, dst, cap = m:arg32(1), m:arg(3), m:sarg32(4), m:arg(5), m:sarg32(6)
    local s = n < 0 and (m:cstring(src) .. "\0") or m:read(src, n)
    local cps
    if cp == 65001 then
        cps = utf8_decode(s)
    else
        cps = { s:byte(1, -1) }
        if cp == 1252 or cp == 0 then
            for i, b in ipairs(cps) do cps[i] = CHARS.cp1252[b] or b end
        end
    end
    local units = {}
    for _, c in ipairs(cps) do
        if c >= 0x10000 then
            c = c - 0x10000
            units[#units + 1] = 0xd800 + math.floor(c / 1024)
            units[#units + 1] = 0xdc00 + c % 1024
        else
            units[#units + 1] = c
        end
    end
    if cap == 0 then return #units end
    local k = math.min(#units, cap)
    local buf = ffi.new("uint16_t[?]", math.max(k, 1))
    for i = 1, k do buf[i - 1] = units[i] end
    if k > 0 then m:write(dst, buf, 2 * k) end
    return k
end)
def("WideCharToMultiByte", 8, function(m)
    local cp, src, n, dst, cap = m:arg32(1), m:arg(3), m:sarg32(4), m:arg(5), m:sarg32(6)
    local units = {}
    local i = 0
    while true do
        if n >= 0 and i >= n then break end
        local u = m:u16(src + 2 * i)
        units[#units + 1] = u
        i = i + 1
        if n < 0 and u == 0 then break end
    end
    local out = {}
    local k = 1
    while k <= #units do
        local c = units[k]
        if c >= 0xd800 and c < 0xdc00 and units[k + 1] and units[k + 1] >= 0xdc00 and units[k + 1] < 0xe000 then
            c = 0x10000 + (c - 0xd800) * 1024 + (units[k + 1] - 0xdc00)
            k = k + 1
        end
        if cp == 65001 then
            if c < 0x80 then out[#out + 1] = string.char(c)
            elseif c < 0x800 then out[#out + 1] = string.char(0xc0 + math.floor(c / 64), 0x80 + c % 64)
            elseif c < 0x10000 then out[#out + 1] = string.char(0xe0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
            else out[#out + 1] = string.char(0xf0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
        else
            if cp == 1252 or cp == 0 then c = FROM1252[c] or (c >= 0x80 and c < 0xa0 and 63) or c end
            out[#out + 1] = string.char(c < 256 and c or 63)
        end
        k = k + 1
    end
    local s = table.concat(out)
    if cap == 0 then return #s end
    s = s:sub(1, cap)
    if #s > 0 then m:write(dst, s, #s) end
    return #s
end)

-- GetStringTypeW(CT_CTYPE1): the character type bits of each UTF-16 unit, as Windows gives them
-- (measured on Windows 11 for U+0000..U+00FF and U+FF00..U+FFFF, the units a char or a
-- sign-extended char can be; elsewhere an approximation that has never been reached)
local CTYPE1 = CHARS.ctype1
def("GetStringTypeW", 4, function(m)
    local kind, src, n, out = m:arg32(1), m:arg(2), m:sarg32(3), m:arg(4)
    if kind ~= 1 then
        return noreturn(m, "GetStringTypeW: info type " .. kind .. " not implemented")
    end
    if n < 0 then
        n = 0
        while m:u16(src + 2 * n) ~= 0 do n = n + 1 end
        n = n + 1
    end
    for i = 0, n - 1 do
        local c = m:u16(src + 2 * i)
        local t = CTYPE1(c)
        if t == nil then
            return noreturn(m, string.format("GetStringTypeW: U+%04X has no measured type", c))
        end
        ffi.cast("uint16_t *", m.buf8)[0] = t
        m.engine:write(out + 2 * i, m.buf8, 2)
    end
    return 1
end)
def("GetStringTypeA", 5, function(m) return noreturn(m, "GetStringTypeA not implemented") end)

-- LCMapStringW / LCMapStringEx: lower and upper case as Windows maps them (en-US); nothing else
local LCMAP_LOWERCASE, LCMAP_UPPERCASE = 0x100, 0x200
local function lcmap(m, flags, src, n, dst, cap)
    local map
    if bit.band(flags, LCMAP_LOWERCASE) ~= 0 then map = CHARS.lower
    elseif bit.band(flags, LCMAP_UPPERCASE) ~= 0 then map = CHARS.upper
    else return noreturn(m, string.format("LCMapString: flags 0x%x not implemented", flags)) end
    if n < 0 then
        n = 0
        while m:u16(src + 2 * n) ~= 0 do n = n + 1 end
        n = n + 1
    end
    if cap == 0 then return n end
    local k = math.min(n, cap)
    for i = 0, k - 1 do
        local c = m:u16(src + 2 * i)
        ffi.cast("uint16_t *", m.buf8)[0] = map[c] or c
        m.engine:write(dst + 2 * i, m.buf8, 2)
    end
    return k
end
def("LCMapStringW", 6, function(m)
    return lcmap(m, m:arg32(2), m:arg(3), m:sarg32(4), m:arg(5), m:sarg32(6))
end)
def("LCMapStringEx", 9, function(m)
    return lcmap(m, m:arg32(2), m:arg(3), m:sarg32(4), m:arg(5), m:sarg32(6))
end)

return hle_msvc
