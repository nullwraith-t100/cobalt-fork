--[[
    Cobalt Fork v2.4 — Hook (Fase 3)
    Constrói registros de call (§6.7) a partir de um disparo de remote.
    Só coleta: Enrich.pack() nos args, corr "<vm>:<n>", caller via checkcaller,
    tick, tseq, action_sig/action_n via Enrich. Nada de gravação em disco aqui —
    Recorder faz isso. Não toca Src/Utils/Hooking.luau.
]]

local Hook = {}
Hook.__index = Hook

-- Resolve Enrich dinamicamente (evita problema de upvalue nil quando modulos
-- sao carregados fora de ordem em ambientes isolados do loadstring).
local function _enrich()
    return _G.Enrich
end

local RunService = nil
pcall(function() RunService = game:GetService("RunService") end)

local function tick_now()
    if RunService and typeof(RunService.Heartbeat) == "RBXScriptSignal" then
        -- Heartbeat não expõe tick direto; usamos os.clock como proxí de tick
        return math.floor(os.clock() * 1000)
    end
    return math.floor(os.clock() * 1000)
end

local function is_exec_caller()
    if typeof(checkcaller) == "function" then
        local ok, res = pcall(checkcaller)
        if ok then return res == true end
    end
    return false
end

local function normalize_path(path)
    path = tostring(path or "")
    -- Players.<qualquer> → Players.LocalPlayer
    path = path:gsub("^Players%.[%w%s%-_]+", "Players.LocalPlayer")
    -- Workspace.<nome do char> → Workspace.LocalCharacter (heurística fraca: só se diferir de LocalCharacter)
    return path
end

local function src_info()
    local info = { path = nil, line = nil, stack = {}, unresolved = false }
    local ok = pcall(function()
        local s, l = debug.info(2, "s"), debug.info(2, "l")
        info.path = s or nil
        info.line = l or nil
    end)
    if not ok then info.unresolved = true end
    if info.path then info.path = normalize_path(info.path) end
    return info
end

-- ============================================================
-- build_record(opts) -> (ok, record)
-- ============================================================

function Hook.build_record(opts)
    opts = opts or {}
    local remote = opts.remote
    local remote_id = opts.remote_id
    local method = opts.method -- "FireServer" | "InvokeServer" | "OnClientEvent" | "OnClientInvoke"
    local args = opts.args or {}
    local vm = opts.vm or 0
    local caller = opts.caller or (is_exec_caller() and "exec" or "game")

    if not remote or type(remote) ~= "string" then
        return false, "remote_obrigatorio"
    end
    if method ~= "FireServer" and method ~= "InvokeServer" and method ~= "OnClientEvent" and method ~= "OnClientInvoke" then
        return false, "method_invalido"
    end

    local corr = string.format("%d:%d", vm, Hook._next_n(vm))

    local tick = opts.tick or tick_now()
    local tseq = opts.tseq or 0

    local src = opts.src or src_info()
    if opts.src and opts.src.path then
        src.path = normalize_path(opts.src.path)
    elseif src.path then
        src.path = normalize_path(src.path)
    end

    -- Enrich pack nos args (serialize → redact → cap → hash)
    local packed_args = {}
    local arg_nodes = {}
    for i, a in ipairs(args) do
        local ok, node = _enrich().pack_arg(a)
        if ok then
            packed_args[i] = node
            arg_nodes[i] = node
        else
            packed_args[i] = { t = "opaque", class = "pack_error" }
            arg_nodes[i] = packed_args[i]
        end
    end

    local args_sha = _enrich().args_sha(packed_args)

    local record = {
        ts = opts.ts or os.time(),
        tick = tick,
        tseq = tseq,
        corr = corr,
        vm = vm,
        caller = caller,
        dir = "out",
        remote_id = remote_id,
        remote = remote,
        class = opts.class or "RemoteEvent",
        unreliable = opts.unreliable or false,
        method = method,
        src = src,
        args = packed_args,
        args_sha = args_sha,
        dedup_key = nil, -- one-way: null; invoke preenchido pelo Pair
        count = 1,
        ts_first = os.time(),
        ts_last = os.time(),
        dt_ms = { min = 0, median = 0, max = 0 },
        upvals_ref = opts.upvals_ref,
        consts_ref = opts.consts_ref,
        redacted = false,
        likely_encrypted = false,
        ret = nil,
        ret_trunc = false,
        elapsed_ms = nil,
        err = nil,
        err_trunc = false,
        outcome = nil,
        outcome_counts = {},
        outcome_from = nil,
        blocked = false,
        ctx = {},
        flags = {},
        tree_ready = true,
        intercept_out = opts.intercept_out,
    }

    -- action cluster via Enrich (gap fecha cluster, action_n incrementa)
    local action = _enrich().tick_action(tostring(remote_id), tick)
    record.action_sig = action.action_sig
    record.action_n = action.action_n
    record.action_span_ms = action.action_span_ms

    -- ctx mínimo: normalização de caminho já feita em src.path
    if opts.ctx then record.ctx = opts.ctx end

    -- tree_ready: false se ts antes do fim do snapshot
    if opts.snapshot_end_ts and record.ts < opts.snapshot_end_ts then
        record.tree_ready = false
    end

    -- dedup_key para one-way é null (schema: ausente = não aplicável). Para invoke, preenchido depois.
    if method == "FireServer" or method == "OnClientEvent" then
        record.dedup_key = nil
    end

    return true, record
