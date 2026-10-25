--[[
    Cobalt Fork v2.4 — loader do teste da lacuna 6 (UI Viewer)
    Chunk minusculo: baixa tests/ui.spec.luau, compila e roda.
    Erro de compile é impresso com linha real.
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/ui.spec.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[ui] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[ui] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, res = pcall(chunk)
if not ran then
    return warn("[ui] runtime: " .. tostring(res))
end
return res
