--[[
    Cobalt Fork v2.4 — teste sintético da Fase 5 (roda no executor)
    Orquestra Session + Scanner + Hook + Pair + Recorder + Inventory + Derive + Diff.
    Sem jogo real: simula o fluxo com registros sintéticos. Grava Cobalt/phase5_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_phase5/" .. tostring(os.time())
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
local Scanner, e3 = fetch_module("Src/Scanner/init.luau")
local Hook, e4 = fetch_module("Src/Hook/init.luau")
local Pair, e5 = fetch_module("Src/Pair/init.luau")
local Recorder, e6 = fetch_module("Src/Recorder/init.luau")
local Inventory, e7 = fetch_module("Src/Inventory/init.luau")
local Derive, e8 = fetch_module("Src/Derive/init.luau")
local Diff, e9 = fetch_module("Src/Diff/init.luau")
local Main, e10 = fetch_module("Src/Main/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Session", Session ~= nil, e2)
check("load Scanner", Scanner ~= nil, e3)
check("load Hook", Hook ~= nil, e4)
check("load Pair", Pair ~= nil, e5)
check("load Recorder", Recorder ~= nil, e6)
check("load Inventory", Inventory ~= nil, e7)
check("load Derive", Derive ~= nil, e8)
check("load Diff", Diff ~= nil, e9)
check("load Main", Main ~= nil, e10)
if not (Enrich and Session and Scanner and Hook and Pair and Recorder and Inventory and Derive and Diff and Main) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/phase5_test.json", enc)
    warn("[phase5] modulo nao carregou — veja Cobalt/phase5_test.json")
    return results
end

_G.Enrich = Enrich

-- ============================================================
-- 1. Main.start com módulos injetados
-- ============================================================

local main = Main.new({
    mode = "full",
    modules = {
        Enrich = Enrich, Session = Session, Scanner = Scanner,
        Hook = Hook, Pair = Pair, Recorder = Recorder,
        Inventory = Inventory, Derive = Derive, Diff = Diff,
    },
})
check("main new", main ~= nil)

local start_ok, start_res = xpcall(function()
    return main:start()
end, function(err)
    return tostring(err) .. "\n" .. (debug and debug.traceback() or "")
end)
if type(start_ok) == "boolean" and not start_ok then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results, start_error = tostring(start_res) })
    pcall(writefile, "Cobalt/phase5_test.json", enc)
    warn("[phase5] start falhou: " .. tostring(start_res))
    return results
end
check("main start", start_ok == true, tostring(start_res))
if not start_ok then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/phase5_test.json", enc)
    return results
end

-- ============================================================
-- 2. Sessão criada: meta.json, manifest.json, sessions.idx, SCHEMA.md
-- ============================================================

