--[[
    Cobalt Fork v2.4 — teste sintético da lacuna 1: FnInfo (roda no executor)
    Valida captura de consts/upvals, fn_info.ndjson, shared/fn_info/<sha>.json,
    shared/scripts/<sha>.luau + .meta.json, não-duplicação e refresh de upvals.
    Grava Cobalt/fninfo_test.json.
]]

local BASE = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/"
local DIR = "Cobalt/test_fninfo/" .. tostring(os.time())
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
local FnInfo, e2 = fetch_module("Src/FnInfo/init.luau")

check("load Enrich", Enrich ~= nil, e1)
check("load FnInfo", FnInfo ~= nil, e2)
if not (Enrich and FnInfo) then
    local enc = game:GetService("HttpService"):JSONEncode({ pass = false, results = results })
    pcall(writefile, "Cobalt/fninfo_test.json", enc)
    warn("[fninfo] modulo nao carregou — veja Cobalt/fninfo_test.json")
    return results
end

_G.Enrich = Enrich

-- ============================================================
-- 1. captura de consts/upvals
-- ============================================================

local function fn_with_upvals()
    local up = "secreto"
    return function(x)
        return x + up
    end
end

local inner = fn_with_upvals()
local fi = FnInfo.new(DIR, "sess_fninfo")

local ok, sha, entry = fi:capture(inner, "Players.LocalPlayer.PlayerScripts.Test", 42, Enrich)
check("capture ok", ok == true, tostring(sha))
check("sha 16 hex", type(sha) == "string" and #sha == 16 and sha:match("^%x+$") ~= nil, tostring(sha))
check("entry tem consts", type(entry.consts) == "table", tostring(type(entry.consts)))
check("entry tem upvals", type(entry.upvals) == "table", tostring(type(entry.upvals)))
check("upvals_available", entry.upvals_available == true, tostring(entry.upvals_available))
check("consts_available", type(entry.consts_available) == "boolean", tostring(entry.consts_available))
check("first_ts presente", type(entry.first_ts) == "number", tostring(entry.first_ts))
check("upvals_sha presente", type(entry.upvals_sha) == "string" and #entry.upvals_sha == 16, entry.upvals_sha)

-- ============================================================
-- 2. não duplica mesma função
-- ============================================================

local ok2, sha2, entry2 = fi:capture(inner, "Players.LocalPlayer.PlayerScripts.Test", 42, Enrich)
check("nao duplica", ok2 == true and sha2 == nil and entry2 == nil, tostring(sha2) .. " / " .. tostring(entry2))

-- ============================================================
-- 3. função diferente gera nova entrada
-- ============================================================

local function outra_fn(a, b) return a + b end
local ok3, sha3, entry3 = fi:capture(outra_fn, "Players.LocalPlayer.PlayerScripts.Outra", 10, Enrich)
check("nova entrada", ok3 == true and type(sha3) == "string" and #sha3 == 16, tostring(sha3))
check("entries = 2", #fi.entries == 2, tostring(#fi.entries))

-- ============================================================
-- 4. write_ndjson com header
-- ============================================================

local okw, content = fi:write_ndjson("sess_fninfo")
check("write_ndjson ok", okw == true and type(content) == "string" and #content > 0, tostring(content))
if type(content) == "string" then
    local lines = {}
    for line in content:gmatch("[^\n]+") do lines[#lines + 1] = line end
    check("ndjson header + 2 linhas", #lines == 3, tostring(#lines))
    local okh, h = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[1]) end)
    check("ndjson header _h=1", okh and h._h == 1 and h.file == "fn_info")
    local oke, e1 = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[2]) end)
    check("linha fn_info entry 1", oke and e1.src == "Players.LocalPlayer.PlayerScripts.Test" and e1.line == 42)
    local oke2, e2e = pcall(function() return game:GetService("HttpService"):JSONDecode(lines[3]) end)
    check("linha fn_info entry 2", oke2 and e2e.src == "Players.LocalPlayer.PlayerScripts.Outra" and e2e.line == 10)
end

-- ============================================================
-- 5. shared/fn_info/<sha>.json gravado
-- ============================================================

local shared_json_ok = false
if typeof(listfiles) == "function" then
    local l_ok, files = pcall(listfiles, DIR .. "/../shared/fn_info")
    if l_ok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("%.json$") then
                local c_ok, c = pcall(readfile, f)
                if c_ok and type(c) == "string" then
                    local dec_ok, obj = pcall(function() return game:GetService("HttpService"):JSONDecode(c) end)
                    if dec_ok and type(obj) == "table" and obj.src then shared_json_ok = true break end
                end
            end
        end
    end
end
check("shared/fn_info/*.json gravado", shared_json_ok)

-- ============================================================
-- 6. shared/scripts/<sha>.luau + .meta.json
-- ============================================================

local shared_luau_ok = false
local shared_meta_ok = false
if typeof(listfiles) == "function" then
    local l_ok, files = pcall(listfiles, DIR .. "/../shared/scripts")
    if l_ok and type(files) == "table" then
        for _, f in ipairs(files) do
            if f:match("%.luau$") then shared_luau_ok = true end
            if f:match("%.meta%.json$") then shared_meta_ok = true end
        end
    end
end
check("shared/scripts/*.luau gravado", shared_luau_ok)
check("shared/scripts/*.meta.json gravado", shared_meta_ok)

-- ============================================================
-- 7. refresh_upvals atualiza entrada existente
-- ============================================================

local ok_refresh = fi:refresh_upvals(inner, "Players.LocalPlayer.PlayerScripts.Test", 42, Enrich, os.time() + 5)
check("refresh_upvals ok", ok_refresh == true, tostring(ok_refresh))
check("upvals_last_ts atualizado", fi.entries[1].upvals_last_ts >= fi.entries[1].first_ts, tostring(fi.entries[1].upvals_last_ts) .. " vs " .. tostring(fi.entries[1].first_ts))

-- ============================================================
-- 8. caps: consts/upvals truncados em 50
-- ============================================================

local muitos = {}
for i = 1, 60 do muitos[i] = i end
local fn_many = function() return muitos end
local ok4, sha4, entry4 = fi:capture(fn_many, "Players.LocalPlayer.PlayerScripts.Muitos", 1, Enrich)
check("consts_trunc quando > 50", entry4.consts_trunc == true, tostring(entry4.consts_trunc))
check("consts limitado a 50", #entry4.consts == 50, tostring(#entry4.consts))

-- ============================================================
-- resultado
-- ============================================================

local summary = { pass = (failed == 0), failed = failed, total = #results, ts = os.time(), results = results }
local enc_ok, enc = pcall(function() return game:GetService("HttpService"):JSONEncode(summary) end)
if enc_ok then pcall(writefile, "Cobalt/fninfo_test.json", enc) end

print(string.format("[fninfo] %d/%d ok, %d falhas", #results - failed, #results, failed))
for _, r in ipairs(results) do
    if not r.ok then print(string.format("[fninfo] FALHOU: %s -> %s", r.name, tostring(r.detail))) end
end
return summary
