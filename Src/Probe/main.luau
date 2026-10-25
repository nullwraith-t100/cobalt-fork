--[[
    Cobalt Fork v2.4 — Fase 0: Probe entry point
    Baixa e executa Src/Probe/init.luau via HttpGet, grava Cobalt/probe.json.
    Execute este arquivo no Delta via loadstring.
--]]

local http = game:GetService("HttpService")

local function fetch_src()
    local url = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Probe/init.luau"
    local ok, res = pcall(http.GetAsync, http, url)
    if not ok then
        error("Falha ao baixar init.luau: " .. tostring(res))
    end
    return res
end

local src = fetch_src()

local chunk, err = loadstring(src, "=Src/Probe/init.luau")
if not chunk then
    error("Falha ao compilar init.luau: " .. tostring(err))
end

local Probe = chunk()
if not Probe or type(Probe.run) ~= "function" then
    error("init.luau não retornou um módulo com Probe.run")
end

local ok, report = pcall(function()
    return Probe.run()
end)

if ok then
    print("[Probe] Concluído. Resultado gravado em Cobalt/probe.json")
    print("[Probe] Executor: " .. tostring(report.executor) .. " " .. tostring(report.executor_version))
    print("[Probe] Timestamp: " .. tostring(report.timestamp))
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
