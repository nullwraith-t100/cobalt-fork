--[[
    Cobalt Fork v2.4 — WindUI Recorder (Fase 9 / §14 DESIGN.md)
    UI usando WindUI (Footagesus/WindUI).
    Sem hotkey, sem "open folder" (Android).
    Salva config em config.json com redaction_salt.
--]]

local UI = {}
UI.__index = UI

local HttpService = game:GetService("HttpService")

local WINDUI_URLS = {
    "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",
    "https://raw.githubusercontent.com/Footagesus/WindUI/master/dist/main.lua",
}

local function fetch_windui()
    for _, url in ipairs(WINDUI_URLS) do
        local ok, src = pcall(function() return game:HttpGet(url) end)
        if ok and type(src) == "string" and #src > 1000 then
            local chunk, err = loadstring(src)
            if chunk then
                local run_ok, windui = pcall(chunk)
                if run_ok and type(windui) == "table" and type(windui.CreateWindow) == "function" then
                    return windui
                end
            end
        end
    end
    return nil
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

local function ensure_dir(path)
    if typeof(makefolder) == "function" then
        pcall(makefolder, path)
    end
    return true
end

function UI.new(complete_inst)
    local self = setmetatable({}, UI)
    self.complete = complete_inst
    self.main = complete_inst and complete_inst.main or nil
    self.window = nil
    self.windui = nil
    self.config_path = "Cobalt/config.json"
    self.config = {}
    self.visible = false
    self.stats_labels = {}
    return self
end

function UI:load_config()
    ensure_dir("Cobalt")
    local ok, content = read_file(self.config_path)
    if ok then
        local dec_ok, decoded = safe_decode(content)
        if dec_ok and type(decoded) == "table" then
            self.config = decoded
            return true
        end
    end
    self.config = {
        mode = "full",
        redaction_on = true,
        redaction_regex = "^(token|apikey|api_key|secret|password|passwd|auth|authorization|signature|sig|credential|cookie|jwt|bearer)$",
        redaction_min_sha_len = 16,
        storage_threshold_bytes = 209715200,
        rotation_limit_bytes = 6291456,
        mem_spool_bytes = 8388608,
        rare_threshold = 5,
        pair_window_ms_min = 500,
        pair_window_ms_max = 3000,
        pair_window_unreliable_ms = 200,
        action_gap_ms = 100,
        dedup_window_ms = 2000,
        invoke_timeout_ms = 10000,
        queue_cap = 5000,
        actor_channel_cap = 500,
        pending_cap = 5000,
        max_nodes = 15000,
        diff_enabled = false,
        legacy_filelog = false,
    }
    return false
end

function UI:save_config()
    local enc_ok, enc = pcall(function() return HttpService:JSONEncode(self.config) end)
    if not enc_ok then return false, enc end
    return write_file(self.config_path, enc)
end

function UI:probe_status()
    local ok, content = read_file("Cobalt/probe.json")
    if not ok then return nil end
    local dec_ok, decoded = safe_decode(content)
    if not dec_ok then return nil end
    return decoded
end

function UI:start()
    self:load_config()

    local windui = _G.CobaltFork_WindUI or fetch_windui()
    if not windui then
        return false, "windui_nao_disponivel"
    end
    self.windui = windui

    local ok, window = pcall(function()
        return windui:CreateWindow({
            Title = "Cobalt Fork v2.4 - Recorder",
            Folder = "Cobalt",
            Icon = "solar:folder-2-bold-duotone",
            HideSearchBar = true,
            OpenButton = {
                Title = "Open Recorder",
                Enabled = true,
                Draggable = true,
                OnlyMobile = false,
            },
            Topbar = {
                Height = 44,
                ButtonsType = "Mac",
            },
        })
    end)
    if not ok or not window then
        return false, "janela: " .. tostring(window)
    end
    self.window = window

    local ok2, tab = pcall(function()
        return window:Tab({
            Title = "Recorder",
            Icon = "solar:record-circle-bold",
            Border = true,
        })
    end)
    if not ok2 or not tab then
        return false, "tab: " .. tostring(tab)
    end
    self.recorder_tab = tab

    self:build_recorder_tab()

    self.visible = true
    return true, self
