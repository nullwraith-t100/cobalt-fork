--[[
    Cobalt Fork v2.4 — loader do teste da Fase 5
    Chunk minusculo: baixa tests/phase5.spec.luau, compila e roda.
    Erro de compile é impresso com linha real.
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/phase5.spec.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[phase5] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[phase5] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, res = pcall(chunk)
if not ran then
    return warn("[phase5] runtime: " .. tostring(res))
end
return res
