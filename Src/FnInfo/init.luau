--[[
    Cobalt Fork v2.4 — FnInfo (Fase 6, lacuna 1)
    Coleta consts/upvals por função (§6.8), gera fn_info.ndjson e
    shared/fn_info/<sha>.json content-addressed.
    Upvalues: debug.getupvalue no Delta devolve só o valor -> nome indisponível;
    usamos o valor serializado + hash da versão. Não duplica: já visto não regrava.
]]

local FnInfo = {}
FnInfo.__index = FnInfo

-- converte um valor Lua (possivelmente tabela) para string segura para hash
local function upval_to_str(v)
    local t = type(v)
    if t == "string" then return v end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "nil" then return "nil" end
    if t == "table" then
        local ok, enc = pcall(function() return HttpService:JSONEncode(v) end)
        if ok then return enc end
        return "table:" .. tostring(v)
    end
    return "opaque:" .. t
end

-- monta a string de upvals para hashear
local function upvals_concat(upvals)
    local parts = {}
    for _, v in ipairs(upvals) do
        parts[#parts + 1] = upval_to_str(v)
    end
    return table.concat(parts, "|")
end

local HttpService = game:GetService("HttpService")

local function safe_encode(value)
    local ok, res = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return true, res end
    return false, tostring(res)
end

local function safe_decode(str)
    local ok, res = pcall(function() return HttpService:JSONDecode(str) end)
    if ok then return true, res end
    return false, tostring(res)
end

local function read_file(path)
    local ok, content = pcall(readfile, path)
    if ok and type(content) == "string" then return true, content end
    return false, tostring(content)
end

local function write_file(path, content)
    local ok, err = pcall(writefile, path, content)
    if ok then return true end
    return false, tostring(err)
end

local function header(session)
    return {
        _h = 1,
        schema = { major = 2, minor = 4 },
        file = "fn_info",
        session = session,
        mode = "full",
        redaction = { on = true, regex_version = "v1" },
        ts_header = os.time(),
    }
end

-- ============================================================
-- new
-- ============================================================

function FnInfo.new(session_dir, session)
    local self = setmetatable({}, FnInfo)
    self.session_dir = session_dir
    self.session = session
    self.seen = {} -- "<path>:<line>" -> true
    self.entries = {} -- linhas NDJSON
    self.shared_dir = session_dir .. "/../shared" -- Cobalt/shared
    return self
end

function FnInfo:_shared_path(sha, kind)
    return self.shared_dir .. "/" .. kind .. "/" .. sha .. "." .. (kind == "fn_info" and "json" or "luau")
end

-- ============================================================
-- captura de consts/upvals de uma função
-- ============================================================

local function get_source(fn)
    local ok, src = pcall(function() return debug.info(fn, "s") end)
    if ok and type(src) == "string" then return src end
    return nil
end

local function get_line(fn)
    local ok, line = pcall(function() return debug.info(fn, "l") end)
    if ok and type(line) == "number" then return line end
    return nil
end

local function get_consts(fn)
    local ok, consts = pcall(function() return getconstants(fn) end)
    if ok and type(consts) == "table" then return consts end
    return {}
end

local function get_upvals(fn)
    local upvals = {}
    local i = 1
    while true do
        local ok, a, b = pcall(function() return debug.getupvalue(fn, i) end)
        if not ok then break end
        -- Delta: debug.getupvalue devolve so o valor. Lua 5.1: (nome, valor).
        -- Pegamos o valor: se b existe, e b; senao, a.
        local val = b ~= nil and b or a
        if val == nil then break end
        upvals[#upvals + 1] = val
        i = i + 1
        if i > 200 then break end
    end
    return upvals
end

local function get_protos(fn)
    local ok, protos = pcall(function() return getprotos(fn) end)
    if ok and type(protos) == "table" then return protos end
    return {}
end

-- serializa consts/upvals via Enrich (tipagem §6.7.1 + redação §9 + caps)
local function serialize_list(values, Enrich)
    local out = {}
    for _, v in ipairs(values) do
        local ok, node = Enrich.pack_arg(v)
        if ok then out[#out + 1] = node else out[#out + 1] = { t = "opaque", class = "pack_error" } end
    end
    return out
end

-- ============================================================
-- capture(fn, src_path, line) -> (ok, sha, entry)
-- ============================================================

function FnInfo:capture(fn, src_path, line, Enrich)
    if not Enrich then return false, "enrich_nao_disponivel" end
    local key = tostring(src_path or "") .. ":" .. tostring(line or 0)
    if self.seen[key] then return true, nil, nil end -- já visto, não duplica

    local src = get_source(fn) or src_path or ""
    local ln = get_line(fn) or line or 0
    local sha = Enrich.hash64(src .. ":" .. tostring(ln))

    local consts = get_consts(fn)
    local upvals = get_upvals(fn)

    local consts_nodes = serialize_list(consts, Enrich)
    local upvals_nodes = serialize_list(upvals, Enrich)

    local consts_trunc = #consts_nodes > 50
    local upvals_trunc = #upvals_nodes > 50
    if consts_trunc then
        for i = 51, #consts_nodes do consts_nodes[i] = nil end
    end
    if upvals_trunc then
        for i = 51, #upvals_nodes do upvals_nodes[i] = nil end
    end

    -- converte upvals para strings seguras antes de hashear (table.concat nao aceita tabelas)
    local upval_strs = {}
    for _, v in ipairs(upvals) do
        upval_strs[#upval_strs + 1] = upval_to_str(v)
    end

    local entry = {
        src = src_path or src,
        line = ln,
        consts = consts_nodes,
        consts_trunc = consts_trunc,
        upvals = upvals_nodes,
        upvals_trunc = upvals_trunc,
        upvals_available = #upvals > 0,
        consts_available = #consts > 0,
        first_ts = os.time(),
        upvals_last_ts = os.time(),
        upvals_sha = Enrich.hash64(table.concat(upval_strs, "|")),
    }

    self.seen[key] = true
    self.entries[#self.entries + 1] = entry

    -- grava shared/fn_info/<sha>.json (content-addressed)
    local ok, enc = safe_encode(entry)
    if ok then
        local sdir = self.shared_dir .. "/fn_info"
        pcall(makefolder, sdir)
        write_file(sdir .. "/" .. sha .. ".json", enc)
    end

    -- grava shared/scripts/<sha>.luau + .meta.json se houver source
    if type(src) == "string" and #src > 0 then
        local sdir = self.shared_dir .. "/scripts"
        pcall(makefolder, sdir)
        write_file(sdir .. "/" .. sha .. ".luau", src)
        local meta = {
            sha = sha,
            src = src_path or src,
            line = ln,
            size = #src,
            first_ts = os.time(),
        }
        local ok2, meta_enc = safe_encode(meta)
        if ok2 then write_file(sdir .. "/" .. sha .. ".meta.json", meta_enc) end
    end

    return true, sha, entry
end

-- ============================================================
-- write_ndjson(session) -> (ok, content)
-- ============================================================

function FnInfo:write_ndjson(session)
    local lines = {}
    local ok, hline = safe_encode(header(session))
    if not ok then return false, hline end
    lines[1] = hline
    for _, entry in ipairs(self.entries) do
        local ok, line = safe_encode(entry)
        if ok then lines[#lines + 1] = line end
    end
    return true, table.concat(lines, "\n") .. "\n"
end

-- ============================================================
-- re-captura upvals quando changed_args detecta mudança (§6.8)
-- ============================================================

function FnInfo:refresh_upvals(fn, src_path, line, Enrich, new_ts)
    if not Enrich then return false end
    local key = tostring(src_path or "") .. ":" .. tostring(line or 0)
    -- encontra a entrada existente
    for _, entry in ipairs(self.entries) do
        if entry.src == (src_path or "") and entry.line == (line or 0) then
            local upvals = get_upvals(fn)
            local upvals_nodes = serialize_list(upvals, Enrich)
            local upvals_trunc = #upvals_nodes > 50
            if upvals_trunc then
                for i = 51, #upvals_nodes do upvals_nodes[i] = nil end
            end
            entry.upvals = upvals_nodes
            entry.upvals_trunc = upvals_trunc
            entry.upvals_last_ts = new_ts or os.time()
            entry.upvals_sha = Enrich.hash64(upvals_concat(upvals))
            return true
        end
    end
    return false
end

return FnInfo
