-- oracle/hle_string.lua : std::string of libstdc++ (the C++11 ABI, std::__cxx11::basic_string<char>)
-- for the builds whose CString is one (2.x and 3.x). The member functions the game calls out of
-- line, in Lua, on the object's own layout:
--
--   { char *_M_p; size_t _M_string_length; union { char _M_local_buf[16]; size_t _M_allocated_capacity; } }
--
-- A string is "local" when _M_p points at its own _M_local_buf (capacity 15).

local ffi = require("ffi")

local S = {}

local function W(m) return m.word end

local function get(m, s)
    local w = W(m)
    local p, len = m:ptr(s), m:ptr(s + w)
    local localbuf = s + 2 * w
    local cap = (p == localbuf) and 15 or m:ptr(s + 2 * w)
    return p, len, cap, localbuf
end

local function text(m, s)
    local p, len = get(m, s)
    return len > 0 and m:read(p, len) or ""
end

-- the string's new content: in the local buffer when it fits, else a new block (capacity grown
-- as _M_create grows it: at least twice the old capacity)
local function set(m, s, value)
    local w = W(m)
    local p, _, cap, localbuf = get(m, s)
    local n = #value
    if n > cap then
        local newcap = math.max(n, 2 * cap)
        local np = m:alloc(newcap + 1)
        if p ~= localbuf then
            m:free(p)
        end
        p, cap = np, newcap
        m:set_ptr(s, p)
        m:set_ptr(s + 2 * w, cap)
    end
    m:write(p, value .. "\0", n + 1)
    m:set_ptr(s + w, n)
    return s
end

local function init(m, s, value)
    local w = W(m)
    m:set_ptr(s, s + 2 * w)
    m:set_ptr(s + w, 0)
    m:set_u8(s + 2 * w, 0)
    return set(m, s, value)
end

local function idx(m, i)
    -- size_t npos is -1
    local v = m:arg(i)
    if v >= 2 ^ (m.bits) - 1 then return math.huge end
    return v
end

local function npos() return -1 end

