--[[
    Cobalt Fork v2.4 — Pair (Fase 3)
    FIFO por remote_id. Cada incoming consome no máximo uma outgoing pendente
    do mesmo remote_id. Rejeição estrutural do incoming antes de qualquer
    heurística de string. Expiração de pendentes sem janela.
]]

local Pair = {}
Pair.__index = Pair

local REJECT_WORDS = {
    rejected = true, invalid = true, denied = true,
    ratelimit = true, ratelimited = true, cooldown = true,
    kick = true, kicked = true, forbidden = true,
    unauthorised = true, unauthorized = true,
}

local function word_in(s)
    s = tostring(s):lower()
    for w in s:gmatch("[%w']+") do
        if REJECT_WORDS[w] then return true end
    end
    return false
end

-- rejeição estrutural do incoming.args[1] (§7.2)
local function incoming_rejected(args)
    if type(args) ~= "table" or #args == 0 then return false end
    local first = args[1]
    if type(first) == "table" then
        if first.success == false or first.ok == false then return true end
        for _, k in ipairs({ "error", "err", "reason", "message" }) do
            local v = first[k]
            if type(v) == "string" and #v > 0 then return true end
        end
        return false
    end
    if type(first) == "string" then
        return word_in(first)
    end
    return false
end

-- ============================================================
-- new
-- ============================================================

function Pair.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Pair)
    self.pair_window_ms = opts.pair_window_ms or 3000
    self.pending_cap = opts.pending_cap or 5000
    self.invoke_timeout_ms = opts.invoke_timeout_ms or 10000

    -- filas FIFO por remote_id: { {record, ts_push}, ... }
    self.pending = {}
    -- pendentes para expiração por tempo
    self.pending_ts = {}
    self.pending_count = 0

    -- stats por remote (alimenta end.json stats_by_remote)
    self.stats_by_remote = {}

    return self
end

local function remote_key(self, remote_id)
    return tostring(remote_id)
end

function Pair:_ensure_stats(remote_id, remote_name)
    local key = remote_key(self, remote_id)
    local st = self.stats_by_remote[key]
    if not st then
        st = {
            remote_id = remote_id,
            remote = remote_name,
            calls_raw = 0, accepted = 0, weakly_accepted = 0, rejected = 0,
            silent = 0, timeout = 0, pending = 0, unknown = 0, blocked = 0,
            callers = {},
        }
        self.stats_by_remote[key] = st
    end
    return st
end

-- ============================================================
-- push_outgoing(record) -> (ok, paired_or_nil)
-- Empilha outgoing pendente. Se já houver incoming esperando (raro), casal.
-- ============================================================

function Pair:push_outgoing(record)
    if record.blocked then
        self:_bump_stats(record, "blocked")
        return true, nil
    end
    local method = record.method
    if method == "InvokeServer" then
        -- invoke síncrono: não vai pra fila FIFO; fica pendente esperando ret/timeout
        self:_register_pending(record)
        return true, nil
    end
    -- FireServer / OnClientEvent: tenta casar com incoming já esperando
    local key = remote_key(self, record.remote_id)
    local queue = self.pending[key]
    if queue and #queue > 0 then
        -- incoming esperando? na fila de outgoing só entra outgoing. Incoming vem separado.
        -- aqui não há incoming; apenas enfileira.
    end
    self:_register_pending(record)
    return true, nil
end

