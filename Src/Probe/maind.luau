--[[
    Cobalt Fork v2.4 — Probe diagnóstico (build d)
    Testa cada função isoladamente para achar o nil.
--]]

local function safe(name, fn)
    local ok, res = pcall(fn)
    if ok then
        print("[OK] " .. name)
    else
        print("[ERR] " .. name .. ": " .. tostring(res))
    end
    return ok, res
end

print("iniciando diagnostico")

safe("appendfile_exists", function()
    print(typeof(appendfile))
end)

safe("writefile_exists", function()
    print(typeof(writefile))
end)

safe("io_open", function()
    local f = io.open("Cobalt/Probe/diag.txt", "w")
    if f then f:write("ok"); f:close() end
end)

safe("jsonencode", function()
    local s = game:GetService("HttpService"):JSONEncode({a=1})
    print(s)
end)

safe("get_executor", function()
    print(tostring(identifyexecutor and identifyexecutor() or "sem identifyexecutor"))
end)

safe("run_probe", function()
    -- tenta chamar Probe.run se existir
    if Probe and Probe.run then
        Probe.run()
    else
        print("Probe ou Probe.run nao existe ainda")
    end
end)

print("diagnostico fim")
