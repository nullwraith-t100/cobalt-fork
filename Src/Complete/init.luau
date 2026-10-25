--[[
    Cobalt Fork v2.4 — Complete (Fase final)
    Entry point da versão completa. Carrega todos os módulos e inicia a sessão
    via Main. Chamado pelo loader mínimo tests/run_complete.luau.
    Não grava nada sem redação: Enrich.pack() sempre antes do Recorder.
]]

local Complete = {}
Complete.__index = Complete

local function fetch(rel)
    local ok, src = pcall(function() return game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/" .. rel) end)
    if not ok or type(src) ~= "string" then return nil, "HttpGet: " .. tostring(src) end
    local chunk, err = loadstring(src)
    if not chunk then return nil, string.format("compile %s: %s", rel, tostring(err)) end
    local run_ok, mod = pcall(chunk)
    if not run_ok then return nil, "runtime " .. rel .. ": " .. tostring(mod) end
    if type(mod) ~= "table" then return nil, "retorno nao e tabela: " .. type(mod) end
    return mod
end

function Complete.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Complete)
    self.mode = opts.mode or "full"
    self.parent_session = opts.parent_session
    return self
end

function Complete:start()
    local mods = {}
    for _, rel in ipairs({
        "Src/Enrich/init.luau",
        "Src/Session/init.luau",
        "Src/Scanner/init.luau",
        "Src/Hook/init.luau",
        "Src/Pair/init.luau",
        "Src/Recorder/init.luau",
        "Src/Inventory/init.luau",
        "Src/Derive/init.luau",
        "Src/Diff/init.luau",
        "Src/FnInfo/init.luau",
        "Src/Dedup/init.luau",
        "Src/UI/init.luau",
        "Src/Main/init.luau",
    }) do
        local m, err = fetch(rel)
        if not m then
            return false, "modulo " .. rel .. " falhou: " .. tostring(err)
        end
        mods[rel] = m
    end

    _G.Enrich = mods["Src/Enrich/init.luau"]

    local Main = mods["Src/Main/init.luau"]
    local main = Main.new({
        mode = self.mode,
        parent_session = self.parent_session,
        modules = mods,
    })
    local ok, res = main:start()
    if not ok then return false, "main:start: " .. tostring(res) end

    self.main = main
    self.mods = mods
    return true, self
end

function Complete:on_outgoing(record)
    if self.main then self.main:on_outgoing(record) end
end

function Complete:on_incoming(record)
    if self.main then self.main:on_incoming(record) end
end

function Complete:on_invoke_resolved(record, ret, err, elapsed_ms)
    if self.main then self.main:on_invoke_resolved(record, ret, err, elapsed_ms) end
end

function Complete:capture_fn(fn, src_path, line)
    if self.main then self.main:capture_fn(fn, src_path, line) end
end

function Complete:expire_pendings(older_than_ts, observable_map)
    if self.main then self.main:expire_pendings(older_than_ts, observable_map) end
end

function Close()
    -- nao fecha automaticamente; chamar Complete:close() ou deixar o teleport/foco fazer
end

function Complete:close(reason, extra)
    if not self.main then return false, "no_session" end
    return self.main:close(reason, extra)
end

return Complete
