--[[
    Cobalt Fork v2.4 — Scanner (Fase 3)
    Snapshot inicial da árvore (§6.5) com snapshot_start_ts/end_ts, deltas com seq
    (§6.6), filtro de inclusão. Sem rescan. Orçamento 4 ms/frame via task.spawn.
    Conteúdo-addressado: scripts/<sha> e fn_info/<sha> em shared/.
]]

local Scanner = {}
Scanner.__index = Scanner

local HttpService = game:GetService("HttpService")

local WHITELIST_PROPS = {
    Humanoid = { "Health", "WalkSpeed", "JumpPower" },
    BasePart = { "Position", "CFrame", "Anchored", "CanCollide" },
    Model = { "PrimaryPart" },
    ValueBase = { "Value" },
    GuiObject = { "Text", "Size", "Position", "Visible" },
    Player = { "Team", "Character" },
    Camera = { "FieldOfView" },
}

local STANDARD_PART_NAMES = { Part = true, MeshPart = true, WedgePart = true }

local function safe_encode(value)
    local ok, res = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return true, res end
    return false, tostring(res)
end

local function shallow_copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

-- ============================================================
-- new
-- ============================================================

function Scanner.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Scanner)
    self.session_dir = opts.session_dir or "Cobalt/session"
    self.max_nodes = opts.max_nodes or 15000
    self.tree_seq = 0
    self.snapshot_start_ts = nil
    self.snapshot_end_ts = nil
    self.nodes = {}       -- path -> nó
    self.tree_lines = {}  -- linhas NDJSON do snapshot
    self.delta_lines = {} -- linhas NDJSON de delta
    self.truncated = false
    self.by_rule = {}
    return self
end

-- ============================================================
-- filtros de inclusão (§6.5)
-- ============================================================

local function get_children(inst)
    local ok, children = pcall(function() return inst:GetChildren() end)
    if ok and type(children) == "table" then return children end
    return {}
end

local function get_attrs(inst)
    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if ok and type(attrs) == "table" then return attrs end
    return {}
end

local function get_tags(inst)
    local ok, tags = pcall(function() return inst:GetTags() end)
    if ok and type(tags) == "table" then return tags end
    return {}
end

local function get_parent(inst)
    local ok, p = pcall(function() return inst.Parent end)
    if ok then return p end
    return nil
end

local function get_name(inst)
    local ok, n = pcall(function() return inst.Name end)
    if ok then return n end
    return ""
end

local function get_class(inst)
    local ok, c = pcall(function() return inst.ClassName end)
    if ok then return c end
    return "unknown"
end

local function depth_of(inst)
    local d = 0
    local cur = inst
    while cur do
        local p = get_parent(cur)
        if not p then break end
        d = d + 1
        cur = p
    end
    return d
end

local function rule_for(class, parent, depth, attrs, tags, children_classes)
    -- 1. classe de remote → sempre
    if class == "RemoteEvent" or class == "RemoteFunction" then return 1 end
    -- 2. #attrs > 0 → sempre
    local na = 0
    for _ in pairs(attrs) do na = na + 1 end
    if na > 0 then return 2 end
    -- 3. #tags > 0 → sempre
    if #tags > 0 then return 3 end
    -- 4. Humanoid ou Model com filho Humanoid → entidade
    if class == "Humanoid" then return 4 end
    if class == "Model" then
        for _, ch in ipairs(children_classes or {}) do
            if ch == "Humanoid" then return 4 end
        end
    end
    -- 5. sob Workspace depth ≤ 4 → Model/Folder/Humanoid/BasePart nome não-padrão
    if depth <= 4 then
        if class == "Model" or class == "Folder" or class == "Humanoid" then return 5 end
        if class == "BasePart" and not STANDARD_PART_NAMES[get_name_from_class(class)] then return 5 end
    end
    -- 6. sob PlayerGui → GUI
    if parent and get_class(parent) == "PlayerGui" then return 6 end
    -- 7. ValueBase com nome significativo → estado
    if class:match("Value$") then return 7 end
    -- 8. Script/LocalScript/ModuleScript → nó mínimo
    if class == "Script" or class == "LocalScript" or class == "ModuleScript" then return 8 end
    -- 9. BasePart sob Model já incluído, ou nome não-padrão
    if class == "BasePart" then return 9 end
    return nil
end

local function get_name_from_class(class)
    -- placeholder; o nome real vem da instância
    return class
end

-- ============================================================
-- nó de uma instância
-- ============================================================

