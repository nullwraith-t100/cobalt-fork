--[[
    Cobalt Fork v2.4 — Loader FINAL com Wind UI (Fase 9 / §14 DESIGN.md)
    Inicia o fork completo e abre a aba Recorder com controles de config,
    pause/resume, stats ao vivo e probe status.

    Uso no Delta:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/run_final.luau"))()
]]

local COMPLETE_URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Complete/init.luau"
local WINDUI_URL   = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/UI/WindUI.luau"

local function fetch_module(url)
    local ok, src = pcall(function() return game:HttpGet(url) end)
    if not ok or type(src) ~= "string" then
        return nil, "HttpGet falhou: " .. tostring(src)
    end
    local chunk, err = loadstring(src)
    if not chunk then
        return nil, string.format("compile (%d B): %s", #src, tostring(err))
    end
    local run_ok, mod = pcall(chunk)
    if not run_ok then
        return nil, "runtime: " .. tostring(mod)
    end
    if type(mod) ~= "table" then
        return nil, "retorno nao e tabela: " .. type(mod)
    end
    return mod
end

-- 1. carrega Wind UI
local windui, werr = fetch_module(WINDUI_URL)
if not windui then
    return warn("[final] Wind UI nao carregou: " .. tostring(werr))
end

-- 2. carrega Complete (entry point do fork)
local complete, cerr = fetch_module(COMPLETE_URL)
if not complete then
    return warn("[final] Complete nao carregou: " .. tostring(cerr))
end

-- 3. instancia Complete
local ok2, complete_inst = pcall(function() return complete.new() end)
if not ok2 then
    return warn("[final] complete.new falhou: " .. tostring(complete_inst))
end

-- 4. instancia UI Wind UI (passa a instância Complete como "main")
local UI = windui
local ok3, ui = pcall(function() return UI.new(complete_inst) end)
if not ok3 then
    return warn("[final] UI.new falhou: " .. tostring(ui))
end

-- 5. start da janela UI
local ok4, win_err = ui:start()
if not ok4 then
    return warn("[final] UI:start falhou: " .. tostring(win_err))
end

print("[final] Cobalt Fork v2.4 com Wind UI iniciado.")
print("[final] Janela Recorder aberta. Ajuste config e clique para iniciar/sessao.")

-- 6. loop de stats ao vivo (atualiza a cada 2 s enquanto a janela estiver visível)
task.spawn(function()
    while ui.visible do
        pcall(function() ui:update_stats() end)
        task.wait(2)
    end
end)

return ui, complete_inst
