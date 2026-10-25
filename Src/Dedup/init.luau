--[[
    Cobalt Fork v2.4 — Dedup (Fase 7, lacuna 3)
    Agrega calls iguais por args_sha (full) ou dedup_key (lite): contagem,
    ts_first/ts_last e distribuicao dt_ms (min/median/max). Nao funde entre
    action_n diferente (dedup nao atravessa action clusters).
]]

local Dedup = {}
Dedup.__index = Dedup

function Dedup.new(mode)
    local self = setmetatable({}, Dedup)
    self.mode = mode or "full"
    -- chave dedup -> registro agregado
    self.aggregated = {}
    -- ordem de insercao para saida deterministica
    self.order = {}
    return self
end

-- chave de dedup: full usa args_sha; lite usa dedup_key
local function dedup_key(self, record)
    if self.mode == "lite" then
        return record.dedup_key or ("lite:" .. tostring(record.remote_id) .. ":" .. tostring(record.method))
    end
    return record.args_sha or ("full:" .. tostring(record.remote_id) .. ":" .. tostring(record.method))
end

-- ============================================================
-- dedup(record) -> (ok, record_or_nil)
-- Se ja existe uma entrada com mesma chave e mesmo action_n, agrega.
-- Se action_n diferente, retorna o registro para saida independente.
-- ============================================================

function Dedup:dedup(record)
    local key = dedup_key(self, record)
    local action_n = record.action_n or 0
    local agg_key = key .. ":" .. tostring(action_n)

    local existing = self.aggregated[agg_key]
    if not existing then
        -- primeira vez: cria entrada agregada
        local copy = {}
        for k, v in pairs(record) do copy[k] = v end
        copy.count = 1
        copy.ts_first = record.ts or os.time()
        copy.ts_last = record.ts or os.time()
        copy.dt_ms = { min = 0, median = 0, max = 0 }
        copy._dt_samples = {}
        copy._last_ts = record.ts or os.time()
        self.aggregated[agg_key] = copy
        self.order[#self.order + 1] = agg_key
        return true, copy
    end

    -- agrega: incrementa count, atualiza ts, adiciona amostra dt_ms
    existing.count = existing.count + 1
    local ts = record.ts or os.time()
    if ts < existing.ts_first then existing.ts_first = ts end
    if ts > existing.ts_last then existing.ts_last = ts end

    -- dt_ms: diferenca entre esta call e a anterior do mesmo grupo
    local prev_ts = existing._last_ts
    if prev_ts then
        local dt = math.floor((ts - prev_ts) * 1000)
        table.insert(existing._dt_samples, dt)
    end
    existing._last_ts = ts

    -- recalcula estatisticas dt_ms
    local samples = existing._dt_samples
    if #samples > 0 then
        local sorted = {}
        for _, s in ipairs(samples) do table.insert(sorted, s) end
        table.sort(sorted)
        local n = #sorted
        existing.dt_ms = {
            min = sorted[1],
            max = sorted[n],
            median = sorted[math.floor((n + 1) / 2)],
        }
    end

    -- retorna nil: ainda nao e hora de saida (espera mais dedup ou expiracao)
    return true, nil
end

-- ============================================================
-- flush(): retorna todos os registros agregados prontos para saida
-- ============================================================

function Dedup:flush()
    local out = {}
    for _, agg_key in ipairs(self.order) do
        local entry = self.aggregated[agg_key]
        -- remove campo interno
        entry._dt_samples = nil
        entry._last_ts = nil
        out[#out + 1] = entry
    end
    self.aggregated = {}
    self.order = {}
    return out
end

-- ============================================================
-- pending(): retorna registros agregados ainda nao finalizados
-- (para expiracao no close)
-- ============================================================

function Dedup:pending()
    local out = {}
    for _, agg_key in ipairs(self.order) do
        local entry = self.aggregated[agg_key]
        entry._dt_samples = nil
        entry._last_ts = nil
        out[#out + 1] = entry
    end
    return out
end

return Dedup
