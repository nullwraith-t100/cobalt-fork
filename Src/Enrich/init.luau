--[[
    Cobalt Fork v2.4 — Enrich (Fase 2)
    Pipeline fixa: serialize → redact → cap → hash (§9 DESIGN.md).
    Tipagem §6.7.1, redação §9, caps §9, hash 64 bits §6.7 (FNV-1a duplo 32 bits = 16 hex).
    Probe: getscripthash retorna nil no Delta → sempre FNV-1a 64.
]]

local Enrich = {}

-- ============================================================
-- Hash 64 bits — FNV-1a duplo 32 bits (16 hex)
-- ============================================================

local FNV_OFFSET = 0x811c9dc5
local FNV_PRIME = 0x01000193
local FNV_SEED_B = 0x9e3779b9

-- multiplicação modular 32 bits sem perda de precisão (doubles)
local function mul32(a, b)
    local alo = a % 65536
    local ahi = math.floor(a / 65536)
    local blo = b % 65536
    local bhi = math.floor(b / 65536)
    local lo = alo * blo
    local mid = (alo * bhi + ahi * blo) % 65536
    return (lo + mid * 65536) % 4294967296
end

local function fnv1a_32(str, seed)
    local h = seed
    for i = 1, #str do
        h = bit32.bxor(h, string.byte(str, i))
        h = mul32(h, FNV_PRIME)
    end
    return h
end

-- hash64(str) -> 16 hex
function Enrich.hash64(str)
    str = tostring(str)
    local a = fnv1a_32(str, FNV_OFFSET)
    local b = fnv1a_32(str, bit32.bxor(FNV_OFFSET, FNV_SEED_B))
    return string.format("%08x%08x", a, b)
end

-- ============================================================
-- Redação §9 — regex de token inteiro em chaves/nomes
-- ============================================================

local REDACT_TOKENS = {
    token = true, apikey = true, api_key = true, secret = true,
    password = true, passwd = true, auth = true, authorization = true,
    signature = true, sig = true, credential = true, cookie = true,
    jwt = true, bearer = true,
}

