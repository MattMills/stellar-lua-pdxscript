-- oracle/hle_cowstring.lua : std::string of the old libstdc++ ABI (copy-on-write, gcc 4), for the
-- 1.x builds whose CString is one. The object is one pointer to the characters; before them is the
-- representation:
--
--   struct _Rep { size_t _M_length; size_t _M_capacity; int _M_refcount; }   then the characters
--
-- A refcount of 0 is one owner. The empty string is libstdc++'s _S_empty_rep_storage, an imported
-- data object: here a block of zeros, which reads as an empty representation. Strings are never
-- shared here: a copy is a new representation.

local S = {}

local function rep_size(m) return m.bits == 64 and 24 or 12 end

-- a new representation holding value, with at least that capacity; returns the characters
local function make(m, value, capacity)
    local n = #value
    capacity = math.max(capacity or n, n)
    local rs = rep_size(m)
    local rep = m:alloc(rs + capacity + 1)
    m:set_ptr(rep, n)
    m:set_ptr(rep + m.word, capacity)
    m:set_u32(rep + 2 * m.word, 0)
    m:write(rep + rs, value .. "\0", n + 1)
    return rep + rs
end

local function chars(m, s) return m:ptr(s) end

local function text(m, s)
    local p = chars(m, s)
    local n = m:ptr(p - rep_size(m))
    return n > 0 and m:read(p, n) or ""
end

local function dispose(m, p)
    local rep = p - rep_size(m)
    if m:block_size(rep) then
        m:free(rep)
    end
end

local function set(m, s, value)
    local old = chars(m, s)
    m:set_ptr(s, make(m, value))
    dispose(m, old)
    return s
end

local function npos_arg(m, i)
    local v = m:arg(i)
    if v >= 2 ^ m.bits - 1 then return math.huge end
    return v
end

local function cmp(a, b)
    if a == b then return 0 end
    return a < b and -1 or 1
end