local function sub(str, pos, n)
    return str:sub(pos + 1, n == math.huge and #str or pos + n)
end

-- the C++11 ABI members: name -> function(m), with `m` (size_t = unsigned long, 64-bit) and `j`
-- (unsigned int, 32-bit) spellings both registered
local F = {}
F["9_M_createERmm"] = function(m)
    local capref, old = m:arg(2), m:arg(3)
    local cap = m:ptr(capref)
    if cap > old and cap < 2 * old then
        cap = 2 * old
        m:set_ptr(capref, cap)
    end
    return m:alloc(cap + 1)
end
F["10_M_disposeEv"] = function(m)
    local s = m:arg(1)
    local p, _, _, localbuf = get(m, s)
    if p ~= localbuf then m:free(p) end
end
F["10_M_destroyEm"] = function(m) m:free(m:ptr(m:arg(1))) end
F["9_M_mutateEmmPKcm"] = function(m)
    local s, pos, len1, cs, len2 = m:arg(1), m:arg(2), m:arg(3), m:arg(4), m:arg(5)
    local old = text(m, s)
    local ins = (cs ~= 0 and len2 > 0) and m:read(cs, len2) or ""
    local value = old:sub(1, pos) .. ins .. old:sub(pos + len1 + 1)
    -- _M_mutate always reallocates
    local w = W(m)
    local p, _, cap, localbuf = get(m, s)
    local newcap = #value
    if newcap > cap and newcap < 2 * cap then newcap = 2 * cap end
    local np = m:alloc(newcap + 1)
    m:write(np, value .. "\0", #value + 1)
    if p ~= localbuf then m:free(p) end
    m:set_ptr(s, np)
    m:set_ptr(s + 2 * w, newcap)
    m:set_ptr(s + w, #value)
end
F["10_M_replaceEmmPKcm"] = function(m)
    local s, pos, len1, cs, len2 = m:arg(1), m:arg(2), m:arg(3), m:arg(4), m:arg(5)
    local old = text(m, s)
    local ins = (cs ~= 0 and len2 > 0) and m:read(cs, len2) or ""
    return set(m, s, old:sub(1, pos) .. ins .. old:sub(pos + len1 + 1))
end
F["14_M_replace_auxEmmmc"] = function(m)
    local s, pos, n1, n2, c = m:arg(1), m:arg(2), m:arg(3), m:arg(4), m:arg(5) % 256
    local old = text(m, s)
    return set(m, s, old:sub(1, pos) .. string.rep(string.char(c), n2) .. old:sub(pos + n1 + 1))
end
F["9_M_appendEPKcm"] = function(m)
    local s, cs, n = m:arg(1), m:arg(2), m:arg(3)
    return set(m, s, text(m, s) .. (n > 0 and m:read(cs, n) or ""))
end
F["9_M_assignERKS4_"] = function(m)
    local s, o = m:arg(1), m:arg(2)
    if s ~= o then set(m, s, text(m, o)) end
end
F["8_M_eraseEmm"] = function(m)
    local s, pos, n = m:arg(1), m:arg(2), m:arg(3)
    local old = text(m, s)
    set(m, s, old:sub(1, pos) .. old:sub(pos + n + 1))
end
F["7reserveEm"] = function(m)
    local s, n = m:arg(1), m:arg(2)
    local w = W(m)
    local p, len, cap, localbuf = get(m, s)
    if n > cap then
        local value = text(m, s)
        local newcap = math.max(n, 2 * cap)
        local np = m:alloc(newcap + 1)
        m:write(np, value .. "\0", len + 1)
        if p ~= localbuf then m:free(p) end
        m:set_ptr(s, np)
        m:set_ptr(s + 2 * w, newcap)
    end
end
F["7reserveEv"] = function() end
F["6resizeEmc"] = function(m)
    local s, n, c = m:arg(1), m:arg(2), m:arg(3) % 256
    local old = text(m, s)
    if n <= #old then
        set(m, s, old:sub(1, n))
    else
        set(m, s, old .. string.rep(string.char(c), n - #old))
    end
end
F["4swapERS4_"] = function(m)
    local a, b = m:arg(1), m:arg(2)
    local ta, tb = text(m, a), text(m, b)
    set(m, a, tb)
    set(m, b, ta)
end
F["7compareEPKc"] = function(m)
    local a, b = text(m, m:arg(1)), m:cstring(m:arg(2))
    if a == b then return 0 end
    return a < b and -1 or 1
end
-- compare(pos, n, const string&): the substring [pos, pos + n) with the other string
F["7compareEmmRKS4_"] = function(m)
    local a = sub(text(m, m:arg(1)), m:arg(2), idx(m, 3))
    local b = text(m, m:arg(4))
    if a == b then return 0 end
    return a < b and -1 or 1
end
-- compare(pos, n, const char*)
F["7compareEmmPKc"] = function(m)
    local a = sub(text(m, m:arg(1)), m:arg(2), idx(m, 3))
    local b = m:cstring(m:arg(4))
    if a == b then return 0 end
    return a < b and -1 or 1
end
F["7compareERKS4_"] = function(m)
    local a, b = text(m, m:arg(1)), text(m, m:arg(2))
    if a == b then return 0 end
    return a < b and -1 or 1
end
F["4findEPKcmm"] = function(m)
    local s, cs, pos, n = m:arg(1), m:arg(2), m:arg(3), m:arg(4)
    local str = text(m, s)
    local needle = n > 0 and m:read(cs, n) or ""
    local i = str:find(needle, pos + 1, true)
    return i and i - 1 or npos(m)
end
F["4findEcm"] = function(m)
    local str, c, pos = text(m, m:arg(1)), m:arg(2) % 256, m:arg(3)
    local i = str:find(string.char(c), pos + 1, true)
    return i and i - 1 or npos(m)
end
F["5rfindEcm"] = function(m)
    local str, c, pos = text(m, m:arg(1)), string.char(m:arg(2) % 256), idx(m, 3)
    for i = math.min(#str, pos + 1), 1, -1 do
        if str:sub(i, i) == c then return i - 1 end
    end
    return npos(m)
end
F["5rfindEPKcmm"] = function(m)
    local str, cs, pos, n = text(m, m:arg(1)), m:arg(2), idx(m, 3), m:arg(4)
    local needle = n > 0 and m:read(cs, n) or ""
    for i = math.min(#str - #needle + 1, pos + 1), 1, -1 do
        if str:sub(i, i + #needle - 1) == needle then return i - 1 end
    end
    return npos(m)
end
F["6substrEmm"] = function(m)
    -- returns a string: the hidden result pointer comes first
    local out, s, pos, n = m:arg(1), m:arg(2), m:arg(3), idx(m, 4)
    init(m, out, sub(text(m, s), pos, n))
    m:callee_pops(4)
    return out
end
F["12find_first_ofEPKcmm"] = function(m)
    local str, cs, pos, n = text(m, m:arg(1)), m:arg(2), m:arg(3), m:arg(4)
    local set_ = n > 0 and m:read(cs, n) or ""
    for i = pos + 1, #str do
        if set_:find(str:sub(i, i), 1, true) then return i - 1 end
    end
    return npos(m)
end
F["16find_first_not_ofEPKcmm"] = function(m)
    local str, cs, pos, n = text(m, m:arg(1)), m:arg(2), m:arg(3), m:arg(4)
    local set_ = n > 0 and m:read(cs, n) or ""
    for i = pos + 1, #str do
        if not set_:find(str:sub(i, i), 1, true) then return i - 1 end
    end
    return npos(m)
end
F["11find_last_ofEPKcmm"] = function(m)
    local str, cs, pos, n = text(m, m:arg(1)), m:arg(2), idx(m, 3), m:arg(4)
    local set_ = n > 0 and m:read(cs, n) or ""
    for i = math.min(#str, pos + 1), 1, -1 do
        if set_:find(str:sub(i, i), 1, true) then return i - 1 end
    end
    return npos(m)
end
-- constructors and assignment
F["C1ERKS4_"] = function(m) init(m, m:arg(1), text(m, m:arg(2))) end
F["C2ERKS4_"] = F["C1ERKS4_"]
F["C1EPKcRKS3_"] = function(m) init(m, m:arg(1), m:cstring(m:arg(2))) end
F["C2EPKcRKS3_"] = F["C1EPKcRKS3_"]
F["C1ERKS4_mm"] = function(m) init(m, m:arg(1), sub(text(m, m:arg(2)), m:arg(3), idx(m, 4))) end
F["C2ERKS4_mm"] = F["C1ERKS4_mm"]
F["C1EOS4_"] = function(m)
    local s, o = m:arg(1), m:arg(2)
    init(m, s, text(m, o))
    init(m, o, "")
end
F["C2EOS4_"] = F["C1EOS4_"]
F["D1Ev"] = F["10_M_disposeEv"]
F["D2Ev"] = F["10_M_disposeEv"]
F["aSERKS4_"] = function(m)
    local s, o = m:arg(1), m:arg(2)
    if s ~= o then set(m, s, text(m, o)) end
    return s
end
F["aSEOS4_"] = function(m)
    local s, o = m:arg(1), m:arg(2)
    set(m, s, text(m, o))
    set(m, o, "")
    return s
end
F["aSEPKc"] = function(m) return set(m, m:arg(1), m:cstring(m:arg(2))) end
F["6appendEPKc"] = function(m) local s = m:arg(1) return set(m, s, text(m, s) .. m:cstring(m:arg(2))) end
F["6appendEPKcm"] = function(m)
    local s, cs, n = m:arg(1), m:arg(2), m:arg(3)
    return set(m, s, text(m, s) .. (n > 0 and m:read(cs, n) or ""))
end
F["6appendERKS4_"] = function(m) local s = m:arg(1) return set(m, s, text(m, s) .. text(m, m:arg(2))) end
F["9push_backEc"] = function(m) local s = m:arg(1) set(m, s, text(m, s) .. string.char(m:arg(2) % 256)) end
F["6insertEmPKc"] = function(m)
    local s, pos, cs = m:arg(1), m:arg(2), m:arg(3)
    local old = text(m, s)
    return set(m, s, old:sub(1, pos) .. m:cstring(cs) .. old:sub(pos + 1))
end

local PREFIX = "_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE"
local PREFIX_K = "_ZNKSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE"
local CONST = { ["7compareEPKc"] = true, ["7compareERKS4_"] = true, ["7compareEmmRKS4_"] = true,
    ["7compareEmmPKc"] = true, ["4findEPKcmm"] = true,
    ["4findEcm"] = true, ["5rfindEcm"] = true, ["5rfindEPKcmm"] = true, ["6substrEmm"] = true,
    ["12find_first_ofEPKcmm"] = true, ["16find_first_not_ofEPKcmm"] = true,
    ["11find_last_ofEPKcmm"] = true }

-- the 32-bit spelling of a member: size_t is unsigned int (j) instead of unsigned long (m) in
-- the parameters (after the E that ends the name)
local function spelling32(suffix)
    local name, params
    local n = suffix:match("^(%d+)")
    if n then
        name = suffix:sub(1, #n + tonumber(n))
    else
        name = suffix:sub(1, 2)  -- C1, C2, D1, D2, aS
    end
    params = suffix:sub(#name + 1)
    return name .. params:gsub("m", "j")
end

-- install(L): adds every member to the import table L under its mangled names (64 and 32 bit)
function S.install(L)
    for suffix, f in pairs(F) do
        local prefix = CONST[suffix] and PREFIX_K or PREFIX
        L[prefix .. suffix] = f
        L[prefix .. spelling32(suffix)] = f
    end
end

S.text, S.init, S.set = text, init, set

return S
