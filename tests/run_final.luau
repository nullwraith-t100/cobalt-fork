--[[
    Cobalt Fork v2.4 — Loader FINAL com Wind UI (Fase 9 / §14 DESIGN.md)
    Usa Wind UI (Footagesus/WindUI) para a aba Recorder.
    Inicia o fork completo e abre a aba Recorder com controles de config,
    pause/resume, stats ao vivo e probe status. Copia probe.json para Cobalt/.

    Uso no Delta:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/run_final.luau"))()
]]

local COMPLETE_URL = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/Complete/init.luau"
local UI_URL       = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/Src/UI/WindUI.luau"
local PROBE_URL    = "https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/docs/probe.json"

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

local function fetch_text(url)
    local ok, src = pcall(function() return game:HttpGet(url) end)
    if not ok or type(src) ~= "string" then
        return nil, "HttpGet falhou: " .. tostring(src)
    end
    return src
end

-- 1. copia probe.json para Cobalt/ (obrigatório antes do Recorder abrir)
local probe_src, perr = fetch_text(PROBE_URL)
if probe_src then
    local ok, err = pcall(writefile, "Cobalt/probe.json", probe_src)
    if ok then
        print("[final] probe.json copiado para Cobalt/probe.json")
    else
        print("[final] falha ao gravar probe.json: " .. tostring(err))
    end
else
    print("[final] nao baixou probe.json: " .. tostring(perr))
end

-- 2. carrega meu modulo UI (que internamente busca o WindUI)
local ui_mod, uierr = fetch_module(UI_URL)
if not ui_mod then
    return warn("[final] UI nao carregou: " .. tostring(uierr))
end
print("[final] UI carregada: " .. UI_URL)

-- 3. carrega Complete (entry point do fork)
local complete, cerr = fetch_module(COMPLETE_URL)
if not complete then
    return warn("[final] Complete nao carregou: " .. tostring(cerr))
end

-- 4. instancia Complete
local ok2, complete_inst = pcall(function() return complete.new() end)
if not ok2 then
    return warn("[final] complete.new falhou: " .. tostring(complete_inst))
end

-- 5. instancia UI (passa a instância Complete)
local ok3, ui = pcall(function() return ui_mod.new(complete_inst) end)
if not ok3 then
    return warn("[final] UI.new falhou: " .. tostring(ui))
end

-- 6. start da janela UI
local ok4, win_err = ui:start()
if not ok4 then
    return warn("[final] UI:start falhou: " .. tostring(win_err))
end

print("[final] Cobalt Fork v2.4 iniciado com Wind UI. Janela Recorder aberta.")

-- 7. loop de stats ao vivo (atualiza a cada 2 s enquanto a janela estiver visível)
task.spawn(function()
    while ui.visible do
        pcall(function() ui:update_stats() end)
        task.wait(2)
    end
end)

return ui, complete_inst
