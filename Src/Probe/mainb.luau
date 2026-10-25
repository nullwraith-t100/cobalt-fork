--[[
    Cobalt Fork v2.4 — Fase 0: Probe entry point (build b)
    Execute via loadstring no Delta.
--]]

local function try_get_http()
    local ok, svc = pcall(function()
        return game:GetService("HttpService")
    end)
    if ok and svc then return svc end
    ok, svc = pcall(function()
        return game.HttpService
    end)
    if ok and svc then return svc end
    ok, svc = pcall(function()
        return _G.HttpService
    end)
    if ok and svc then return svc end
    return nil
end

local function main()
    local http = try_get_http()
    if not http then
        warn("[Probe] HttpService indisponível")
        return
    end

    local url = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Probe/init.luau"
    local ok, src = pcall(function()
        return http:GetAsync(url)
    end)
    if not ok then
        warn("[Probe] Falha ao baixar init.luau: " .. tostring(src))
        return
    end

    local chunk, err = loadstring(src)
    if not chunk then
        warn("[Probe] Falha ao compilar init.luau: " .. tostring(err))
        return
    end

    local Probe = chunk()
    if not Probe or type(Probe.run) ~= "function" then
        warn("[Probe] init.luau não retornou um módulo com Probe.run")
        return
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
end

local ok, err = pcall(main)
if not ok then
    warn("[Probe] Erro fatal: " .. tostring(err))
end
