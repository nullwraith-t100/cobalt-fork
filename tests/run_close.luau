--[[
    Cobalt Fork v2.4 — loader de fechamento de sessão.
    Inicia o fork, aguarda captura de tráfego e fecha limpo via complete:close(),
    gerando end.json, manifest preenchido, tree.ndjson, tree_delta.ndjson,
    inventory.ndjson, fn_info.ndjson, game_summary.json e remote_profiles.json.

    Uso no Delta:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/run_close.luau"))()
]]

local URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Complete/init.luau"

local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" then
    return warn("[close] HttpGet falhou: " .. tostring(src))
end

local chunk, err = loadstring(src)
if not chunk then
    return warn(string.format("[close] compile falhou (%d B): %s", #src, tostring(err)))
end

local ran, mod = pcall(chunk)
if not ran then
    return warn("[close] runtime: " .. tostring(mod))
end

local ok2, complete = pcall(function() return mod.new() end)
if not ok2 then
    return warn("[close] new falhou: " .. tostring(complete))
end

local ok3, started, err = pcall(function() return complete:start() end)
if not ok3 then
    return warn("[close] start falhou (pcall): " .. tostring(started))
end
if not started then
    return warn("[close] start falhou: " .. tostring(err))
end

print("[close] Cobalt Fork v2.4 iniciado. Sessao: " .. tostring(complete.main.session.session))
print("[close] Aguardando captura de tráfego (10 s)...")

-- aguarda captura de tráfego de remotos
task.wait(10)

-- fecha a sessão limpo, gerando end.json + arquivos derivados
local ok4, end_rec = pcall(function() return complete:close("manual") end)
if not ok4 then
    return warn("[close] close falhou (pcall): " .. tostring(end_rec))
end
if not ok4 then
    return warn("[close] close retornou falso: " .. tostring(end_rec))
end

print("[close] Sessao fechada. Motivo: " .. tostring(end_rec.reason))
print("[close] calls_raw: " .. tostring(end_rec.counts_final and end_rec.counts_final.calls_raw or "?"))
print("[close] records_written: " .. tostring(end_rec.counts_final and end_rec.counts_final.records_written or "?"))
print("[close] flush_errors: " .. tostring(end_rec.counts_final and end_rec.counts_final.flush_errors or "?"))
print("[close] encode_errors: " .. tostring(end_rec.counts_final and end_rec.counts_final.encode_errors or "?"))
print("[close] Arquivos em: " .. tostring(complete.main.session_dir))

return complete
