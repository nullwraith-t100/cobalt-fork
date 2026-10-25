--[[
    Cobalt Fork v2.4 — Inventory (Fase 4)
    Constrói inventory.ndjson (§6.4): header + 1 linha por item.
    Itens: remote, script, filtered, late_remote.
    observable — remoto tem listener client-side OU correlaciona com campo plausível na tree.
    incoming_coverage — hooked / pre_existing / late.
]]

local Inventory = {}
Inventory.__index = Inventory

local HttpService = game:GetService("HttpService")

local function safe_encode(value)
    local ok, res = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return true, res end
    return false, tostring(res)
end

local function header(session, mode)
    return {
        _h = 1,
        schema = { major = 2, minor = 4 },
        file = "inventory",
        session = session,
        mode = mode,
        redaction = { on = true, regex_version = "v1" },
        ts_header = os.time(),
    }
end

function Inventory.new(session, mode)
    local self = setmetatable({}, Inventory)
    self.session = session
    self.mode = mode or "full"
    self.items = {}      -- linhas NDJSON (tabelas)
    self.remote_ids = {} -- path -> remote_id (estável na sessão)
    self.next_id = 1
    self.ignored_patterns = {} -- prefixos ignorados
    self.filtered = {}     -- linhas de kind:"filtered"
    return self
end

-- registra um padrão de filtro (prefixo ignorado)
function Inventory:add_filter(pattern)
    self.ignored_patterns[#self.ignored_patterns + 1] = pattern
end

-- ignora um remote se o path casar com algum padrão de filtro
function Inventory:is_ignored(path)
    for _, pat in ipairs(self.ignored_patterns) do
        if path:sub(1, #pat) == pat then return true end
    end
    return false
end

-- atribui um remote_id estável por path (único na sessão)
function Inventory:remote_id_for(path)
    local rid = self.remote_ids[path]
    if not rid then
        rid = self.next_id
        self.next_id = self.next_id + 1
        self.remote_ids[path] = rid
    end
    return rid
end

-- registra um remote visto
function Inventory:add_remote(path, class, opts)
    opts = opts or {}
    if self:is_ignored(path) then
        self.filtered[#self.filtered + 1] = {
            kind = "filtered",
            type = "prefix",
            pattern = opts.filter_pattern or path:match("^[^.]+%.[^.]+") or path,
        }
        return nil
    end
    local rid = self:remote_id_for(path)
    local unreliable = class == "UnreliableRemoteEvent"
    local item = {
        kind = "remote",
        remote_id = rid,
        path = path,
        class = class,
        unreliable = unreliable,
        tags = opts.tags or {},
        attrs = opts.attrs or {},
        ignored = false,
        observable = opts.observable or false,
        incoming_coverage = {
            hooked = opts.hooked or 0,
            pre_existing = opts.pre_existing or 0,
            late = opts.late or 0,
        },
        client_listeners = opts.client_listeners or {},
    }
    self.items[#self.items + 1] = item
    return rid
end

-- registra um script visto (sha do bytecode ou source)
function Inventory:add_script(path, bytecode_sha, size, decompile_ok, raw_bytecode, class)
    self.items[#self.items + 1] = {
        kind = "script",
        path = path,
        class = class or "Script",
        bytecode_sha = bytecode_sha,
        size = size or 0,
        decompile_ok = decompile_ok or false,
        raw_bytecode = raw_bytecode or false,
    }
end

-- registra um remote criado durante a sessão (late)
function Inventory:add_late_remote(path, remote_id, first_ts)
    self.items[#self.items + 1] = {
        kind = "late_remote",
        remote_id = remote_id,
        path = path,
        first_ts = first_ts or os.time(),
    }
end

-- escreve inventory.ndjson com header
function Inventory:write(session, mode)
    local lines = {}
    local ok, hline = safe_encode(header(session, mode))
    if not ok then return false, hline end
    lines[1] = hline
    for _, item in ipairs(self.items) do
        local ok, line = safe_encode(item)
        if ok then lines[#lines + 1] = line end
    end
    for _, f in ipairs(self.filtered) do
        local ok, line = safe_encode(f)
        if ok then lines[#lines + 1] = line end
    end
    return table.concat(lines, "\n") .. "\n"
end

-- estatísticas do inventory (para game_summary / remote_profiles)
function Inventory:stats()
    local remotes, scripts, filtered, late = 0, 0, 0, 0
    local observable = 0
    local unobservable = 0
    local by_prefix = {}
    local by_class = {}
    for _, item in ipairs(self.items) do
        if item.kind == "remote" then
            remotes = remotes + 1
            by_class[item.class] = (by_class[item.class] or 0) + 1
            if item.observable then observable = observable + 1 else unobservable = unobservable + 1 end
            local prefix = item.path:match("^[^.]+%.[^.]+%.[^.]+") or "Misc"
            by_prefix[prefix] = (by_prefix[prefix] or 0) + 1
        elseif item.kind == "script" then
            scripts = scripts + 1
        elseif item.kind == "late_remote" then
            late = late + 1
        end
    end
    for _, f in ipairs(self.filtered) do
        filtered = filtered + 1
    end
    return {
        remotes = remotes, scripts = scripts, filtered = filtered, late = late,
        observable = observable, unobservable = unobservable,
        by_prefix = by_prefix, by_class = by_class,
    }
end

return Inventory