-- { prefix, member, 32-bit parameters, function }; the 64-bit spelling has m for j
local E = {
    { "_ZNSs", "C1", "PKcRKSaIcE", function(m) m:set_ptr(m:arg(1), make(m, m:cstring(m:arg(2)))) end },
    { "_ZNSs", "C1", "PKcjRKSaIcE", function(m)
        local n = m:arg(3)
        m:set_ptr(m:arg(1), make(m, n > 0 and m:read(m:arg(2), n) or ""))
    end },
    { "_ZNSs", "C1", "RKSs", function(m) m:set_ptr(m:arg(1), make(m, text(m, m:arg(2)))) end },
    { "_ZNSs", "C1", "RKSsjj", function(m)
        local t, pos, n = text(m, m:arg(2)), m:arg(3), npos_arg(m, 4)
        m:set_ptr(m:arg(1), make(m, t:sub(pos + 1, n == math.huge and #t or pos + n)))
    end },
    { "_ZNSs", "C1", "jcRKSaIcE", function(m)
        m:set_ptr(m:arg(1), make(m, string.rep(string.char(m:arg(3) % 256), m:arg(2))))
    end },
    { "_ZNSs", "D1", "v", function(m) dispose(m, chars(m, m:arg(1))) end },
    { "_ZNSs4_Rep", "10_M_destroy", "RKSaIcE", function(m)
        local rep = m:arg(1)
        if m:block_size(rep) then m:free(rep) end
    end },
    { "_ZNSs4_Rep", "10_M_dispose", "RKSaIcE", function(m)
        local rep = m:arg(1)
        if m:block_size(rep) then m:free(rep) end
    end },
    { "_ZNSs4_Rep", "9_S_create", "jjRKSaIcE", function(m)
        local cap, old = m:arg(1), m:arg(2)
        if cap > old and cap < 2 * old then cap = 2 * old end
        return make(m, "", cap) - rep_size(m)
    end },
    { "_ZNSs4_Rep", "8_M_clone", "RKSaIcEj", function(m)
        local rep, extra = m:arg(1), m:arg(3)
        local p = rep + rep_size(m)
        local n = m:ptr(rep)
        return make(m, n > 0 and m:read(p, n) or "", m:ptr(rep + m.word) + extra)
    end },
    { "_ZNSs", "12_M_leak_hard", "v", function() end },
    { "_ZNSs", "9_M_mutate", "jjj", function(m)
        local s, pos, len1, len2 = m:arg(1), m:arg(2), m:arg(3), m:arg(4)
        local t = text(m, s)
        set(m, s, t:sub(1, pos) .. string.rep("\0", len2) .. t:sub(pos + len1 + 1))
    end },
    { "_ZNSs", "6assign", "RKSs", function(m)
        local s, o = m:arg(1), m:arg(2)
        if s ~= o then set(m, s, text(m, o)) end
        return s
    end },
    { "_ZNSs", "6assign", "PKcj", function(m)
        local n = m:arg(3)
        return set(m, m:arg(1), n > 0 and m:read(m:arg(2), n) or "")
    end },
    { "_ZNSs", "6append", "PKcj", function(m)
        local s, n = m:arg(1), m:arg(3)
        return set(m, s, text(m, s) .. (n > 0 and m:read(m:arg(2), n) or ""))
    end },
    { "_ZNSs", "6append", "RKSs", function(m)
        local s = m:arg(1)
        return set(m, s, text(m, s) .. text(m, m:arg(2)))
    end },
    { "_ZNSs", "6append", "jc", function(m)
        local s = m:arg(1)
        return set(m, s, text(m, s) .. string.rep(string.char(m:arg(3) % 256), m:arg(2)))
    end },
    { "_ZNSs", "9push_back", "c", function(m)
        local s = m:arg(1)
        set(m, s, text(m, s) .. string.char(m:arg(2) % 256))
    end },
    { "_ZNSs", "7reserve", "j", function(m)
        local s = m:arg(1)
        local old = chars(m, s)
        m:set_ptr(s, make(m, text(m, s), m:arg(2)))
        dispose(m, old)
    end },
    { "_ZNSs", "6resize", "jc", function(m)
        local s, n, c = m:arg(1), m:arg(2), m:arg(3) % 256
        local t = text(m, s)
        set(m, s, n <= #t and t:sub(1, n) or t .. string.rep(string.char(c), n - #t))
    end },
    { "_ZNSs", "5erase", "jj", function(m)
        local s, pos, n = m:arg(1), m:arg(2), npos_arg(m, 3)
        local t = text(m, s)
        set(m, s, t:sub(1, pos) .. (n == math.huge and "" or t:sub(pos + n + 1)))
        return s
    end },
    { "_ZNSs", "7replace", "jjPKcj", function(m)
        local s, pos, n1, cs, n2 = m:arg(1), m:arg(2), m:arg(3), m:arg(4), m:arg(5)
        local t = text(m, s)
        return set(m, s, t:sub(1, pos) .. (n2 > 0 and m:read(cs, n2) or "") .. t:sub(pos + n1 + 1))
    end },
    { "_ZNSs", "6insert", "jPKcj", function(m)
        local s, pos, cs, n = m:arg(1), m:arg(2), m:arg(3), m:arg(4)
        local t = text(m, s)
        return set(m, s, t:sub(1, pos) .. (n > 0 and m:read(cs, n) or "") .. t:sub(pos + 1))
    end },
    { "_ZNSs", "4swap", "RSs", function(m)
        local a, b = m:arg(1), m:arg(2)
        local pa, pb = m:ptr(a), m:ptr(b)
        m:set_ptr(a, pb)
        m:set_ptr(b, pa)
    end },
    { "_ZNSs", "aS", "PKc", function(m) return set(m, m:arg(1), m:cstring(m:arg(2))) end },
    { "_ZNSs", "aS", "RKSs", function(m)
        local s, o = m:arg(1), m:arg(2)
        if s ~= o then set(m, s, text(m, o)) end
        return s
    end },
    { "_ZNKSs", "7compare", "PKc", function(m) return cmp(text(m, m:arg(1)), m:cstring(m:arg(2))) end },
    { "_ZNKSs", "7compare", "RKSs", function(m) return cmp(text(m, m:arg(1)), text(m, m:arg(2))) end },
    { "_ZNKSs", "4find", "PKcjj", function(m)
        local t, cs, pos, n = text(m, m:arg(1)), m:arg(2), m:arg(3), m:arg(4)
        local i = t:find(n > 0 and m:read(cs, n) or "", pos + 1, true)
        return i and i - 1 or -1
    end },
    { "_ZNKSs", "4find", "cj", function(m)
        local t, c, pos = text(m, m:arg(1)), string.char(m:arg(2) % 256), m:arg(3)
        local i = t:find(c, pos + 1, true)
        return i and i - 1 or -1
    end },
    { "_ZNKSs", "5rfind", "cj", function(m)
        local t, c, pos = text(m, m:arg(1)), string.char(m:arg(2) % 256), npos_arg(m, 3)
        for i = math.min(#t, pos + 1), 1, -1 do
            if t:sub(i, i) == c then return i - 1 end
        end
        return -1
    end },
    { "_ZNKSs", "6substr", "jj", function(m)
        -- the result comes first (a hidden pointer)
        local out, t, pos, n = m:arg(1), text(m, m:arg(2)), m:arg(3), npos_arg(m, 4)
        m:set_ptr(out, make(m, t:sub(pos + 1, n == math.huge and #t or pos + n)))
        m:callee_pops(4)
        return out
    end },
}

-- std::tr1::hash<std::string>::operator()(std::string) const (gcc 4: _Fnv_hash, FNV-1a over the
-- characters, 32-bit; 1.x's hash tables of CString). The string, a class with a copy constructor,
-- is passed by reference to a copy. Without it every key hashed to 0 and the initializers' tables
-- of thousands of names took minutes.
local function tr1_hash(m)
    local t = text(m, m:arg(2))
    local h = 2166136261
    for i = 1, #t do
        h = require("bit").bxor(h, t:byte(i)) % 2 ^ 32
        -- the product exceeds a double's 53 bits: split the prime (16777619 = 2^24 + 403)
        h = (h * 403 + (h % 256) * 2 ^ 24) % 2 ^ 32
    end
    return h
end

function S.install(L)
    L._ZNKSt3tr14hashISsEclESs = tr1_hash
    for _, e in ipairs(E) do
        local prefix, member, params, f = e[1], e[2], e[3], e[4]
        local p64 = params:gsub("j", "m")
        L[prefix .. member .. "E" .. params] = f
        L[prefix .. member .. "E" .. p64] = f
        if member == "C1" or member == "D1" then
            local two = member:sub(1, 1) .. "2"
            L[prefix .. two .. "E" .. params] = f
            L[prefix .. two .. "E" .. p64] = f
        end
    end
end

return S
