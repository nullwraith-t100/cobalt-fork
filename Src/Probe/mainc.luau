--[[
    Cobalt Fork v2.4 — Fase 0: Probe entry point (build c)
    Tudo embarcado, sem HttpService. Execute via loadstring no Delta.
--]]

local Probe = {}

-- Helpers ---------------------------------------------------------------

local function now_ts()
    return os.time()
end

local function try(name, fn)
    local ok, res = pcall(fn)
    if ok then
        return { ok = true, value = res }
    end
    return { ok = false, error = tostring(res) }
end

local function str_or_nil(v)
    if v == nil then return nil end
    return tostring(v)
end

-- Teste 1: appendfile performance (1, 10, 40 MB) -----------------------

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
        table.insert(results, {
            size_mb = size_mb,
            ok = r.ok,
            elapsed_ms = elapsed_ms,
            error = r.error,
        })
    end
    local t1 = results[1] and results[1].elapsed_ms or 0
    local t2 = results[2] and results[2].elapsed_ms or 0
    local t3 = results[3] and results[3].elapsed_ms or 0
    local super_linear = false
    if t2 > 0 and t3 > 0 then
        super_linear = t3 > (t2 * 4)
    end
    return {
        per_size = results,
        super_linear = super_linear,
    }
end

-- Teste 2: renamefile / movefile --------------------------------------

local function test_renamefile()
    return {
        renamefile_exists = typeof(renamefile) == "function",
        movefile_exists = typeof(movefile) == "function",
    }
end

-- Teste 3: getscripthash ----------------------------------------------

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
        sample = str_or_nil(sample),
    }
end

-- Teste 4: getconnections ---------------------------------------------

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

-- Teste 5: Comm channel ----------------------------------------------

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

-- Teste 6: OnTeleport / queue_on_teleport ----------------------------

local function test_on_teleport()
    local players = game:GetService("Players")
    local lp = players.LocalPlayer
    local on_teleport_available = false
    local queue_on_teleport_available = typeof(queue_on_teleport) == "function" or typeof(queueonteleport) == "function"
    if lp then
        on_teleport_available = typeof(lp.OnTeleport) ~= "nil"
    end
    return {
        available = on_teleport_available,
        queue_on_teleport = queue_on_teleport_available,
    }
end

-- Teste 7: WindowFocusReleased ---------------------------------------

local function test_window_focus_released()
    local uis = game:GetService("UserInputService")
    local available = typeof(uis.WindowFocusReleased) ~= "nil"
    return {
        available = available,
    }
end

-- Teste 8: Nome do upvalue via debug.getupvalue ----------------------

local function test_upvalue_name()
    local exists = typeof(debug.getupvalue) == "function"
    local returns_tuple = false
    if exists then
        local up_val = nil
        local up_name = nil
        local r = try("debug_getupvalue", function()
            local x = 42
            local function f() return x end
            up_name, up_val = debug.getupvalue(f, 1)
        end)
        if r.ok then
            returns_tuple = (up_name ~= nil and up_val ~= nil)
        end
    end
    return {
        exists = exists,
        returns_tuple = returns_tuple,
    }
end

-- Teste 9: JSONEncode com NaN/Inf/UTF-8 inválido ---------------------

local function test_jsonencode_invalid()
    local json = game:GetService("HttpService"):JSONEncode
    local results = {}
    local function test_json(label, value)
        local r = try("jsonencode_" .. label, function()
            return json(value)
        end)
        if r.ok then
            results[label] = "ok"
        else
            local err = tostring(r.error):lower()
            if err:find("nan") or err:find("inf") or err:find("invalid") or err:find("utf") or err:find("encode") then
                results[label] = "fail"
            else
                results[label] = "corrupt"
            end
        end
    end
    test_json("nan", { v = 0 / 0 })
    test_json("inf", { v = 1 / 0 })
    test_json("utf8_invalid", { v = "\xff\xfe" })
    return {
        nan = results.nan or "unknown",
        inf = results.inf or "unknown",
        utf8_invalid = results.utf8_invalid or "unknown",
    }