end

function UI:build_recorder_tab()
    local tab = self.recorder_tab
    local main = self.main
    local cfg = self.config

    -- no WindUI, elementos ficam dentro de Section, nao direto no Tab
    local function add_section(name)
        local ok, section = pcall(function() return tab:Section({ Title = name }) end)
        if not ok then return nil end
        return section
    end

    local function add_toggle(section, label, key, default)
        local ok, toggle = pcall(function()
            return section:Toggle({
                Title = label,
                Value = cfg[key] ~= nil and cfg[key] or default,
                Callback = function(v)
                    cfg[key] = v == true
                    UI:save_config()
                end,
            })
        end)
        return ok and toggle or nil
    end

    local function add_input(section, label, key, placeholder, default)
        local ok, input = pcall(function()
            return section:Input({
                Title = label,
                Placeholder = placeholder or "",
                Value = tostring(cfg[key] ~= nil and cfg[key] or default),
                Callback = function(v)
                    cfg[key] = v
                    UI:save_config()
                end,
            })
        end)
        return ok and input or nil
    end

    local function add_dropdown(section, label, key, options, default)
        local ok, dropdown = pcall(function()
            return section:Dropdown({
                Title = label,
                Values = options,
                Value = cfg[key] ~= nil and cfg[key] or options[1],
                Callback = function(v)
                    cfg[key] = v
                    UI:save_config()
                end,
            })
        end)
        return ok and dropdown or nil
    end

    local function add_button(section, label, callback)
        local ok, btn = pcall(function()
            return section:Button({
                Title = label,
                Callback = callback,
            })
        end)
        return ok and btn or nil
    end

    local function add_stat(key)
        local ok, par = pcall(function()
            return tab:Paragraph({
                Title = key .. ":",
                Desc = "0",
                Justify = "Center",
                ImageSize = 0,
            })
        end)
        if ok then
            self.stats_labels[key] = par
        end
        return par
    end

    local sec_mode = add_section("Mode")
    if sec_mode then
        add_dropdown(sec_mode, "Mode", "mode", { "full", "lite", "dry" }, cfg.mode or "full")
    end

    local sec_red = add_section("Redacao")
    if sec_red then
        add_toggle(sec_red, "Redacao ativa", "redaction_on", true)
        add_input(sec_red, "Regex de redacao", "redaction_regex", "^(token|apikey|...)", cfg.redaction_regex)
        add_input(sec_red, "Min sha length", "redaction_min_sha_len", "16", tostring(cfg.redaction_min_sha_len or 16))
    end

    local sec_st = add_section("Storage")
    if sec_st then
        add_input(sec_st, "Storage threshold (MB)", "storage_threshold_bytes", "200", tostring(math.floor((cfg.storage_threshold_bytes or 209715200) / 1024 / 1024)))
        add_input(sec_st, "Rotation limit (MB)", "rotation_limit_bytes", "6", tostring(math.floor((cfg.rotation_limit_bytes or 6291456) / 1024 / 1024)))
        add_input(sec_st, "Mem spool (MB)", "mem_spool_bytes", "8", tostring(math.floor((cfg.mem_spool_bytes or 8388608) / 1024 / 1024)))
    end

    local sec_pair = add_section("Pair & Action")
    if sec_pair then
        add_input(sec_pair, "Pair window min (ms)", "pair_window_ms_min", "500", tostring(cfg.pair_window_ms_min or 500))
        add_input(sec_pair, "Pair window max (ms)", "pair_window_ms_max", "3000", tostring(cfg.pair_window_ms_max or 3000))
        add_input(sec_pair, "Action gap (ms)", "action_gap_ms", "100", tostring(cfg.action_gap_ms or 100))
        add_input(sec_pair, "Rare threshold", "rare_threshold", "5", tostring(cfg.rare_threshold or 5))
        add_toggle(sec_pair, "Diff enabled", "diff_enabled", false)
    end

    local sec_ctrl = add_section("Controles")
    if sec_ctrl then
        add_button(sec_ctrl, "Pause", function()
            local rec = main and main.recorder
            if rec then rec:pause() end
        end)
        add_button(sec_ctrl, "Resume", function()
            local rec = main and main.recorder
            if rec then rec:resume() end
        end)
        add_button(sec_ctrl, "Minimizar", function()
            if self.window and self.window.SetToggleKey then
                -- minimizar/ocultar a janela
                pcall(function() self.window:SetVisible(false) end)
            end
        end)
        add_button(sec_ctrl, "Clean orphans", function()
            print("[UI] Clean orphans solicitado (execucao manual pendente - sem auto-delete por design)")
        end)
    end

    local sec_probe = add_section("Probe status")
    if sec_probe then
        local probe = self:probe_status()
        if probe then
            add_stat("executor")
            self.stats_labels.executor:Desc(tostring(probe.executor or "?"))
            add_stat("versao")
            self.stats_labels.versao:Desc(tostring(probe.executor_version or "?"))
            if probe.results then
                for nome, res in pairs(probe.results) do
                    local status = "?"
                    if res.ok == false then status = "FALHOU"
                    elseif res.exists == false then status = "INDISPONIVEL"
                    elseif res.available == false then status = "INDISPONIVEL"
                    else status = "OK" end
                    add_stat(nome)
                    self.stats_labels[nome]:Desc(status)
                end
            end
            if probe.recommended_config then
                add_stat("bytecode_hash")
                self.stats_labels.bytecode_hash:Desc(tostring(probe.recommended_config.bytecode_hash or "?"))
            end
        else
            add_stat("probe")
            self.stats_labels.probe:Desc("probe.json nao encontrado")
        end
    end

    local sec_stats = add_section("Stats ao vivo")
    if sec_stats then
        add_stat("calls_raw")
        add_stat("records_written")
        add_stat("dropped")
        add_stat("flush_errors")
        add_stat("encode_errors")
        add_stat("paused")
    end
