-- oracle/hle_tree.lua : the out-of-line parts of libstdc++'s containers that the game's static
-- initializers and readers call: the red-black tree of std::map / std::set (tree.cc) and the
-- prime rehash policy of the (tr1 and C++11) hash tables (hashtable_c++0x.cc).
--
-- _Rb_tree_node_base is { color (int: 0 red, 1 black), parent, left, right }; the header node's
-- parent is the root, its left the leftmost node, its right the rightmost.

local T = {}

local RED, BLACK = 0, 1

local function node(m)
    local w = m.word
    local o = { color = 0, parent = w, left = 2 * w, right = 3 * w }
    local N = {}
    function N.color(x) return m:u32(x + o.color) end
    function N.set_color(x, c) m:set_u32(x + o.color, c) end
    function N.parent(x) return m:ptr(x + o.parent) end
    function N.set_parent(x, v) m:set_ptr(x + o.parent, v) end
    function N.left(x) return m:ptr(x + o.left) end
    function N.set_left(x, v) m:set_ptr(x + o.left, v) end
    function N.right(x) return m:ptr(x + o.right) end
    function N.set_right(x, v) m:set_ptr(x + o.right, v) end
    return N
end

local function minimum(N, x)
    while N.left(x) ~= 0 do x = N.left(x) end
    return x
end

local function maximum(N, x)
    while N.right(x) ~= 0 do x = N.right(x) end
    return x
end

local function increment(N, x)
    if N.right(x) ~= 0 then
        x = N.right(x)
        while N.left(x) ~= 0 do x = N.left(x) end
    else
        local y = N.parent(x)
        while x == N.right(y) do
            x = y
            y = N.parent(y)
        end
        if N.right(x) ~= y then x = y end
    end
    return x
end

local function decrement(N, x)
    if N.color(x) == RED and N.parent(N.parent(x)) == x then
        x = N.right(x)
    elseif N.left(x) ~= 0 then
        local y = N.left(x)
        while N.right(y) ~= 0 do y = N.right(y) end
        x = y
    else
        local y = N.parent(x)
        while x == N.left(y) do
            x = y
            y = N.parent(y)
        end
        x = y
    end
    return x
end

local function rotate_left(N, x, header)
    local y = N.right(x)
    N.set_right(x, N.left(y))
    if N.left(y) ~= 0 then N.set_parent(N.left(y), x) end
    N.set_parent(y, N.parent(x))
    if x == N.parent(header) then
        N.set_parent(header, y)
    elseif x == N.left(N.parent(x)) then
        N.set_left(N.parent(x), y)
    else
        N.set_right(N.parent(x), y)
    end
    N.set_left(y, x)
    N.set_parent(x, y)
end

local function rotate_right(N, x, header)
    local y = N.left(x)
    N.set_left(x, N.right(y))
    if N.right(y) ~= 0 then N.set_parent(N.right(y), x) end
    N.set_parent(y, N.parent(x))
    if x == N.parent(header) then
        N.set_parent(header, y)
    elseif x == N.right(N.parent(x)) then
        N.set_right(N.parent(x), y)
    else
        N.set_left(N.parent(x), y)
    end
    N.set_right(y, x)
    N.set_parent(x, y)
end

-- _Rb_tree_insert_and_rebalance(bool insert_left, node *x, node *p, node &header)
local function insert_and_rebalance(m)
    local N = node(m)
    local insert_left, x, p, header = m:arg(1) % 256 ~= 0, m:arg(2), m:arg(3), m:arg(4)
    N.set_parent(x, p)
    N.set_left(x, 0)
    N.set_right(x, 0)
    N.set_color(x, RED)
    if insert_left then
        N.set_left(p, x)
        if p == header then
            N.set_parent(header, x)
            N.set_right(header, x)
        elseif p == N.left(header) then
            N.set_left(header, x)
        end
    else
        N.set_right(p, x)
        if p == N.right(header) then
            N.set_right(header, x)
        end
    end
    -- rebalance
    while x ~= N.parent(header) and N.color(N.parent(x)) == RED do
        local xpp = N.parent(N.parent(x))
        if N.parent(x) == N.left(xpp) then
            local y = N.right(xpp)
            if y ~= 0 and N.color(y) == RED then
                N.set_color(N.parent(x), BLACK)
                N.set_color(y, BLACK)
                N.set_color(xpp, RED)
                x = xpp
            else
                if x == N.right(N.parent(x)) then
                    x = N.parent(x)
                    rotate_left(N, x, header)
                end
                N.set_color(N.parent(x), BLACK)
                N.set_color(xpp, RED)
                rotate_right(N, xpp, header)
            end
        else
            local y = N.left(xpp)
            if y ~= 0 and N.color(y) == RED then
                N.set_color(N.parent(x), BLACK)
                N.set_color(y, BLACK)
                N.set_color(xpp, RED)
                x = xpp
            else
                if x == N.left(N.parent(x)) then
                    x = N.parent(x)
                    rotate_right(N, x, header)
                end
                N.set_color(N.parent(x), BLACK)
                N.set_color(xpp, RED)
                rotate_left(N, xpp, header)
            end
        end
    end
    N.set_color(N.parent(header), BLACK)
