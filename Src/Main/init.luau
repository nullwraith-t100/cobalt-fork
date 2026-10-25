--[[
    Cobalt Fork v2.4 — Main (Fase 5)
    Orquestrador: Session.begin -> Scanner.snapshot -> Hooks -> Pair -> Recorder ->
    loop de dedup/flush -> end.json no close/teleport/foco.
    Não grava sem redação: Enrich.pack() sempre antes do Recorder.
    Módulos são injetados via opts.modules (ou require, se disponível).
]]

local Main = {}
Main.__index = Main

local function _require(name)
    if typeof(require) == "function" then
        local ok, mod = pcall(require, name)
        if ok then return mod end
    end
    return nil
end

-- ============================================================
-- new
-- ============================================================

function Main.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Main)
    self.session = nil
    self.recorder = nil
    self.pair = nil
    self.scanner = nil
    self.hook = nil
    self.inventory = nil
    self.derive = nil
    self.diff = nil
    self.running = false
    self.config = opts.config
    self.mode = opts.mode or "full"
    self.parent_session = opts.parent_session
    self.on_record = opts.on_record or function(rec) end
    self.started_ts = nil
    self.session_dir = nil
    self.stats_by_remote = {}

    -- injeta módulos (ou require se disponível)
    local m = opts.modules or {}
    self.modules = {
        Session = m.Session or _require("Src.Session"),
        Scanner = m.Scanner or _require("Src.Scanner"),
        Hook = m.Hook or _require("Src.Hook"),
        Pair = m.Pair or _require("Src.Pair"),
        Recorder = m.Recorder or _require("Src.Recorder"),
        Inventory = m.Inventory or _require("Src.Inventory"),
        Derive = m.Derive or _require("Src.Derive"),
        Diff = m.Diff or _require("Src.Diff"),
        Enrich = m.Enrich or _require("Src.Enrich"),
    }
    return self
end

-- ============================================================
-- start: Session.begin + Scanner + Hook + Pair + Recorder
-- ============================================================

function Main:start()
    local Session = self.modules.Session
    local Scanner = self.modules.Scanner
    local Hook = self.modules.Hook
    local Pair = self.modules.Pair
    local Recorder = self.modules.Recorder
    local Inventory = self.modules.Inventory

    if not Session then return false, "modulo Session nao disponível" end

    -- config (cria config.json com redaction_salt se necessário)
    local cfg = Session.load_config("Cobalt")
    self.config = cfg

    -- Session.begin
    local sess = Session.new({ dir = "Cobalt", mode = self.mode, parent_session = self.parent_session })
    local ok, res = sess:begin_session()
    if not ok then return false, "session_begin: " .. tostring(res) end
    self.session = sess
    self.session_dir = sess.session_dir

    -- Scanner.snapshot em task.spawn, orçamento 4 ms/frame
    local scan = Scanner and Scanner.new({ session_dir = self.session_dir, max_nodes = cfg.max_nodes or 15000 }) or nil
    if scan then
        local snap_ok, snap_res = pcall(function() return scan:snapshot() end)
        if not snap_ok then snap_res = { ok = false, nodes = 0, truncated = true } end
    end
    self.scanner = scan

    -- Inventory
    local inv = Inventory and Inventory.new(sess.session, self.mode) or nil
    self.inventory = inv

    -- Recorder dentro do diretório da sessão
    local rec = Recorder and Recorder.new({
        dir = self.session_dir,
        session = sess.session,
        mode = self.mode,
        config = {
            rotation_limit_bytes = cfg.rotation_limit_bytes or 6291456,
            flush_batch = cfg.flush_batch or 100,
            retry_delays_ms = cfg.retry_delays_ms or { 100, 500, 2000 },
            storage_threshold_bytes = cfg.storage_threshold_bytes or 209715200,
            legacy_filelog = cfg.legacy_filelog or false,
        },
        logger = nil,
    }) or nil
    if not rec then return false, "recorder nao disponível" end
    local rec_ok, rec_err = rec:start()
    if not rec_ok then return false, "recorder_start: " .. tostring(rec_err) end
    self.recorder = rec

    -- Pair
    local pair = Pair and Pair.new({
        pair_window_ms = cfg.pair_window_ms_max or 3000,
        pending_cap = cfg.pending_cap or 5000,
        invoke_timeout_ms = cfg.invoke_timeout_ms or 10000,
    }) or nil
    if not pair then return false, "pair nao disponível" end
    self.pair = pair

    -- Hook
    local hk = Hook and Hook.new() or nil
    if hk then hk.reset_corr() end
    self.hook = hk

    -- Loop principal em task.spawn: processa pendentes do Pair -> Recorder
    self.running = true
    task.spawn(function()
        self:_main_loop()
    end)

    self.started_ts = os.time()
    return true, self
end

-- ============================================================
-- _main_loop: flush periódico + expiração de pendentes
-- ============================================================

function Main:_main_loop()
    local last_flush = os.clock()
    local last_expire = os.clock()
    local flush_interval = 2.0
    local expire_interval = 5.0

    while self.running do
        task.wait(0.2)

        -- flush periódico do Recorder
        if os.clock() - last_flush >= flush_interval then
            pcall(function() self.recorder:flush() end)
            last_flush = os.clock()
        end

        -- expiração de pendentes antigos (a cada 5 s)
        if os.clock() - last_expire >= expire_interval then
            local older_than = os.time() - 30 -- pendentes com mais de 30 s
            self:expire_pendings(older_than, {})
            last_expire = os.clock()
        end
    end