end

-- Teste 10: decompile ------------------------------------------------

local function test_decompile()
    local decompile_exists = typeof(decompile) == "function"
    local cost_ms = 0
    local limited = false
    if decompile_exists then
        local total = 0
        local count = 0
        local targets = {}
        for _, s in ipairs(game:GetDescendants()) do
            if s:IsA("ModuleScript") or s:IsA("LocalScript") then
                table.insert(targets, s)
                if #targets >= 5 then break end
            end
        end
        for _, s in ipairs(targets) do
            local start = os.clock()
            pcall(decompile, s)
            total += (os.clock() - start) * 1000
            count += 1
        end
        if count > 0 then
            cost_ms = math.floor(total / count)
        end
        limited = cost_ms > 200
    end
    return {
        exists = decompile_exists,
        avg_cost_ms = cost_ms,
        limited = limited,
    }
end

-- Executor ----------------------------------------------------------

local function identify_executor()
    local name = "Unknown"
    local version = "Unknown"
    if typeof(identifyexecutor) == "function" then
        local r = try("identifyexecutor", function()
            name = tostring(identifyexecutor())
        end)
        if not r.ok then name = "Unknown" end
    end
    local v = name:match("(%d+%.%d+%.%d+)")
    if v then version = v end
    return name, version
end

-- Recomendação de config ---------------------------------------------

local function recommend_config(results)
    local rotation_limit = 6291456 -- 6 MB padrão
    if results.appendfile_perf and results.appendfile_perf.super_linear then
        rotation_limit = 2097152 -- 2 MB se super-linear
    end
    local bytecode_hash = "fnv1a_64"
    if results.getscripthash and results.getscripthash.exists and results.getscripthash.returns_sha256 then
        bytecode_hash = "getscripthash"
    end
    local decompile_limited = false
    if results.decompile_cost then
        decompile_limited = results.decompile_cost.limited == true
    end
    return {
        rotation_limit_bytes = rotation_limit,
        mem_spool_bytes = 8388608,
        bytecode_hash = bytecode_hash,
        decompile_limited = decompile_limited,
    }
end

-- Grava probe.json -----------------------------------------------------

local function write_probe(path, content)
    local ok, err = pcall(writefile, path, content)
    if not ok then
        local ok2, err2 = pcall(function()
            local f = io.open(path, "w")
            if f then f:write(content); f:close() end
        end)
        if not ok2 then
            warn("[Probe] Falha ao gravar " .. path .. ": " .. tostring(err2))
        end
    end
end

local function encode_json(value)
    local ok, res = pcall(function()
        return game:GetService("HttpService"):JSONEncode(value)
    end)
    if ok then return res end
    return "{}"
end

-- Run ------------------------------------------------------------------

function Probe.run()
    local executor_name, executor_version = identify_executor()

    local results = {
        appendfile_perf = test_appendfile_perf(),
        renamefile = test_renamefile(),
        getscripthash = test_getscripthash(),
        getconnections = test_getconnections(),
        comm_channel = test_comm_channel(),
        on_teleport = test_on_teleport(),
        window_focus_released = test_window_focus_released(),
        upvalue_name = test_upvalue_name(),
        jsonencode_invalid = test_jsonencode_invalid(),
        decompile_cost = test_decompile(),
    }

    local report = {
        executor = executor_name,
        executor_version = executor_version,
        timestamp = now_ts(),
        results = results,
        recommended_config = recommend_config(results),
    }

    local content = encode_json(report)
    write_probe("Cobalt/probe.json", content)

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

    return report
end

-- Executa automaticamente ao carregar ---------------------------------

local ok, report = pcall(function()
    return Probe.run()
end)

if not ok then
    warn("[Probe] Erro fatal: " .. tostring(report))
end

return report