end

-- _Rb_tree_rebalance_for_erase(node *z, node &header) -> the node to free (z)
local function rebalance_for_erase(m)
    local N = node(m)
    local z, header = m:arg(1), m:arg(2)
    local root_get = function() return N.parent(header) end
    local y, x, x_parent = z, 0, 0
    if N.left(y) == 0 then
        x = N.right(y)
    elseif N.right(y) == 0 then
        x = N.left(y)
    else
        y = N.right(y)
        while N.left(y) ~= 0 do y = N.left(y) end
        x = N.right(y)
    end
    if y ~= z then
        N.set_parent(N.left(z), y)
        N.set_left(y, N.left(z))
        if y ~= N.right(z) then
            x_parent = N.parent(y)
            if x ~= 0 then N.set_parent(x, N.parent(y)) end
            N.set_left(N.parent(y), x)
            N.set_right(y, N.right(z))
            N.set_parent(N.right(z), y)
        else
            x_parent = y
        end
        if root_get() == z then
            N.set_parent(header, y)
        elseif N.left(N.parent(z)) == z then
            N.set_left(N.parent(z), y)
        else
            N.set_right(N.parent(z), y)
        end
        N.set_parent(y, N.parent(z))
        local c = N.color(y)
        N.set_color(y, N.color(z))
        N.set_color(z, c)
        y = z
    else
        x_parent = N.parent(y)
        if x ~= 0 then N.set_parent(x, N.parent(y)) end
        if root_get() == z then
            N.set_parent(header, x)
        elseif N.left(N.parent(z)) == z then
            N.set_left(N.parent(z), x)
        else
            N.set_right(N.parent(z), x)
        end
        if N.left(header) == z then
            if N.right(z) == 0 then
                N.set_left(header, N.parent(z))
            else
                N.set_left(header, minimum(N, x))
            end
        end
        if N.right(header) == z then
            if N.left(z) == 0 then
                N.set_right(header, N.parent(z))
            else
                N.set_right(header, maximum(N, x))
            end
        end
    end
    if N.color(y) ~= RED then
        while x ~= root_get() and (x == 0 or N.color(x) == BLACK) do
            if x == N.left(x_parent) then
                local w = N.right(x_parent)
                if N.color(w) == RED then
                    N.set_color(w, BLACK)
                    N.set_color(x_parent, RED)
                    rotate_left(N, x_parent, header)
                    w = N.right(x_parent)
                end
                if (N.left(w) == 0 or N.color(N.left(w)) == BLACK) and
                    (N.right(w) == 0 or N.color(N.right(w)) == BLACK) then
                    N.set_color(w, RED)
                    x = x_parent
                    x_parent = N.parent(x_parent)
                else
                    if N.right(w) == 0 or N.color(N.right(w)) == BLACK then
                        N.set_color(N.left(w), BLACK)
                        N.set_color(w, RED)
                        rotate_right(N, w, header)
                        w = N.right(x_parent)
                    end
                    N.set_color(w, N.color(x_parent))
                    N.set_color(x_parent, BLACK)
                    if N.right(w) ~= 0 then N.set_color(N.right(w), BLACK) end
                    rotate_left(N, x_parent, header)
                    break
                end
            else
                local w = N.left(x_parent)
                if N.color(w) == RED then
                    N.set_color(w, BLACK)
                    N.set_color(x_parent, RED)
                    rotate_right(N, x_parent, header)
                    w = N.left(x_parent)
                end
                if (N.right(w) == 0 or N.color(N.right(w)) == BLACK) and
                    (N.left(w) == 0 or N.color(N.left(w)) == BLACK) then
                    N.set_color(w, RED)
                    x = x_parent
                    x_parent = N.parent(x_parent)
                else
                    if N.left(w) == 0 or N.color(N.left(w)) == BLACK then
                        N.set_color(N.right(w), BLACK)
                        N.set_color(w, RED)
                        rotate_left(N, w, header)
                        w = N.left(x_parent)
                    end
                    N.set_color(w, N.color(x_parent))
                    N.set_color(x_parent, BLACK)
                    if N.left(w) ~= 0 then N.set_color(N.left(w), BLACK) end
                    rotate_right(N, x_parent, header)
                    break
                end
            end
        end
        if x ~= 0 then N.set_color(x, BLACK) end
    end
    return y
end