function Pair:_register_pending(record)
    local key = remote_key(self, record.remote_id)
    self.pending[key] = self.pending[key] or {}
    table.insert(self.pending[key], { record = record, ts = record.ts or os.time(), tick = record.tick or 0 })
    self.pending_count = self.pending_count + 1
    local st = self:_ensure_stats(record.remote_id, record.remote)
    st.calls_raw = st.calls_raw + 1
    st.pending = st.pending + 1
    if st.callers then
        local src = record.src and record.src.path
        if src then
            local found = false
            for _, c in ipairs(st.callers) do
                if c.src == src then c.count = c.count + 1; found = true; break end
            end
            if not found then st.callers[#st.callers + 1] = { src = src, count = 1 } end
        end
    end
    -- backpressure: excede pending_cap → drop o mais antigo não-protegido
    if self.pending_count > self.pending_cap then
        self:_expire_oldest("expired_pressure")
    end
end

-- ============================================================
-- push_incoming(record) -> (ok, outcome, outcome_from, paired_corr)
-- Consome no máximo uma outgoing pendente FIFO do mesmo remote_id.
-- ============================================================

function Pair:push_incoming(record)
    if record.method ~= "OnClientEvent" and record.method ~= "OnClientInvoke" then
        return false, nil, nil, nil
    end
    local key = remote_key(self, record.remote_id)
    local queue = self.pending[key]
    local paired = nil
    if queue and #queue > 0 then
        paired = table.remove(queue, 1)
        self.pending_count = self.pending_count - 1
    end

    local st = self:_ensure_stats(record.remote_id, record.remote)
    st.calls_raw = st.calls_raw + 1

    if not paired then
        -- incoming sem outgoing: não gera par (schema: silent/unknown só com observable)
        return true, nil, nil, nil
    end

    local precord = paired.record
    local args = record.args or {}

    -- 1. rejeição estrutural
    if incoming_rejected(args) then
        precord.outcome = "rejected"
        precord.outcome_from = "incoming:" .. (record.corr or "?")
        st.rejected = st.rejected + 1
        st.pending = math.max(0, st.pending - 1)
        return true, "rejected", "incoming:" .. (record.corr or "?"), precord.corr
    end

    -- 2. casado sem rejeição → accepted
    precord.outcome = "accepted"
    precord.outcome_from = "incoming:" .. (record.corr or "?")
    st.accepted = st.accepted + 1
    st.pending = math.max(0, st.pending - 1)
    return true, "accepted", "incoming:" .. (record.corr or "?"), precord.corr
end

-- ============================================================
-- resolve_invoke(record, ret, err, elapsed_ms) -> outcome, outcome_from
-- Chamado quando InvokeServer retorna (ou timeout).
-- ============================================================

function Pair:resolve_invoke(record, ret, err, elapsed_ms)
    local st = self:_ensure_stats(record.remote_id, record.remote)
    st.calls_raw = st.calls_raw + 1

    if err then
        record.outcome = "unknown"
        record.outcome_from = "err"
        record.err = err
        st.unknown = st.unknown + 1
        self:_unregister(record)
        return "unknown", "err"
    end

    if elapsed_ms and elapsed_ms >= self.invoke_timeout_ms then
        record.outcome = "timeout"
        record.outcome_from = "timeout"
        st.timeout = st.timeout + 1
        self:_unregister(record)
        return "timeout", "timeout"
    end

    -- critério estrutural (§7.2)
    if ret == nil or ret == false then
        record.outcome = "weakly_accepted"
        record.outcome_from = "ret_falsy"
        st.weakly_accepted = st.weakly_accepted + 1
    elseif type(ret) == "table" then
        if ret.success == false or ret.ok == false or ret.error ~= nil or ret.err ~= nil or ret.reason ~= nil then
            record.outcome = "rejected"
            record.outcome_from = "ret_structural"
            st.rejected = st.rejected + 1
        else
            record.outcome = "accepted"
            record.outcome_from = "ret"
            st.accepted = st.accepted + 1
        end
    else
        record.outcome = "accepted"
        record.outcome_from = "ret"
        st.accepted = st.accepted + 1
    end

    record.ret = ret
    record.elapsed_ms = elapsed_ms
    self:_unregister(record)
    return record.outcome, record.outcome_from
end

-- ============================================================
-- expire(older_than_ts) -> resolvidos
-- Pendentes sem janela expiram: unknown/unobservable ou silent.
-- ============================================================

function Pair:expire(older_than_ts, observable_map)
    local resolved = {}
    for key, queue in pairs(self.pending) do
        local i = 1
        while i <= #queue do
            local entry = queue[i]
            local rec = entry.record
            if entry.ts < older_than_ts then
                table.remove(queue, i)
                self.pending_count = self.pending_count - 1
                local st = self:_ensure_stats(rec.remote_id, rec.remote)
                local obs = observable_map and observable_map[tostring(rec.remote_id)]
                if not obs then
                    rec.outcome = "unknown"
                    rec.outcome_from = "unobservable"
                    st.unknown = st.unknown + 1
                else
                    rec.outcome = "silent"
                    rec.outcome_from = nil
                    st.silent = st.silent + 1
                end
                st.pending = math.max(0, st.pending - 1)
                resolved[#resolved + 1] = rec
            else
                i = i + 1
            end
        end
    end
    return resolved
end

function Pair:_expire_oldest(reason)
    local oldest_key, oldest_entry, oldest_idx = nil, nil, nil
    for key, queue in pairs(self.pending) do
        for idx, entry in ipairs(queue) do
            if not oldest_entry or entry.ts < oldest_entry.ts then
                oldest_key, oldest_entry, oldest_idx = key, entry, idx
            end
        end
    end
    if oldest_entry then
        table.remove(self.pending[oldest_key], oldest_idx)
        self.pending_count = self.pending_count - 1
        local st = self:_ensure_stats(oldest_entry.record.remote_id, oldest_entry.record.remote)
        oldest_entry.record.outcome = "unknown"
        oldest_entry.record.outcome_from = reason
        st.unknown = st.unknown + 1
        st.pending = math.max(0, st.pending - 1)
    end
end

function Pair:_unregister(record)
    local key = remote_key(self, record.remote_id)
    local queue = self.pending[key]
    if queue then
        for i, entry in ipairs(queue) do
            if entry.record == record then
                table.remove(queue, i)
                self.pending_count = self.pending_count - 1
                break
            end
        end
    end
end

function Pair:pending_list()
    local out = {}
    for _, queue in pairs(self.pending) do
        for _, entry in ipairs(queue) do
            out[#out + 1] = entry.record
        end
    end
    return out
end

function Pair:stats()
    return self.stats_by_remote
end

return Pair
