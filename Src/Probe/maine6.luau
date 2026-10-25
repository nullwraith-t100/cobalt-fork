--[[
    Cobalt Fork v2.4 — Probe build e6 (testes 1, 2, 3, 4, 5)
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

local function test_getscripthash()
    local exists = typeof(getscripthash) == "function"
    local returns_sha256 = false
    local sample = nil
    if exists then
        local r = try("getscripthash", function()
            sample = getscripthash(getfenv and getfenv() or _G)
        end)
        if r.ok and typeof(sample) == "string" then
            returns_sha256 = (#sample >= 64)
        end
    end
    return {
        exists = exists,
        returns_sha256 = returns_sha256,
        sample = tostring(sample),
    }
end

local function test_getconnections()
    local exists = typeof(getconnections) == "function"
    local returns_function = false
    local hookable = false
    if exists then
        local bindable = Instance.new("BindableEvent")
        local conn_fn = function() end
        bindable.Event:Connect(conn_fn)
        local conns = try("getconnections_call", function()
            return getconnections(bindable.Event)
        end)
        if conns.ok and typeof(conns.value) == "table" then
            for _, c in ipairs(conns.value) do
                if typeof(c.Function) == "function" then
                    returns_function = true
                    break
                end
            end
        end
        if returns_function and typeof(hookfunction) == "function" then
            local hook_r = try("hookfunction_test", function()
                local hooked = hookfunction(conn_fn, function() end)
                return typeof(hooked) == "function"
            end)
            hookable = hook_r.ok and hook_r.value == true
        end
        bindable:Destroy()
    end
    return {
        exists = exists,
        returns_function = returns_function,
        hookable = hookable,
    }
end

local function test_comm_channel()
    local getactors_ok = typeof(getactors) == "function"
    local create_comm_channel_ok = typeof(create_comm_channel) == "function"
    local names_match = false
    local actors = {}
    if getactors_ok then
        local r = try("getactors_call", function()
            actors = getactors()
        end)
        getactors_ok = r.ok
    end
    if create_comm_channel_ok then
        local r = try("create_comm_channel_call", function()
            local id, channel = create_comm_channel()
            names_match = (typeof(id) == "string" or typeof(id) == "number")
                and (typeof(channel) == "table"
                or (typeof(channel) == "Instance" and channel.ClassName == "BindableEvent"))
        end)
        if not r.ok then
            create_comm_channel_ok = false
        end
    end
    return {
        getactors = getactors_ok,
        create_comm_channel = create_comm_channel_ok,
        names_match = names_match,
        actor_count = typeof(actors) == "table" and #actors or 0,
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
        getscripthash = test_getscripthash(),
        getconnections = test_getconnections(),
        comm_channel = test_comm_channel(),
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