-- true se a chave casa um token sensivel — token INTEIRO, nunca substring.
-- "apikey"/"api_key" casam; "KeyCode"/"TokenCount" nao. camelCase so redige
-- quando o token sensivel e o ultimo segmento (authToken, userPassword).
function Enrich.key_is_sensitive(name)
    local lower = tostring(name):lower()
    if REDACT_TOKENS[lower] then return true end
    for part in lower:gmatch("[^_%-%.]+") do
        if REDACT_TOKENS[part] then return true end
    end
    local camel = tostring(name):gsub("(%l)(%u)", "%1 %2"):gsub("(%d)(%u)", "%1 %2")
    local segs = {}
    for tok in camel:gmatch("%S+") do segs[#segs + 1] = tok:lower() end
    if #segs > 1 and REDACT_TOKENS[segs[#segs]] then return true end
    return false
end

-- padrões de conteúdo em valores
local CONTENT_PATTERNS = {
    jwt = "eyJ[%w%-%_]+%.",
    discord = "discordapp?%.com/api/webhooks",
    hex32 = "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x",
    b64long = "[A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=][A-Za-z0-9+/=]",
}

-- entropia simples de Shannon para strings longas
local function shannon_entropy(s)
    local counts = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        counts[b] = (counts[b] or 0) + 1
    end
    local e = 0
    for _, c in pairs(counts) do
        local p = c / #s
        e = e - p * (math.log(p) / math.log(2))
    end
    return e
end

local function is_high_entropy(s)
    if #s < 24 then return false end
    return shannon_entropy(s) > 4.5
end

function Enrich.value_is_sensitive(value)
    if type(value) ~= "string" then return false end
    if value:match(CONTENT_PATTERNS.jwt) then return true end
    if value:match(CONTENT_PATTERNS.discord) then return true end
    if value:match("^" .. CONTENT_PATTERNS.hex32) and #value >= 32 then return true end
    if #value >= 32 and value:match("^[A-Za-z0-9+/=]+$") and is_high_entropy(value) then return true end
    return false
end

-- ============================================================
-- Tipagem §6.7.1
-- ============================================================

local function is_valid_utf8(s)
    return utf8.len(s) ~= nil
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_encode(s)
    local out = {}
    local i = 1
    local n = #s
    while i <= n do
        local a = string.byte(s, i)
        local b = string.byte(s, i + 1)
        local c = string.byte(s, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(v / 262144) % 64
        local c2 = math.floor(v / 4096) % 64
        local c3 = math.floor(v / 64) % 64
        local c4 = v % 64
        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1) .. B64_CHARS:sub(c2 + 1, c2 + 1)
        if b then out[#out + 1] = B64_CHARS:sub(c3 + 1, c3 + 1) else out[#out + 1] = "=" end
        if c then out[#out + 1] = B64_CHARS:sub(c4 + 1, c4 + 1) else out[#out + 1] = "=" end
        i = i + 3
    end
    return table.concat(out)
end

Enrich.b64_encode = b64_encode

local function enc_string(v)
    if is_valid_utf8(v) then
        return { t = "string", v = v, trunc = false }
    end
    return { t = "string", b64 = b64_encode(v), bin = true, trunc = false }
end

local function enc_number(v)
    if v ~= v then return { t = "number", v = nil, special = "nan" } end
    if v == math.huge then return { t = "number", v = nil, special = "inf" } end
    if v == -math.huge then return { t = "number", v = nil, special = "-inf" } end
    return { t = "number", v = v }
end

local function enc_enum(v)
    local name = tostring(v)
    local n = nil
    -- EnumItem tem .Value; EnumType tem .GetEnumItems? simplificamos
    local ok, val = pcall(function() return v.Value end)
    if ok and type(val) == "number" then n = val end
    return { t = "Enum", v = name, n = n }
end

-- serialize com detecção de ciclo/refs
local function serialize_value(v, depth, seen, max_depth)
    if depth > max_depth then
        return { t = "opaque", class = "depth_cap" }
    end
    local ty = typeof(v)

    if v == nil then return { t = "nil" } end
    if ty == "boolean" then return { t = "bool", v = v } end
    if ty == "number" then return enc_number(v) end
    if ty == "string" then return enc_string(v) end

    if ty == "Vector2" or ty == "Vector3" or ty == "Vector2int16" or ty == "Vector3int16" then
        local arr = { v.X, v.Y }
        if ty == "Vector3" or ty == "Vector3int16" then arr[3] = v.Z end
        return { t = ty, v = arr }
    end
    if ty == "CFrame" then
        local pos = { v.X, v.Y, v.Z }
        -- GetComponents retorna 12 valores; 3x3 a partir dos 9 rotacionais
        local c = { v:GetComponents() }
        local rows = {
            { c[4], c[5], c[6] },
            { c[7], c[8], c[9] },
            { c[10], c[11], c[12] },
        }
        return { t = "CFrame", pos = pos, rot = rows, rot_order = "row-major" }
    end
    if ty == "Color3" then return { t = "Color3", v = { v.R, v.G, v.B }, scale = "0-1" } end
    if ty == "BrickColor" then return { t = "BrickColor", n = v.Number, name = v.Name } end
    if ty == "UDim" then return { t = "UDim", v = { v.Scale, v.Offset } } end
    if ty == "UDim2" then return { t = "UDim2", v = { { v.X.Scale, v.X.Offset }, { v.Y.Scale, v.Y.Offset } } } end
    if ty == "Rect" then return { t = "Rect", v = { { v.Min.X, v.Min.Y }, { v.Max.X, v.Max.Y } } } end
    if ty == "NumberRange" then return { t = "NumberRange", v = { v.Min, v.Max } } end
    if ty == "NumberSequence" then
        local kps, kp_ok = {}, pcall(function()
            for _, kp in ipairs(v.Keypoints) do kps[#kps + 1] = { kp.Time or 0, kp.Value or 0, kp.Envelope or 0 } end
        end)
        return { t = "NumberSequence", kps = kps, ok = kp_ok }
    end
    if ty == "ColorSequence" then
        local kps, kp_ok = {}, pcall(function()
            for _, kp in ipairs(v.Keypoints) do
                local val = kp.Value
                local rgb = { 0, 0, 0 }
                if type(val) == "table" then rgb = { val.R or 0, val.G or 0, val.B or 0 } end
                kps[#kps + 1] = { kp.Time or 0, rgb, kp.Envelope or 0 }
            end
        end)
        return { t = "ColorSequence", kps = kps, ok = kp_ok }
    end
    if ty == "Ray" then return { t = "Ray", origin = { v.Origin.X, v.Origin.Y, v.Origin.Z }, dir = { v.Direction.X, v.Direction.Y, v.Direction.Z } } end
    if ty == "Region3" then
        local c = v.CFrame
        local size = v.Size
        return { t = "Region3", min = { c.X - size.X / 2, c.Y - size.Y / 2, c.Z - size.Z / 2 }, max = { c.X + size.X / 2, c.Y + size.Y / 2, c.Z + size.Z / 2 } }
    end
    if ty == "Region3int16" then return { t = "Region3int16", min = { v.Min.X, v.Min.Y, v.Min.Z }, max = { v.Max.X, v.Max.Y, v.Max.Z } } end
    if ty == "TweenInfo" then
        return { t = "TweenInfo", time = v.Time, easing = v.EasingStyle.Value, style = v.EasingDirection.Value, delay = v.DelayTime, ["repeat"] = v.RepeatCount, reverse = v.Reverses and 1 or 0 }
    end
    if ty == "DateTime" then return { t = "DateTime", unix = v.UnixTimestamp, iso = v:ToIsoDate() } end
    if ty == "Font" then return { t = "Font", family = v.Family, weight = v.Weight.Value, style = v.Style.Value } end
    if ty == "PhysicalProperties" then return { t = "PhysicalProperties", density = v.Density, friction = v.Friction, elasticity = v.Elasticity } end
    if ty == "EnumItem" then return enc_enum(v) end
    if ty == "Enum" then return { t = "Enum", v = tostring(v) } end
    if ty == "Axes" then
        local a = {}
        if v.X then a[#a + 1] = "X" end
        if v.Y then a[#a + 1] = "Y" end
        if v.Z then a[#a + 1] = "Z" end
        return { t = "Axes", v = a }
    end
    if ty == "Faces" then
        local a = {}
        if v.Top then a[#a + 1] = "Top" end
        if v.Bottom then a[#a + 1] = "Bottom" end
        if v.Left then a[#a + 1] = "Left" end
        if v.Right then a[#a + 1] = "Right" end
        if v.Back then a[#a + 1] = "Back" end
        if v.Front then a[#a + 1] = "Front" end
        return { t = "Faces", v = a }
    end
    if ty == "Instance" then
        local path = nil
        local ok, p = pcall(function() return v:GetFullName() end)
        if ok then path = p end
        return { t = "Instance", v = path or tostring(v), class = v.ClassName, detached = (v.Parent == nil) }
    end
    if ty == "buffer" then
        local ok, len = pcall(function() return buffer.len(v) end)
        len = ok and len or 0
        local ok2, s = pcall(function() return buffer.tostring(v) end)
        s = ok2 and s or ""
        return { t = "buffer", len = len, entropy = 0, likely_encrypted = false, b64 = s:sub(1, 500), trunc = #s > 500 }
    end
    if ty == "function" then
        local ok, src, line = pcall(function() return debug.info(v, "s"), debug.info(v, "l") end)
        return { t = "opaque", class = "function", src = ok and src or nil, line = ok and line or nil }
    end
    if ty == "thread" then return { t = "opaque", class = "thread" } end
    if ty == "userdata" then return { t = "opaque", class = ty, v = tostring(v) } end

    if ty == "table" then
        if seen[v] then
            return { t = "ref", id = seen[v] }
        end
        if depth >= max_depth then
            return { t = "table", arr = {}, map = {}, keys_n = 0, trunc = true }
        end
        local id = #seen + 1
        seen[v] = id
        local arr, map = {}, {}
        local keys_n = 0
        for k, val in pairs(v) do
            keys_n = keys_n + 1
            if type(k) == "number" and k >= 1 and k % 1 == 0 then
                arr[k] = serialize_value(val, depth + 1, seen, max_depth)
            else
                map[#map + 1] = { serialize_value(k, depth + 1, seen, max_depth), serialize_value(val, depth + 1, seen, max_depth) }
            end
        end
        return { t = "table", arr = arr, map = map, keys_n = keys_n, trunc = false, def = { id = id } }
    end

    return { t = "opaque", class = ty, v = tostring(v) }
end

-- ============================================================
-- Redação recursiva sobre args/upvals/consts/ret/err
-- ============================================================

local REDACTION_SALT = ""
local REDACTION_MIN_SHA_LEN = 16

function Enrich.set_salt(salt)
    REDACTION_SALT = tostring(salt or "")
    return true
end

local function redacted_string(value)
    local r = { t = "string", redacted = true, trunc = false }
    if #value >= REDACTION_MIN_SHA_LEN then
        r.sha = Enrich.hash64(REDACTION_SALT .. value)
    else
        r.redacted_short = true
    end
    return r
end

local function redact_node(node, depth, max_depth)
    if type(node) ~= "table" then return node end
    if depth > max_depth then return node end

    -- string direta
    if node.t == "string" and type(node.v) == "string" then
        if Enrich.value_is_sensitive(node.v) then
            return redacted_string(node.v)
        end
        return node
    end

    -- tabela: redigir chaves sensíveis e recursar
    if node.t == "table" then
        local new = { t = "table", arr = {}, map = {}, keys_n = node.keys_n, trunc = node.trunc }
        if node.def then new.def = node.def end
        -- array
        for i, v in ipairs(node.arr or {}) do
            new.arr[i] = redact_node(v, depth + 1, max_depth)
        end
        -- map
        for _, kv in ipairs(node.map or {}) do
            local k, v = kv[1], kv[2]
            local key_name = nil
            if k and k.t == "string" and type(k.v) == "string" then key_name = k.v end
            if key_name and Enrich.key_is_sensitive(key_name) then
                -- chave sensivel -> valor redigido
                local vnode = v
                if vnode and vnode.t == "string" and type(vnode.v) == "string" then
                    new.map[#new.map + 1] = { k, redacted_string(vnode.v) }
                else
                    new.map[#new.map + 1] = { k, { t = "redacted" } }
                end
            else
                new.map[#new.map + 1] = { redact_node(k, depth + 1, max_depth), redact_node(v, depth + 1, max_depth) }
            end
        end
        return new
    end

    -- outros tipos com possiveis campos string (CFrame etc não têm)
    return node
end

-- ============================================================
-- Caps §9
-- ============================================================

local CAPS = {
    args_depth = 5,
    args_array = 200,
    args_table_keys = 100,
    args_string = 200,
    upvals_consts = 50,
    ret_bytes = 1024,
    err_bytes = 500,
    buffer_b64 = 500,
    stack_frames = 8,
}

local function cap_node(node, depth)
    if type(node) ~= "table" then return node end
    if depth > CAPS.args_depth then return node end
    if node.t == "string" then
        if type(node.v) == "string" and #node.v > CAPS.args_string then
            node.v = node.v:sub(1, CAPS.args_string)
            node.trunc = true
        end
        return node
    end
    if node.t == "table" then
        if #node.arr > CAPS.args_array then
            for i = CAPS.args_array + 1, #node.arr do node.arr[i] = nil end
            node.trunc = true
        end
        if #node.map > CAPS.args_table_keys then
            for i = CAPS.args_table_keys + 1, #node.map do node.map[i] = nil end
            node.trunc = true
        end
        for i, v in ipairs(node.arr) do node.arr[i] = cap_node(v, depth + 1) end
        for _, kv in ipairs(node.map) do
            kv[1] = cap_node(kv[1], depth + 1)
            kv[2] = cap_node(kv[2], depth + 1)
        end
        return node
    end
    return node
end

-- ============================================================
-- Serialização canônica para hash (chaves ordenadas, %.17g, tipos)
-- ============================================================

local function canonical_number(n)
    if n ~= n then return "nan" end
    if n == math.huge then return "inf" end
    if n == -math.huge then return "-inf" end
    if n % 1 == 0 and math.abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.17g", n)
end

local function canonical(v)
    if v == nil then return "n" end
    local t = type(v)
    if t == "boolean" then return v and "b1" or "b0" end
    if t == "number" then return "d" .. canonical_number(v) end
    if t == "string" then return "s" .. #v .. ":" .. v end
    if t == "table" then
        -- ordena chaves por representação canônica
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            return canonical(a) < canonical(b)
        end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = canonical(k) .. "=" .. canonical(v[k])
        end
        return "t{" .. table.concat(parts, ";") .. "}"
    end
    return "u" .. tostring(v)
end

function Enrich.canonical(v)
    return canonical(v)
end

-- ============================================================
-- Pipeline público
-- ============================================================

-- serialize_arg(v) -> node tipado
function Enrich.serialize(v)
    local ok, node = pcall(serialize_value, v, 0, {}, CAPS.args_depth)
    if not ok then
        return false, { t = "opaque", class = "serialize_error", v = tostring(node) }
    end
    return true, node
end

-- redact_node(node) -> node
function Enrich.redact(node)
    local ok, res = pcall(redact_node, node, 0, CAPS.args_depth)
    if not ok then return false, { t = "opaque", class = "redact_error" } end
    return true, res
end

-- cap_node(node) -> node
function Enrich.cap(node)
    local ok, res = pcall(cap_node, node, 0)
    if not ok then return false, { t = "opaque", class = "cap_error" } end
    return true, res
end

-- pack_arg(v): serialize → redact → cap, retorna node final
function Enrich.pack_arg(v)
    local ok1, node = Enrich.serialize(v)
    if not ok1 then return false, node end
    local ok2, red = Enrich.redact(node)
    if not ok2 then return false, red end
    local ok3, capped = Enrich.cap(red)
    if not ok3 then return false, capped end
    return true, capped
end

-- args_sha sobre serialização canônica pós-redação, pré-truncamento
function Enrich.args_sha(nodes)
    local parts = {}
    for i, node in ipairs(nodes) do
        parts[i] = canonical(node)
    end
    return Enrich.hash64(table.concat(parts, "|"))
end

-- ============================================================
-- corr "<vm>:<n>" e action tracking
-- ============================================================

local corr_counts = {}

function Enrich.new_corr(vm)
    vm = vm or 0
    corr_counts[vm] = (corr_counts[vm] or 0) + 1
    return string.format("%d:%d", vm, corr_counts[vm])
end

function Enrich.reset_corr()
    corr_counts = {}
end

-- action cluster por gap
local action_state = {
    last_ts = 0,
    last_sig = nil,
    n = 0,
    current_remotes = {},
}

function Enrich.action_gap_ms()
    return 100
end

function Enrich.tick_action(remote_id, ts_ms)
    local gap = Enrich.action_gap_ms()
    if ts_ms - action_state.last_ts > gap then
        -- fecha cluster, novo n
        if next(action_state.current_remotes) then
            action_state.n = action_state.n + 1
        end
        action_state.current_remotes = {}
    end
    action_state.last_ts = ts_ms
    action_state.current_remotes[remote_id] = true
    -- assinatura = hash dos remotes ordenados
    local ids = {}
    for id in pairs(action_state.current_remotes) do ids[#ids + 1] = id end
    table.sort(ids)
    local sig = Enrich.hash64(table.concat(ids, ","))
    action_state.last_sig = sig
    return {
        action_sig = sig,
        action_n = action_state.n,
        action_span_ms = 0,
    }
end

function Enrich.reset_actions()
    action_state = { last_ts = 0, last_sig = nil, n = 0, current_remotes = {} }
end

return Enrich
