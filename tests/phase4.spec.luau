--[[
    Cobalt Fork v2.4 — teste sintético da Fase 4 (roda no executor)
    Carrega Enrich/Inventory/Derive/Diff do repo, valida inventory.ndjson,
    game_summary.json, remote_profiles.json e diff cross-session. Grava
    Cobalt/phase4_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_phase4/" .. tostring(os.time())
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
local Inventory, e2 = fetch_module("Src/Inventory/init.luau")
local Derive, e3 = fetch_module("Src/Derive/init.luau")
local Diff, e4 = fetch_module("Src/Diff/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Inventory", Inventory ~= nil, e2)
check("load Derive", Derive ~= nil, e3)
check("load Diff", Diff ~= nil, e4)
if not (Enrich and Inventory and Derive and Diff) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/phase4_test.json", enc)
    warn("[phase4] modulo nao carregou — veja Cobalt/phase4_test.json")
    return results
end

_G.Enrich = Enrich

-- ============================================================
-- 1. Inventory: add_remote, write, header
-- ============================================================

local inv = Inventory.new("sess_1", "full")
inv:add_filter("ReplicatedStorage.Assets.Decor")
inv:add_remote("ReplicatedStorage.Remotes.Shoot", "RemoteEvent", {
    tags = { "Combat" }, attrs = {}, observable = false,
    hooked = 0, pre_existing = 0, late = 0,
})
inv:add_remote("ReplicatedStorage.Remotes.Chat", "RemoteEvent", {
    tags = {}, attrs = {}, observable = true,
    hooked = 1, pre_existing = 1, late = 0,
    client_listeners = { { script = "Players.LocalPlayer.Chat", line = 30, fn = "onMsg" } },
})
inv:add_remote("ReplicatedStorage.Assets.Decor.FX", "RemoteEvent", { tags = {} })
-- filtrado não deve aparecer como remote
inv:add_script("Players.LocalPlayer.PlayerScripts.Weapon", "ab12cd34ef567890", 4096, true, false, "ModuleScript")
inv:add_late_remote("ReplicatedStorage.Remotes.Dynamic", 42, 1720000010)

local content, err = inv:write("sess_1", "full")
check("inventory write ok", type(content) == "string" and #content > 0, tostring(err))
if type(content) == "string" then
    local lines = {}
    for line in content:gmatch("[^\n]+") do lines[#lines + 1] = line end
    check("inventory header + 6 linhas", #lines == 6, tostring(#lines) .. " linhas")
    local okh, h = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[1]) end)
    check("inventory header _h=1", okh and h._h == 1 and h.file == "inventory")
    -- linha do remote Shoot
    local okr, r = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[2]) end)
    check("remote Shoot parsed", okr and r.kind == "remote" and r.remote_id == 1 and r.path == "ReplicatedStorage.Remotes.Shoot")
    -- linha do remote Chat (observable)
    local okc, c = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[3]) end)
    check("remote Chat observable", okc and c.observable == true)
    -- linha script
    local oks, s = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[4]) end)
    check("linha script", oks and s.kind == "script" and s.bytecode_sha == "ab12cd34ef567890")
    -- linha late_remote
    local okl, l = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[5]) end)
    check("linha late_remote", okl and l.kind == "late_remote")
    -- linha filtrada
    local okf, f = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[6]) end)
    check("linha filtrada", okf and f.kind == "filtered")
end

-- ============================================================
-- 2. Inventory: remote_id estável por path
-- ============================================================

local inv2 = Inventory.new("sess_2", "full")
local r1 = inv2:remote_id_for("RS.A")
local r2 = inv2:remote_id_for("RS.A")
local r3 = inv2:remote_id_for("RS.B")
check("remote_id estável", r1 == r2, tostring(r1) .. " vs " .. tostring(r2))
check("remote_id diferente por path", r1 ~= r3, tostring(r1) .. " vs " .. tostring(r3))

-- ============================================================
-- 3. Inventory stats
-- ============================================================

local st = inv:stats()
check("stats remotes=2", st.remotes == 2, tostring(st.remotes))
check("stats scripts=1", st.scripts == 1, tostring(st.scripts))
check("stats filtered=1", st.filtered == 1, tostring(st.filtered))
check("stats late=1", st.late == 1, tostring(st.late))
check("stats observable=1", st.observable == 1, tostring(st.observable))
check("stats unobservable=1", st.unobservable == 1, tostring(st.unobservable))

-- ============================================================
-- 4. Derive: game_summary
-- ============================================================

