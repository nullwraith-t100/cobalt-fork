--[[
    Cobalt Fork v2.4 — Derive (Fase 4)
    Gera game_summary.json (§6.11) e remote_profiles.json (§6.12) a partir
    dos dados coletados na sessão (inventory, calls, pair stats). Offline.
]]

local Derive = {}
Derive.__index = Derive

local HttpService = game:GetService("HttpService")

local function safe_encode(value)
    local ok, res = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return true, res end
    return false, tostring(res)
end

function Derive.new(inventory, calls, pair_stats)
    local self = setmetatable({}, Derive)
    self.inventory = inventory   -- tabela Inventory
    self.calls = calls or {}     -- lista de registros de call
    self.pair_stats = pair_stats or {} -- stats_by_remote do Pair
    return self
end

-- game_summary.json (§6.11)
function Derive:game_summary(session, game_id, place_version)
    local inv_stats = self.inventory:stats()
    local class_histogram = {}
    local attrs_top = {}
    local tags_top = {}

    -- classe dos nós da tree (se disponível via inventory.itens de script)
    -- aqui agregamos o que temos
    local scripts_by_type = {}
    for _, item in ipairs(self.inventory.items) do
        if item.kind == "script" then
            local t = item.class == "ModuleScript" and "ModuleScript" or
                      item.class == "LocalScript" and "LocalScript" or "Script"
            scripts_by_type[t] = (scripts_by_type[t] or 0) + 1
        end
    end

    -- contagem de remotes por prefixo
    local remotes_by_prefix = {}
    for prefix, n in pairs(inv_stats.by_prefix) do
        remotes_by_prefix[prefix] = n
    end

    -- classes vistas (heurística: itens de remote têm class)
    for class, n in pairs(inv_stats.by_class) do
        class_histogram[class] = n
    end

    return {
        schema = { major = 2, minor = 4 },
        session = session,
        game_id = game_id or 0,
        place_version = place_version or 0,
        class_histogram = class_histogram,
        attrs_top = attrs_top,
        tags_top = tags_top,
        leaderstats_keys = {},
        player_gui_roots = {},
        remotes_by_prefix = remotes_by_prefix,
        scripts_by_type = scripts_by_type,
        observable_remotes = inv_stats.observable,
        unobservable_remotes = inv_stats.unobservable,
    }
end

-- remote_profiles.json (§6.12)
function Derive:remote_profiles()
    local profiles = {}
    for _, item in ipairs(self.inventory.items) do
        local is_remote = (item.kind == "remote")
        if is_remote then
            local rid = tostring(item.remote_id)
            local path = item.path
            local st = self.pair_stats[rid] or self.pair_stats[path] or {}
            local calls = 0
            for _, c in ipairs(self.calls) do
                if tostring(c.remote_id) == rid or c.remote == path then
                    calls = calls + 1
                end
            end

            -- aridades e tipos por posição a partir dos calls reais
            local arities = {}
            local arg_types_by_pos = {}
            local callers = {}
            local first_ts, last_ts
            local response_candidates = {}
            local correlated_tree_fields = {}

            for _, c in ipairs(self.calls) do
                if tostring(c.remote_id) == rid or c.remote == path then
                    local n = #(c.args or {})
                    arities[n] = (arities[n] or 0) + 1
                    if c.ts then
                        if not first_ts or c.ts < first_ts then first_ts = c.ts end
                        if not last_ts or c.ts > last_ts then last_ts = c.ts end
                    end
                    local src = c.src and c.src.path
                    if src then
                        local found = false
                        for _, cal in ipairs(callers) do
                            if cal.src == src then cal.count = cal.count + 1; found = true; break end
                        end
                        if not found then callers[#callers + 1] = { src = src, count = 1 } end
                    end
                    -- tipos por posição
                    for i, a in ipairs(c.args or {}) do
                        arg_types_by_pos[i] = arg_types_by_pos[i] or {}
                        local t = a.t or "?"
                        arg_types_by_pos[i][t] = (arg_types_by_pos[i][t] or 0) + 1
                    end
                    -- intercept sample (um por remote)
                    if not response_candidates[1] then
                        response_candidates[1] = string.format(
                            'game:GetService("%s"):%s(%s)',
                            path:match("^([^.]+)") or "ReplicatedStorage",
                            c.method or "FireServer",
                            #(c.args or {})
                        )
                    end
                end
            end

            -- arg_types_by_pos: converter mapa de contagens para lista ordenada
            local atbp = {}
            for i, m in pairs(arg_types_by_pos) do
                local entry = {}
                for t, cnt in pairs(m) do entry[#entry + 1] = { t = t, n = cnt } end
                atbp[i] = entry
            end

            -- outcome_counts a partir dos calls resolvidos
            local outcome_counts = {}
            for _, c in ipairs(self.calls) do
                if (tostring(c.remote_id) == rid or c.remote == path) and c.outcome then
                    outcome_counts[c.outcome] = (outcome_counts[c.outcome] or 0) + 1
                end
            end

            profiles[path] = {
                remote_id = item.remote_id,
                calls_raw = calls,
                arities = arities,
                arg_types_by_pos = atbp,
                pos_constants = {},
                numeric_ranges = {},
                enums_seen = {},
                dt_ms = st.dt_ms or { min = 0, median = 0, max = 0, p95 = 0 },
                callers = callers,
                response_candidates = response_candidates,
                correlated_tree_fields = correlated_tree_fields,
                observable = item.observable or false,
                outcome_counts = outcome_counts,
                intercept_sample = response_candidates[1],
            }
        end
    end
    return profiles
end

-- escreve ambos os arquivos
function Derive:write(session_dir, session, game_id, place_version)
    local ok1, gs = safe_encode(self:game_summary(session, game_id, place_version))
    if ok1 then
        pcall(function() writefile(session_dir .. "/game_summary.json", gs) end)
    end
    local ok2, rp = safe_encode(self:remote_profiles())
    if ok2 then
        pcall(function() writefile(session_dir .. "/remote_profiles.json", rp) end)
    end
    return ok1 and ok2, ok1 and gs or nil, ok2 and rp or nil
end

return Derive
