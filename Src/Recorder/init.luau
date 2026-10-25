--[[
    Cobalt Fork v2.4 — Recorder (Fase 2)
    Fila, buffer, flush com jitter, rotação numerada, ctl lines, mem_spool.
    Só a main VM escreve (appendfile só daqui). Toda escrita JSON em pcall.
    Header NDJSON §6.0, ctl lines §10.

    Probe fixes: renamefile/movefile não existem → rotação numerada pura.
    appendfile não super-linear → rotation_limit 6 MB.
]]

local Recorder = {}
Recorder.__index = Recorder

local HttpService = game:GetService("HttpService")

local DEFAULTS = {
    rotation_limit_bytes = 6291456,
    mem_spool_bytes = 8388608,
    flush_interval_ms_min = 1500,
    flush_interval_ms_max = 3500,
    flush_batch = 100,
    queue_cap = 5000,
    storage_threshold_bytes = 209715200,
    heartbeat_ms = 5000,
    retry_delays_ms = { 100, 500, 2000 },
    -- espelho opcional no logger legado do Cobalt (Src/Utils/FileLog.luau, intocado)
    legacy_filelog = false,
    -- modos §11: full | lite | dry
    mode = "full",
    -- lite: profundidade máxima de serialização de args
    lite_args_depth = 2,
}

local function now_ms()
    return os.clock() * 1000
end

local function safe_encode(value)
    local ok, res = pcall(function()
        return HttpService:JSONEncode(value)
    end)
    if ok then return true, res end
    return false, tostring(res)
end

local function write_file(path, content)
    local ok, err = pcall(writefile, path, content)
    if ok then return true end
    return false, tostring(err)
end

local function ensure_dir(path)
    if typeof(makefolder) == "function" then
        pcall(makefolder, path)
    end
    return true
end

-- ============================================================
-- new
-- ============================================================

function Recorder.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Recorder)
    self.config = table.clone(DEFAULTS)
    for k, v in pairs(opts.config or {}) do self.config[k] = v end

    self.session = opts.session or "test_session"
    self.mode = opts.mode or "full"
    self.dry = opts.dry == true
    self.lite = self.mode == "lite"
    self.redaction = opts.redaction or { on = true, regex_version = "v1" }
    self.prefix = opts.prefix or "calls" -- calls.NNNN.ndjson
    self.dir = opts.dir or "Cobalt"     -- diretório de dados
    self.logger = opts.logger           -- FileLog legado, só espelho de debug

    self.queue = {}
    self.spool = {}
    self.spool_bytes = 0
    self.bytes_written = 0
    self.file_index = 0
    self.current_file = nil
    self.current_bytes = 0
    self.current_lines = 0

    self.dropped = 0
    self.flush_errors = 0
    self.consecutive_errors = 0
    self.encode_errors = 0
    self.storage_full = false
    self.running = false
    self.seq = 0
    self.ctl_depth = 0
    self.last_write_ok = true

    self.files = {}       -- entries para manifest
    self.last_hb_ts = 0
    self.pending_since_gap = 0
    -- janela do arquivo ativo (vai para manifest e calls.idx)
    self.ts_min = nil
    self.ts_max = nil
    self.corr_first = nil
    self.corr_last = nil
    -- indices por chamada (§6.9)
    self.by_remote = {}
    self.by_source = {}
    self.by_action_n = {}
    return self
end

-- ============================================================
-- Header §6.0
-- ============================================================

function Recorder:header(file_name)
    local header = {
        _h = 1,
        schema = { major = 2, minor = 4 },
        file = file_name == "calls" and "calls" or file_name,
        session = self.session,
        mode = self.mode,
        redaction = { on = self.redaction.on, regex_version = self.redaction.regex_version },
        ts_header = os.time(),
    }
    local ok, line = safe_encode(header)
    if not ok then return false, line end
    return true, line
end

-- ============================================================
-- append com retry + mem_spool §10
-- ============================================================

