--[[
    Cobalt Fork v2.4 — Loader completo (mínimo, ~1 KB)
    Carrega Src/Complete/init.luau e inicia a sessão completa.
    Teste no Delta:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/run_complete.luau"))()
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Complete/init.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[complete] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[complete] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, mod = pcall(chunk)
if not ran then
    return warn("[complete] runtime: " .. tostring(mod))
end

local ok2, complete = pcall(function() return mod.new() end)
if not ok2 then
    return warn("[complete] new falhou: " .. tostring(complete))
end

local ok3, started, err = pcall(function() return complete:start() end)
if not ok3 then
    return warn("[complete] start falhou (pcall): " .. tostring(started))
end
if not started then
    return warn("[complete] start falhou: " .. tostring(err))
end

print("[complete] Cobalt Fork v2.4 iniciado. Sessao: " .. tostring(complete.main.session.session))
print("[complete] Arquivos gravados em: " .. tostring(complete.main.session_dir))
return complete
