--[[
    Cobalt Fork v2.4 — loader do teste da lacuna 5 (Modos lite/dry)
    Chunk minusculo: baixa tests/modes.spec.luau, compila e roda.
    Erro de compile é impresso com linha real.
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/modes.spec.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[modes] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[modes] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, res = pcall(chunk)
if not ran then
    return warn("[modes] runtime: " .. tostring(res))
end
return res