local function build_node(inst, parent_path, depth)
    local class = get_class(inst)
    local name = get_name(inst)
    local path = parent_path and (parent_path .. "." .. name) or name
    local children = get_children(inst)
    local child_classes = {}
    for _, ch in ipairs(children) do child_classes[#child_classes + 1] = get_class(ch) end
    local attrs = get_attrs(inst)
    local tags = get_tags(inst)

    local rule = rule_for(class, get_parent(inst), depth, attrs, tags, child_classes)
    if not rule then return nil end

    local node = {
        path = path,
        parent = parent_path,
        class = class,
        name = name,
        depth = depth,
        rule = rule,
        attrs = next(attrs) and attrs or nil,
        tags = #tags > 0 and tags or nil,
        sha = nil,
    }
    -- scripts: sha no inventário, nó mínimo
    if rule == 8 then
        local ok, src = pcall(function() return inst.Source end)
        if ok and type(src) == "string" then
            node.sha = Enrich and Enrich.hash64(src) or nil
        end
    end
    return node
end

-- ============================================================
-- snapshot (scan completo, orçamento 4 ms/frame)
-- ============================================================

function Scanner:snapshot()
    self.snapshot_start_ts = os.time()
    self.nodes = {}
    self.tree_lines = {}
    local count = 0
    local truncated = false

    local frame_budget_ms = 4
    local frame_start = os.clock()

    local function visit(inst, parent_path, depth)
        if truncated then return end
        count = count + 1
        if count > self.max_nodes then
            truncated = true
            return
        end
        local node = build_node(inst, parent_path, depth)
        if node then
            self.nodes[node.path] = node
            self.by_rule[node.rule] = (self.by_rule[node.rule] or 0) + 1
            local line_ok, line = safe_encode(node)
            if line_ok then self.tree_lines[#self.tree_lines + 1] = line end
        end
        -- orçamento: a cada 100 nós, cede o frame
        if count % 100 == 0 then
            local elapsed = (os.clock() - frame_start) * 1000
            if elapsed > frame_budget_ms then
                task.wait()
                frame_start = os.clock()
            end
        end
        for _, ch in ipairs(get_children(inst)) do
            visit(ch, node and node.path or parent_path, depth + 1)
            if truncated then return end
        end
    end

    pcall(function()
        for _, s in ipairs(game:GetDescendants()) do
            visit(s, nil, depth_of(s))
            if truncated then break end
        end
    end)

    self.snapshot_end_ts = os.time()
    self.truncated = truncated
    return {
        ok = true,
        nodes = #self.nodes,
        truncated = truncated,
        by_rule = shallow_copy(self.by_rule),
        snapshot_start_ts = self.snapshot_start_ts,
        snapshot_end_ts = self.snapshot_end_ts,
    }
end

-- ============================================================
-- delta (op batched por janela, seq monotônico)
-- ============================================================

function Scanner:delta(op, reason, payload)
    self.tree_seq = self.tree_seq + 1
    local entry = {
        op = op,
        reason = reason,
        seq = self.tree_seq,
        ts = os.time(),
    }
    for k, v in pairs(payload) do entry[k] = v end
    local ok, line = safe_encode(entry)
    if ok then self.delta_lines[#self.delta_lines + 1] = line end
    return self.tree_seq, entry
end

function Scanner:change(path, patch)
    return self:delta("change", "prop_change", { path = path, patch = patch })
end

function Scanner:add_many(nodes, reason)
    local np = {}
    for _, n in ipairs(nodes) do np[#np + 1] = n end
    return self:delta("add_many", reason or "child_added", { nodes = np })
end

function Scanner:remove_many(paths)
    return self:delta("remove_many", "child_removed", { paths = paths })
end

function Scanner:tags(path, add, del)
    return self:delta("tags", "tags", { path = path, add = add, del = del })
end

-- ============================================================
-- grava tree.ndjson e tree_delta.ndjson com header
-- ============================================================

function Scanner:write_tree_file(session)
    local header = {
        _h = 1, schema = { major = 2, minor = 4 }, file = "tree",
        session = session, mode = "full",
        redaction = { on = true, regex_version = "v1" },
        ts_header = os.time(),
        snapshot_start_ts = self.snapshot_start_ts,
        snapshot_end_ts = self.snapshot_end_ts,
    }
    local lines = {}
    local ok, hline = safe_encode(header)
    if ok then lines[1] = hline end
    for _, l in ipairs(self.tree_lines) do lines[#lines + 1] = l end
    return table.concat(lines, "\n") .. "\n", self.truncated
end

function Scanner:write_delta_file(session)
    local header = {
        _h = 1, schema = { major = 2, minor = 4 }, file = "tree_delta",
        session = session, mode = "full",
        redaction = { on = true, regex_version = "v1" },
        ts_header = os.time(),
    }
    local lines = {}
    local ok, hline = safe_encode(header)
    if ok then lines[1] = hline end
    for _, l in ipairs(self.delta_lines) do lines[#lines + 1] = l end
    return table.concat(lines, "\n") .. "\n"
end

function Scanner:tree_stats()
    return {
        scanned = 0, -- preenchido pelo caller
        included = #self.nodes,
        truncated = self.truncated,
        by_rule = shallow_copy(self.by_rule),
    }
end

return Scanner
