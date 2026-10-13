-- oracle/gamelog.lua : the game's log, captured. CLogger::Log(file, line, level) gives a
-- CLogStream (an ostringstream) that the caller writes to with << and that writes the message
-- when it is destroyed. Here the stream is a Lua buffer: the game's CLogStream functions are
-- replaced (machine.lua: m:replace), and the libstdc++ ostream inserters the game calls on it
-- append to it. Every message ends in m.log:
--
--   m.log[i] = { file = "...", line = n, level = n, text = "..." }
--
--   require("oracle.gamelog").install(m)   -- before the game's code runs

local gamelog = {}

local function stream(m, address)
    m.streams = m.streams or {}
    local s = m.streams[address]
    if not s then
        s = { parts = {} }
        m.streams[address] = s
    end
    return s
end

local function append(m, address, text)
    local s = stream(m, address)
    s.parts[#s.parts + 1] = text
    return address
end

local function open(m, address, file, line, level)
    m.streams = m.streams or {}
    m.streams[address] = { parts = {}, file = file ~= 0 and m:cstring(file) or nil, line = line,
        level = level }
end

local function close(m, address)
    local s = m.streams and m.streams[address]
    if s then
        m.log = m.log or {}
        m.log[#m.log + 1] = { file = s.file, line = s.line, level = s.level, text = table.concat(s.parts) }
        m.streams[address] = nil
    end
end

local function signed32(v)
    v = v % 2 ^ 32
    return v >= 2 ^ 31 and v - 2 ^ 32 or v
end

-- the text of a CString, through the game's own CString::GetTCharPtr() (a nested call; every
-- version has it, and the layouts differ: an old ABI std::string, a C++11 one, 4.x's own with the
-- characters at +0x10)
local function cstring_text(m, cs)
    if m.windows then
        return gamelog.msvc_string(m, cs)
    end
    local ok, s = pcall(function()
        local get = m:has("_ZNK7CString11GetTCharPtrEv")
        return m:cstring(get and m:call(get, cs) or m:ptr(cs), 4096)
    end)
    return ok and s or "<CString>"
end

-- a logger's Log(int level, CString const& file, int line, CString const& text): the messages that
-- do not go through a CLogStream (the reader's errors)
local function logger_log(m)
    m.log = m.log or {}
    m.log[#m.log + 1] = { level = signed32(m:arg(2)), file = cstring_text(m, m:arg(3)),
        line = signed32(m:arg(4)), text = cstring_text(m, m:arg(5)) }
end

-- the game's own functions
local GAME = {
    -- CLogger::Log(char const* file, unsigned line, int level) -> CLogStream (returned through a
    -- hidden pointer, the first argument)
    _ZN7CLogger3LogEPKcji = function(m)
        local out = m:arg(1)
        open(m, out, m:arg(3), m:arg(4), signed32(m:arg(5)))
        m:callee_pops(4)
        return out
    end,
    -- CLogStream(CLogger*, char const* file, unsigned line, int level)
    _ZN10CLogStreamC1EP7CLoggerPKcji = function(m) open(m, m:arg(1), m:arg(3), m:arg(4), signed32(m:arg(5))) end,
    _ZN10CLogStreamC2EP7CLoggerPKcji = function(m) open(m, m:arg(1), m:arg(3), m:arg(4), signed32(m:arg(5))) end,
    _ZN10CLogStreamC1ERKS_ = function(m)
        local s = stream(m, m:arg(2))
        m.streams[m:arg(1)] = { parts = { table.concat(s.parts) }, file = s.file, line = s.line, level = s.level }
    end,
    _ZN10CLogStreamD0Ev = function(m) close(m, m:arg(1)) end,
    _ZN10CLogStreamD1Ev = function(m) close(m, m:arg(1)) end,
    _ZN10CLogStreamD2Ev = function(m) close(m, m:arg(1)) end,
}
GAME._ZN10CLogStreamC2ERKS_ = GAME._ZN10CLogStreamC1ERKS_
-- the loggers: the null logger InitGame would make, the file logger, the filter
GAME._ZN11CNullLogger3LogEiRK7CStringiS2_ = logger_log
GAME._ZN11CFileLogger3LogEiRK7CStringiS2_ = logger_log
GAME._ZN13CFilterLogger3LogEiRK7CStringiS2_ = logger_log
-- CLogStream::operator<< (the C++11 ABI builds tag them [abi:cxx11]): returns the stream
for _, tag in ipairs({ "", "B5cxx11" }) do
    GAME["_ZN10CLogStreamls" .. tag .. "EPKc"] = function(m) return append(m, m:arg(1), m:cstring(m:arg(2))) end
    GAME["_ZN10CLogStreamls" .. tag .. "EPc"] = GAME["_ZN10CLogStreamls" .. tag .. "EPKc"]
    GAME["_ZN10CLogStreamls" .. tag .. "Ei"] = function(m) return append(m, m:arg(1), tostring(signed32(m:arg(2)))) end
    GAME["_ZN10CLogStreamls" .. tag .. "Ej"] = function(m) return append(m, m:arg(1), tostring(m:arg(2) % 2 ^ 32)) end
    GAME["_ZN10CLogStreamls" .. tag .. "Ef"] = function(m) return append(m, m:arg(1), "<float>") end
    GAME["_ZN10CLogStreamls" .. tag .. "ERK7CString"] = function(m)
        return append(m, m:arg(1), cstring_text(m, m:arg(2)))
    end
end
-- operator<<(std::ostream&, CString const&), the game's
GAME._ZlsRSoRK7CString = function(m) return append(m, m:arg(1), cstring_text(m, m:arg(2))) end

-- libstdc++'s inserters, on whatever stream: they append to its buffer
local IMPORTS = {
    -- __ostream_insert(ostream&, char const*, streamsize)
    _ZSt16__ostream_insertIcSt11char_traitsIcEERSt13basic_ostreamIT_T0_ES6_PKS3_l = function(m)
        local n = m:arg(3)
        return append(m, m:arg(1), n > 0 and m:read(m:arg(2), n) or "")
    end,
    _ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_PKc = function(m)
        return append(m, m:arg(1), m:cstring(m:arg(2)))
    end,
    _ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_c = function(m)
        return append(m, m:arg(1), string.char(m:arg(2) % 256))
    end,
    _ZNSolsEi = function(m) return append(m, m:arg(1), tostring(signed32(m:arg(2)))) end,
    _ZNSolsEj = function(m) return append(m, m:arg(1), tostring(m:arg(2) % 2 ^ 32)) end,
    _ZNSolsEs = function(m) return append(m, m:arg(1), tostring(m:arg(2) % 65536)) end,
    _ZNSo9_M_insertIlEERSoT_ = function(m) return append(m, m:arg(1), tostring(m:sarg(2))) end,
    _ZNSo9_M_insertImEERSoT_ = function(m) return append(m, m:arg(1), tostring(m:arg(2))) end,
    _ZNSo9_M_insertIxEERSoT_ = function(m) return append(m, m:arg(1), tostring(m:sarg(2))) end,
    _ZNSo9_M_insertIyEERSoT_ = function(m) return append(m, m:arg(1), tostring(m:arg(2))) end,
    _ZNSo9_M_insertIdEERSoT_ = function(m) return append(m, m:arg(1), "<double>") end,
    _ZNSo9_M_insertIbEERSoT_ = function(m) return append(m, m:arg(1), m:arg(2) % 256 ~= 0 and "1" or "0") end,
    _ZNSo9_M_insertIPKvEERSoT_ = function(m) return append(m, m:arg(1), string.format("0x%x", m:arg(2))) end,
}
-- the 32-bit spelling of __ostream_insert (streamsize is int)
IMPORTS._ZSt16__ostream_insertIcSt11char_traitsIcEERSt13basic_ostreamIT_T0_ES6_PKS3_i =
    IMPORTS._ZSt16__ostream_insertIcSt11char_traitsIcEERSt13basic_ostreamIT_T0_ES6_PKS3_l

-- gamelog.install_imports(L): the inserters, into an import table (hle.lua)
function gamelog.install_imports(L)
    for name, f in pairs(IMPORTS) do
        L[name] = f
    end
end

-- The Windows builds: the game's own CLogStream (an MSVC std::ostringstream) runs as it is, and
-- writes its message, when it is destroyed, to the logger CLogger::AccessInstance gives: the
-- virtual Log(int level, CString const& file, int line, CString const& message) of the loggers,
-- replaced as on Linux. Where no logger is set (CLogger::_pInstance), a CNullLogger is put there
-- (an object with its vtable). A CString is an MSVC std::string (4.x: with an allocator before
-- it): its characters inline while short, else behind a pointer, then the size and the capacity;
-- where, is found by making two with the game's CString(char const*) (GetTCharPtr is inlined in
-- most Windows builds).
local function probe_cstring(m)
    local ctor = m:has("??0CString@@QEAA@PEBD@Z") or m:has("??0CString@@QAE@PBD@Z")
    if not ctor then return nil end
    local w = m.word
    local short, long = "ab", string.rep("L", 40) .. "probe"
    local a, b = m:alloc(0x100), m:alloc(0x100)
    m:call(ctor, a, m:string(short))
    m:call(ctor, b, m:string(long))
    local layout = {}
    for o = 0, 0x60 - w, w do
        if not layout.size and m:ptr(a + o) == #short and m:ptr(b + o) == #long then
            layout.size = o
        end
    end
    for o = 0, 0x60 - w, w do
        if not layout.data then
            local ok, s = pcall(m.cstring, m, m:ptr(b + o), #long + 1)
            if ok and s == long and m:cstring(a + o, 8) == short then
                layout.data = o
            end
        end
    end
    if layout.size then
        layout.capacity = layout.size + w
    end
    if layout.size and layout.data then
        return layout
    end
end

function gamelog.msvc_string(m, s)
    local L = m.cstring_layout
    if not L then return "<CString>" end
    local ok, text = pcall(function()
        local size = m:ptr(s + L.size)
        local cap = m:ptr(s + L.capacity)
        if size > 1e6 then return "<CString>" end
        local p = cap >= 16 and m:ptr(s + L.data) or s + L.data
        return size > 0 and m:read(p, size) or ""
    end)
    return ok and text or "<CString>"
end

local MSVC_LOGGERS = {}
for _, class in ipairs({ "CNullLogger", "CFileLogger", "CFilterLogger" }) do
    MSVC_LOGGERS[#MSVC_LOGGERS + 1] = "?Log@" .. class .. "@@UEAAXHAEBVCString@@H0@Z"
    MSVC_LOGGERS[#MSVC_LOGGERS + 1] = "?Log@" .. class .. "@@UAEXHABVCString@@H0@Z"
end

local function install_msvc(m)
    m.cstring_layout = probe_cstring(m)
    local n = 0
    for _, name in ipairs(MSVC_LOGGERS) do
        if m:replace_symbol(name, logger_log) then
            n = n + 1
        end
    end
    local null_vt = m:has("??_7CNullLogger@@6B@")
    local instance = m:has("?_pInstance@CLogger@@0V?$unique_ptr@VCLogger@@U?$default_delete@VCLogger@@@std@@@std@@A") or
        m:has("?_pInstance@CLogger@@0V?$auto_ptr@VCLogger@@@std@@A")
    if null_vt and instance and m:ptr(instance) == 0 then
        local logger = m:alloc(0x400)
        m:set_ptr(logger, null_vt)
        m:set_ptr(instance, logger)
        m.logger = logger
    end
    return n
end

-- gamelog.install(m): the game's logging functions replaced on the machine
function gamelog.install(m)
    m.log = m.log or {}
    if m.windows then
        return install_msvc(m)
    end
    local n = 0
    for name, f in pairs(GAME) do
        if m:replace_symbol(name, f) then
            n = n + 1
        end
    end
    return n
end

return gamelog