end

-- contador monotônico por VM (corr "<vm>:<n>")
local corr_n = {}
function Hook._next_n(vm)
    vm = vm or 0
    corr_n[vm] = (corr_n[vm] or 0) + 1
    return corr_n[vm]
end

function Hook.reset_corr()
    corr_n = {}
    local e = _enrich()
    if e and e.reset_actions then
        e.reset_actions()
    end
end

function Hook.new()
    return setmetatable({}, Hook)
end

-- ============================================================
-- instalação de hooks (só se houver globals; sem jogo real não dispara)
-- ============================================================

function Hook:install_namecall(on_outgoing)
    if typeof(hookmetamethod) ~= "function" then return false, "hookmetamethod_nao_disponivel" end
    local mt = getrawmetatable(game)
    local old = mt.__namecall
    local ok, err = pcall(function()
        setreadonly(mt, false)
        mt.__namecall = function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }
            if (method == "FireServer" or method == "InvokeServer") and self:IsA("RemoteEvent") or self:IsA("RemoteFunction") then
                pcall(function()
                    local rec_ok, rec = Hook.build_record({
                        remote = self:GetFullName(),
                        remote_id = 0, -- preenchido pelo Scanner/inventory
                        method = method,
                        args = args,
                        caller = is_exec_caller() and "exec" or "game",
                    })
                    if rec_ok then on_outgoing(rec) end
                end)
            end
            return old(self, ...)
        end
        setreadonly(mt, true)
    end)
    if not ok then return false, tostring(err) end
    return true
end

function Hook:install_connections(on_incoming)
    if typeof(getconnections) ~= "function" then return false, "getconnections_nao_disponivel" end
    local hooked = 0
    pcall(function()
        for _, s in ipairs(game:GetDescendants()) do
            if s:IsA("RemoteEvent") or s:IsA("RemoteFunction") then
                local sig = (s:IsA("RemoteEvent") and s.OnClientEvent) or (s:IsA("RemoteFunction") and s.OnClientInvoke)
                if sig then
                    local ok, conns = pcall(getconnections, sig)
                    if ok and type(conns) == "table" then
                        for _, c in ipairs(conns) do
                            if typeof(c.Function) == "function" then
                                local ok2, hooked_fn = pcall(hookfunction, c.Function, function(...)
                                    local args = { ... }
                                    pcall(function()
                                        local rec_ok, rec = Hook.build_record({
                                            remote = s:GetFullName(),
                                            remote_id = 0,
                                            method = s:IsA("RemoteEvent") and "OnClientEvent" or "OnClientInvoke",
                                            args = args,
                                            dir = "in",
                                        })
                                        if rec_ok then on_incoming(rec) end
                                    end)
                                    return hooked_fn(...)
                                end)
                                if ok2 then hooked = hooked + 1 end
                            end
                        end
                    end
                end
            end
        end
    end)
    return true, hooked
end

function Hook:start(opts)
    opts = opts or {}
    local on_outgoing = opts.on_outgoing or function() end
    local on_incoming = opts.on_incoming or function() end
    local r1, e1 = self:install_namecall(on_outgoing)
    local r2, e2 = self:install_connections(on_incoming)
    return r1 or r2, { namecall = { ok = r1, err = e1 }, connections = { ok = r2, hooked = e2 } }
end

Hook.normalize_path = normalize_path
Hook.src_info = src_info

return Hook
