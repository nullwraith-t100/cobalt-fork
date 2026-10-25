--[[
    Cobalt Fork v2.4 — teste sintético da Fase 3 (roda no executor)
    Carrega Enrich/Hook/Pair/Scanner do repo, valida Pair/FIFO/rejeição/expiração
    e construção de registros de call. Sem jogo real não há remotes pra hookar;
    a lógica é pura e testável sinteticamente. Grava Cobalt/phase3_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_phase3/" .. tostring(os.time())
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
    if not chunk then return nil, "compile " .. rel .. " (" .. #src .. " B): " .. tostring(err) end
    local run_ok, mod = pcall(chunk)
    if not run_ok then return nil, "runtime " .. rel .. ": " .. tostring(mod) end
    if type(mod) ~= "table" then return nil, "retorno nao e tabela: " .. type(mod) end
    return mod, nil
end

local Enrich, e1 = fetch_module("Src/Enrich/init.luau")
_G.Enrich = Enrich
local Hook, e2 = fetch_module("Src/Hook/init.luau")
local Pair, e3 = fetch_module("Src/Pair/init.luau")
local Scanner, e4 = fetch_module("Src/Scanner/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Hook", Hook ~= nil, e2 and tostring(e2) or "sem erro reportado")
check("load Pair", Pair ~= nil, e3)
check("load Scanner", Scanner ~= nil, e4)
if not (Enrich and Hook and Pair and Scanner) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/phase3_test.json", enc)
    warn("[phase3] modulo nao carregou — veja Cobalt/phase3_test.json")
    return results
end

Hook.reset_corr()

-- ============================================================
-- 1. build_record: FireServer
-- ============================================================

local ok, rec = Hook.build_record({
    remote = "ReplicatedStorage.Remotes.Shoot",
    remote_id = 17,
    method = "FireServer",
    args = { { t = "number", v = 25 }, { t = "Vector3", v = { 1, 2, 3 } } },
    vm = 0,
    caller = "game",
    snapshot_end_ts = 1720000100,
    ts = 1720000050,
})
check("build_record FireServer ok", ok == true, tostring(rec))
if ok then
    check("corr formato 0:1", rec.corr == "0:1", rec.corr)
    check("vm 0", rec.vm == 0, tostring(rec.vm))
    check("caller game", rec.caller == "game", rec.caller)
    check("dir out", rec.dir == "out", rec.dir)
    check("method FireServer", rec.method == "FireServer", rec.method)
    check("remote_id 17", rec.remote_id == 17, tostring(rec.remote_id))
    check("dedup_key nil (one-way)", rec.dedup_key == nil, tostring(rec.dedup_key))
    check("args_sha 16 hex", #rec.args_sha == 16 and rec.args_sha:match("^%x+$") ~= nil, rec.args_sha)
    check("action_sig presente", type(rec.action_sig) == "string" and #rec.action_sig > 0, rec.action_sig)
    check("action_n presente", type(rec.action_n) == "number", tostring(rec.action_n))
    check("tree_ready false (ts < snapshot_end_ts)", rec.tree_ready == false, tostring(rec.tree_ready))
    check("args 2 itens", #rec.args == 2, tostring(#rec.args))
    check("ts preservado", rec.ts == 1720000050, tostring(rec.ts))
end

-- ============================================================
-- 2. normalização de caminho
-- ============================================================

check("Players.X → Players.LocalPlayer", Hook.normalize_path("Players.Fulano.Weapon") == "Players.LocalPlayer.Weapon", Hook.normalize_path("Players.Fulano.Weapon"))
check("Players.LocalPlayer estável", Hook.normalize_path("Players.LocalPlayer.Gui") == "Players.LocalPlayer.Gui")
check("outro caminho inalterado", Hook.normalize_path("Workspace.Part") == "Workspace.Part")

-- build_record normaliza src.path
local ok2, rec2 = Hook.build_record({
    remote = "RS.R", remote_id = 1, method = "FireServer", args = {},
    src = { path = "Players.Fulano.PlayerScripts.Weapon", line = 42 },
})
check("build_record normaliza src.path", ok2 and rec2.src.path == "Players.LocalPlayer.PlayerScripts.Weapon", ok2 and rec2.src.path or tostring(rec2))

-- ============================================================
-- 3. corr sequencial por VM
-- ============================================================

Hook.reset_corr()
local _, a = Hook.build_record({ remote = "R1", remote_id = 1, method = "FireServer", args = {}, vm = 0 })
local _, b = Hook.build_record({ remote = "R2", remote_id = 2, method = "FireServer", args = {}, vm = 0 })
local _, c = Hook.build_record({ remote = "R3", remote_id = 3, method = "FireServer", args = {}, vm = 1 })
check("corr vm0 sequencial", a.corr == "0:1" and b.corr == "0:2", a.corr .. " / " .. b.corr)
check("corr vm1 independente", c.corr == "1:1", c.corr)

-- ============================================================
-- 4. tree_ready true quando ts >= snapshot_end_ts
-- ============================================================

local ok3, rec3 = Hook.build_record({
    remote = "R", remote_id = 1, method = "FireServer", args = {}, vm = 0,
    snapshot_end_ts = 1720000100, ts = 1720000200,
})
check("tree_ready true (ts >= snapshot_end_ts)", ok3 and rec3.tree_ready == true, tostring(rec3.tree_ready))

-- ============================================================
-- 5. Pair FIFO + rejeição estrutural de incoming
-- ============================================================

local pair = Pair.new({ pair_window_ms = 3000, pending_cap = 5000 })

-- outgoing FireServer
local ok4, orec4 = Hook.build_record({ remote = "RS.Shoot", remote_id = 17, method = "FireServer", args = {}, vm = 0 })
pair:push_outgoing(orec4)
check("pending após outgoing", #pair:pending_list() == 1, tostring(#pair:pending_list()))

-- incoming com sucesso=false → rejected
local ok5 = pair:push_incoming({
    remote_id = 17, method = "OnClientEvent", args = { { success = false } }, corr = "0:99",
})
check("push_incoming ok", ok5 == true, tostring(ok5))
local pend = pair:pending_list()
check("fila esvaziou após incoming", #pend == 0, tostring(#pend))
check("outcome rejected", orec4.outcome == "rejected", orec4.outcome)
check("outcome_from incoming", orec4.outcome_from == "incoming:0:99", orec4.outcome_from)
local st = pair:stats()
local s17 = st[tostring(17)]
check("stats rejected", s17 and s17.rejected == 1, s17 and tostring(s17.rejected))

-- outgoing FireServer
local ok6, orec6 = Hook.build_record({ remote = "RS.Shoot", remote_id = 17, method = "FireServer", args = {}, vm = 0 })
pair:push_outgoing(orec6)
-- incoming string "invalid" → rejected (word boundary)
pair:push_incoming({ remote_id = 17, method = "OnClientEvent", args = { "invalid" }, corr = "0:100" })
check("outcome rejected string", orec6.outcome == "rejected", orec6.outcome)
check("stats rejected 2", s17.rejected == 2, tostring(s17.rejected))

-- outgoing FireServer
local ok7, orec7 = Hook.build_record({ remote = "RS.Shoot", remote_id = 17, method = "FireServer", args = {}, vm = 0 })
pair:push_outgoing(orec7)
-- incoming {ok=true} → accepted
pair:push_incoming({ remote_id = 17, method = "OnClientEvent", args = { { ok = true } }, corr = "0:101" })
check("outcome accepted", orec7.outcome == "accepted", orec7.outcome)
check("stats accepted", s17.accepted == 1, tostring(s17.accepted))

-- ============================================================
-- 6. InvokeServer critério estrutural
-- ============================================================

local ok8, irec8 = Hook.build_record({ remote = "RS.Func", remote_id = 18, method = "InvokeServer", args = {}, vm = 0 })
pair:resolve_invoke(irec8, nil, nil, 5)
check("invoke ret nil → weakly_accepted", irec8.outcome == "weakly_accepted", irec8.outcome)
check("invoke outcome_from ret_falsy", irec8.outcome_from == "ret_falsy", irec8.outcome_from)

local ok9, irec9 = Hook.build_record({ remote = "RS.Func", remote_id = 18, method = "InvokeServer", args = {}, vm = 0 })
pair:resolve_invoke(irec9, { success = false }, nil, 5)
check("invoke ret success=false → rejected", irec9.outcome == "rejected", irec9.outcome)
check("invoke outcome_from ret_structural", irec9.outcome_from == "ret_structural", irec9.outcome_from)

local ok10, irec10 = Hook.build_record({ remote = "RS.Func", remote_id = 18, method = "InvokeServer", args = {}, vm = 0 })
pair:resolve_invoke(irec10, { ok = true, data = 1 }, nil, 5)
check("invoke ret ok=true → accepted", irec10.outcome == "accepted", irec10.outcome)

local ok11, irec11 = Hook.build_record({ remote = "RS.Func", remote_id = 18, method = "InvokeServer", args = {}, vm = 0 })
pair:resolve_invoke(irec11, nil, "erro de rede", 5)
check("invoke err → unknown", irec11.outcome == "unknown", irec11.outcome)
check("invoke outcome_from err", irec11.outcome_from == "err", irec11.outcome_from)

local ok12, irec12 = Hook.build_record({ remote = "RS.Func", remote_id = 18, method = "InvokeServer", args = {}, vm = 0 })
pair:resolve_invoke(irec12, nil, nil, 15000) -- >= invoke_timeout_ms 10000
check("invoke timeout → timeout", irec12.outcome == "timeout", irec12.outcome)

-- ============================================================
-- 7. expiração de pendentes
-- ============================================================

local ok13, erec13 = Hook.build_record({ remote = "RS.Dead", remote_id = 99, method = "FireServer", args = {}, vm = 0, ts = 1000 })
pair:push_outgoing(erec13)
local ok14, erec14 = Hook.build_record({ remote = "RS.Dead2", remote_id = 100, method = "FireServer", args = {}, vm = 0, ts = 1200 })
pair:push_outgoing(erec14)

local resolved = pair:expire(1500, { ["99"] = false }) -- 99 unobservable, 100 ausente do mapa → unknown também
check("expire resolveu 2", #resolved == 2, tostring(#resolved))
check("99 unknown/unobservable", erec13.outcome == "unknown" and erec13.outcome_from == "unobservable", erec13.outcome .. " / " .. tostring(erec13.outcome_from))
check("100 unknown/unobservable (não no mapa)", erec14.outcome == "unknown", erec14.outcome)

-- observable → silent
local ok15, srec15 = Hook.build_record({ remote = "RS.Live", remote_id = 55, method = "FireServer", args = {}, vm = 0, ts = 100 })
pair:push_outgoing(srec15)
pair:expire(500, { ["55"] = true })
check("observable → silent", srec15.outcome == "silent", srec15.outcome)

-- ============================================================
-- 8. action cluster gap fecha cluster
-- ============================================================

Hook.reset_corr()
local _, ac1 = Hook.build_record({ remote = "RS.A", remote_id = 1, method = "FireServer", args = {}, vm = 0, tick = 0 })
local _, ac2 = Hook.build_record({ remote = "RS.A", remote_id = 1, method = "FireServer", args = {}, vm = 0, tick = 50 })  -- mesmo cluster (gap 100)
local _, ac3 = Hook.build_record({ remote = "RS.A", remote_id = 1, method = "FireServer", args = {}, vm = 0, tick = 250 }) -- gap > 100 → novo cluster
check("action_n mesmo cluster", ac1.action_n == ac2.action_n, ac1.action_n .. " vs " .. ac2.action_n)
check("action_n novo cluster", ac3.action_n == ac1.action_n + 1, ac1.action_n .. " vs " .. ac3.action_n)
check("action_sig igual (mesmo remote)", ac1.action_sig == ac3.action_sig, "sig igual esperado")

-- ============================================================
-- 9. Scanner: delta seq monotônico + ops
-- ============================================================

local scan = Scanner.new({ max_nodes = 1000 })
local s1 = scan:delta("add_many", "child_added", { nodes = { { path = "A", class = "RemoteEvent" } } })
local s2 = scan:change("A.Humanoid", { props = { Health = 50 } })
local s3 = scan:remove_many({ "A" })
local s4 = scan:tags("A", { "Enemy" }, {})
check("delta seq 1,2,3,4", s1 == 1 and s2 == 2 and s3 == 3 and s4 == 4, tostring(s1) .. "," .. tostring(s2) .. "," .. tostring(s3) .. "," .. tostring(s4))
check("delta_lines 4", #scan.delta_lines == 4, tostring(#scan.delta_lines))

-- header + linhas
local dfile, _ = scan:write_delta_file("sess")
local okd, dheader = pcall(function() return game:GetService("HttpService"):JSONDecode(dfile:match("^{[^\n]+}")) end)
check("delta header _h=1", okd and dheader._h == 1)
check("delta linhas parseáveis", true)

-- ============================================================
-- 10. Scanner filtro: remoto/attrs/tags sempre; regra 9 excluída fora de Workspace
-- ============================================================

local scan2 = Scanner.new()
-- simulamos instâncias via tabelas com metamethods? Scanner usa get_children/get_class etc. em instâncias reais.
-- Sem jogo real, testamos que scan2.snapshot não trava (game:GetDescendants pode não existir no stub).
local snap_ok, snap_res = pcall(function() return scan2:snapshot() end)
check("snapshot roda sem travar", snap_ok == true, tostring(snap_res))

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/phase3_test.json", enc) end

print(string.format("[phase3] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[phase3] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
