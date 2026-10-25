--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 4: Ciclo de vida Android (roda no executor)
    Valida install_lifecycle_listeners, _on_teleport, _on_focus_lost, unload.
    Sem jogo real: testa a lógica pura (end.json, reason, stats).
    Grava Cobalt/lifecycle_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_lifecycle/" .. tostring(os.time())
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
local Session, e2 = fetch_module("Src/Session/init.luau")
local Recorder, e3 = fetch_module("Src/Recorder/init.luau")
local Pair, e4 = fetch_module("Src/Pair/init.luau")
local Dedup, e5 = fetch_module("Src/Dedup/init.luau")
local Main, e6 = fetch_module("Src/Main/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Session", Session ~= nil, e2)
check("load Recorder", Recorder ~= nil, e3)
check("load Pair", Pair ~= nil, e4)
check("load Dedup", Dedup ~= nil, e5)
check("load Main", Main ~= nil, e6)
if not (Enrich and Session and Recorder and Pair and Dedup and Main) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/lifecycle_test.json", enc)
    warn("[lifecycle] modulo nao carregou — veja Cobalt/lifecycle_test.json")
    return results
end

_G.Enrich = Enrich

-- ============================================================
-- 1. Main.start com módulos injetados
-- ============================================================

local main = Main.new({
    mode = "full",
    modules = {
        Enrich = Enrich, Session = Session, Recorder = Recorder,
        Pair = Pair, Dedup = Dedup,
    },
})
check("main new", main ~= nil)

local start_ok = xpcall(function()
    return main:start()
end, function(err) return tostring(err) end)
check("main start", start_ok == true, tostring(start_ok and "ok" or start_ok))
if not start_ok then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/lifecycle_test.json", enc)
    return results
end

local sess_dir = main.session_dir
check("session_dir definido", type(sess_dir) == "string" and #sess_dir > 0)

-- ============================================================
-- 2. install_lifecycle_listeners nao trava (sem jogo real)
-- ============================================================

local ok_listen = main:install_lifecycle_listeners()
check("install_lifecycle_listeners ok", ok_listen == true)

-- ============================================================
-- 3. _on_teleport: fecha sessão com reason=teleport
-- ============================================================

-- grava um registro para ter algo no Recorder
main.recorder:enqueue({
    corr = "0:1", ts = os.time(), caller = "game", remote_id = 17,
    remote = "RS.Test", method = "FireServer", args = {},
    args_sha = Enrich.hash64("x"), outcome = "unknown", outcome_from = "unobservable",
})
main.recorder:flush()

local ok_tel = main:_on_teleport()
check("on_teleport nao retorna erro", ok_tel == nil) -- close retorna (ok, end_rec)

-- end.json escrito
local end_ok = (select(1, pcall(isfile, sess_dir .. "/end.json"))) == true
check("end.json apos teleport", end_ok)

local end_raw = select(2, pcall(readfile, sess_dir .. "/end.json"))
local end_ok2 = false
if type(end_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(end_raw) end)
    end_ok2 = ok and obj.closed == true and obj.reason == "teleport"
end
check("end.json reason=teleport", end_ok2)

-- running deve ser false
check("running false apos teleport", main.running == false)

-- ============================================================
-- 4. Nova sessao para _on_focus_lost (teleport ja encerrou a anterior)
-- ============================================================

-- Como _on_teleport chama close() que define self.session = nil,
-- precisamos de um novo Main para testar focus_lost.
local main2 = Main.new({
    mode = "full",
    modules = {
        Enrich = Enrich, Session = Session, Recorder = Recorder,
        Pair = Pair, Dedup = Dedup,
    },
})
local ok2 = xpcall(function() return main2:start() end, function(err) return tostring(err) end)
check("main2 start", ok2 == true, tostring(ok2))

main2.recorder:enqueue({
    corr = "0:1", ts = os.time(), caller = "game", remote_id = 18,
    remote = "RS.Test2", method = "FireServer", args = {},
    args_sha = Enrich.hash64("y"), outcome = "unknown", outcome_from = "unobservable",
})
main2.recorder:flush()

local ok_focus = main2:_on_focus_lost()
check("on_focus_lost nao retorna erro", ok_focus == nil)

local end2_ok = (select(1, pcall(isfile, main2.session_dir .. "/end.json"))) == true
check("end.json apos focus_lost", end2_ok)

local end2_raw = select(2, pcall(readfile, main2.session_dir .. "/end.json"))
local end2_ok2 = false
if type(end2_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(end2_raw) end)
    end2_ok2 = ok and obj.closed == true and obj.reason == "focus_lost"
end
check("end.json reason=focus_lost", end2_ok2)

-- ============================================================
-- 5. unload: fecha sessão com reason=unload
-- ============================================================

local main3 = Main.new({
    mode = "full",
    modules = {
        Enrich = Enrich, Session = Session, Recorder = Recorder,
        Pair = Pair, Dedup = Dedup,
    },
})
local ok3 = xpcall(function() return main3:start() end, function(err) return tostring(err) end)
check("main3 start", ok3 == true, tostring(ok3))

main3.recorder:enqueue({
    corr = "0:1", ts = os.time(), caller = "game", remote_id = 19,
    remote = "RS.Test3", method = "FireServer", args = {},
    args_sha = Enrich.hash64("z"), outcome = "unknown", outcome_from = "unobservable",
})
main3.recorder:flush()

main3:unload()

local end3_ok = (select(1, pcall(isfile, main3.session_dir .. "/end.json"))) == true
check("end.json apos unload", end3_ok)

local end3_raw = select(2, pcall(readfile, main3.session_dir .. "/end.json"))
local end3_ok2 = false
if type(end3_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(end3_raw) end)
    end3_ok2 = ok and obj.closed == true and obj.reason == "unload"
end
check("end.json reason=unload", end3_ok2)

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/lifecycle_test.json", enc) end

print(string.format("[lifecycle] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[lifecycle] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
