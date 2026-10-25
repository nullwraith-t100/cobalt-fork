--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 6: UI Viewer (roda no executor)
    Valida leitura de sessions.idx, meta.json, end.json, inventory.ndjson, calls.ndjson,
    game_summary.json, remote_profiles.json, diff.json.
    Grava Cobalt/ui_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_ui/" .. tostring(os.time())
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

local UI, e1 = fetch_module("Src/UI/init.luau")

check("load UI", UI ~= nil, e1)
if not UI then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/ui_test.json", enc)
    warn("[ui] modulo nao carregou — veja Cobalt/ui_test.json")
    return results
end

-- ============================================================
-- 1. Criar arquivos de sessão sintéticos
-- ============================================================

local JSON = game:GetService("HttpService")

local function write_json(path, obj)
    local ok, enc = pcall(function() return JSON:JSONEncode(obj) end)
    if ok then pcall(writefile, path, enc) end
    return ok
end

-- meta.json
write_json(DIR .. "/meta.json", {
    schema = { major = 2, minor = 4 },
    session = "sess_ui_test",
    mode = "full",
    executor = "Delta",
    platform = "Android",
    place_id = 123456,
    game_id = 789,
    place_version = 42,
    ts_start = 1720000000,
    streaming = true,
})

-- end.json
write_json(DIR .. "/end.json", {
    schema = { major = 2, minor = 4 },
    session = "sess_ui_test",
    reason = "manual",
    closed = true,
    counts_final = {
        calls_raw = 100,
        records_written = 80,
        dropped_under_pressure = 5,
        flush_errors = 0,
        encode_errors = 0,
        tail_truncated = false,
    },
})

-- inventory.ndjson
local inv_lines = {}
table.insert(inv_lines, JSON:JSONEncode({ _h = 1, schema = { major = 2, minor = 4 }, file = "inventory" }))
table.insert(inv_lines, JSON:JSONEncode({ kind = "remote", remote_id = 1, path = "RS.Shoot", class = "RemoteEvent", observable = true }))
table.insert(inv_lines, JSON:JSONEncode({ kind = "remote", remote_id = 2, path = "RS.Chat", class = "RemoteEvent", observable = false }))
table.insert(inv_lines, JSON:JSONEncode({ kind = "script", path = "Players.LocalPlayer.Weapon", class = "LocalScript" }))
table.insert(inv_lines, JSON:JSONEncode({ kind = "filtered", type = "prefix", pattern = "RS.Assets" }))
pcall(writefile, DIR .. "/inventory.ndjson", table.concat(inv_lines, "\n") .. "\n")

-- calls.0001.ndjson
local calls_lines = {}
table.insert(calls_lines, JSON:JSONEncode({ _h = 1, schema = { major = 2, minor = 4 }, file = "calls" }))
for i = 1, 10 do
    table.insert(calls_lines, JSON:JSONEncode({ corr = "0:" .. i, remote_id = 17, method = "FireServer", ts = 1720000000 + i }))
end
pcall(writefile, DIR .. "/calls.0001.ndjson", table.concat(calls_lines, "\n") .. "\n")

-- tree_delta.ndjson
pcall(writefile, DIR .. "/tree_delta.ndjson", JSON:JSONEncode({ _h = 1, schema = { major = 2, minor = 4 }, file = "tree_delta" }) .. "\n")

-- game_summary.json
write_json(DIR .. "/game_summary.json", {
    schema = { major = 2, minor = 4 },
    session = "sess_ui_test",
    observable_remotes = 5,
    unobservable_remotes = 3,
})

-- remote_profiles.json
write_json(DIR .. "/remote_profiles.json", {
    ["RS.Shoot"] = { remote_id = 1, calls_raw = 50, observable = true },
})

-- diff.json
write_json(DIR .. "/diff.json", {
    schema = { major = 2, minor = 4 },
    added_remotes = { { path = "RS.New" } },
    removed_remotes = {},
    changed_remotes = {},
})

-- sessions.idx
local idx_lines = {}
table.insert(idx_lines, JSON:JSONEncode({ _h = 1, schema = { major = 2, minor = 4 }, file = "sessions" }))
table.insert(idx_lines, JSON:JSONEncode({ session = "sess_ui_test", place_id = 123456, ts_start = 1720000000, ts_end = 1720000100, mode = "full" }))
pcall(writefile, DIR .. "/sessions.idx", table.concat(idx_lines, "\n") .. "\n")

-- ============================================================
-- 2. Testar UI viewer
-- ============================================================

local viewer = UI.new(DIR)

-- list_sessions (opcional: só se sessions.idx existir globalmente)
local ok_sessions, sessions = pcall(function() return viewer:list_sessions("Cobalt") end)
check("list_sessions nao trava", ok_sessions == true, tostring(sessions))

-- session_summary
local ok_sum, summary = viewer:session_summary(DIR)
check("session_summary ok", ok_sum == true, tostring(summary))

if ok_sum then
    check("session identificado", summary.session == "sess_ui_test", tostring(summary.session))
    check("meta lida", summary.meta ~= nil and summary.meta.session == "sess_ui_test")
    check("end stats", summary.end_stats ~= nil and summary.end_stats.calls_raw == 100)
    check("end reason", summary.end_reason == "manual")
    check("inventory remotes=2", summary.inventory ~= nil and summary.inventory.remotes == 2, tostring(summary.inventory and summary.inventory.remotes))
    check("inventory scripts=1", summary.inventory ~= nil and summary.inventory.scripts == 1)
    check("inventory filtered=1", summary.inventory ~= nil and summary.inventory.filtered == 1)
    check("calls arquivos=1", #summary.calls_files == 1, tostring(#summary.calls_files))
    check("calls total=10", summary.calls_total == 10, tostring(summary.calls_total))
    check("game_summary observable=5", summary.derived.game_summary ~= nil and summary.derived.game_summary.observable_remotes == 5)
    check("remote_profiles tem RS.Shoot", summary.derived.remote_profiles ~= nil and summary.derived.remote_profiles["RS.Shoot"] ~= nil)
    check("diff added=1", summary.derived.diff ~= nil and #summary.derived.diff.added_remotes == 1)
end

-- ============================================================
-- 3. print_summary nao trava
-- ============================================================

if ok_sum then
    local ok_print = xpcall(function() viewer:print_summary(summary) end, function(err) return tostring(err) end)
    check("print_summary nao trava", ok_print == true, tostring(ok_print))
end

-- ============================================================
-- resultado
-- ============================================================

local summary_out = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return JSON:JSONEncode(summary_out) end)
if enc_ok then pcall(writefile, "Cobalt/ui_test.json", enc_out) end

print(string.format("[ui] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[ui] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary_out
