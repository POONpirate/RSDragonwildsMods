-- json.lua — minimal pure-Lua JSON encoder/decoder
-- Handles the flat { itemPath, count } structures used by PersonalInventoryMod.
-- Based on the public-domain rxi/json.lua (https://github.com/rxi/json.lua)

local json = {}

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode

local escape_char_map = {
    ["\\"] = "\\\\", ["\""] = "\\\"", ["\b"] = "\\b",
    ["\f"] = "\\f",  ["\n"] = "\\n",  ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_str(s)
    return s:gsub('[\\"%c]', function(c)
        return escape_char_map[c] or string.format("\\u%04x", c:byte())
    end)
end

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return true
end

encode = function(val, stack)
    local t = type(val)
    stack = stack or {}

    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "number" then
        if val ~= val then return "null" end  -- NaN
        return string.format("%.14g", val)
    elseif t == "string" then
        return '"' .. escape_str(val) .. '"'
    elseif t == "table" then
        if stack[val] then error("circular reference") end
        stack[val] = true
        local res
        if is_array(val) then
            res = {}
            for _, v in ipairs(val) do
                table.insert(res, encode(v, stack))
            end
            res = "[" .. table.concat(res, ",") .. "]"
        else
            res = {}
            for k, v in pairs(val) do
                if type(k) ~= "string" then
                    error("JSON object keys must be strings, got: " .. type(k))
                end
                table.insert(res, '"' .. escape_str(k) .. '":' .. encode(v, stack))
            end
            res = "{" .. table.concat(res, ",") .. "}"
        end
        stack[val] = nil
        return res
    else
        error("JSON encode: unsupported type '" .. t .. "'")
    end
end

function json.encode(val)
    return encode(val)
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local decode

local function create_set(...)
    local res = {}
    for _, v in ipairs({...}) do res[v] = true end
    return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
-- NOTE: presence must be checked via literal_set, NOT the value table —
-- literals["false"] is false and literals["null"] is nil, so `not literals[s]`
-- would wrongly reject valid "false"/"null" tokens.
local literal_set   = create_set("true", "false", "null")
local literals      = { ["true"] = true, ["false"] = false, ["null"] = nil }

local function next_char(str, idx, set, negate)
    for i = idx, #str do
        if set[str:sub(i, i)] ~= negate then return i end
    end
    return #str + 1
end

local function decode_error(str, idx, msg)
    local line = 1
    for i = 1, idx - 1 do
        if str:sub(i, i) == "\n" then line = line + 1 end
    end
    error(string.format("%s at line %d col %d", msg, line, idx - 1))
end

local function parse_unicode_escape(s)
    local n1 = tonumber(s:sub(1, 4), 16)
    if s:sub(5, 6) == "\\u" then
        local n2 = tonumber(s:sub(7, 10), 16)
        n1 = 0x10000 + (n1 - 0xD800) * 0x400 + (n2 - 0xDC00)
    end
    if n1 < 0x80 then
        return string.char(n1)
    elseif n1 < 0x800 then
        return string.char(0xC0 + math.floor(n1 / 64), 0x80 + (n1 % 64))
    elseif n1 < 0x10000 then
        return string.char(0xE0 + math.floor(n1 / 4096),
                           0x80 + math.floor((n1 % 4096) / 64),
                           0x80 + (n1 % 64))
    else
        return string.char(0xF0 + math.floor(n1 / 262144),
                           0x80 + math.floor((n1 % 262144) / 4096),
                           0x80 + math.floor((n1 % 4096) / 64),
                           0x80 + (n1 % 64))
    end
end

local function parse_string(str, i)
    local res = ""
    local j = i + 1
    while j <= #str do
        local c = str:sub(j, j)
        if c == '"' then
            return res, j + 1
        elseif c == "\\" then
            local nc = str:sub(j + 1, j + 1)
            if not escape_chars[nc] then
                decode_error(str, j, "invalid escape char '" .. nc .. "'")
            end
            if nc == "u" then
                local hex = str:sub(j + 2, j + 5)
                if #hex < 4 then decode_error(str, j, "invalid unicode escape") end
                res = res .. parse_unicode_escape(hex .. str:sub(j + 6, j + 11))
                j = j + (str:sub(j + 6, j + 7) == "\\u" and 11 or 5)
            else
                local map = { b="\b", f="\f", n="\n", r="\r", t="\t" }
                res = res .. (map[nc] or nc)
                j = j + 1
            end
        else
            res = res .. c
        end
        j = j + 1
    end
    decode_error(str, i, "unterminated string")
end

local function parse_number(str, i)
    local s = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    local n = tonumber(s)
    if not n then decode_error(str, i, "invalid number") end
    return n, i + #s
end

local function parse_literal(str, i)
    local s = str:match("^[a-z]+", i)
    if not literal_set[s] then decode_error(str, i, "invalid literal '" .. tostring(s) .. "'") end
    return literals[s], i + #s
end

local function parse_array(str, i)
    local res = {}
    local n = 1
    i = i + 1
    while true do
        local x
        i = next_char(str, i, space_chars, true)
        if str:sub(i, i) == "]" then return res, i + 1 end
        x, i = decode(str, i)
        res[n] = x
        n = n + 1
        i = next_char(str, i, space_chars, true)
        local c = str:sub(i, i)
        if c == "]" then return res, i + 1 end
        if c ~= "," then decode_error(str, i, "expected ']' or ','") end
        i = i + 1
    end
end

local function parse_object(str, i)
    local res = {}
    i = i + 1
    while true do
        local key, val
        i = next_char(str, i, space_chars, true)
        if str:sub(i, i) == "}" then return res, i + 1 end
        if str:sub(i, i) ~= '"' then decode_error(str, i, "expected string key") end
        key, i = parse_string(str, i)
        i = next_char(str, i, space_chars, true)
        if str:sub(i, i) ~= ":" then decode_error(str, i, "expected ':'") end
        i = next_char(str, i + 1, space_chars, true)
        val, i = decode(str, i)
        res[key] = val
        i = next_char(str, i, space_chars, true)
        local c = str:sub(i, i)
        if c == "}" then return res, i + 1 end
        if c ~= "," then decode_error(str, i, "expected '}' or ','") end
        i = i + 1
    end
end

local char_func_map = {
    ['"'] = parse_string, ["0"] = parse_number, ["1"] = parse_number,
    ["2"] = parse_number, ["3"] = parse_number, ["4"] = parse_number,
    ["5"] = parse_number, ["6"] = parse_number, ["7"] = parse_number,
    ["8"] = parse_number, ["9"] = parse_number, ["-"] = parse_number,
    ["t"] = parse_literal, ["f"] = parse_literal, ["n"] = parse_literal,
    ["["] = parse_array,   ["{"] = parse_object,
}

decode = function(str, idx)
    local chr = str:sub(idx, idx)
    local f = char_func_map[chr]
    if f then
        return f(str, idx)
    end
    decode_error(str, idx, "unexpected character '" .. chr .. "'")
end

function json.decode(str)
    if type(str) ~= "string" then
        error("json.decode: expected string, got " .. type(str))
    end
    local i = next_char(str, 1, space_chars, true)
    local res, j = decode(str, i)
    i = next_char(str, j, space_chars, true)
    if i <= #str then
        decode_error(str, i, "trailing garbage")
    end
    return res
end

return json