function Recorder:append_raw(line)
    if self.storage_full then return false, "storage_full" end
    -- modo dry: não grava nada, só conta
    if self.dry then
        self.current_bytes = self.current_bytes + #line
        self.bytes_written = self.bytes_written + #line
        self.current_lines = self.current_lines + 1
        return true
    end

    local path = self.current_file
    local delays = self.config.retry_delays_ms
    for attempt = 1, #delays do
        local ok, err = pcall(appendfile, path, line)
        if ok then
            self.consecutive_errors = 0
            self.current_bytes = self.current_bytes + #line
            self.bytes_written = self.bytes_written + #line
            self.current_lines = self.current_lines + 1
            return true
        end
        self.consecutive_errors = self.consecutive_errors + 1
        task.wait(delays[attempt] / 1000)
    end

    -- após 3 falhas → mem_spool
    if self.consecutive_errors >= 3 then
        local room = self.config.mem_spool_bytes - self.spool_bytes
        if #line <= room then
            self.spool[#self.spool + 1] = { file = self.current_file, line = line }
            self.spool_bytes = self.spool_bytes + #line
            return false, "spooled"
        else
            self.dropped = self.dropped + 1
            if self.ctl_depth == 0 then self:gap_marker("storage", 1) end
            return false, "spool_full_dropped"
        end
    end

    -- 5 falhas consecutivas → storage_full
    if self.consecutive_errors >= 5 then
        self.storage_full = true
        self.flush_errors = self.flush_errors + 1
        return false, "storage_full"
    end

    self.flush_errors = self.flush_errors + 1
    return false, "append_failed"
end

-- drena mem_spool no próximo flush bem-sucedido
function Recorder:drain_spool()
    if #self.spool == 0 then return end
    local remaining = {}
    local remaining_bytes = 0
    for _, item in ipairs(self.spool) do
        if item.file == self.current_file then
            local ok = pcall(appendfile, item.file, item.line)
            if ok then
                self.current_bytes = self.current_bytes + #item.line
                self.bytes_written = self.bytes_written + #item.line
                self.current_lines = self.current_lines + 1
            else
                remaining[#remaining + 1] = item
                remaining_bytes = remaining_bytes + #item.line
            end
        else
            -- arquivo já rotacionado: anexa no arquivo antigo se existir
            local ok = pcall(appendfile, item.file, item.line)
            if not ok then
                remaining[#remaining + 1] = item
                remaining_bytes = remaining_bytes + #item.line
            end
        end
    end
    self.spool = remaining
    self.spool_bytes = remaining_bytes
end

-- ============================================================
-- ctl lines §10
-- ============================================================

function Recorder:ctl(kind, fields)
    fields = fields or {}
    fields.dir = "ctl"
    fields.kind = kind
    local ok, line = safe_encode(fields)
    if not ok then
        self.encode_errors = self.encode_errors + 1
        return false, line
    end
    -- gap -> ctl -> gap nao pode recursar quando o disco esta falhando
    if self.ctl_depth > 0 then return false, "ctl_nested" end
    self.ctl_depth = self.ctl_depth + 1
    local wrote, err = self:append_raw(line .. "\n")
    self.ctl_depth = self.ctl_depth - 1
    if self.config.legacy_filelog and self.logger then
        pcall(function()
            if wrote then
                self.logger:Info(0, "[rec] " .. kind .. " " .. line)
            else
                self.logger:Error(0, "[rec] " .. kind .. " falhou: " .. tostring(err))
            end
        end)
    end
    return wrote, err
end

function Recorder:gap_marker(cause, n)
    return self:ctl("gap", {
        cause = cause,
        ts_from = os.time(),
        ts_to = os.time(),
        n = n,
    })
end

function Recorder:heartbeat()
    local ok = self:ctl("hb", {
        ts = os.time(),
        queue = #self.queue,
        actor_dropped = 0,
        bytes_written = self.bytes_written,
    })
    self.last_hb_ts = now_ms()
    return ok
end

function Recorder:encode_error(corr, reason)
    self.encode_errors = self.encode_errors + 1
    return self:ctl("encode_error", { corr = corr, reason = tostring(reason) })
end

-- ============================================================
-- Rotação numerada — sem renamefile
-- ============================================================

function Recorder:open_next()
    -- modo dry: não cria arquivo, só incrementa índice
    if self.dry then
        self.file_index = self.file_index + 1
        local name = string.format("%s.%04d.ndjson", self.prefix, self.file_index)
        self.current_file = name
        self.current_bytes = 0
        self.current_lines = 0
        return true, name
    end

    self.file_index = self.file_index + 1
    local name = string.format("%s.%04d.ndjson", self.prefix, self.file_index)
    self.current_file = string.format("%s/%s", self.dir, name)
    self.current_bytes = 0
    self.current_lines = 0
    ensure_dir(self.dir)

    -- arquivo existente = retomada, header já está lá
    local exists = false
    if typeof(isfile) == "function" then
        local ok, res = pcall(isfile, self.current_file)
        exists = ok and res == true
    end
    if exists then
        self.current_lines = 0
        self.current_bytes = 0
        local ok_files, files = pcall(listfiles, self.dir)
        if ok_files and type(files) == "table" then
            local total = 0
            for _, f in ipairs(files) do
                if f:match(self.prefix .. "%.%d+%.ndjson$") then
                    local r_ok, content = pcall(readfile, f)
                    if r_ok and type(content) == "string" then total = total + #content end
                end
            end
            self.bytes_written = total
        end
        return true, name
    end

    -- header imediato
    local ok, hline = self:header("calls")
    if not ok then
        return false, hline
    end
    local w = pcall(appendfile, self.current_file, hline .. "\n")
    if not w then return false, "header_write_failed" end
    self.current_bytes = #hline + 1
    self.bytes_written = self.bytes_written + #hline + 1
    self.current_lines = 1

    self.files[#self.files + 1] = {
        path = name,
        bytes = 0,
        lines = 0,
        closed = false,
        seq_first = self.seq + 1,
        seq_last = self.seq,
    }
    self.ts_min = nil
    self.ts_max = nil
    self.corr_first = nil
    self.corr_last = nil
    self.by_remote = {}
    self.by_source = {}
    self.by_action_n = {}
    return true, name
end

function Recorder:maybe_rotate()
    if not self.current_file then return end
    if self.current_bytes < self.config.rotation_limit_bytes then return end

    -- modo dry: não grava idx
    if self.dry then
        self:open_next()
        return
    end

    -- fecha entrada atual no manifest
    local entry = self.files[#self.files]
    if entry then
        entry.bytes = self.current_bytes
        entry.lines = self.current_lines
        entry.closed = true
        entry.seq_last = self.seq
        entry.ts_min = self.ts_min
        entry.ts_max = self.ts_max
        entry.corr_first = self.corr_first
        entry.corr_last = self.corr_last
        entry.by_remote = self.by_remote
        entry.by_source = self.by_source
        entry.by_action_n = self.by_action_n
        self:write_idx_entry(entry)
    end
    self:open_next()
end

-- calls.idx §6.9: NDJSON, uma linha por arquivo FECHADO
function Recorder:write_idx_entry(entry)
    local path = self.dir .. "/calls.idx"
    local exists = false
    if typeof(isfile) == "function" then
        local ok, res = pcall(isfile, path)
        exists = ok and res == true
    else
        local ok, content = pcall(readfile, path)
        exists = ok and type(content) == "string" and #content > 0
    end

    local function w(line)
        local ok, err = pcall(appendfile, path, line .. "\n")
        if not ok then return false, tostring(err) end
        return true
    end

    if not exists then
        local ok, hline = safe_encode({
            _h = 1,
            schema = { major = 2, minor = 4 },
            file = "calls_idx",
            session = self.session,
            mode = self.mode,
            redaction = { on = self.redaction.on, regex_version = self.redaction.regex_version },
            ts_header = os.time(),
        })
        if not ok then return false, hline end
        local wrote, werr = w(hline)
        if not wrote then return false, werr end
    end

    local ok, line = safe_encode({
        path = entry.path,
        bytes = entry.bytes,
        lines = entry.lines,
        closed = entry.closed,
        ts_min = entry.ts_min,
        ts_max = entry.ts_max,
        corr_first = entry.corr_first,
        corr_last = entry.corr_last,
        seq_first = entry.seq_first,
        seq_last = entry.seq_last,
        by_remote = entry.by_remote or {},
        by_source = entry.by_source or {},
        by_action_n = entry.by_action_n or {},
    })
    if not ok then return false, line end
    return w(line)
end

-- ============================================================
-- Fila
-- ============================================================

function Recorder:enqueue(record)
    if #self.queue >= self.config.queue_cap then
        -- descarta o mais antigo não-blocked/não-pending
        local removed = false
        for i = 1, #self.queue do
            local r = self.queue[i]
            if not (r.blocked or r.pending_pair) then
                table.remove(self.queue, i)
                self.dropped = self.dropped + 1
                removed = true
                break
            end
        end
        if not removed then
            self.dropped = self.dropped + 1
            return false, "queue_full"
        end
    end
    self.queue[#self.queue + 1] = record
    return true
end

-- ============================================================
-- Flush
-- ============================================================

function Recorder:flush()
    if self.storage_full then return false, "storage_full" end
    if not self.current_file then
        local ok, err = self:open_next()
        if not ok then return false, err end
    end

    self:drain_spool()

    local batch_records = {}
    local batch_lines = {}
    local n = 0
    while #self.queue > 0 and n < self.config.flush_batch do
        local rec = table.remove(self.queue, 1)
        local ok, line = safe_encode(rec)
        if ok then
            batch_records[#batch_records + 1] = rec
            batch_lines[#batch_lines + 1] = line
            n = n + 1
        else
            -- §10: encode error vira ctl line e o registro e dropado
            self:encode_error(rec.corr or "?", line)
        end
    end

    if #batch_lines == 0 then return true end

    local payload = table.concat(batch_lines, "\n") .. "\n"

    -- §10: teto de storage checado com contador em memoria, antes de escrever
    if self.bytes_written + #payload > self.config.storage_threshold_bytes then
        self.storage_full = true
        for i = #batch_records, 1, -1 do
            table.insert(self.queue, 1, batch_records[i])
        end
        return false, "storage_full"
    end

    local ok, err = self:append_raw(payload)
    if ok then
        self.current_lines = self.current_lines + #batch_lines - 1
        self.seq = self.seq + #batch_lines
        self.last_write_ok = true
        for _, rec in ipairs(batch_records) do
            local ts = tonumber(rec.ts)
            if ts then
                if not self.ts_min or ts < self.ts_min then self.ts_min = ts end
                if not self.ts_max or ts > self.ts_max then self.ts_max = ts end
            end
            if rec.corr then
                if not self.corr_first then self.corr_first = rec.corr end
                self.corr_last = rec.corr
            end
            -- indices por chamada (§6.9)
            if rec.remote then
                self.by_remote[rec.remote] = (self.by_remote[rec.remote] or 0) + 1
            end
            if rec.src and rec.src.path then
                self.by_source[rec.src.path] = (self.by_source[rec.src.path] or 0) + 1
            end
            if rec.action_n then
                self.by_action_n[tostring(rec.action_n)] = (self.by_action_n[tostring(rec.action_n)] or 0) + 1
            end
        end
    else
        self.last_write_ok = false
        -- nao perde registro quando o append falhou (spool pode ter aceitado)
        if err ~= "spooled" and err ~= "spool_full_dropped" then
            for i = #batch_records, 1, -1 do
                table.insert(self.queue, 1, batch_records[i])
            end
        end
    end
    self:maybe_rotate()
    return ok, err
end

-- ============================================================
-- Loop de flush com jitter 1.5–3.5 s
-- ============================================================

function Recorder:start()
    if self.running then return end
    self.running = true
    local ok, err = self:open_next()
    if not ok then
        self.running = false
        return false, err
    end
    task.spawn(function()
        while self.running do
            local min_ms = self.config.flush_interval_ms_min
            local max_ms = self.config.flush_interval_ms_max
            local jitter = min_ms + math.random() * (max_ms - min_ms)
            task.wait(jitter / 1000)
            if not self.running then break end
            pcall(function() self:flush() end)
            -- heartbeat a cada 5 s
            if now_ms() - self.last_hb_ts >= self.config.heartbeat_ms then
                pcall(function() self:heartbeat() end)
            end
        end
    end)
    return true
end

function Recorder:stop()
    if not self.running and not self.current_file then return end
    self.running = false
    pcall(function() self:flush() end)

    -- fecha entrada atual no manifest
    local entry = self.files[#self.files]
    if entry then
        entry.bytes = self.current_bytes
        entry.lines = self.current_lines
        entry.closed = true
        entry.seq_last = self.seq
        entry.ts_min = self.ts_min
        entry.ts_max = self.ts_max
        entry.corr_first = self.corr_first
        entry.corr_last = self.corr_last
        entry.by_remote = self.by_remote
        entry.by_source = self.by_source
        entry.by_action_n = self.by_action_n
    end
    self.current_file = nil

    -- modo dry: não grava manifest
    if self.dry then return end

    -- grava manifest.json com todas as entradas de calls
    pcall(function() self:write_manifest() end)
end

-- calls.idx §6.9 + manifest: grava o arquivo de índice de chamadas
function Recorder:write_manifest()
    local manifest = {
        schema = { major = 2, minor = 4 },
        files = { calls = self.files },
        idx_covers = {},
        idx_updated_ts = os.time(),
    }
    local ok, enc = safe_encode(manifest)
    if not ok then return false, enc end
    ensure_dir(self.dir)
    return write_file(self.dir .. "/manifest.json", enc)
end

function Recorder:stats()
    return {
        calls_raw = self.seq + #self.queue,
        records_written = self.seq,
        calls_blocked = 0,
        dropped_under_pressure = self.dropped,
        pending_expired_pressure = 0,
        actor_dropped = 0,
        flush_errors = self.flush_errors,
        encode_errors = self.encode_errors,
        tail_truncated = not self.last_write_ok,
        storage_full = self.storage_full,
        orphan_calls = 0,
        pending_at_end = #self.queue,
        bytes_written = self.bytes_written,
        spool_bytes = self.spool_bytes,
        files = self.files,
        active_file = self.current_file,
    }
end

-- caminho absoluto do arquivo ativo (Session valida tail nele)
function Recorder:active_path()
    return self.current_file
end

-- submit: enfileira um registro montado pelo Hook
function Recorder:submit(record)
    if type(record) ~= "table" then return false, "record_not_table" end
    record.ts = record.ts or os.time()
    return self:enqueue(record)
end

return Recorder