local derive = Derive.new(inv, {}, {})
local gs = derive:game_summary("sess_1", 123456, 42)
check("game_summary schema", gs.schema and gs.schema.major == 2 and gs.schema.minor == 4)
check("game_summary session", gs.session == "sess_1")
check("game_summary game_id", gs.game_id == 123456)
check("game_summary observable_remotes=1", gs.observable_remotes == 1, tostring(gs.observable_remotes))
check("game_summary unobservable_remotes=1", gs.unobservable_remotes == 1, tostring(gs.unobservable_remotes))
check("game_summary scripts_by_type ModuleScript=1", gs.scripts_by_type.ModuleScript == 1, tostring(gs.scripts_by_type.ModuleScript))

-- ============================================================
-- 5. Derive: remote_profiles
-- ============================================================

-- calls para popular o profile
local calls = {
    { remote_id = 1, remote = "ReplicatedStorage.Remotes.Shoot", method = "FireServer",
      args = { { t = "number", v = 25 }, { t = "Vector3", v = { 1, 2, 3 } } },
      ts = 1720000001, outcome = "accepted", outcome_from = "incoming:0:5",
      src = { path = "Players.LocalPlayer.Weapon", line = 42 } },
    { remote_id = 1, remote = "ReplicatedStorage.Remotes.Shoot", method = "FireServer",
      args = { { t = "number", v = 50 } },
      ts = 1720000002, outcome = "weakly_accepted", outcome_from = "ret_falsy",
      src = { path = "Players.LocalPlayer.Weapon", line = 42 } },
}
local derive2 = Derive.new(inv, calls, {})
local rp = derive2:remote_profiles()
check("remote_profiles tem Shoot", rp["ReplicatedStorage.Remotes.Shoot"] ~= nil)
local prof = rp["ReplicatedStorage.Remotes.Shoot"]
if prof then
    check("profile calls_raw=2", prof.calls_raw == 2, tostring(prof.calls_raw))
    check("profile arity 2 e 1", prof.arities[2] == 1 and prof.arities[1] == 1, tostring(prof.arities[2]) .. "/" .. tostring(prof.arities[1]))
    check("profile outcome_counts", prof.outcome_counts.accepted == 1 and prof.outcome_counts.weakly_accepted == 1)
    check("profile caller armazenado", #prof.callers == 1 and prof.callers[1].count == 2, tostring(#prof.callers))
    check("profile intercept_sample", type(prof.intercept_sample) == "string" and #prof.intercept_sample > 0, prof.intercept_sample)
end

-- ============================================================
-- 6. Diff: comparar dois inventários
-- ============================================================

local inv_prev = Inventory.new("sess_0", "full")
inv_prev:add_remote("ReplicatedStorage.Remotes.Old", "RemoteEvent", { tags = {}, observable = false })
inv_prev:add_script("Players.LocalPlayer.OldScript", "oldsha", 100, false, false)

local inv_cur = Inventory.new("sess_1", "full")
inv_cur:add_remote("ReplicatedStorage.Remotes.Old", "RemoteEvent", { tags = {}, observable = true }) -- mudou observable
inv_cur:add_remote("ReplicatedStorage.Remotes.New", "RemoteEvent", { tags = {}, observable = false }) -- novo
inv_cur:add_script("Players.LocalPlayer.NewScript", "newsha", 200, true, false) -- novo

local diff = Diff:new()
local d = diff:compare(
    { remotes = {}, scripts = {} },
    { remotes = {}, scripts = {} }
)
-- monta manualmente para o compare receber o formato certo
local cur_parsed = { remotes = {}, scripts = {} }
local prev_parsed = { remotes = {}, scripts = {} }
for _, item in ipairs(inv_cur.items) do
    if item.kind == "remote" then cur_parsed.remotes[item.path] = item end
    if item.kind == "script" then cur_parsed.scripts[item.path] = item end
end
for _, item in ipairs(inv_prev.items) do
    if item.kind == "remote" then prev_parsed.remotes[item.path] = item end
    if item.kind == "script" then prev_parsed.scripts[item.path] = item end
end
local d2 = diff:compare(cur_parsed, prev_parsed)
check("diff added_remotes=1", #d2.added_remotes == 1, tostring(#d2.added_remotes))
check("diff changed_remotes=1", #d2.changed_remotes == 1, tostring(#d2.changed_remotes))
check("diff removed_remotes=0", #d2.removed_remotes == 0, tostring(#d2.removed_remotes))
check("diff added_scripts=1", #d2.added_scripts == 1, tostring(#d2.added_scripts))
check("diff unchanged=0", d2.unchanged == 0, tostring(d2.unchanged))

-- ============================================================
-- 7. Diff: write + encode
-- ============================================================

local okd, encd = pcall(function() return game:GetService("HttpService"):JSONEncode(d2) end)
check("diff JSON encodável", okd == true, tostring(encd))

-- ============================================================
-- 8. Enrich ainda disponível (regressão)
-- ============================================================

local h = Enrich.hash64("abc")
check("Enrich.hash64 ainda funciona", #h == 16, h)

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/phase4_test.json", enc) end

print(string.format("[phase4] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[phase4] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
