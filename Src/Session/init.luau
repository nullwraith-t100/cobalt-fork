--[[
    Cobalt Fork v2.4 — Session (Fase 2)
    Ciclo de vida: begin -> meta.json imutavel + manifest + sessions.idx + SCHEMA.md
                   finish -> valida tail + end.json + manifest + sessions.idx (update)
    sessions.idx e NDJSON e pequeno: reescrito inteiro via writefile (sem renamefile).
    Probe: renamefile/movefile ausentes -> nenhuma operacao depende deles.
]]

local Session = {}
Session.__index = Session

local HttpService = game:GetService("HttpService")

local DATA_DIR = "Cobalt"
local SCHEMA_MAJOR = 2
local SCHEMA_MINOR = 4

-- §6.1 config persistida
local CONFIG_DEFAULTS = {
    redaction_regex = "^(token|apikey|api_key|secret|password|passwd|auth|authorization|signature|sig|credential|cookie|jwt|bearer)$",
    redaction_min_sha_len = 16,
    redaction_salt = nil, -- gerado no primeiro boot
    storage_threshold_bytes = 209715200,
    rotation_limit_bytes = 6291456,
    mem_spool_bytes = 8388608,
    flush_interval_ms_min = 1500,
    flush_interval_ms_max = 3500,
    flush_batch = 100,
    rare_threshold = 5,
    pair_window_ms_min = 500,
    pair_window_ms_max = 3000,
    pair_window_unreliable_ms = 200,
    action_gap_ms = 100,
    dedup_window_ms = 2000,
    invoke_timeout_ms = 10000,
    queue_cap = 5000,
    actor_channel_cap = 500,
    pending_cap = 5000,
    max_nodes = 15000,
    diff_enabled = false,
}

-- ============================================================
-- helpers de arquivo (pcall em tudo)
-- ============================================================

local function safe_encode(value)
    local ok, res = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return true, res end
    return false, tostring(res)
end

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

local function write_file(path, content)
    local ok, err = pcall(writefile, path, content)
    if ok then return true end
    return false, tostring(err)
end

local function append_file(path, content)
    local ok, err = pcall(appendfile, path, content)
    if ok then return true end
    return false, tostring(err)
end

local function ensure_dir(path)
    if typeof(makefolder) == "function" then
        pcall(makefolder, path)
    end
    return true
end

local function now_ts()
    return os.time()
end

-- ============================================================
-- capabilities (§6.1) — derivadas do ambiente, nao do probe.json
-- ============================================================

local function has_global(name)
    local env = _G
    if typeof(getfenv) == "function" then
        local ok, e = pcall(getfenv, 0)
        if ok and type(e) == "table" then env = e end
    end
    return typeof(env[name]) ~= "nil"
end

function Session.detect_capabilities()
    local lp = nil
    pcall(function() lp = game:GetService("Players").LocalPlayer end)
    local uis_ok = pcall(function() return game:GetService("UserInputService").WindowFocusReleased end)

    local returnsp = { getscripthash_sample = nil }
    if has_global("getscripthash") then
        pcall(function() returnsp.getscripthash_sample = getscripthash(getfenv and getfenv() or _G) end)
    end

    return {
        getupvalues = has_global("getupvalues") or (typeof(debug) == "table" and typeof(debug.getupvalues) == "function"),
        getconstants = has_global("getconstants") or (typeof(debug) == "table" and typeof(debug.getconstants) == "function"),
        getprotos = has_global("getprotos") or (typeof(debug) == "table" and typeof(debug.getprotos) == "function"),
        -- probe Delta: debug.getupvalue devolve so o valor -> nome indisponivel
        getupvalue_name = false,
        decompile = has_global("decompile"),
        run_on_actor = has_global("run_on_actor"),
        getactors = has_global("getactors"),
        comm_channel = has_global("create_comm_channel"),
        oth = has_global("getscriptclosure"),
        ping = has_global("firetouchinterest"),
        unload = false, -- Delta nao expoe unload generico; hook via Instance destruida
        appendfile = has_global("appendfile"),
        writefile = has_global("writefile"),
        getconnections = has_global("getconnections"),
        -- existe mas retorna nil no Delta: desligado por contrato
        getscripthash = (type(returnsp.getscripthash_sample) == "string"),
        queue_on_teleport = has_global("queue_on_teleport") or has_global("queueonteleport"),
        on_teleport = lp ~= nil,
        window_focus_released = uis_ok,
        hashlib_sha256 = has_global("crypt") and typeof(crypt) == "table" and typeof(crypt.hash) == "function",
    }
