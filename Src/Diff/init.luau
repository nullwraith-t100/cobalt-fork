--[[
    Cobalt Fork v2.4 — Diff (Fase 4)
    Compara dois inventory.ndjson de sessões do mesmo place_id.
    Gera diff.json (opcional, só se config.diff_enabled).
    Derivável offline de dois inventory.ndjson.
]]

local Diff = {}
Diff.__index = Diff

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

local function parse_inventory(path)
    local ok, content = read_file(path)
    if not ok then return false, content end
    local remotes = {}
    local scripts = {}
    for line in content:gmatch("[^\n]+") do
        local dec_ok, obj = safe_decode(line)
        if dec_ok and type(obj) == "table" and obj._h ~= 1 then
            if obj.kind == "remote" then
                remotes[obj.path] = obj
            elseif obj.kind == "script" then
                scripts[obj.path] = obj
            end
        end
    end
    return true, { remotes = remotes, scripts = scripts }
end

function Diff.new()
    local self = setmetatable({}, Diff)
    return self
end

-- compara dois inventários (atual vs anterior)
function Diff:compare(current_inv, previous_inv)
    local diff = {
        schema = { major = 2, minor = 4 },
        added_remotes = {},
        removed_remotes = {},
        changed_remotes = {},
        added_scripts = {},
        removed_scripts = {},
        unchanged = 0,
    }

    -- remotes adicionados/removidos/alterados
    for path, cur in pairs(current_inv.remotes) do
        local prev = previous_inv.remotes[path]
        if not prev then
            diff.added_remotes[#diff.added_remotes + 1] = cur
        else
            -- mudou classe, observable, tags, attrs?
            local changed = false
            if cur.class ~= prev.class then changed = true end
            if cur.observable ~= prev.observable then changed = true end
            if cur.unreliable ~= prev.unreliable then changed = true end
            if changed then
                diff.changed_remotes[#diff.changed_remotes + 1] = {
                    path = path,
                    remote_id = cur.remote_id,
                    from = prev,
                    to = cur,
                }
            else
                diff.unchanged = diff.unchanged + 1
            end
        end
    end
    for path, prev in pairs(previous_inv.remotes) do
        if not current_inv.remotes[path] then
            diff.removed_remotes[#diff.removed_remotes + 1] = prev
        end
    end

    -- scripts adicionados/removidos
    for path, cur in pairs(current_inv.scripts) do
        if not previous_inv.scripts[path] then
            diff.added_scripts[#diff.added_scripts + 1] = cur
        end
    end
    for path, prev in pairs(previous_inv.scripts) do
        if not current_inv.scripts[path] then
            diff.removed_scripts[#diff.removed_scripts + 1] = prev
        end
    end

    return diff
end

-- escreve diff.json no diretório da sessão atual
function Diff:write(session_dir, diff)
    local ok, enc = safe_encode(diff)
    if ok then
        pcall(function() writefile(session_dir .. "/diff.json", enc) end)
        return true
    end
    return false, enc
end

-- lê sessions.idx, encontra a sessão anterior do mesmo place_id
-- retorna o caminho do inventory.ndjson dessa sessão (ou nil)
function Diff:find_previous_inventory(dir, current_session, place_id)
    local ok, content = read_file(dir .. "/sessions.idx")
    if not ok then return nil end
    local best = nil
    for line in content:gmatch("[^\n]+") do
        local dec_ok, obj = safe_decode(line)
        if dec_ok and type(obj) == "table" and obj._h ~= 1 then
            if obj.place_id == place_id and obj.session ~= current_session and obj.ts_end ~= nil then
                -- a mais recente
                if not best or obj.ts_end > best.ts_end then
                    best = obj
                end
            end
        end
    end
    if not best then return nil end
    return dir .. "/" .. best.session .. "/inventory.ndjson"
end

return Diff