end

function UI:update_stats()
    if not self.main or not self.main.recorder then return end
    local rec = self.main.recorder
    local st = rec:stats()
    for key, lbl in pairs(self.stats_labels or {}) do
        local val = st[key]
        if val == nil then val = 0 end
        if key == "paused" then
            val = rec:is_paused() and 1 or 0
        end
        if lbl and lbl.Desc then
            pcall(function() lbl:Desc(tostring(val)) end)
        end
    end
end

function UI:apply_config()
    if not self.main then return end
    local rec = self.main.recorder
    if rec then
        rec.config.rotation_limit_bytes = self.config.rotation_limit_bytes or rec.config.rotation_limit_bytes
        rec.config.flush_batch = self.config.flush_batch or rec.config.flush_batch
        rec.config.storage_threshold_bytes = self.config.storage_threshold_bytes or rec.config.storage_threshold_bytes
        rec.config.mem_spool_bytes = self.config.mem_spool_bytes or rec.config.mem_spool_bytes
        rec.config.retry_delays_ms = self.config.retry_delays_ms or { 100, 500, 2000 }
    end
end

function UI:start_session()
    if not self.complete then return false, "sem_complete" end
    self:apply_config()
    local ok, res = self.complete:start()
    if not ok then return false, tostring(res) end
    return true, res
end

function UI:close_session(reason)
    if not self.complete then return false, "sem_complete" end
    reason = reason or "manual"
    local ok, end_rec = self.complete:close(reason)
    if not ok then return false, tostring(end_rec) end
    return true, end_rec
end

function UI:destroy()
    if self.window then
        pcall(function() self.window:Destroy() end)
    end
    self.visible = false
end

return UI
