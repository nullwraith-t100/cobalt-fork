--[[
    Cobalt Fork v2.4 — loader do teste da Fase 2
    Chunk minusculo: baixa tests/phase2.spec.luau, compila e roda.
    Se o compile falhar, imprime o erro real em vez de "attempt to call a nil value".
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/phase2.spec.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[phase2] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[phase2] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, res = pcall(chunk)
if not ran then
    return warn("[phase2] runtime: " .. tostring(res))
end
return res
