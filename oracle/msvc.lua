-- oracle/msvc.lua : what the oracle reads from Microsoft Visual C++ decorated names
-- (`?GetTok@CTextLexer@@MEAAHXZ`): the qualified name (CTextLexer::GetTok), whether a name is a
-- function or a variable, its calling convention, and on i386 how many bytes of arguments a
-- __thiscall or __stdcall function removes from the stack when it returns (`ret n`).
--
--   local msvc = require("oracle.msvc")
--   msvc.qualified("??0CMemoryFile@@QAE@PAEHW4EFileType@@W4EFileMode@@_N@Z")  -- "CMemoryFile::CMemoryFile"
--   msvc.signature("?GetTok@CTextLexer@@MAEHXZ", 32)   -- { kind = "function", convention = "thiscall", pops = 0, member = true }
--
-- The grammar is the one documented by the LLVM and Wine undecorators; only what is needed to
-- skip over argument types and to size them is implemented. A name it cannot read gives nil.

local msvc = {}

local SPECIAL = { ["0"] = "<ctor>", ["1"] = "<dtor>", ["2"] = "operator new", ["3"] = "operator delete",
    ["4"] = "operator=", ["5"] = "operator>>", ["6"] = "operator<<", ["7"] = "operator!",
    ["8"] = "operator==", ["9"] = "operator!=", A = "operator[]", B = "operator<cast>",
    C = "operator->", D = "operator*", E = "operator++", F = "operator--", G = "operator-",
    H = "operator+", I = "operator&", J = "operator->*", K = "operator/", L = "operator%",
    M = "operator<", N = "operator<=", O = "operator>", P = "operator>=", Q = "operator,",
    R = "operator()", S = "operator~", T = "operator^", U = "operator|", V = "operator&&",
    W = "operator||", X = "operator*=", Y = "operator+=", Z = "operator-=" }

-- the parser state: s (the name), i (1-based position), names (name back-references), args
-- (argument back-references: sizes)
local P = {}
P.__index = P

local function parser(s, i, bits)
    return setmetatable({ s = s, i = i or 1, names = {}, args = {}, bits = bits or 64 }, P)
end

function P:peek(n)
    return self.s:sub(self.i, self.i + (n or 1) - 1)
end

function P:take(n)
    local v = self:peek(n)
    self.i = self.i + (n or 1)
    return v
end

function P:fail(why)
    error({ msvc = why .. " at " .. self.i .. " in " .. self.s }, 0)
end

-- a simple name: `name@`, or a back-reference digit
function P:simple_name()
    local c = self:peek()
    if c:match("%d") then
        self.i = self.i + 1
        return self.names[tonumber(c) + 1] or self:fail("bad name back-reference")
    end
    if c == "?" and self:peek(2) == "?$" then
        return self:template_name()
    end
    local j = self.s:find("@", self.i, true)
    if not j then self:fail("unterminated name") end
    local name = self.s:sub(self.i, j - 1)
    self.i = j + 1
    if #self.names < 10 then self.names[#self.names + 1] = name end
    return name
end

-- `?$name@<template arguments>@`
function P:template_name()
    self.i = self.i + 2
    local saved_names, saved_args = self.names, self.args
    self.names, self.args = {}, {}
    local j = self.s:find("@", self.i, true)
    if not j then self:fail("unterminated template name") end
    local name = self.s:sub(self.i, j - 1)
    self.i = j + 1
    self.names[1] = name
    while self:peek() ~= "@" do
        if self:peek() == "" then self:fail("unterminated template arguments") end
        self:template_arg()
    end
    self.i = self.i + 1
    self.names, self.args = saved_names, saved_args
    local full = name .. "<>"
    if #self.names < 10 then self.names[#self.names + 1] = full end
    return full
end

function P:number()
    -- an encoded number: `?` for negative, a digit 0-9 for 1-10, or hex letters A-P ending in @
    if self:peek() == "?" then self.i = self.i + 1 end
    local c = self:peek()
    if c:match("%d") then
        self.i = self.i + 1
        return tonumber(c) + 1
    end
    local j = self.s:find("@", self.i, true)
    if not j then self:fail("bad number") end
    self.i = j + 1
    return 0
end

function P:template_arg()
    local c = self:peek()
    if c == "$" then
        local k = self:peek(2)
        if k == "$0" or k == "$H" or k == "$1" or k == "$E" then
            self.i = self.i + 2
            if k == "$0" then self:number()
            elseif k == "$1" or k == "$E" then self:qualified_symbol_ref()
            else self:number() end
            return
        elseif k == "$$" then
            local k3 = self:peek(3)
            if k3 == "$$V" or k3 == "$$Z" then self.i = self.i + 3 return end
        end
    end
    self:type()
end