end

-- ============================================================
-- on_outgoing: chamado pelo Hook quando há um FireServer/InvokeServer
-- ============================================================

function Main:on_outgoing(record)
    if not self.running then return end
    local ok = self.pair:push_outgoing(record)
    if not ok then
        -- backpressure: grava como unknown direto no Recorder
        record.outcome = "unknown"
        record.outcome_from = "expired_pressure"
        self.recorder:submit(record)
    end
end

-- ============================================================
-- on_incoming: chamado pelo Hook quando há um OnClientEvent/OnClientInvoke
-- ============================================================

function Main:on_incoming(record)
    if not self.running then return end
    local ok, outcome, outcome_from, paired_corr = self.pair:push_incoming(record)
    if ok then
        self.recorder:submit(record)
    end
end

-- ============================================================
-- on_invoke_resolved: chamado quando um InvokeServer retorna (ou timeout)
-- ============================================================

function Main:on_invoke_resolved(record, ret, err, elapsed_ms)
    if not self.running then return end
    local outcome, outcome_from = self.pair:resolve_invoke(record, ret, err, elapsed_ms)
    self.recorder:submit(record)
end

-- ============================================================
-- expire_pendings: expira pendentes antigos e grava no Recorder
-- ============================================================

function Main:expire_pendings(older_than_ts, observable_map)
    local resolved = self.pair:expire(older_than_ts, observable_map)
    for _, rec in ipairs(resolved) do
        self.recorder:submit(rec)
    end
end

-- ============================================================
-- close: fecha a sessão (end.json + manifest + sessions.idx + arquivos derivados)
-- ============================================================

function Main:close(reason, extra)
    if not self.session then return false, "no_session" end
    reason = reason or "manual"
    extra = extra or {}
    extra.reason = reason

    self.running = false

    -- drena fila do Recorder e fecha arquivo ativo
    if self.recorder then
        pcall(function() self.recorder:stop() end)
    end

    -- resolve pendentes restantes como unknown/pending
    local pending = self.pair:pending_list()
    for _, rec in ipairs(pending) do
        if not rec.outcome then
            rec.outcome = "unknown"
            rec.outcome_from = "expired_pressure"
        end
        self.recorder:submit(rec)
    end
    pcall(function() self.recorder:flush() end)

    -- stats finais
    local st = self.recorder:stats()
    local inv_stats = self.inventory and self.inventory:stats() or {}

    -- game_summary + remote_profiles
    local Derive = self.modules.Derive
    local derive = Derive and Derive.new(self.inventory, {}, self.pair:stats()) or nil
    local session_dir = self.session_dir
    if derive then
        pcall(function()
            local ok, gs, rp = derive:write(session_dir, self.session.session, 0, 0)
            extra.game_summary = gs
            extra.remote_profiles = rp
        end)
    end

    -- inventory.ndjson
    local Inventory = self.modules.Inventory
    if self.inventory then
        local inv_content = self.inventory:write(self.session.session, self.mode)
        if inv_content then
            pcall(function() writefile(session_dir .. "/inventory.ndjson", inv_content) end)
        end
    end

    -- tree.ndjson + tree_delta.ndjson (do scanner)
    if self.scanner then
        local tree_content, truncated = self.scanner:write_tree_file(self.session.session)
        if tree_content then
            pcall(function() writefile(session_dir .. "/tree.ndjson", tree_content) end)
        end
        local delta_content = self.scanner:write_delta_file(self.session.session)
        if delta_content then
            pcall(function() writefile(session_dir .. "/tree_delta.ndjson", delta_content) end)
        end
    end

    -- diff.json se houver sessão anterior do mesmo place_id
    local Diff = self.modules.Diff
    if Diff then
        local diff = Diff:new()
        local place_id = 0
        pcall(function() place_id = game.PlaceId end)
        local prev_inv_path = diff:find_previous_inventory("Cobalt", self.session.session, place_id)
        if prev_inv_path then
            local ok, prev = pcall(function()
                local content = readfile(prev_inv_path)
                local lines = { remotes = {}, scripts = {} }
                for line in content:gmatch("[^\n]+") do
                    local dec_ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(line) end)
                    if dec_ok and type(obj) == "table" and obj._h ~= 1 then
                        if obj.kind == "remote" then lines.remotes[obj.path] = obj end
                        if obj.kind == "script" then lines.scripts[obj.path] = obj end
                    end
                end
                return lines
            end)
            if ok then
                local cur_parsed = { remotes = {}, scripts = {} }
                for _, item in ipairs(self.inventory.items) do
                    if item.kind == "remote" then cur_parsed.remotes[item.path] = item end
                    if item.kind == "script" then cur_parsed.scripts[item.path] = item end
                end
                local d = diff:compare(cur_parsed, prev)
                diff:write(session_dir, d)
            end
        end
    end

    -- Session.end()
    local ok, end_rec = self.session:close(reason, {
        stats = st,
        files = self.recorder and self.recorder.files or {},
        idx_covers = {},
        idx_updated_ts = os.time(),
        tree_stats = self.scanner and self.scanner:tree_stats() or nil,
        stats_by_remote = self.pair:stats(),
    })
    if not ok then return false, "session_close: " .. tostring(end_rec) end

    self.session = nil
    return true, end_rec
end

return Main
