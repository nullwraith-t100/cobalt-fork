--[[
    Cobalt Fork v2.4 — SimpleUI (Fase 9 / §14 DESIGN.md)
    UI própria em Luau puro, sem dependência externa (Wind UI indisponível no Delta).
    Aba Recorder: mode, redação, storage, pair/action, controles, probe status, stats ao vivo.
    Sem hotkey, sem "open folder" (Android).
]]

local UI = {}
UI.__index = UI

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

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

-- ============================================================
-- helpers de instância
-- ============================================================

local function create(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        local ok = pcall(function() inst[k] = v end)
        if not ok then
            -- tenta setAttribute como fallback
            pcall(function() inst:SetAttribute(k, v) end)
        end
    end
    if parent then inst.Parent = parent end
    return inst
end

local function new_toggle(parent, label, default, callback)
    local frame = create("Frame", {
        Size = UDim2.new(1, -16, 0, 28),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    local btn = create("TextButton", {
        Size = UDim2.new(0, 24, 0, 24),
        Position = UDim2.new(0, 0, 0, 2),
        BackgroundColor3 = default and Color3.fromRGB(0, 170, 255) or Color3.fromRGB(60, 60, 60),
        Text = default and "✓" or "",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 18,
        Parent = frame,
    })
    create("TextLabel", {
        Size = UDim2.new(1, -32, 1, 0),
        Position = UDim2.new(0, 32, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 16,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local state = default == true
    btn.MouseButton1Click:Connect(function()
        state = not state
        btn.BackgroundColor3 = state and Color3.fromRGB(0, 170, 255) or Color3.fromRGB(60, 60, 60)
        btn.Text = state and "✓" or ""
        pcall(callback, state)
    end)
    return { set = function(v) state = v == true; btn.BackgroundColor3 = state and Color3.fromRGB(0, 170, 255) or Color3.fromRGB(60, 60, 60); btn.Text = state and "✓" or "" end, get = function() return state end }
end

local function new_input(parent, label, placeholder, default, callback)
    create("TextLabel", {
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = parent,
    })
    local box = create("TextBox", {
        Size = UDim2.new(1, -16, 0, 24),
        Position = UDim2.new(0, 0, 0, 18),
        BackgroundColor3 = Color3.fromRGB(40, 40, 40),
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        PlaceholderText = placeholder or "",
        Text = tostring(default or ""),
        Parent = parent,
    })
    box.FocusLost:Connect(function(entered)
        if entered then pcall(callback, box.Text) end
    end)
    return { set = function(v) box.Text = tostring(v) end, get = function() return box.Text end }
end

local function new_dropdown(parent, label, options, default, callback)
    create("TextLabel", {
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = parent,
    })
    local btn = create("TextButton", {
        Size = UDim2.new(1, -16, 0, 24),
        Position = UDim2.new(0, 0, 0, 18),
        BackgroundColor3 = Color3.fromRGB(60, 60, 60),
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        Text = tostring(default or options[1]),
        Parent = parent,
    })
    local current = default or options[1]
    btn.MouseButton1Click:Connect(function()
        -- ciclo pelas opções
        local idx = 1
        for i, o in ipairs(options) do if o == current then idx = i break end end
        local next_idx = idx % #options + 1
        current = options[next_idx]
        btn.Text = tostring(current)
        pcall(callback, current)
    end)
    return { set = function(v) current = v; btn.Text = tostring(v) end, get = function() return current end }
end

local function new_button(parent, label, callback)
    local btn = create("TextButton", {
        Size = UDim2.new(1, -16, 0, 30),
        BackgroundColor3 = Color3.fromRGB(80, 80, 80),
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 16,
        Text = label,
        Parent = parent,
    })
    btn.MouseButton1Click:Connect(function() pcall(callback) end)
    return btn
end

local function new_paragraph(parent, title, content)
    local frame = create("Frame", {
        Size = UDim2.new(1, -16, 0, 24),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    create("TextLabel", {
        Size = UDim2.new(0.5, -8, 1, 0),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = title .. ":",
        TextColor3 = Color3.fromRGB(200, 200, 200),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    local val = create("TextLabel", {
        Size = UDim2.new(0.5, -8, 1, 0),
        Position = UDim2.new(0.5, 0, 0, 0),
        BackgroundTransparency = 1,
        Text = tostring(content),
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
    return { set = function(v) val.Text = tostring(v) end }
end

local function new_section(parent, name)
    create("TextLabel", {
        Size = UDim2.new(1, -16, 0, 20),
        Position = UDim2.new(0, 0, 0, 6),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = Color3.fromRGB(150, 200, 255),
        TextSize = 16,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = parent,
    })
    local container = create("Frame", {
        Size = UDim2.new(1, -16, 0, 0),
        Position = UDim2.new(0, 0, 0, 26),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    local layout = create("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = container,
    })
    -- ajusta altura do container com base nos filhos
    local function relayout()
        local h = 6
        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("GuiObject") then
                h = h + child.Size.Y.Offset + 4
            end
        end
        container.Size = UDim2.new(1, -16, 0, h)
    end
    container.ChildAdded:Connect(relayout)
    container.ChildRemoved:Connect(relayout)
    relayout()
    return container, relayout
end

-- ============================================================
-- new
-- ============================================================

function UI.new(complete_inst)
    local self = setmetatable({}, UI)
    self.complete = complete_inst
    self.main = complete_inst and complete_inst.main or nil
    self.screen = nil
    self.window = nil
    self.scroll = nil
    self.content = nil
    self.config_path = "Cobalt/config.json"
    self.config = {}
    self.visible = false
    self.stats_labels = {}
    self.y_offset = 0
    return self
end

-- ============================================================
-- config
-- ============================================================

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

-- ============================================================
-- probe status
-- ============================================================

function UI:probe_status()
    local ok, content = read_file("Cobalt/probe.json")
    if not ok then return nil end
    local dec_ok, decoded = safe_decode(content)
    if not dec_ok then return nil end
    return decoded
end

-- ============================================================
-- start: cria a janela
-- ============================================================

function UI:start()
    self:load_config()

    -- screen gui
    local lp = Players.LocalPlayer
    local gui_parent = lp and lp:FindFirstChild("PlayerGui") or game:GetService("CoreGui")
    self.screen = create("ScreenGui", {
        Name = "CobaltForkUI",
        ResetOnSpawn = false,
        Parent = gui_parent,
    })

    -- janela principal
    self.window = create("Frame", {
        Size = UDim2.new(0, 520, 0, 560),
        Position = UDim2.new(0.5, -260, 0.5, -280),
        BackgroundColor3 = Color3.fromRGB(25, 25, 30),
        BorderSizePixel = 0,
        Parent = self.screen,
    })
    create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = self.window })

    -- barra de título
    create("TextLabel", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundColor3 = Color3.fromRGB(40, 40, 50),
        Text = "Cobalt Fork v2.4 — Recorder",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 18,
        Font = Enum.Font.GothamBold,
        Parent = self.window,
    })

    -- scroll principal
    self.scroll = create("ScrollingFrame", {
        Size = UDim2.new(1, -16, 1, -44),
        Position = UDim2.new(0, 8, 0, 40),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 6,
        Parent = self.window,
    })
    create("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = self.scroll,
    })

    self.content = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        BackgroundTransparency = 1,
        Parent = self.scroll,
    })
    create("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = self.content,
    })

    self:build_recorder_tab()

    self.visible = true
    return true, self
end

-- ============================================================
-- build_recorder_tab
-- ============================================================

function UI:build_recorder_tab()
    local main = self.main
    local cfg = self.config

    local function add_section(name)
        return new_section(self.content, name)
    end

    local function add_toggle(section, label, key, default)
        local t = new_toggle(section, label, cfg[key] ~= nil and cfg[key] or default, function(v)
            cfg[key] = v == true
            UI:save_config()
        end)
        return t
    end

    local function add_input(section, label, key, placeholder, default, input_type)
        local t = new_input(section, label, placeholder or "", cfg[key] ~= nil and cfg[key] or default, function(v)
            if input_type == "number" then
                cfg[key] = tonumber(v)
            else
                cfg[key] = v
            end
            UI:save_config()
        end)
        return t
    end

    local function add_dropdown(section, label, key, options, default)
        local t = new_dropdown(section, label, options, cfg[key] ~= nil and cfg[key] or default, function(v)
            cfg[key] = v
            UI:save_config()
        end)
        return t
    end

    local function add_button(section, label, callback)
        return new_button(section, label, callback)
    end

    local function add_stat(key)
        local cont = create("Frame", {
            Size = UDim2.new(1, -16, 0, 20),
            BackgroundTransparency = 1,
            Parent = self.content,
        })
        create("TextLabel", {
            Size = UDim2.new(0.5, -8, 1, 0),
            BackgroundTransparency = 1,
            Text = key .. ":",
            TextColor3 = Color3.fromRGB(200, 200, 200),
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = cont,
        })
        local val = create("TextLabel", {
            Size = UDim2.new(0.5, -8, 1, 0),
            Position = UDim2.new(0.5, 0, 0, 0),
            BackgroundTransparency = 1,
            Text = "0",
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = cont,
        })
        self.stats_labels[key] = val
    end

    -- ============================================================
    -- Seções
    -- ============================================================

    local sec_mode = add_section("Mode")
    add_dropdown(sec_mode, "Mode", "mode", { "full", "lite", "dry" }, cfg.mode or "full")

    local sec_red = add_section("Redaction")
    add_toggle(sec_red, "Redação ativa", "redaction_on", true)
    add_input(sec_red, "Regex de redação", "redaction_regex", "^(token|apikey|...)", cfg.redaction_regex)
    add_input(sec_red, "Min sha length", "redaction_min_sha_len", "16", tostring(cfg.redaction_min_sha_len or 16), "number")

    local sec_st = add_section("Storage")
    add_input(sec_st, "Storage threshold (MB)", "storage_threshold_bytes", "200", tostring(math.floor((cfg.storage_threshold_bytes or 209715200) / 1024 / 1024)), "number")
    add_input(sec_st, "Rotation limit (MB)", "rotation_limit_bytes", "6", tostring(math.floor((cfg.rotation_limit_bytes or 6291456) / 1024 / 1024)), "number")
    add_input(sec_st, "Mem spool (MB)", "mem_spool_bytes", "8", tostring(math.floor((cfg.mem_spool_bytes or 8388608) / 1024 / 1024)), "number")

    local sec_pair = add_section("Pair & Action")
    add_input(sec_pair, "Pair window min (ms)", "pair_window_ms_min", "500", tostring(cfg.pair_window_ms_min or 500), "number")
    add_input(sec_pair, "Pair window max (ms)", "pair_window_ms_max", "3000", tostring(cfg.pair_window_ms_max or 3000), "number")
    add_input(sec_pair, "Action gap (ms)", "action_gap_ms", "100", tostring(cfg.action_gap_ms or 100), "number")
    add_input(sec_pair, "Rare threshold", "rare_threshold", "5", tostring(cfg.rare_threshold or 5), "number")
    add_toggle(sec_pair, "Diff enabled", "diff_enabled", false)

    local sec_ctrl = add_section("Controles")
    add_button(sec_ctrl, "Pause", function()
        local rec = main and main.recorder
        if rec then rec:pause() end
    end)
    add_button(sec_ctrl, "Resume", function()
        local rec = main and main.recorder
        if rec then rec:resume() end
    end)
    add_button(sec_ctrl, "Clean orphans", function()
        print("[UI] Clean orphans solicitado (execução manual pendente — sem auto-delete por design)")
    end)

    local sec_probe = add_section("Probe status")
    local probe = self:probe_status()
    if probe then
        add_stat("executor"); self.stats_labels.executor:set(tostring(probe.executor or "?"))
        add_stat("versão"); self.stats_labels.versão:set(tostring(probe.executor_version or "?"))
        if probe.results then
            for nome, res in pairs(probe.results) do
                local status = "?"
                if res.ok == false then status = "FALHOU"
                elseif res.exists == false then status = "INDISPONÍVEL"
                elseif res.available == false then status = "INDISPONÍVEL"
                else status = "OK" end
                add_stat(nome); self.stats_labels[nome]:set(status)
            end
        end
        if probe.recommended_config then
            add_stat("bytecode_hash"); self.stats_labels.bytecode_hash:set(tostring(probe.recommended_config.bytecode_hash or "?"))
        end
    else
        add_stat("probe"); self.stats_labels.probe:set("probe.json não encontrado")
    end

    local sec_stats = add_section("Stats ao vivo")
    add_stat("calls_raw")
    add_stat("records_written")
    add_stat("dropped")
    add_stat("flush_errors")
    add_stat("encode_errors")
    add_stat("paused")
end

-- ============================================================
-- update_stats
-- ============================================================

function UI:update_stats()
    if not self.main or not self.main.recorder then return end
    local rec = self.main.recorder
    local st = rec:stats()
    for key, lbl in pairs(self.stats_labels or {}) do
        local val = st[key]
        if val == nil then val = "0" end
        if key == "paused" then
            val = tostring(rec:is_paused())
        end
        pcall(function() lbl:set(val) end)
    end
end

-- ============================================================
-- apply_config
-- ============================================================

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

-- ============================================================
-- start_session / close_session
-- ============================================================

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

-- ============================================================
-- destroy
-- ============================================================

function UI:destroy()
    if self.screen then
        pcall(function() self.screen:Destroy() end)
    end
    self.visible = false
end

return UI