-- a reference to a symbol inside a template argument: a whole decorated name
function P:qualified_symbol_ref()
    if self:peek() ~= "?" then self:fail("bad symbol reference") end
    -- skip to the end conservatively: decorated name, then its type
    local inner = parser(self.s, self.i + 1, self.bits)
    inner:qualified()
    inner:symbol_type()
    self.i = inner.i
end

-- a qualified name: fragments up to `@`; returns them innermost first
function P:qualified()
    local parts = {}
    while self:peek() ~= "@" do
        if self:peek() == "" then self:fail("unterminated qualified name") end
        if self:peek() == "?" and self:peek(2) ~= "?$" then
            -- a nested name (an anonymous namespace `?A0x...@` or a local scope `?1??...`)
            local j = self.s:find("@", self.i, true)
            parts[#parts + 1] = self.s:sub(self.i, j - 1)
            self.i = j + 1
        else
            parts[#parts + 1] = self:simple_name()
        end
    end
    self.i = self.i + 1
    return parts
end

local PRIM = { C = 4, D = 4, E = 4, F = 4, G = 4, H = 4, I = 4, J = 4, K = 4, M = 4, N = 8, O = 8 }
local EXT = { D = 4, E = 4, F = 4, G = 4, H = 4, I = 4, J = 8, K = 8, L = 16, M = 16, N = 4, Q = 4,
    S = 4, U = 4, W = 4 }

-- skips cv qualifiers and pointer modifiers before a pointee: E (ptr64), F, I (restrict)
function P:modifiers()
    while true do
        local c = self:peek()
        if c == "E" or c == "F" or c == "I" then
            self.i = self.i + 1
        else
            return
        end
    end
end

-- a type; returns its size as an argument on the stack (nil when it is a class by value)
function P:type(in_args)
    local start = self.i
    local c = self:take()
    local size
    if PRIM[c] then
        return PRIM[c]
    elseif c == "X" then
        return 0
    elseif c == "_" then
        local k = self:take()
        size = EXT[k] or self:fail("unknown extended type _" .. k)
        if k == "J" or k == "K" or k == "L" or k == "M" then
            -- remembered as back-references
            if in_args and #self.args < 10 then self.args[#self.args + 1] = size end
        end
        return size
    elseif c:match("%d") then
        return self.args[tonumber(c) + 1] or self:fail("bad argument back-reference")
    elseif c == "P" or c == "Q" or c == "R" or c == "S" or c == "A" or c == "B" then
        if self:peek() == "6" or self:peek() == "8" then
            self.i = self.i + 1
            self:function_type()
        else
            self:modifiers()
            self:take()  -- cv: A B C D
            if self:peek() == "Y" then
                self:array()
            else
                self:type()
            end
        end
        size = self.bits / 8
    elseif c == "$" then
        local k = self:take(2)
        if k == "$Q" or k == "$R" then
            self:modifiers()
            self:take()
            self:type()
            size = self.bits / 8
        elseif k == "$C" then
            self:take()
            size = self:type()
        elseif k == "$A" then
            self:take()  -- 6 or 8
            self:function_type()
            size = 0
        elseif k == "$T" then
            size = self.bits / 8   -- std::nullptr_t
        else
            self:fail("unknown $ type $" .. k)
        end
    elseif c == "V" or c == "U" or c == "T" then
        self:qualified()
        size = nil
    elseif c == "W" then
        self:take()  -- the enum's underlying type (4: int)
        self:qualified()
        size = 4
    elseif c == "?" then
        self:take()  -- cv of a class returned or passed by value
        size = self:type()
    else
        self:fail("unknown type " .. c)
    end
    if in_args and self.i - start > 1 and #self.args < 10 then
        self.args[#self.args + 1] = size or false
    end
    return size
end

function P:array()
    self.i = self.i + 1
    local n = self:number()
    for _ = 1, n do self:number() end
    self:type()
end

-- an argument list: X (none), or types up to @ (then Z) or Z (varargs); returns the stack bytes
function P:arglist()
    if self:peek() == "X" then
        self.i = self.i + 1
        return 0
    end
    local total = 0
    while true do
        local c = self:peek()
        if c == "@" then
            self.i = self.i + 1
            return total
        elseif c == "Z" then
            self.i = self.i + 1
            return total, true
        elseif c == "" then
            self:fail("unterminated argument list")
        end
        local size = self:type(true)
        if size == nil then
            total = nil
        elseif total then
            total = total + math.max(4, size + (4 - size % 4) % 4)
        end
    end
end

local CONVENTION = { A = "cdecl", B = "cdecl", C = "pascal", D = "pascal", E = "thiscall",
    F = "thiscall", G = "stdcall", H = "stdcall", I = "fastcall", J = "fastcall", Q = "vectorcall" }

-- the calling convention letter, a return type (or @ for none), an argument list, a throw
-- specification
function P:function_type(no_return)
    local cc = CONVENTION[self:take()] or self:fail("unknown calling convention")
    local hidden = false
    if not no_return then
        if self:peek() == "@" then
            self.i = self.i + 1
        else
            -- a class returned by value is written through a hidden pointer, an argument
            local c = self:peek()
            hidden = c == "V" or c == "U" or c == "T" or (c == "?" and self.s:sub(self.i + 2, self.i + 2):match("[VUT]") ~= nil)
            self:type()
        end
    end
    local bytes, varargs = self:arglist()
    if hidden and bytes then
        bytes = bytes + self.bits / 8
    end
    self.hidden_return = hidden
    -- the throw specification: Z, or a type list (rare)
    if self:peek() == "Z" then
        self.i = self.i + 1
    elseif self:peek() == "_" and self:peek(2) == "_E" then
        self.i = self.i + 2
    end
    return cc, bytes, varargs
end

local MEMBER = {}
for c in ("ABEFIJMNQRUV"):gmatch(".") do MEMBER[c] = "member" end
for c in ("CDKLST"):gmatch(".") do MEMBER[c] = "static" end
for c in ("GHOPWX"):gmatch(".") do MEMBER[c] = "thunk" end
MEMBER.Y, MEMBER.Z = "global", "global"

-- the type of a symbol after its name: a function or a variable
function P:symbol_type()
    local c = self:take()
    if c:match("[0-4]") then
        -- a variable: 0-2 static members, 3 global, 4 function-local static
        self:type()
        self:modifiers()
        self:take()
        return { kind = "variable" }
    elseif c == "6" or c == "7" then
        -- a vtable or vbtable
        return { kind = "vtable" }
    end
    local kind = MEMBER[c]
    if not kind then self:fail("unknown symbol type " .. c) end
    local info = { kind = "function", member = kind == "member" or kind == "thunk" }
    if kind == "thunk" then self:number() end
    if info.member then
        self:modifiers()
        self:take()  -- the cv qualifiers of this
    end
    local cc, bytes, varargs = self:function_type(self.no_return)
    info.convention, info.arg_bytes, info.varargs = cc, bytes, varargs
    info.hidden_return = self.hidden_return
    return info
end

-- msvc.qualified(decorated) -> "Scope::name" (constructors are "Class::Class", destructors
-- "Class::~Class"), or nil for a name that is not decorated C++
function msvc.qualified(s)
    if s:sub(1, 1) ~= "?" then
        return nil
    end
    local ok, r = pcall(function()
        local p = parser(s, 2)
        local special
        if p:peek() == "?" and p:peek(2) ~= "?$" then
            p.i = p.i + 1
            local c = p:take()
            if c == "_" then
                c = c .. p:take()
            end
            special = c
        end
        local parts
        if special then
            parts = p:qualified()
            local cls = parts[1] and parts[1]:gsub("<>$", "")
            local name = special == "0" and cls or special == "1" and ("~" .. cls) or SPECIAL[special] or ("?" .. special)
            table.insert(parts, 1, name)
        else
            parts = p:qualified()
        end
        local out = {}
        for k = #parts, 1, -1 do
            out[#out + 1] = parts[k]
        end
        return table.concat(out, "::")
    end)
    return ok and r or nil
end

-- msvc.signature(decorated, bits) -> { kind = "function" | "variable" | "vtable", convention,
-- member, arg_bytes (i386: the bytes of arguments on the stack, `this` not counted for
-- __thiscall), pops (what the function removes when it returns) } or nil
function msvc.signature(s, bits)
    if s:sub(1, 1) ~= "?" then
        -- a C name: on i386 `_name` is __cdecl and `_name@n` __stdcall (n bytes)
        local n = s:match("^_[%w_]+@(%d+)$")
        if n then
            return { kind = "function", convention = "stdcall", arg_bytes = tonumber(n), pops = tonumber(n) }
        end
        return nil
    end
    local ok, r = pcall(function()
        local p = parser(s, 2, bits)
        local special
        if p:peek() == "?" and p:peek(2) ~= "?$" then
            p.i = p.i + 1
            special = p:take()
            if special == "_" then special = special .. p:take() end
        end
        p:qualified()
        -- constructors and destructors have no return type: `@` stands in its place
        local info = p:symbol_type()
        return info
    end)
    if not ok then
        return nil, type(r) == "table" and r.msvc or tostring(r)
    end
    if r.kind == "function" then
        local pops = 0
        if (r.convention == "thiscall" or r.convention == "stdcall") and not r.varargs then
            pops = r.arg_bytes
        end
        r.pops = pops
    end
    return r
end

return msvc
