--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 3: Dedup (roda no executor)
    Valida agregacao por args_sha, contagem, ts_first/ts_last, dt_ms,
    nao-fusao entre action_n diferente, modo lite com dedup_key.
    Grava Cobalt/dedup_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_dedup/" .. tostring(os.time())
local results = {}
local failed = 0

local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    if not ok then failed = failed + 1 end
end

local function fetch_module(rel)
    local ok, src = pcall(function() return game:HttpGet(BASE .. rel) end)
    if not ok or type(src) ~= "string" then return nil, "HttpGet: " .. tostring(src) end
    local chunk, err = loadstring(src)
    if not chunk then return nil, string.format("compile %s (%d B): %s", rel, #src, tostring(err)) end
    local run_ok, mod = pcall(chunk)
    if not run_ok then return nil, "runtime " .. rel .. ": " .. tostring(mod) end
    if type(mod) ~= "table" then return nil, "retorno nao e tabela: " .. type(mod) end
    return mod, nil
end

local Enrich, e1 = fetch_module("Src/Enrich/init.luau")
local Dedup, e2 = fetch_module("Src/Dedup/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Dedup", Dedup ~= nil, e2)
if not (Enrich and Dedup) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/dedup_test.json", enc)
    warn("[dedup] modulo nao carregou — veja Cobalt/dedup_test.json")
    return results
end

_G.Enrich = Enrich

-- ============================================================
-- 1. modo full: mesma args_sha + mesmo action_n agrega
-- ============================================================

local dedup = Dedup.new("full")

local sha_a = Enrich.hash64("args_a")
local sha_b = Enrich.hash64("args_b")

local r1 = {
    corr = "0:1", ts = 1000, remote_id = 17, method = "FireServer",
    args_sha = sha_a, action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted", outcome_from = "incoming:0:99",
}
local r2 = {
    corr = "0:2", ts = 1005, remote_id = 17, method = "FireServer",
    args_sha = sha_a, action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted", outcome_from = "incoming:0:99",
}
local r3 = {
    corr = "0:3", ts = 1010, remote_id = 17, method = "FireServer",
    args_sha = sha_b, action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted", outcome_from = "incoming:0:99",
}

local ok1, out1 = dedup:dedup(r1)
check("dedup primeira chamada retorna registro", ok1 == true and type(out1) == "table", tostring(out1))
check("count inicia em 1", out1.count == 1, tostring(out1.count))
check("ts_first igual ts", out1.ts_first == 1000, tostring(out1.ts_first))
check("ts_last igual ts", out1.ts_last == 1000, tostring(out1.ts_last))

local ok2, out2 = dedup:dedup(r2)
check("dedup mesma chave + action_n agrega (nao retorna ainda)", ok2 == true and out2 == nil, tostring(out2))

local ok3, out3 = dedup:dedup(r3)
check("dedup args_sha diferente retorna registro", ok3 == true and type(out3) == "table", tostring(out3))

-- flush deve retornar r1 agregado (count=2) e r3 (count=1)
local flushed = dedup:flush()
check("flush retorna 2 registros", #flushed == 2, tostring(#flushed))

local agg_a = flushed[1]
local agg_b = flushed[2]
-- identificar qual e qual
if agg_a.args_sha == sha_a then
    check("agregado sha_a count=2", agg_a.count == 2, tostring(agg_a.count))
    check("agregado sha_a dt_ms min=5000", agg_a.dt_ms.min == 5000, tostring(agg_a.dt_ms.min))
    check("agregado sha_a dt_ms max=5000", agg_a.dt_ms.max == 5000, tostring(agg_a.dt_ms.max))
    check("agregado sha_a ts_first=1000", agg_a.ts_first == 1000, tostring(agg_a.ts_first))
    check("agregado sha_a ts_last=1005", agg_a.ts_last == 1005, tostring(agg_a.ts_last))
else
    check("agregado sha_a count=2 (ordem invertida)", agg_b.count == 2, tostring(agg_b.count))
end

-- ============================================================
-- 2. nao funde entre action_n diferente
-- ============================================================

local dedup2 = Dedup.new("full")
local r4 = {
    corr = "0:4", ts = 2000, remote_id = 17, method = "FireServer",
    args_sha = sha_a, action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted",
}
local r5 = {
    corr = "0:5", ts = 2010, remote_id = 17, method = "FireServer",
    args_sha = sha_a, action_n = 2, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted",
}

local ok4, o4 = dedup2:dedup(r4)
check("dedup2 primeira", ok4 == true and type(o4) == "table")
local ok5, o5 = dedup2:dedup(r5)
-- mesma args_sha mas action_n diferente -> deve retornar registro separado (nao agrega com o anterior)
check("dedup nao funde entre action_n diferente", ok5 == true and type(o5) == "table", tostring(o5))

local flushed2 = dedup2:flush()
check("flush2 retorna 2 registros (action_n diferentes)", #flushed2 == 2, tostring(#flushed2))

-- ============================================================
-- 3. modo lite: usa dedup_key
-- ============================================================

local dedup3 = Dedup.new("lite")
local r6 = {
    corr = "0:6", ts = 3000, remote_id = 17, method = "FireServer",
    dedup_key = "dk1", action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted",
}
local r7 = {
    corr = "0:7", ts = 3005, remote_id = 17, method = "FireServer",
    dedup_key = "dk1", action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted",
}

local ok6, o6 = dedup3:dedup(r6)
check("lite primeira", ok6 == true and type(o6) == "table")
local ok7, o7 = dedup3:dedup(r7)
check("lite mesma dedup_key agrega", ok7 == true and o7 == nil)

local flushed3 = dedup3:flush()
check("lite flush retorna 1 registro com count=2", #flushed3 == 1 and flushed3[1].count == 2, tostring(#flushed3) .. " / " .. tostring(flushed3[1] and flushed3[1].count))

-- ============================================================
-- 4. pending() nao esvazia, flush() esvazia
-- ============================================================

local dedup4 = Dedup.new("full")
local r8 = {
    corr = "0:8", ts = 4000, remote_id = 17, method = "FireServer",
    args_sha = sha_a, action_n = 1, caller = "game",
    src = { path = "Players.LocalPlayer.Weapon", line = 42 },
    outcome = "accepted",
}
dedup4:dedup(r8)
local pend = dedup4:pending()
check("pending nao esvazia", #pend == 1 and #dedup4:pending() == 1, tostring(#pend))
local flushed4 = dedup4:flush()
check("flush esvazia", #flushed4 == 1 and #dedup4:pending() == 0, tostring(#dedup4:pending()))

-- ============================================================
-- 5. dt_ms com 3+ amostras
-- ============================================================

local dedup5 = Dedup.new("full")
local ts_vals = { 5000, 5010, 5030, 5035 }
for i, ts in ipairs(ts_vals) do
    local rr = {
        corr = "0:" .. (100 + i), ts = ts, remote_id = 17, method = "FireServer",
        args_sha = sha_a, action_n = 1, caller = "game",
        src = { path = "Players.LocalPlayer.Weapon", line = 42 },
        outcome = "accepted",
    }
    dedup5:dedup(rr)
end
local flushed5 = dedup5:flush()
check("dt_ms 4 amostras", #flushed5 == 1, tostring(#flushed5))
local d = flushed5[1].dt_ms
check("dt_ms min=5000", d.min == 5000, tostring(d.min))
check("dt_ms max=20000", d.max == 20000, tostring(d.max))
check("dt_ms median=5000/10000/20000", d.median == 5000 or d.median == 10000 or d.median == 20000, tostring(d.median))

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/dedup_test.json", enc) end

print(string.format("[dedup] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[dedup] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
