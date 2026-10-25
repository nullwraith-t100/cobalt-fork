--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 5: Modos lite e dry (roda no executor)
    Valida: dry não grava arquivo (só conta), lite grava com args compactos, full grava tudo.
    Grava Cobalt/modes_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_modes/" .. tostring(os.time())
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
    pcall(writefile, "Cobalt/modes_test.json", enc)
    warn("[modes] modulo nao carregou — veja Cobalt/modes_test.json")
    return results
end

-- ============================================================
-- 1. Modo dry: não grava arquivo, só conta
-- ============================================================

local rec_dry = Recorder.new({
    dir = DIR .. "/dry",
    session = "sess_dry",
    mode = "full",
    dry = true,
    config = { rotation_limit_bytes = 200, retry_delays_ms = { 10 } },
})

local opened = rec_dry:open_next()
check("dry open_next ok", opened == true)

for i = 1, 10 do
    rec_dry:enqueue({
        corr = "0:" .. i, ts = os.time(), caller = "game", remote_id = 17,
        remote = "RS.Test", method = "FireServer", args = { { t = "number", v = i } },
        args_sha = Enrich.hash64("arg" .. i), outcome = "unknown", outcome_from = "unobservable",
    })
end

local flushed = rec_dry:flush()
check("dry flush ok", flushed == true)
rec_dry:stop()

-- modo dry não deve criar arquivo .ndjson
local dry_files = {}
if typeof(listfiles) == "function" then
    local lok, files = pcall(listfiles, DIR .. "/dry")
    if lok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("%.ndjson$") then dry_files[#dry_files + 1] = f end
        end
    end
end
check("dry nao grava arquivo .ndjson", #dry_files == 0, tostring(#dry_files) .. " arquivos")

-- stats ainda funcionam em modo dry
local st = rec_dry:stats()
check("dry stats records_written=10", st.records_written == 10, tostring(st.records_written))

-- ============================================================
-- 2. Modo lite: grava normalmente (args compactos vem do Hook/Enrich)
-- ============================================================

local rec_lite = Recorder.new({
    dir = DIR .. "/lite",
    session = "sess_lite",
    mode = "lite",
    config = { rotation_limit_bytes = 200, retry_delays_ms = { 10 } },
})

local opened2 = rec_lite:open_next()
check("lite open_next ok", opened2 == true)

-- args compactos (depth 2): apenas valores simples, sem tabelas aninhadas
local args_compact = {
    { t = "number", v = 42 },
    { t = "string", v = "oi" },
}

rec_lite:enqueue({
    corr = "0:1", ts = os.time(), caller = "game", remote_id = 17,
    remote = "RS.Test", method = "FireServer", args = args_compact,
    args_sha = Enrich.hash64("compact"), outcome = "accepted", outcome_from = "ret",
    dedup_key = "dk1",
})

rec_lite:flush()
rec_lite:stop()

-- modo lite grava arquivo
local lite_files = {}
if typeof(listfiles) == "function" then
    local lok, files = pcall(listfiles, DIR .. "/lite")
    if lok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("%.ndjson$") then lite_files[#lite_files + 1] = f end
        end
    end
end
check("lite grava arquivo .ndjson", #lite_files >= 1, tostring(#lite_files) .. " arquivos")

local lite_st = rec_lite:stats()
check("lite stats records_written=1", lite_st.records_written == 1, tostring(lite_st.records_written))

-- ============================================================
-- 3. Modo full: grava tudo (padrao, ja testado no phase5)
-- ============================================================

local rec_full = Recorder.new({
    dir = DIR .. "/full",
    session = "sess_full",
    mode = "full",
    config = { rotation_limit_bytes = 200, retry_delays_ms = { 10 } },
})

local opened3 = rec_full:open_next()
check("full open_next ok", opened3 == true)

rec_full:enqueue({
    corr = "0:1", ts = os.time(), caller = "game", remote_id = 17,
    remote = "RS.Test", method = "FireServer", args = args_compact,
    args_sha = Enrich.hash64("full"), outcome = "accepted", outcome_from = "ret",
})

rec_full:flush()
rec_full:stop()

local full_files = {}
if typeof(listfiles) == "function" then
    local lok, files = pcall(listfiles, DIR .. "/full")
    if lok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("%.ndjson$") then full_files[#full_files + 1] = f end
        end
    end
end
check("full grava arquivo .ndjson", #full_files >= 1, tostring(#full_files) .. " arquivos")

-- ============================================================
-- 4. Modo é propagado no header do arquivo
-- ============================================================

if #full_files >= 1 then
    local function read_first_line(path)
        local ok, content = pcall(readfile, path)
        if not ok or type(content) ~= "string" then return nil end
        return content:match("([^\n]*)")
    end
    local first = read_first_line(DIR .. "/full/" .. full_files[1])
    if first then
        local ok, hdr = pcall(function() return game:GetService("HttpService"):JSONDecode(first) end)
        check("full header mode=full", ok and hdr.mode == "full", ok and tostring(hdr.mode) or "decode falhou")
    end
end

if #lite_files >= 1 then
    local function read_first_line(path)
        local ok, content = pcall(readfile, path)
        if not ok or type(content) ~= "string" then return nil end
        return content:match("([^\n]*)")
    end
    local first = read_first_line(DIR .. "/lite/" .. lite_files[1])
    if first then
        local ok, hdr = pcall(function() return game:GetService("HttpService"):JSONDecode(first) end)
        check("lite header mode=lite", ok and hdr.mode == "lite", ok and tostring(hdr.mode) or "decode falhou")
    end
end

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/modes_test.json", enc) end

print(string.format("[modes] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[modes] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