end

-- ============================================================
-- config persistida (§6.1) + salt por instalacao
-- ============================================================

local function random_salt()
    local parts = {}
    for i = 1, 8 do
        parts[i] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(parts)
end

function Session.load_config(dir)
    dir = dir or DATA_DIR
    local path = dir .. "/config.json"
    local cfg
    local ok, content = read_file(path)
    if ok then
        local dec_ok, decoded = safe_decode(content)
        if dec_ok and type(decoded) == "table" then cfg = decoded end
    end
    cfg = cfg or {}
    for k, v in pairs(CONFIG_DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    if cfg.redaction_salt == nil then
        cfg.redaction_salt = random_salt()
        local enc_ok, enc = safe_encode(cfg)
        if enc_ok then write_file(path, enc) end
    end
    return cfg
end

-- ============================================================
-- sessions.idx (§6.10) — NDJSON, reescrito inteiro
-- ============================================================

local function idx_path(dir) return dir .. "/sessions.idx" end

local function idx_header()
    return {
        _h = 1,
        schema = { major = SCHEMA_MAJOR, minor = SCHEMA_MINOR },
        file = "sessions",
        session = "-",
        mode = "-",
        redaction = { on = true, regex_version = "v1" },
        ts_header = now_ts(),
    }
end

local function idx_load(dir)
    local entries = {}
    local had_header = false
    local ok, content = read_file(idx_path(dir))
    if ok and content and #content > 0 then
        for line in content:gmatch("[^\n]+") do
            local dec_ok, obj = safe_decode(line)
            if dec_ok and type(obj) == "table" then
                if obj._h == 1 then
                    had_header = true
                else
                    entries[#entries + 1] = obj
                end
            end
        end
    end
    return entries, had_header
end

local function idx_store(dir, entries)
    local lines = {}
    local enc_ok, header = safe_encode(idx_header())
    if not enc_ok then return false, header end
    lines[1] = header
    for _, e in ipairs(entries) do
        local ok, line = safe_encode(e)
        if ok then lines[#lines + 1] = line end
    end
    return write_file(idx_path(dir), table.concat(lines, "\n") .. "\n")
end

-- ============================================================
-- SCHEMA.md (§6.13) — gerado no begin
-- ============================================================

local SCHEMA_MD = [==[
# Cobalt Fork v2.4 — schema das sessoes

Schema major 2, minor 4. Todo `.ndjson` comeca com uma linha de header:
`{"_h":1,"schema":{"major":2,"minor":4},"file":"...","session":"...","mode":"...","redaction":{"on":true,"regex_version":"v1"},"ts_header":...}`

Leitor: `schema.major` diferente do conhecido -> abortar. `schema.minor` maior -> ignorar campos desconhecidos.
`redaction.on` decide se a ausencia de um campo e redacao ou ausencia real.

## Arquivos

| arquivo | conteudo |
|---|---|
| `meta.json` | imutavel, escrito no begin |
| `end.json` | escrito no close; ausente = crash |
| `manifest.json` | atualizado a cada flush / rotacao / close |
| `inventory.ndjson` | header + 1 linha por remote/script/filter |
| `tree.ndjson` | header + 1 linha por no |
| `tree_delta.ndjson` | header + 1 linha por op |
| `calls.0001.ndjson` | header + 1 linha por registro; rotacao numerada |
| `fn_info.ndjson` | header + 1 linha por funcao vista |
| `calls.idx` | NDJSON, 1 linha por chave de arquivo fechado |
| `game_summary.json` | derivado no end |
| `remote_profiles.json` | derivado no end |
| `diff.json` | opcional, so com `config.diff_enabled` |

## Registro de call

Campos: `corr` (`"<vm>:<n>"`), `seq`, `tseq`, `ts`, `caller` (`"game"` ou `"exec"`), `remote`,
`remote_id`, `method`, `dedup_key`, `args`, `args_sha`, `upvals`, `consts`, `ret`, `err`,
`elapsed_ms`, `outcome`, `outcome_from`, `blocked`, `ctx`, `action_sig`, `action_n`, `tree_ready`.

`args`, `upvals`, `consts`, `ret` usam a tipagem por no: `{"t":"string","v":"..."}`,
`{"t":"number","v":1.5}`, `{"t":"table","arr":[...],"map":[[k,v],...]}` etc.
Binario invalido em UTF-8 vai como `{"t":"string","b64":"<hex>","bin":true}`.
NaN/Inf viram `{"t":"number","special":"nan"|"inf"|"-inf"}` — nunca entram no JSON.

## Outcome

| outcome | origem | significado |
|---|---|---|
| `accepted` | `ret`, `incoming:<corr>` | retorno nao falsy, ou incoming casado sem sinal de rejeicao |
| `weakly_accepted` | `ret_falsy`, `tree_delta:<path>:<field>` | retorno nil/false, ou campo plausivel mudou na janela |
| `rejected` | `ret_structural`, `incoming:<corr>` | `success=false`, `error!=nil`, ou string de rejeicao com word boundary |
| `silent` | — | sem incoming e sem mudanca, mas existe listener client |
| `timeout` | — | `InvokeServer` nao retornou em `invoke_timeout_ms` |
| `unknown` | `unobservable`, `ambiguous`, `remote_destroyed`, `err` | sem evidencia suficiente; err de cliente nunca e rejeicao |
| `pending` | — | par nao resolvido antes do close |

`rejected` exige `incoming` casado ou retorno estrutural. Ausencia de rejeicao nunca vira `accepted`.

## Ausente vs null

- Campo ausente: nao se aplica (ex.: `ret` em `FireServer`, `outcome` em `OnClientEvent`).
- Campo `null`: aplicava-se e o valor era nil.
- `redacted:true` + `sha` ou `redacted_short:true`: valor existia e foi removido pela §9.

## Limites conhecidos

- `likely_encrypted` em `buffer` e heuristica de entropia (>4.5 bits/byte, >=24 bytes); falso positivo em payload comprimido.
- `tree_delta` como corroboracao e plausibilidade, nao prova causal. `delta_ts_gap_ms` fica no registro.
- `remote_id` e estavel por sessao, nao entre sessoes. Use o nome em `remote` para cross-session.
- Nome de upvalue indisponivel no Delta (`debug.getupvalue` devolve so valor) -> redacao por hash do valor.
- `getscripthash` existe mas retorna nil -> todo hash e FNV-1a duplo 32 bits (16 hex).

## Correlacao entre arquivos

`calls.idx` tem uma linha por arquivo fechado, com `corr_first`/`corr_last`, `ts_min`/`ts_max`,
`seq_first`/`seq_last` e os indices `by_remote`, `by_source`, `by_action_n`.
O arquivo ativo nao tem idx; `manifest.idx_covers` lista os cobertos.

## Estado da arvore em tseq

`tree.ndjson` e o snapshot inicial. Aplique `tree_delta.ndjson` em ordem de `seq` enquanto `seq <= tseq`.
Ops sao idempotentes: `add` substitui, `change` sobrescreve, `remove` e no-op se o no sumiu.
Calls com `ts < snapshot_end_ts` carregam `tree_ready:false`.

## Changelog

- 2.4 — NDJSON com header, rotacao numerada, hash 64 bits, `corr` por VM, `action_sig`/`action_n`,
  `tseq`, `snapshot_start/end`, Pair FIFO por remote, `end.json` imutavel, SCHEMA.md gerado.
]==]

function Session.generate_schema(dir)
    dir = dir or DATA_DIR
    return write_file(dir .. "/SCHEMA.md", SCHEMA_MD)
end

-- ============================================================
-- tail safe (§10)
-- ============================================================

-- Valida a ultima linha de um NDJSON (usado no boot para sessoes sem end.json).
function Session.validate_tail(path)
    local ok, content = read_file(path)
    if not ok then return false, content end
    if #content == 0 then return false, "empty" end
    local trimmed = content:gsub("\n+$", "")
    local last = trimmed:match("([^\n]*)$")
    if not last or #last == 0 then return false, "no_line" end
    local dec_ok, obj = safe_decode(last)
    if not dec_ok or type(obj) ~= "table" then
        return false, "tail_unparseable"
    end
    return true, obj
end

-- ============================================================
-- new / begin
-- ============================================================

local function sanitize_id(s)
    s = tostring(s or "")
    s = s:gsub("[^%w%-_]", "")
    if #s > 40 then s = s:sub(1, 40) end
    return s
end

local function build_session_id(ts_start)
    local job = ""
    pcall(function() job = game.JobId end)
    job = sanitize_id(job)
    if job == "" then
        local place = 0
        pcall(function() place = game.PlaceId end)
        job = "place" .. tostring(place)
    end
    return string.format("%s_%d", job, ts_start)
end

function Session.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Session)
    self.dir = opts.dir or DATA_DIR
    self.mode = opts.mode or "full"
    self.parent_session = opts.parent_session
    self.config = opts.config or Session.load_config(self.dir)
    self.capabilities = opts.capabilities or Session.detect_capabilities()
    self.ts_start = opts.ts_start or now_ts()
    self.session = opts.session or build_session_id(self.ts_start)
    self.session_dir = self.dir .. "/" .. self.session
    self.started = false
    self.ended = false
    self.recorder = opts.recorder
    self.snapshot_start_ts = nil
    self.snapshot_end_ts = nil
    return self
end

function Session:path(name)
    return self.session_dir .. "/" .. name
end

function Session:meta()
    local place_id, game_id, place_version, game_name, job_id = 0, 0, 0, "", ""
    pcall(function()
        place_id = game.PlaceId
        game_id = game.GameId
        place_version = game.PlaceVersion
        game_name = game.Name
        job_id = game.JobId
    end)
    local streaming = false
    pcall(function() streaming = game:GetService("Workspace").StreamingEnabled end)

    return {
        schema = { major = SCHEMA_MAJOR, minor = SCHEMA_MINOR },
        session = self.session,
        parent_session = self.parent_session,
        ts_start = self.ts_start,
        place_id = place_id,
        game_id = game_id,
        place_version = place_version,
        game = game_name,
        job_id = job_id,
        streaming = streaming,
        executor = "Delta",
        platform = "Android",
        cobalt = "fork-v2.4",
        mode = self.mode,
        clock = string.format("os.clock+offset@%.3f", self.ts_start),
        config = self.config,
        capabilities = self.capabilities,
    }
end

function Session:write_manifest(extra)
    local files = extra and extra.files or (self.recorder and self.recorder.files) or {}
    local manifest = {
        schema = { major = SCHEMA_MAJOR, minor = SCHEMA_MINOR },
        files = { calls = files },
        idx_covers = extra and extra.idx_covers or {},
        idx_updated_ts = extra and extra.idx_updated_ts or 0,
        tree_stats = extra and extra.tree_stats or nil,
    }
    local ok, enc = safe_encode(manifest)
    if not ok then return false, enc end
    return write_file(self:path("manifest.json"), enc)
end

function Session:begin_session()
    if self.started then return false, "already_started" end
    ensure_dir(self.dir)
    ensure_dir(self.session_dir)

    -- recorder grava dentro do diretorio da sessao
    if self.recorder then
        self.recorder.session = self.session
        self.recorder.dir = self.session_dir
    end

    -- meta.json imutavel: nao sobrescreve se ja existe
    local meta_ok, meta_content = read_file(self:path("meta.json"))
    if not meta_ok or #meta_content == 0 then
        local enc_ok, enc = safe_encode(self:meta())
        if not enc_ok then return false, enc end
        local wrote, werr = write_file(self:path("meta.json"), enc)
        if not wrote then return false, werr end
    end

    local m_ok, m_err = self:write_manifest({ files = {}, idx_covers = {}, idx_updated_ts = 0 })
    if not m_ok then return false, m_err end

    local entries = idx_load(self.dir)
    local place_id = 0
    pcall(function() place_id = game.PlaceId end)
    entries[#entries + 1] = {
        session = self.session,
        place_id = place_id,
        ts_start = self.ts_start,
        ts_end = nil,
        mode = self.mode,
    }
    local i_ok, i_err = idx_store(self.dir, entries)
    if not i_ok then return false, i_err end

    Session.generate_schema(self.dir)

    self.started = true
    return true, self
end

-- ============================================================
-- close
-- ============================================================

function Session:close(reason, extra)
    if self.ended then return false, "already_ended" end
    if not self.started then return false, "not_started" end
    reason = reason or "manual"
    extra = extra or {}

    local stats = extra.stats
    local last_calls = extra.last_calls_file

    -- integra o Recorder: stop() faz o flush final e fecha a entrada do manifest
    if self.recorder then
        if not last_calls then last_calls = self.recorder:active_path() end
        pcall(function() self.recorder:stop() end)
        if not stats then stats = self.recorder:stats() end
        if not extra.files then extra.files = self.recorder.files end
    end
    stats = stats or { calls_raw = 0, records_written = 0 }

    -- valida tail do ultimo arquivo de calls; erro do recorder vale como truncado
    if last_calls then
        local ok = Session.validate_tail(last_calls)
        if not ok then stats.tail_truncated = true end
    end
    if stats.tail_truncated == nil then stats.tail_truncated = false end

    if extra.game_summary then
        local ok, enc = safe_encode(extra.game_summary)
        if ok then write_file(self:path("game_summary.json"), enc) end
    end
    if extra.remote_profiles then
        local ok, enc = safe_encode(extra.remote_profiles)
        if ok then write_file(self:path("remote_profiles.json"), enc) end
    end

    local end_record = {
        schema = { major = SCHEMA_MAJOR, minor = SCHEMA_MINOR },
        session = self.session,
        ts_end = extra.ts_end or (self.ts_start + os.clock()),
        closed = true,
        reason = reason,
        counts_final = stats,
        stats_by_remote = extra.stats_by_remote or {},
    }
    local enc_ok, enc = safe_encode(end_record)
    if not enc_ok then return false, enc end
    local wrote, werr = write_file(self:path("end.json"), enc)
    if not wrote then return false, werr end

    self:write_manifest({
        files = extra.files or (self.recorder and self.recorder.files) or {},
        idx_covers = extra.idx_covers or {},
        idx_updated_ts = now_ts(),
        tree_stats = extra.tree_stats,
    })

    -- sessions.idx: substitui a linha desta sessao
    local entries = idx_load(self.dir)
    local found = false
    for _, e in ipairs(entries) do
        if e.session == self.session then
            e.ts_end = end_record.ts_end
            e.mode = self.mode
            found = true
        end
    end
    if not found then
        entries[#entries + 1] = {
            session = self.session,
            ts_start = self.ts_start,
            ts_end = end_record.ts_end,
            mode = self.mode,
        }
    end
    idx_store(self.dir, entries)

    self.ended = true
    return true, end_record
end

Session["end"] = Session.close

-- ============================================================
-- boot: valida sessoes sem end.json (§6.2, §6.10)
-- ============================================================

function Session.boot_validate(dir)
    dir = dir or DATA_DIR
    local entries = idx_load(dir)
    local report = { checked = 0, missing_end = 0, valid = 0, truncated = 0, details = {} }
    for _, e in ipairs(entries) do
        if e.ts_end == nil and type(e.session) == "string" then
            report.checked = report.checked + 1
            local sdir = dir .. "/" .. e.session
            local end_ok = read_file(sdir .. "/end.json")
            if not end_ok then
                report.missing_end = report.missing_end + 1
                -- ultimo calls.NNNN.ndjson da sessao
                local last = nil
                if typeof(listfiles) == "function" then
                    local l_ok, files = pcall(listfiles, sdir)
                    if l_ok and type(files) == "table" then
                        for _, f in ipairs(files) do
                            if f:match("calls%.%d+%.ndjson$") then
                                if not last or f > last then last = f end
                            end
                        end
                    end
                end
                local tail_ok, tail = true, nil
                if last then tail_ok, tail = Session.validate_tail(last) end
                if tail_ok then
                    report.valid = report.valid + 1
                else
                    report.truncated = report.truncated + 1
                end
                report.details[#report.details + 1] = {
                    session = e.session,
                    file = last,
                    tail_ok = tail_ok,
                }
            end
        end
    end
    return true, report
end

return Session