-- the primes of libstdc++'s __prime_list (the first ones and then about every 5%), enough for the
-- bucket counts a reader asks for
local PRIMES = { 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73,
    79, 83, 89, 97, 103, 109, 113, 127, 137, 139, 149, 157, 167, 179, 193, 199, 211, 227, 241, 257,
    277, 293, 313, 337, 359, 383, 409, 439, 467, 503, 541, 577, 619, 661, 709, 761, 823, 887, 953,
    1031, 1109, 1193, 1289, 1381, 1493, 1613, 1741, 1879, 2029, 2179, 2357, 2549, 2753, 2971, 3209,
    3469, 3739, 4027, 4349, 4703, 5087, 5503, 5953, 6427, 6949, 7517, 8123, 8783, 9497, 10273,
    11113, 12011, 12983, 14033, 15173, 16411, 17749, 19183, 20753, 22447, 24281, 26267, 28411,
    30727, 33223, 35933, 38873, 42043, 45481, 49201, 53201, 57557, 62233, 67307, 72817, 78779,
    85229, 92203, 99733, 107897, 116731, 126271, 136607, 147793, 159871, 172933, 187091, 202409,
    218971, 236897, 256279, 277261, 299951, 324503, 351061, 379787, 410857, 444487, 480881,
    520241, 562841, 608903, 658753, 712697, 771049, 834181, 902483, 976369, 1056323, 1142821,
    1236397, 1337629, 1447153, 1565659, 1693859, 1832561, 1982627, 2144977, 2320627, 2510653,
    2716249, 2938679, 3179303, 3439651, 3721303, 4026031, 4355707, 4712381, 5098259, 5515729,
    5967347, 6456007, 6984629, 7556579, 8175383, 8844859, 9569143, 10352717, 11200489, 12117689,
    13109983, 14183539, 15345007, 16601593, 17961079, 19431899, 21023161, 22744717, 24607243 }

local function next_prime(n)
    for _, p in ipairs(PRIMES) do
        if p >= n then return p end
    end
    return n % 2 == 0 and n + 1 or n
end

-- _Prime_rehash_policy { float max_load_factor; (float growth_factor;) size_t next_resize }
local function policy_load(m, self)
    local f = m:read(self, 4)
    return require("ffi").cast("const float *", f)[0]
end

-- std::tr1::__detail::__prime_list, which 1.x's executables copy from libstdc++ (R_386_COPY) and
-- search inline for a hash table's bucket count: _S_n_primes + 1 sorted entries (256 + 1 of 32
-- bits; 304 + 1 of 64), these primes and then the largest prime of the width. Left zero, every
-- table had 0 buckets (a division by zero in find).
local function prime_list(m, at)
    local n, top = m.bits == 32 and 257 or 305, 4294967291
    for i = 1, n do
        m:set_ptr(at + (i - 1) * m.word, PRIMES[i] or top)
    end
end

function T.install(L)
    L.copy = L.copy or {}
    L.copy._ZNSt3tr18__detail12__prime_listE = prime_list
    L._ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_ = insert_and_rebalance
    L._ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_ = rebalance_for_erase
    L._ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base = function(m) return increment(node(m), m:arg(1)) end
    L._ZSt18_Rb_tree_incrementPKSt18_Rb_tree_node_base = L._ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base
    L._ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base = function(m) return decrement(node(m), m:arg(1)) end
    L._ZSt18_Rb_tree_decrementPKSt18_Rb_tree_node_base = L._ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base
    for _, ns in ipairs({ "_ZNKSt3tr18__detail20_Prime_rehash_policy", "_ZNKSt8__detail20_Prime_rehash_policy" }) do
        -- tr1 (gcc 4): { float max_load; float growth; size_t next_resize }, C++11: { float; size_t }
        local tr1 = ns:find("tr1", 1, true)
        local function resize_at(m) return tr1 and 8 or m.word end
        local function next_bkt_for(m, self, n, lf)
            local p = next_prime(n)
            m:set_ptr(self + resize_at(m), math.floor(p * lf))
            return p
        end
        -- _M_next_bkt(size_t n) const: the next prime, and the size at which to grow again
        local function next_bkt(m)
            local self, n = m:arg(1), m:arg(2)
            return next_bkt_for(m, self, math.max(n, 1), policy_load(m, self))
        end
        -- _M_need_rehash(n_bkt, n_elt, n_ins) const -> pair<bool, size_t>
        local function need_rehash(m)
            local sret = m.bits == 32
            local base = sret and 1 or 0
            local self = m:arg(base + 1)
            local n_bkt, n_elt, n_ins = m:arg(base + 2), m:arg(base + 3), m:arg(base + 4)
            local lf = policy_load(m, self)
            local need, count = false, 0
            if n_elt + n_ins > m:ptr(self + resize_at(m)) then
                local min_bkts = (n_elt + n_ins) / lf
                if min_bkts >= n_bkt then
                    need, count = true, next_bkt_for(m, self, math.max(math.floor(min_bkts) + 1, n_bkt * 2), lf)
                else
                    m:set_ptr(self + resize_at(m), math.floor(n_bkt * lf))
                end
            end
            if sret then
                local out = m:arg(1)
                m:set_u8(out, need and 1 or 0)
                m:set_ptr(out + m.word, count)
                m:callee_pops(4)
                return out
            end
            -- x86-64: { bool, size_t } in rax:rdx
            m.engine:set_reg("rdx", count)
            return need and 1 or 0
        end
        L[ns .. "11_M_next_bktEj"] = next_bkt
        L[ns .. "11_M_next_bktEm"] = next_bkt
        L[ns .. "14_M_need_rehashEjjj"] = need_rehash
        L[ns .. "14_M_need_rehashEmmm"] = need_rehash
    end
end

return T
