--[[
    Cobalt Fork v2.4 — Fase 0: Probe entry point
    Chama Probe.run() e grava Cobalt/probe.json.
    Execute este arquivo no Delta.
--]]

local Probe = require(script and script.Parent:FindFirstChild("init") or nil)

-- Fallback se require via script não funcionar (ex.: execução direta)
if not Probe then
    local ok, mod = pcall(function()
        return loadfile("Src/Probe/init.luau")()
    end)
    if ok then Probe = mod end
end

if not Probe then
    warn("[Probe] Não foi possível carregar o módulo Probe.")
    return
end

local ok, report = pcall(function()
    return Probe.run()
end)

if ok then
    print("[Probe] Concluído. Resultado gravado em Cobalt/probe.json")
    print("[Probe] Executor: " .. tostring(report.executor) .. " " .. tostring(report.executor_version))
    print("[Probe] Timestamp: " .. tostring(report.timestamp))
    -- imprime resumo dos testes
    for nome, res in pairs(report.results or {}) do
        local status = "?"
        if res.ok == false then status = "FALHOU"
        elseif res.exists == false then status = "INDISPONÍVEL"
        elseif res.available == false then status = "INDISPONÍVEL"
        else status = "OK" end
        print(string.format("  [%s] %s", status, nome))
    end
else
    warn("[Probe] Erro ao executar: " .. tostring(report))
end

return report
