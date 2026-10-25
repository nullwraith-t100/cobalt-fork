--[[
    Cobalt Fork v2.4 — UI Viewer (Fase 9, lacuna 6)
    Viewer standalone da aba Recorder (§14 DESIGN.md).
    Lê os arquivos gravados na sessão e exibe estatísticas para consumo por IA/operador.
    Sem dependência do menu do Cobalt (bundle intocado): roda como script separado.
]]

local UI = {}
UI.__index = UI

local HttpService = game:GetService("HttpService")

local function safe_decode(str)
    local ok, res = pcall(function() return HttpService:JSONDecode(str) end)
    if ok then return true, res end
    return false, tostring(res)
end

local function read_file(path)
    local ok, content = pcall(readfile, path)
    if ok and type(content) == "string" then return true, content end
    return false, tostring(content)
end

local function read_ndjson(path)
    local rows = {}
    local ok, content = read_file(path)
    if not ok then return false, content end
    for line in content:gmatch("[^\n]+") do
        local dec_ok, obj = safe_decode(line)
        if dec_ok and type(obj) == "table" and obj._h ~= 1 then
            rows[#rows + 1] = obj
        end
    end
    return true, rows
end

-- ============================================================
-- new
-- ============================================================

function UI.new(session_dir)
    local self = setmetatable({}, UI)
    self.session_dir = session_dir
    return self
end

-- ============================================================
-- listar sessoes (sessions.idx)
-- ============================================================

function UI:list_sessions(dir)
    dir = dir or "Cobalt"
    local sessions = {}
    local ok, content = read_file(dir .. "/sessions.idx")
    if not ok then return false, content end
    for line in content:gmatch("[^\n]+") do
        local dec_ok, obj = safe_decode(line)
        if dec_ok and type(obj) == "table" and obj._h ~= 1 then
            sessions[#sessions + 1] = obj
        end
    end
    return true, sessions
end

-- ============================================================
-- resumo de uma sessão
-- ============================================================

function UI:session_summary(session_dir)
    session_dir = session_dir or self.session_dir
    local summary = {
        session = nil,
        meta = nil,
        end_stats = nil,
        inventory = nil,
        calls_files = {},
        tree_files = {},
        derived = {},
    }

    -- meta.json
    local ok_meta, meta_raw = read_file(session_dir .. "/meta.json")
    if ok_meta then
        local ok, meta = safe_decode(meta_raw)
        if ok then summary.meta = meta; summary.session = meta.session end
    end

    -- end.json
    local ok_end, end_raw = read_file(session_dir .. "/end.json")
    if ok_end then
        local ok, end_rec = safe_decode(end_raw)
        if ok then summary.end_stats = end_rec.counts_final; summary.end_reason = end_rec.reason end
    end

    -- inventory.ndjson
    local ok_inv, inv_rows = read_ndjson(session_dir .. "/inventory.ndjson")
    if ok_inv then
        summary.inventory = { remotes = 0, scripts = 0, filtered = 0, late = 0 }
        for _, row in ipairs(inv_rows) do
            if row.kind == "remote" then summary.inventory.remotes = summary.inventory.remotes + 1
            elseif row.kind == "script" then summary.inventory.scripts = summary.inventory.scripts + 1
            elseif row.kind == "filtered" then summary.inventory.filtered = summary.inventory.filtered + 1
            elseif row.kind == "late_remote" then summary.inventory.late = summary.inventory.late + 1 end
        end
    end

    -- arquivos de calls
    if typeof(listfiles) == "function" then
        local ok_files, files = pcall(listfiles, session_dir)
        if ok_files and type(files) == "table" then
            for _, f in ipairs(files) do
                if f:match("calls%.%d+%.ndjson$") then
                    summary.calls_files[#summary.calls_files + 1] = f
                elseif f:match("tree_delta%.ndjson$") then
                    summary.tree_files[#summary.tree_files + 1] = f
                elseif f:match("game_summary%.json$") then
                    local ok_gs, gs_raw = read_file(f)
                    if ok_gs then
                        local ok, gs = safe_decode(gs_raw)
                        if ok then summary.derived.game_summary = gs end
                    end
                elseif f:match("remote_profiles%.json$") then
                    local ok_rp, rp_raw = read_file(f)
                    if ok_rp then
                        local ok, rp = safe_decode(rp_raw)
                        if ok then summary.derived.remote_profiles = rp end
                    end
                elseif f:match("diff%.json$") then
                    local ok_d, d_raw = read_file(f)
                    if ok_d then
                        local ok, d = safe_decode(d_raw)
                        if ok then summary.derived.diff = d end
                    end
                end
            end
        end
    end

    -- contar linhas de calls
    summary.calls_total = 0
    for _, f in ipairs(summary.calls_files) do
        local ok_rows, rows = read_ndjson(f)
        if ok_rows then
            for _, row in ipairs(rows) do
                if row._h ~= 1 then summary.calls_total = summary.calls_total + 1 end
            end
        end
    end

    return true, summary
end

-- ============================================================
-- imprimir resumo (texto)
-- ============================================================

function UI:print_summary(summary)
    print("=== Cobalt Fork v2.4 — Sessão: " .. tostring(summary.session) .. " ===")
    if summary.meta then
        print("Modo: " .. tostring(summary.meta.mode) .. " | Executor: " .. tostring(summary.meta.executor)
            .. " | Platform: " .. tostring(summary.meta.platform))
        print("PlaceId: " .. tostring(summary.meta.place_id) .. " | GameId: " .. tostring(summary.meta.game_id)
            .. " | PlaceVersion: " .. tostring(summary.meta.place_version))
        print("Start: " .. tostring(summary.meta.ts_start) .. " | Streaming: " .. tostring(summary.meta.streaming))
    end
    if summary.end_stats then
        print("--- End stats ---")
        print("  calls_raw: " .. tostring(summary.end_stats.calls_raw)
            .. " | records_written: " .. tostring(summary.end_stats.records_written)
            .. " | dropped: " .. tostring(summary.end_stats.dropped_under_pressure)
            .. " | flush_errors: " .. tostring(summary.end_stats.flush_errors)
            .. " | encode_errors: " .. tostring(summary.end_stats.encode_errors)
            .. " | tail_truncated: " .. tostring(summary.end_stats.tail_truncated))
        print("  Reason: " .. tostring(summary.end_reason or "?"))
    end
    if summary.inventory then
        print("--- Inventory ---")
        print("  remotes: " .. tostring(summary.inventory.remotes)
            .. " | scripts: " .. tostring(summary.inventory.scripts)
            .. " | filtered: " .. tostring(summary.inventory.filtered)
            .. " | late: " .. tostring(summary.inventory.late))
    end
    print("--- Calls ---")
    print("  arquivos: " .. tostring(#summary.calls_files)
        .. " | total de registros: " .. tostring(summary.calls_total))
    if summary.derived.game_summary then
        print("--- game_summary ---")
        print("  observable: " .. tostring(summary.derived.game_summary.observable_remotes)
            .. " | unobservable: " .. tostring(summary.derived.game_summary.unobservable_remotes))
    end
    if summary.derived.remote_profiles then
        local n = 0
        for _ in pairs(summary.derived.remote_profiles) do n = n + 1 end
        print("--- remote_profiles ---")
        print("  remotes com perfil: " .. tostring(n))
    end
    if summary.derived.diff then
        print("--- diff ---")
        print("  added: " .. tostring(#(summary.derived.diff.added_remotes or {}))
            .. " | removed: " .. tostring(#(summary.derived.diff.removed_remotes or {}))
            .. " | changed: " .. tostring(#(summary.derived.diff.changed_remotes or {})))
    end
    print("=== Fim ===")
end

return UI