local sess_dir = main.session_dir
check("session_dir definido", type(sess_dir) == "string" and #sess_dir > 0, tostring(sess_dir))

local meta_raw = select(2, pcall(readfile, sess_dir .. "/meta.json"))
local meta_ok = false
if type(meta_raw) == "string" and #meta_raw > 0 then
    local ok, meta = pcall(function() return game:GetService("HttpService"):JSONDecode(meta_raw) end)
    meta_ok = ok and meta.session == main.session.session and meta.capabilities ~= nil
end
check("meta.json escrito", meta_ok)
check("manifest.json escrito", (select(1, pcall(isfile, sess_dir .. "/manifest.json"))) == true)
check("SCHEMA.md escrito", (select(1, pcall(isfile, sess_dir .. "/SCHEMA.md"))) == true)

-- sessions.idx tem a sessão com ts_end:null
local idx = {}
local ok_idx, idx_content = pcall(readfile, "Cobalt/sessions.idx")
if ok_idx then
    for line in idx_content:gmatch("[^\n]+") do
        local dec_ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(line) end)
        if dec_ok and type(obj) == "table" and obj.session == main.session.session then
            idx[#idx + 1] = obj
        end
    end
end
check("sessions.idx tem sessão", #idx == 1, tostring(#idx))
if #idx == 1 then
    check("sessions.idx ts_end null", idx[1].ts_end == nil, tostring(idx[1].ts_end))
end

if main.session then
    local sess_obj = main.session
    local sess_session = sess_obj.session
    check("main.session.session definido", type(sess_session) == "string" and #sess_session > 0, tostring(sess_session))
else
    check("main.session.session definido", false, "main.session is nil")
end

-- ============================================================
-- 3. Fluxo de call: on_outgoing -> Pair pendente -> on_incoming casado -> Recorder
-- ============================================================

Hook.reset_corr()

local ok1, rec1 = Hook.build_record({
    remote = "ReplicatedStorage.Remotes.Shoot", remote_id = 17, method = "FireServer",
    args = { { t = "number", v = 25 } }, vm = 0, caller = "game",
})
check("build_record outgoing", ok1 == true, tostring(rec1))

main:on_outgoing(rec1)
check("pendente após outgoing", #main.pair:pending_list() == 1, tostring(#main.pair:pending_list()))

-- incoming casado → accepted
local ok2 = main.pair:push_incoming({
    remote_id = 17, method = "OnClientEvent", args = { { ok = true } }, corr = "0:99",
})
check("push_incoming ok", ok2 == true, tostring(ok2))
check("fila esvaziou", #main.pair:pending_list() == 0, tostring(#main.pair:pending_list()))
check("outcome accepted", rec1.outcome == "accepted", rec1.outcome)

-- outro outgoing sem incoming → fica pendente
local ok3, rec3 = Hook.build_record({
    remote = "ReplicatedStorage.Remotes.Chat", remote_id = 18, method = "FireServer",
    args = {}, vm = 0, caller = "game",
})
main:on_outgoing(rec3)
check("pendente após outgoing sem incoming", #main.pair:pending_list() == 1, tostring(#main.pair:pending_list()))

-- ============================================================
-- 4. main:close() → end.json, manifest, sessions.idx atualizado, arquivos derivados
-- ============================================================

local ok4, end_rec = main:close("manual", {})
check("main close ok", ok4 == true, tostring(end_rec))
check("end.json escrito", (select(1, pcall(isfile, sess_dir .. "/end.json"))) == true)

local end_raw = select(2, pcall(readfile, sess_dir .. "/end.json"))
local end_ok = false
if type(end_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(end_raw) end)
    end_ok = ok and obj.closed == true and obj.reason == "manual" and obj.counts_final ~= nil
end
check("end.json válido", end_ok)

-- extrai session id do meta.json (escrito por Session.begin)
local main_session_id = nil
local meta_raw = select(2, pcall(readfile, "Cobalt/test_phase5/" .. tostring(os.time()) .. "/meta.json"))
-- nao sabemos o DIR exato aqui; vamos pegar de main.session_dir se disponível
local sdir = main.session_dir or ""
if type(sdir) == "string" and #sdir > 0 then
    local mr = select(2, pcall(readfile, sdir .. "/meta.json"))
    if type(mr) == "string" and #mr > 0 then
        local ok, meta = pcall(function() return game:GetService("HttpService"):JSONDecode(mr) end)
        if ok and meta.session then main_session_id = meta.session end
    end
end
check("session_dir definido", type(sdir) == "string" and #sdir > 0, tostring(sdir))
check("main.session.session definido", type(main_session_id) == "string" and #main_session_id > 0, tostring(main_session_id))

-- sessions.idx agora tem ts_end preenchido
local idx2 = {}
local ok_idx2, idx_content2 = pcall(readfile, "Cobalt/sessions.idx")
if ok_idx2 then
    for line in idx_content2:gmatch("[^\n]+") do
        local dec_ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(line) end)
        if dec_ok and type(obj) == "table" and obj.session == main_session_id then
            idx2[#idx2 + 1] = obj
        end
    end
end
check("sessions.idx ts_end preenchido", #idx2 == 1 and idx2[1].ts_end ~= nil, tostring(idx2[1] and idx2[1].ts_end or "ausente"))

-- ============================================================
-- 5. Arquivos derivados: inventory, tree, tree_delta
-- ============================================================

check("inventory.ndjson escrito", (select(1, pcall(isfile, sess_dir .. "/inventory.ndjson"))) == true)
check("tree.ndjson escrito", (select(1, pcall(isfile, sess_dir .. "/tree.ndjson"))) == true)
check("tree_delta.ndjson escrito", (select(1, pcall(isfile, sess_dir .. "/tree_delta.ndjson"))) == true)

-- ============================================================
-- 6. game_summary.json e remote_profiles.json
-- ============================================================

check("game_summary.json escrito", (select(1, pcall(isfile, sess_dir .. "/game_summary.json"))) == true)
check("remote_profiles.json escrito", (select(1, pcall(isfile, sess_dir .. "/remote_profiles.json"))) == true)

-- ============================================================
-- 7. calls.0001.ndjson gravado pelo Recorder
-- ============================================================

local calls_ok = false
if typeof(listfiles) == "function" then
    local l_ok, files = pcall(listfiles, sess_dir)
    if l_ok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("calls%.%d+%.ndjson$") then calls_ok = true break end
        end
    end
end
check("calls.NNNN.ndjson existe", calls_ok)

-- ============================================================
-- 8. close duplo é rejeitado
-- ============================================================

local ok5, err5 = main:close("manual", {})
check("close duplo rejeitado", ok5 == false, tostring(err5))

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/phase5_test.json", enc) end

print(string.format("[phase5] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[phase5] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
