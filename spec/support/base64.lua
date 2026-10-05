-- Pure-Lua standard base64 (RFC 4648 alphabet, with `=` padding).
local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}
for i = 1, 64 do DECODE[ALPHABET:sub(i, i)] = i - 1 end

function M.encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
            .. (b and ALPHABET:sub(c3 + 1, c3 + 1) or "=")
            .. (c and ALPHABET:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

function M.decode(s)
    s = s:gsub("=", "")
    local out = {}
    for i = 1, #s, 4 do
        local n, count = 0, 0
        for j = i, math.min(i + 3, #s) do
            n = n * 64 + DECODE[s:sub(j, j)]
            count = count + 1
        end
        for _ = count + 1, 4 do n = n * 64 end
        local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
        out[#out + 1] = bytes:sub(1, count - 1)
    end
    return table.concat(out)
end

return M
