--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 2: calls.idx completo (roda no executor)
    Valida que calls.idx tem header + 1 linha por arquivo FECHADO, com
    ts_min/ts_max, corr_first/corr_last, seq_first/seq_last, by_remote, by_source, by_action_n.
    Grava Cobalt/callidx_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_callidx/" .. tostring(os.time())
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
local Recorder, e2 = fetch_module("Src/Recorder/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load Recorder", Recorder ~= nil, e2)
if not (Enrich and Recorder) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/callidx_test.json", enc)
    warn("[callidx] modulo nao carregou — veja Cobalt/callidx_test.json")
    return results
end

-- ============================================================
-- 1. Recorder com limite baixo forca rotacao
-- ============================================================

local rec = Recorder.new({
    dir = DIR,
    session = "sess_callidx",
    prefix = "calls",
    mode = "full",
    config = {
        rotation_limit_bytes = 200, -- muito baixo: rotacao rapida
        flush_batch = 1000,
        retry_delays_ms = { 10 }
    }
})

local opened = rec:open_next()
check("abre calls.0001", opened == true, tostring(opened))

-- grava 30 registros pequenos para forcar rotacao (cada linha ~200 bytes)
for i = 1, 30 do
    rec:enqueue({
        corr = "0:" .. i,
        seq = i,
        ts = 1720000000 + i,
        caller = "game",
        remote = "ReplicatedStorage.Remotes.Shoot",
        remote_id = 17,
        method = "FireServer",
        src = { path = "Players.LocalPlayer.PlayerScripts.Weapon", line = 42 },
        args = { { t = "number", v = i } },
        args_sha = Enrich.hash64("arg" .. i),
        action_n = math.floor((i - 1) / 10) + 1, -- clusters de 10
        outcome = "unknown",
        outcome_from = "unobservable",
    })
end

local flushed = rec:flush()
check("flush grava e rotaciona", flushed == true, tostring(flushed))
check("rotacionou para calls.0002", rec.file_index >= 2, "file_index=" .. tostring(rec.file_index))
rec:stop()

-- ============================================================
-- 2. calls.idx: header + 1 linha por arquivo fechado
-- ============================================================

local function read_lines(path)
    local ok, content = pcall(readfile, path)
    if not ok or type(content) ~= "string" then return nil end
    local out = {}
    for line in content:gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end

local idx = read_lines(DIR .. "/calls.idx")
check("calls.idx existe", idx ~= nil and #idx >= 2, idx and (#idx .. " linhas") or "ausente")
if idx and #idx >= 2 then
    local okh, h = pcall(function() return game:GetService("HttpService"):JSONDecode(idx[1]) end)
    check("calls.idx header _h=1", okh and h._h == 1 and h.file == "calls_idx")

    local oke, entry = pcall(function() return game:GetService("HttpService"):JSONDecode(idx[#idx]) end)
    check("calls.idx ultima entrada parseavel", oke and type(entry) == "table", tostring(entry))

    if oke and type(entry) == "table" then
        check("entrada tem path", type(entry.path) == "string" and #entry.path > 0, tostring(entry.path))
        check("entrada tem bytes", type(entry.bytes) == "number", tostring(entry.bytes))
        check("entrada tem lines", type(entry.lines) == "number", tostring(entry.lines))
        check("entrada closed=true", entry.closed == true, tostring(entry.closed))
        check("entrada ts_min", type(entry.ts_min) == "number", tostring(entry.ts_min))
        check("entrada ts_max", type(entry.ts_max) == "number", tostring(entry.ts_max))
        check("entrada corr_first", type(entry.corr_first) == "string", tostring(entry.corr_first))
        check("entrada corr_last", type(entry.corr_last) == "string", tostring(entry.corr_last))
        check("entrada seq_first", type(entry.seq_first) == "number", tostring(entry.seq_first))
        check("entrada seq_last", type(entry.seq_last) == "number", tostring(entry.seq_last))
        check("entrada by_remote tem Shoot", type(entry.by_remote) == "table" and entry.by_remote["ReplicatedStorage.Remotes.Shoot"] ~= nil, tostring(entry.by_remote and entry.by_remote["ReplicatedStorage.Remotes.Shoot"]))
        check("entrada by_source tem Weapon", type(entry.by_source) == "table" and entry.by_source["Players.LocalPlayer.PlayerScripts.Weapon"] ~= nil, tostring(entry.by_source and entry.by_source["Players.LocalPlayer.PlayerScripts.Weapon"]))
        check("entrada by_action_n preenchido", type(entry.by_action_n) == "table" and next(entry.by_action_n) ~= nil, tostring(entry.by_action_n))
    end
end

-- ============================================================
-- 3. manifest cobre o arquivo fechado
-- ============================================================

local man_raw = select(2, pcall(readfile, DIR .. "/manifest.json"))
local man_ok = false
if type(man_raw) == "string" then
    local ok, man = pcall(function() return game:GetService("HttpService"):JSONDecode(man_raw) end)
    print("[DEBUG callidx] man decode:", ok, "type:", type(man))
    if ok and man.files and man.files.calls then
        print("[DEBUG callidx] num entradas:", #man.files.calls)
        local fechados = 0
        for _, f in ipairs(man.files.calls) do
            if f.closed == true then fechados = fechados + 1 end
            print("[DEBUG callidx] entry:", f.path, "closed:", f.closed)
        end
        man_ok = fechados >= 1
    end
end
check("manifest tem arquivo fechado", man_ok)

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/callidx_test.json", enc) end

print(string.format("[callidx] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[callidx] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
