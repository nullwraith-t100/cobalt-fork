--[[
    Cobalt Fork v2.4 — Probe build e3 (testes 1 e 2)
--]]

local function try(name, fn)
    local ok, res = pcall(fn)
    if ok then return { ok = true, value = res } end
    return { ok = false, error = tostring(res) }
end

local function test_appendfile_perf()
    local results = {}
    for _, size_mb in ipairs({ 1, 10, 40 }) do
        local size = size_mb * 1024 * 1024
        local data = string.rep("A", size)
        local path = "Cobalt/Probe/test_" .. size_mb .. "mb.bin"
        local start = os.clock()
        local r = try("appendfile_" .. size_mb, function()
            appendfile(path, data)
        end)
        local elapsed_ms = math.floor((os.clock() - start) * 1000)
        table.insert(results, { size_mb = size_mb, ok = r.ok, elapsed_ms = elapsed_ms, error = r.error })
    end
    local t1 = results[1] and results[1].elapsed_ms or 0
    local t2 = results[2] and results[2].elapsed_ms or 0
    local t3 = results[3] and results[3].elapsed_ms or 0
    local super_linear = false
    if t2 > 0 and t3 > 0 then
        super_linear = t3 > (t2 * 4)
    end
    return { per_size = results, super_linear = super_linear }
end

local function test_renamefile()
    return {
        renamefile_exists = typeof(renamefile) == "function",
        movefile_exists = typeof(movefile) == "function",
    }
end

local function identify_executor()
    local name = "Unknown"
    local version = "Unknown"
    if typeof(identifyexecutor) == "function" then
        local r = try("identifyexecutor", function() name = tostring(identifyexecutor()) end)
        if not r.ok then name = "Unknown" end
    end
    local v = name:match("(%d+%.%d+%.%d+)")
    if v then version = v end
    return name, version
end

local function encode_json(value)
    local ok, res = pcall(function() return game:GetService("HttpService"):JSONEncode(value) end)
    if ok then return res end
    return "{}"
end

local function write_probe(path, content)
    local ok, err = pcall(writefile, path, content)
    if not ok then
        warn("[Probe] Falha ao gravar " .. path .. ": " .. tostring(err))
    end
end

local function run()
    local executor_name, executor_version = identify_executor()
    local results = {
        appendfile_perf = test_appendfile_perf(),
        renamefile = test_renamefile(),
    }
    local report = {
        executor = executor_name,
        executor_version = executor_version,
        timestamp = os.time(),
        results = results,
    }
    write_probe("Cobalt/probe.json", encode_json(report))
    print("[Probe] Concluído. Gravado em Cobalt/probe.json")
    print("[Probe] Executor: " .. executor_name .. " " .. executor_version)
    return report
end

local ok, report = pcall(run)
if not ok then warn("[Probe] Erro fatal: " .. tostring(report)) end
return report
