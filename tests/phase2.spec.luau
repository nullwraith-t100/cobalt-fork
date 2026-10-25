--[[
    Cobalt Fork v2.4 — teste da Fase 2 (roda no executor)
    Carrega Enrich/Recorder/Session do repo, valida os invariantes e grava
    Cobalt/phase2_test.json. Se um modulo falhar ao compilar, reporta o erro real.

    Delta nao tem require de arquivo local: cada modulo e loadstring de um chunk
    que retorna a tabela. Chunk com erro devolve nil + mensagem — capturamos.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_phase2/" .. tostring(os.time())
local results = {}
local failed = 0

local function check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
    if not ok then failed = failed + 1 end
end

local function fetch_module(rel)
    local ok, src = pcall(function() return game:HttpGet(BASE .. rel) end)
    if not ok or type(src) ~= "string" then
        return nil, "HttpGet falhou: " .. tostring(src)
    end
    local chunk, err = loadstring(src)
    if not chunk then
        return nil, string.format("compile %s (%d B): %s", rel, #src, tostring(err))
    end
    local run_ok, mod = pcall(chunk)
    if not run_ok then
        return nil, "runtime " .. rel .. ": " .. tostring(mod)
    end
    return mod
end

local Enrich, e1 = fetch_module("Src/Enrich/init.luau")
local Recorder, e2 = fetch_module("Src/Recorder/init.luau")
local Session, e3 = fetch_module("Src/Session/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Recorder", Recorder ~= nil, e2)
check("load Session", Session ~= nil, e3)
if not (Enrich and Recorder and Session) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/phase2_test.json", enc)
    warn("[phase2] modulo nao carregou — veja Cobalt/phase2_test.json")
    return results
end

-- ============================================================
-- 1. hash 64 bits — deterministico, 16 hex, sensivel
-- ============================================================

local h1 = Enrich.hash64("abc")
local h2 = Enrich.hash64("abc")
local h3 = Enrich.hash64("abd")
check("hash64 deterministico", h1 == h2, h1)
check("hash64 16 hex", #h1 == 16 and h1:match("^%x+$") ~= nil, h1)
check("hash64 sensivel", h1 ~= h3, h1 .. " vs " .. h3)
-- ordem de chaves nao muda o hash canonico
local c1 = Enrich.canonical({ a = 1, b = 2 })
local c2 = Enrich.canonical({ b = 2, a = 1 })
check("canonical ordem-independente", c1 == c2, c1)

-- ============================================================
-- 2. redacao §9
-- ============================================================

local function node_for(v)
    local ok, node = Enrich.pack_arg(v)
    if not ok then return nil end
    return node
end

-- chave sensivel com JWT no valor
local n_token = node_for({ token = "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc" })
local red_token = false
if n_token and n_token.t == "table" then
    for _, kv in ipairs(n_token.map) do
        if kv[1].v == "token" then
            red_token = (kv[2].redacted == true and kv[2].sha ~= nil)
        end
    end
end
check("redige chave token + sha", red_token, "campo token")

-- chave sensivel apikey
local n_key = node_for({ apikey = "A1B2C3D4E5F6G7H8I9J0" })
local red_key = false
if n_key and n_key.t == "table" then
    for _, kv in ipairs(n_key.map) do
        if kv[1].v == "apikey" then red_key = (kv[2].redacted == true) end
    end
end
check("redige apikey", red_key, "campo apikey")

-- nome parecido nao pode ser redigido (word token, nao substring)
local n_safe = node_for({ KeyCode = 65, TokenCount = 3 })
local safe_ok = false
if n_safe and n_safe.t == "table" then
    local kept = 0
    for _, kv in ipairs(n_safe.map) do
        if kv[2].redacted ~= true then kept = kept + 1 end
    end
    safe_ok = kept == 2
end
check("nao redige KeyCode/TokenCount", safe_ok, "tokens inteiros")

-- valor solto com JWT (sem chave sensivel) tambem cai
local n_val = node_for("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig")
check("redige JWT no valor", n_val ~= nil and n_val.redacted == true, "valor solto")

-- ============================================================
-- 3. tipagem §6.7.1 — roundtrip dos tipos que importam
-- ============================================================

local cases = {
    { name = "nil", v = nil },
    { name = "bool", v = true },
    { name = "number", v = 1.5 },
    { name = "string", v = "oi" },
    { name = "Vector3", v = Vector3.new(1, 2, 3) },
    { name = "Vector2", v = Vector2.new(4, 5) },
    { name = "CFrame", v = CFrame.new(1, 2, 3) },
    { name = "Color3", v = Color3.fromRGB(10, 20, 30) },
    { name = "UDim2", v = UDim2.new(0, 10, 1, -5) },
    { name = "Rect", v = Rect.new(0, 0, 10, 10) },
    { name = "NumberRange", v = NumberRange.new(1, 2) },
    { name = "NumberSequence", v = NumberSequence.new(0, 1) },
    { name = "ColorSequence", v = ColorSequence.new(Color3.new(1, 1, 1)) },
    { name = "BrickColor", v = BrickColor.new("Really red") },
    { name = "EnumItem", v = Enum.KeyCode.A },
    { name = "TweenInfo", v = TweenInfo.new(0.5) },
    { name = "Instance", v = workspace },
    { name = "table", v = { 1, 2, 3, x = "y" } },
    { name = "nan", v = 0 / 0 },
    { name = "inf", v = 1 / 0 },
    { name = "utf8 invalido", v = "\255\254\253" },
}

for _, c in ipairs(cases) do
    local node = node_for(c.v)
    local ok = node ~= nil and typeof(node.t) == "string"
    local detail = ok and node.t or "nil"
    if ok and c.name == "CFrame" then
        ok = node.rot ~= nil and #node.pos == 3
    elseif ok and c.name == "nan" then
        ok = node.special == "nan"
    elseif ok and c.name == "inf" then
        ok = node.special == "inf"
    elseif ok and c.name == "utf8 invalido" then
        ok = node.bin == true and node.b64 ~= nil
    elseif ok and c.name == "Instance" then
        ok = node.class ~= nil
    elseif ok and c.name == "EnumItem" then
        ok = node.n ~= nil
    end
    check("tipo " .. c.name, ok, detail)
end

-- ============================================================
-- 4. Recorder — escrita, header, rotacao numerada
-- ============================================================

local rec = Recorder.new({
    dir = DIR,
    session = "test_" .. tostring(os.time()),
    prefix = "calls",
    mode = "full",
    config = { rotation_limit_bytes = 2048, flush_batch = 1000, retry_delays_ms = { 10 } },
})

local opened, open_err = rec:open_next()
check("recorder abre calls.0001", opened == true, tostring(open_err))

for i = 1, 60 do
    rec:enqueue({
        corr = "0:" .. i,
        seq = i,
        ts = os.time(),
        caller = "game",
        remote = "ReplicatedStorage.Remotes.Test",
        remote_id = 7,
        method = "FireServer",
        args = { { t = "number", v = i } },
        args_sha = Enrich.hash64("arg" .. i),
        outcome = "unknown",
        outcome_from = "unobservable",
    })
end

local flushed, flush_err = rec:flush()
check("flush grava batch", flushed == true, tostring(flush_err))
check("rotacionou para 0002", rec.file_index >= 2, "file_index=" .. tostring(rec.file_index))

local function read_lines(path)
    local ok, content = pcall(readfile, path)
    if not ok or type(content) ~= "string" then return nil end
    local out = {}
    for line in content:gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end

local f1 = read_lines(DIR .. "/calls.0001.ndjson")
check("calls.0001 existe", f1 ~= nil and #f1 > 1, f1 and (#f1 .. " linhas") or "ausente")
if f1 and f1[1] then
    local ok, header = pcall(function()
        return game:GetService("HttpService"):JSONDecode(f1[1])
    end)
    check("header _h=1", ok and header._h == 1, ok and tostring(header.file) or "decode falhou")
    check("header schema 2.4", ok and header.schema and header.schema.major == 2 and header.schema.minor == 4)
end
local f2 = read_lines(DIR .. "/calls.0002.ndjson")
check("calls.0002 existe", f2 ~= nil and #f2 >= 1, f2 and (#f2 .. " linhas") or "ausente")

-- calls.idx §6.9: header + 1 linha por arquivo fechado
local idx_calls = read_lines(DIR .. "/calls.idx")
check("calls.idx existe", idx_calls ~= nil and #idx_calls >= 2, idx_calls and (#idx_calls .. " linhas") or "ausente")
if idx_calls and #idx_calls >= 2 then
    local ok1, h = pcall(function() return game:GetService("HttpService"):JSONDecode(idx_calls[1]) end)
    local ok2, e = pcall(function() return game:GetService("HttpService"):JSONDecode(idx_calls[#idx_calls]) end)
    check("calls.idx header", ok1 and h._h == 1)
    check("calls.idx entrada fechada", ok2 and e.closed == true and e.path ~= nil, ok2 and tostring(e.path) or "decode falhou")
end

-- stats coerentes
local st = rec:stats()
check("stats registros", st.records_written > 0, "written=" .. tostring(st.records_written))
check("stats tail ok", st.tail_truncated == false)

-- ctl line
rec:heartbeat()
local f_last = read_lines(DIR .. "/calls." .. string.format("%04d", rec.file_index) .. ".ndjson")
local has_hb = false
if f_last then
    for _, line in ipairs(f_last) do
        local ok, obj = pcall(function()
            return game:GetService("HttpService"):JSONDecode(line)
        end)
        if ok and type(obj) == "table" and obj.kind == "hb" and obj.dir == "ctl" then has_hb = true break end
    end
end
check("ctl hb gravado", has_hb)
rec:stop()

-- ============================================================
-- 5. Session — begin/close, sessions.idx, SCHEMA.md, tail
-- ============================================================

local sess = Session.new({ dir = DIR, mode = "full", recorder = nil, ts_start = os.time() })
local began, begin_err = sess:begin_session()
check("session begin", began == true, tostring(begin_err))

local meta_raw = select(2, pcall(readfile, sess:path("meta.json")))
local meta_ok = false
if type(meta_raw) == "string" and #meta_raw > 0 then
    local ok, meta = pcall(function() return game:GetService("HttpService"):JSONDecode(meta_raw) end)
    meta_ok = ok and meta.session == sess.session and meta.capabilities ~= nil
end
check("meta.json imutavel", meta_ok)
check("SCHEMA.md gerado", (select(1, pcall(isfile, DIR .. "/SCHEMA.md"))) == true)

local closed, close_res = sess:close("manual", {
    stats = { calls_raw = 5, records_written = 5 },
    files = {},
})
check("session close", closed == true, tostring(close_res))
local end_ok = pcall(readfile, sess:path("end.json"))
check("end.json escrito", end_ok)

-- sessions.idx tem header + 1 linha com ts_end preenchido
local idx = read_lines(DIR .. "/sessions.idx")
check("sessions.idx existe", idx ~= nil and #idx >= 2, idx and (#idx .. " linhas") or "ausente")
if idx then
    local ok_last, last = pcall(function()
        return game:GetService("HttpService"):JSONDecode(idx[#idx])
    end)
    check("sessions.idx ts_end", ok_last and last.session == sess.session and last.ts_end ~= nil)
end

-- tail truncada detectada
local JSON = game:GetService("HttpService")
local function line(v) return JSON:JSONEncode(v) end

local bad_path = DIR .. "/bad.ndjson"
pcall(writefile, bad_path, line({ _h = 1 }) .. "\n" .. line({ a = 1 }) .. "\n" .. '{"broken":')
local tail_ok, tail_detail = Session.validate_tail(bad_path)
check("tail truncada detectada", tail_ok == false, tostring(tail_detail))

local good_path = DIR .. "/good.ndjson"
pcall(writefile, good_path, line({ _h = 1 }) .. "\n" .. line({ a = 1 }) .. "\n")
local good_ok = Session.validate_tail(good_path)
check("tail valida passa", good_ok == true)

-- ============================================================
-- 6. integracao Session + Recorder (caminho de producao)
-- ============================================================

local rec2 = Recorder.new({ dir = DIR, prefix = "calls", mode = "full", config = { retry_delays_ms = { 10 } } })
local sess2 = Session.new({ dir = DIR, mode = "full", recorder = rec2, ts_start = os.time() + 1 })
local began2 = sess2:begin_session()
check("integracao begin", began2 == true)

local started2 = rec2:start()
check("integracao recorder start", started2 == true)
for i = 1, 5 do
    rec2:submit({ corr = "0:" .. i, caller = "game", remote = "RS.R", method = "FireServer" })
end
rec2.running = false
local flushed2 = rec2:flush()
check("integracao flush", flushed2 == true)

local closed2 = sess2:close("manual", {})
check("integracao close", closed2 == true)

local end_raw = select(2, pcall(readfile, sess2:path("end.json")))
local end_ok2 = false
local end_rec = nil
if type(end_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(end_raw) end)
    if ok then
        end_rec = obj
        end_ok2 = obj.counts_final and obj.counts_final.records_written == 5
    end
end
check("end.json pega stats do recorder", end_ok2, end_rec and tostring(end_rec.counts_final and end_rec.counts_final.records_written) or "sem counts")

local man_raw = select(2, pcall(readfile, sess2:path("manifest.json")))
local man_ok2 = false
if type(man_raw) == "string" then
    local ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(man_raw) end)
    man_ok2 = ok and obj.files and obj.files.calls and #obj.files.calls >= 1
end
check("manifest lista arquivo de calls", man_ok2)

-- ============================================================
-- resultado
-- ============================================================

local summary = {
    pass = (failed == 0),
    failed = failed,
    total = #results,
    ts = os.time(),
    results = results,
}
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/phase2_test.json", enc) end

print(string.format("[phase2] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then
        print(string.format("[phase2] FALHOU: %s -> %s", r.name, tostring(r.detail)))
    end
end
return summary
