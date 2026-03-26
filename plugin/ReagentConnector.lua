--[[
    reagent connector v1.0
    cloud ai bridge for roblox studio

    syncs scripts, structures, and mcp commands
    between studio and the reagent cloud ai server

    ui: catppuccin mocha / purple accent
]]

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local LogService = game:GetService("LogService")
local Selection = game:GetService("Selection")

-- config
local SERVER_URL = "http://localhost:34873"
local POLL_INTERVAL = 0.5
local VERSION = "1.0.0"
local REQUEST_TIMEOUT = 30

local SYNC_SERVICES = {
    "Workspace", "ServerScriptService", "ReplicatedStorage", "ReplicatedFirst",
    "StarterGui", "StarterPack", "StarterPlayer", "ServerStorage",
    "Lighting", "SoundService"
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

-- state
local connected = false
local syncing = false
local autoSync = true
local scriptsOnlyMode = false
local lastPoll = 0
local statsText = ""
local currentProjectName = nil

-- project memory (PlaceId -> ProjectName)
local projectMemory = {}
local MEMORY_KEY = "Reagent_ProjectMemory"

local function loadProjectMemory()
    local success, data = pcall(function()
        return plugin:GetSetting(MEMORY_KEY)
    end)
    if success and data and type(data) == "table" then
        projectMemory = data
    end
end

local function saveProjectMemory()
    pcall(function()
        plugin:SetSetting(MEMORY_KEY, projectMemory)
    end)
end

-- ============ MCP LOG CAPTURE ============

local logBuffer = {}
local MAX_LOG_BUFFER = 100
local lastLogFlush = 0
local LOG_FLUSH_INTERVAL = 2

local function captureLog(message, messageType)
    local logType = "info"
    if messageType == Enum.MessageType.MessageError then
        logType = "error"
    elseif messageType == Enum.MessageType.MessageWarning then
        logType = "warning"
    end

    table.insert(logBuffer, {
        message = message,
        type = logType,
        timestamp = os.time() * 1000
    })

    while #logBuffer > MAX_LOG_BUFFER do
        table.remove(logBuffer, 1)
    end
end

LogService.MessageOut:Connect(function(message, messageType)
    captureLog(message, messageType)
end)

local function flushLogs()
    if not connected or not currentProjectName or #logBuffer == 0 then
        return
    end

    local now = tick()
    if now - lastLogFlush < LOG_FLUSH_INTERVAL then
        return
    end
    lastLogFlush = now

    local logsToSend = logBuffer
    logBuffer = {}

    task.spawn(function()
        pcall(function()
            HttpService:RequestAsync({
                Url = SERVER_URL .. "/mcp/logs",
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode({
                    project = currentProjectName,
                    logs = logsToSend
                }),
                Timeout = 5
            })
        end)
    end)
end

-- ============ MCP COMMAND HANDLING ============

local function resolveInstancePath(pathStr)
    local parts = string.split(pathStr, ".")
    local current = game

    for _, part in ipairs(parts) do
        if current then
            current = current:FindFirstChild(part)
        else
            return nil
        end
    end

    return current
end

local function getInstancePath(instance)
    local path = {}
    local current = instance
    while current and current ~= game do
        table.insert(path, 1, current.Name)
        current = current.Parent
    end
    return table.concat(path, ".")
end

local function serializeValue(value)
    local t = typeof(value)
    if t == "Vector3" then
        return { X = value.X, Y = value.Y, Z = value.Z }
    elseif t == "Color3" then
        return { R = value.R, G = value.G, B = value.B }
    elseif t == "CFrame" then
        return { Position = serializeValue(value.Position) }
    elseif t == "UDim2" then
        return {
            X = { Scale = value.X.Scale, Offset = value.X.Offset },
            Y = { Scale = value.Y.Scale, Offset = value.Y.Offset }
        }
    elseif t == "BrickColor" then
        return value.Name
    elseif t == "EnumItem" then
        return tostring(value)
    elseif t == "Instance" then
        return getInstancePath(value)
    elseif t == "string" or t == "number" or t == "boolean" then
        return value
    else
        return tostring(value)
    end
end

local function deserializeValue(value, targetType)
    if targetType == "Vector3" and type(value) == "table" then
        return Vector3.new(value.X or 0, value.Y or 0, value.Z or 0)
    elseif targetType == "Color3" and type(value) == "table" then
        return Color3.new(value.R or 0, value.G or 0, value.B or 0)
    elseif targetType == "UDim2" and type(value) == "table" then
        return UDim2.new(
            value.X and value.X.Scale or 0, value.X and value.X.Offset or 0,
            value.Y and value.Y.Scale or 0, value.Y and value.Y.Offset or 0
        )
    end
    return value
end

local function executeMcpCommand(cmd)
    local cmdType = cmd.type
    local params = cmd.params or {}

    if cmdType == "get-instance" then
        local instance = resolveInstancePath(params.path)
        if not instance then
            return { error = "Instance not found: " .. params.path }
        end

        local props = {}
        pcall(function()
            props.Name = instance.Name
            props.ClassName = instance.ClassName
            props.Parent = instance.Parent and getInstancePath(instance.Parent) or nil

            for _, prop in ipairs({"Position", "Size", "CFrame", "Color", "BrickColor", "Transparency", "Anchored", "CanCollide", "Material"}) do
                pcall(function()
                    props[prop] = serializeValue(instance[prop])
                end)
            end
        end)

        return { instance = props, path = params.path }

    elseif cmdType == "get-children" then
        local instance = resolveInstancePath(params.path)
        if not instance then
            return { error = "Instance not found: " .. params.path }
        end

        local children = {}
        for _, child in ipairs(instance:GetChildren()) do
            table.insert(children, {
                name = child.Name,
                className = child.ClassName,
                path = getInstancePath(child)
            })
        end

        return { children = children, count = #children }

    elseif cmdType == "find-instances" then
        local root = params.root and resolveInstancePath(params.root) or game
        if not root then
            return { error = "Root not found: " .. tostring(params.root) }
        end

        local results = {}
        local function search(instance)
            local match = true

            if params.className and instance.ClassName ~= params.className then
                match = false
            end
            if params.name and instance.Name ~= params.name then
                match = false
            end
            if params.property and params.value then
                local ok, val = pcall(function() return instance[params.property] end)
                if not ok or tostring(val) ~= params.value then
                    match = false
                end
            end

            if match and instance ~= root then
                table.insert(results, {
                    name = instance.Name,
                    className = instance.ClassName,
                    path = getInstancePath(instance)
                })
            end

            if #results < 100 then
                for _, child in ipairs(instance:GetChildren()) do
                    search(child)
                end
            end
        end

        search(root)
        return { results = results, count = #results }

    elseif cmdType == "run-lua" then
        local code = params.code
        if not code then
            return { error = "No code provided" }
        end

        local fn, loadErr = loadstring(code)
        if not fn then
            return { error = "Syntax error: " .. tostring(loadErr) }
        end

        local ok, result = pcall(fn)
        if not ok then
            return { error = "Runtime error: " .. tostring(result) }
        end

        return { result = serializeValue(result) }

    elseif cmdType == "get-selection" then
        local selected = Selection:Get()
        local items = {}
        for _, item in ipairs(selected) do
            table.insert(items, {
                name = item.Name,
                className = item.ClassName,
                path = getInstancePath(item)
            })
        end
        return { selection = items, count = #items }

    elseif cmdType == "create-instance" then
        local parent = resolveInstancePath(params.parent)
        if not parent then
            return { error = "Parent not found: " .. params.parent }
        end

        local ok, instance = pcall(function()
            local inst = Instance.new(params.className)
            if params.properties then
                for prop, value in pairs(params.properties) do
                    pcall(function()
                        local currentType = typeof(inst[prop])
                        inst[prop] = deserializeValue(value, currentType)
                    end)
                end
            end
            inst.Parent = parent
            return inst
        end)

        if not ok then
            return { error = "Failed to create: " .. tostring(instance) }
        end

        return { created = getInstancePath(instance), className = params.className }

    elseif cmdType == "modify-instance" then
        local instance = resolveInstancePath(params.path)
        if not instance then
            return { error = "Instance not found: " .. params.path }
        end

        local modified = {}
        for prop, value in pairs(params.properties or {}) do
            local ok, err = pcall(function()
                local currentType = typeof(instance[prop])
                instance[prop] = deserializeValue(value, currentType)
            end)
            if ok then
                table.insert(modified, prop)
            end
        end

        return { modified = modified, path = params.path }

    elseif cmdType == "delete-instance" then
        local instance = resolveInstancePath(params.path)
        if not instance then
            return { error = "Instance not found: " .. params.path }
        end

        local name = instance.Name
        instance:Destroy()
        return { deleted = name, path = params.path }

    elseif cmdType == "get-game-state" then
        local running = RunService:IsRunning()
        return {
            isRunning = running,
            isStudio = RunService:IsStudio(),
            isEdit = not running,
            isClient = RunService:IsClient(),
            isServer = RunService:IsServer()
        }

    elseif cmdType == "undo" then
        local ok, err = pcall(function() ChangeHistoryService:Undo() end)
        if ok then return { status = "undone" }
        else return { error = "Undo failed: " .. tostring(err) } end

    elseif cmdType == "redo" then
        local ok, err = pcall(function() ChangeHistoryService:Redo() end)
        if ok then return { status = "redone" }
        else return { error = "Redo failed: " .. tostring(err) } end

    elseif cmdType == "batch-create" then
        local results = {}
        for _, inst in ipairs(params.instances or {}) do
            local parent = resolveInstancePath(inst.parent)
            if not parent then
                table.insert(results, { error = "Parent not found: " .. tostring(inst.parent) })
            else
                local ok, created = pcall(function()
                    local obj = Instance.new(inst.className)
                    if inst.properties then
                        for prop, value in pairs(inst.properties) do
                            pcall(function()
                                obj[prop] = deserializeValue(value, typeof(obj[prop]))
                            end)
                        end
                    end
                    obj.Parent = parent
                    return obj
                end)
                if ok then
                    table.insert(results, { created = getInstancePath(created), className = inst.className })
                else
                    table.insert(results, { error = tostring(created) })
                end
            end
        end
        return { results = results, count = #results }

    elseif cmdType == "batch-modify" then
        local results = {}
        for _, mod in ipairs(params.modifications or {}) do
            local instance = resolveInstancePath(mod.path)
            if not instance then
                table.insert(results, { error = "Not found: " .. tostring(mod.path) })
            else
                local modified = {}
                for prop, value in pairs(mod.properties or {}) do
                    local ok = pcall(function()
                        instance[prop] = deserializeValue(value, typeof(instance[prop]))
                    end)
                    if ok then table.insert(modified, prop) end
                end
                table.insert(results, { modified = modified, path = mod.path })
            end
        end
        return { results = results, count = #results }

    elseif cmdType == "clone-instance" then
        local instance = resolveInstancePath(params.path)
        if not instance then return { error = "Instance not found: " .. params.path } end
        local ok, clone = pcall(function()
            local c = instance:Clone()
            if params.newParent then
                local parent = resolveInstancePath(params.newParent)
                c.Parent = parent or instance.Parent
            else
                c.Parent = instance.Parent
            end
            return c
        end)
        if ok then return { cloned = getInstancePath(clone), original = params.path }
        else return { error = "Clone failed: " .. tostring(clone) } end

    elseif cmdType == "move-instance" then
        local instance = resolveInstancePath(params.path)
        if not instance then return { error = "Instance not found: " .. params.path } end
        local newParent = resolveInstancePath(params.newParent)
        if not newParent then return { error = "New parent not found: " .. params.newParent } end
        instance.Parent = newParent
        return { moved = getInstancePath(instance), newParent = params.newParent }

    else
        return { error = "Unknown command type: " .. tostring(cmdType) }
    end
end

local function pollMcpCommands()
    if not connected or not currentProjectName then
        return false
    end

    local ok, response = pcall(function()
        return HttpService:RequestAsync({
            Url = SERVER_URL .. "/mcp/commands?project=" .. HttpService:UrlEncode(currentProjectName),
            Method = "GET",
            Timeout = 20
        })
    end)

    if not ok or not response.Success then
        return false
    end

    local decodeOk, data = pcall(HttpService.JSONDecode, HttpService, response.Body)
    if not decodeOk or not data.commands or #data.commands == 0 then
        return false
    end

    for _, cmd in ipairs(data.commands) do
        task.spawn(function()
            local result, err
            local ok2, execErr = pcall(function()
                result = executeMcpCommand(cmd)
            end)

            if not ok2 then
                err = tostring(execErr)
            end

            pcall(function()
                HttpService:RequestAsync({
                    Url = SERVER_URL .. "/mcp/command-result",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({
                        project = currentProjectName,
                        commandId = cmd.id,
                        result = result,
                        error = err
                    }),
                    Timeout = 10
                })
            end)
        end)
    end

    return true
end

local function rememberProject(placeId, projectName)
    if placeId and placeId > 0 and projectName and projectName ~= "" then
        projectMemory[tostring(placeId)] = projectName
        saveProjectMemory()
    end
end

local function getRememberedProject(placeId)
    if placeId and placeId > 0 then
        return projectMemory[tostring(placeId)]
    end
    return nil
end

local function isValidGameName(name)
    if not name or name == "" then return false end
    local invalidNames = {
        ["Game"] = true,
        ["Place"] = true,
        ["Place1"] = true,
        ["Baseplate"] = true,
    }
    if invalidNames[name] then return false end
    if name:match("^Place%s*%d*$") then return false end
    return true
end

loadProjectMemory()

-- ============ GUI SETUP ============

local widgetInfo = DockWidgetPluginGuiInfo.new(
    Enum.InitialDockState.Right, true, false, 300, 450, 260, 350
)

local widget = plugin:CreateDockWidgetPluginGui("ReagentPanel", widgetInfo)
widget.Title = "Reagent"

local toolbar = plugin:CreateToolbar("Reagent")
local toggleButton = toolbar:CreateButton("Reagent", "Toggle Reagent Panel", "rbxassetid://6031075938")
toggleButton.ClickableWhenViewportHidden = true

toggleButton.Click:Connect(function()
    widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
    toggleButton:SetActive(widget.Enabled)
end)

-- ============ CATPPUCCIN MOCHA + PURPLE ACCENT ============
local COLORS = {
    base = Color3.fromRGB(30, 30, 46),
    mantle = Color3.fromRGB(24, 24, 37),
    crust = Color3.fromRGB(17, 17, 27),
    surface0 = Color3.fromRGB(49, 50, 68),
    surface1 = Color3.fromRGB(69, 71, 90),
    surface2 = Color3.fromRGB(88, 91, 112),

    text = Color3.fromRGB(205, 214, 244),
    subtext1 = Color3.fromRGB(186, 194, 222),
    subtext0 = Color3.fromRGB(166, 173, 200),
    overlay2 = Color3.fromRGB(147, 153, 178),
    overlay1 = Color3.fromRGB(127, 132, 156),
    overlay0 = Color3.fromRGB(108, 112, 134),

    -- purple as primary accent (#cba6f7 = mauve in catppuccin)
    accent = Color3.fromRGB(203, 166, 247),
    accentHover = Color3.fromRGB(220, 190, 255),
    accentDim = Color3.fromRGB(150, 120, 200),

    lavender = Color3.fromRGB(180, 190, 254),
    blue = Color3.fromRGB(137, 180, 250),
    green = Color3.fromRGB(166, 227, 161),
    red = Color3.fromRGB(243, 139, 168),
    peach = Color3.fromRGB(250, 179, 135),
    yellow = Color3.fromRGB(249, 226, 175),
    teal = Color3.fromRGB(148, 226, 213),
    mauve = Color3.fromRGB(203, 166, 247),

    -- aliases
    bg = Color3.fromRGB(30, 30, 46),
    bgSecondary = Color3.fromRGB(24, 24, 37),
    bgInput = Color3.fromRGB(49, 50, 68),
    bgLight = Color3.fromRGB(49, 50, 68),
    bgLighter = Color3.fromRGB(69, 71, 90),
    success = Color3.fromRGB(166, 227, 161),
    warning = Color3.fromRGB(249, 226, 175),
    danger = Color3.fromRGB(243, 139, 168),
    textMuted = Color3.fromRGB(166, 173, 200),
    textDim = Color3.fromRGB(108, 112, 134),
    border = Color3.fromRGB(69, 71, 90),
    borderLight = Color3.fromRGB(88, 91, 112),
    logDefault = Color3.fromRGB(147, 153, 178),
    logSuccess = Color3.fromRGB(166, 227, 161),
    logError = Color3.fromRGB(243, 139, 168),
    logInfo = Color3.fromRGB(203, 166, 247),
    logWarning = Color3.fromRGB(249, 226, 175),
}

-- ============ ANIMATION HELPERS ============
local TWEEN_FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_SMOOTH = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local function tweenProperty(obj, props, tweenInfo)
    local tween = TweenService:Create(obj, tweenInfo or TWEEN_FAST, props)
    tween:Play()
    return tween
end

-- main frame
local main = Instance.new("Frame")
main.Size = UDim2.new(1, 0, 1, 0)
main.BackgroundColor3 = COLORS.bg
main.BorderSizePixel = 0
main.Parent = widget

-- ============ HEADER ============
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 52)
header.BackgroundColor3 = COLORS.base
header.BorderSizePixel = 0
header.Parent = main

local headerSep = Instance.new("Frame")
headerSep.Size = UDim2.new(1, 0, 0, 1)
headerSep.Position = UDim2.new(0, 0, 1, -1)
headerSep.BackgroundColor3 = COLORS.accent
headerSep.BackgroundTransparency = 0.6
headerSep.BorderSizePixel = 0
headerSep.Parent = header

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 120, 0, 52)
title.Position = UDim2.new(0, 16, 0, 0)
title.BackgroundTransparency = 1
title.Text = "reagent"
title.TextColor3 = COLORS.accent
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = header

local versionLabel = Instance.new("TextLabel")
versionLabel.Size = UDim2.new(0, 40, 0, 52)
versionLabel.Position = UDim2.new(0, 92, 0, 0)
versionLabel.BackgroundTransparency = 1
versionLabel.Text = "v" .. VERSION
versionLabel.TextColor3 = COLORS.overlay0
versionLabel.TextXAlignment = Enum.TextXAlignment.Left
versionLabel.Font = Enum.Font.Gotham
versionLabel.TextSize = 10
versionLabel.Parent = header

-- cloud ai badge
local cloudBadge = Instance.new("Frame")
cloudBadge.Size = UDim2.new(0, 68, 0, 20)
cloudBadge.Position = UDim2.new(1, -80, 0.5, -10)
cloudBadge.BackgroundColor3 = COLORS.accent
cloudBadge.BackgroundTransparency = 0.85
cloudBadge.BorderSizePixel = 0
cloudBadge.Parent = header

local cloudBadgeCorner = Instance.new("UICorner")
cloudBadgeCorner.CornerRadius = UDim.new(0, 10)
cloudBadgeCorner.Parent = cloudBadge

local cloudBadgeStroke = Instance.new("UIStroke")
cloudBadgeStroke.Color = COLORS.accent
cloudBadgeStroke.Thickness = 1
cloudBadgeStroke.Transparency = 0.5
cloudBadgeStroke.Parent = cloudBadge

local cloudBadgeText = Instance.new("TextLabel")
cloudBadgeText.Size = UDim2.new(1, 0, 1, 0)
cloudBadgeText.BackgroundTransparency = 1
cloudBadgeText.Text = "Cloud AI"
cloudBadgeText.TextColor3 = COLORS.accent
cloudBadgeText.Font = Enum.Font.GothamBold
cloudBadgeText.TextSize = 9
cloudBadgeText.Parent = cloudBadge

-- ============ SEPARATOR HELPER ============
local function createSeparator(parent, posY)
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(1, -40, 0, 1)
    sep.Position = UDim2.new(0, 20, 0, posY)
    sep.BackgroundColor3 = COLORS.surface1
    sep.BackgroundTransparency = 0.5
    sep.BorderSizePixel = 0
    sep.Parent = parent
    return sep
end

-- ============ CONTENT AREA ============
local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 1, -52)
content.Position = UDim2.new(0, 0, 0, 52)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.Parent = main

-- ============ PROJECT CARD ============
local projectCard = Instance.new("Frame")
projectCard.Size = UDim2.new(1, -40, 0, 44)
projectCard.Position = UDim2.new(0, 20, 0, 16)
projectCard.BackgroundColor3 = COLORS.surface0
projectCard.BorderSizePixel = 0
projectCard.Parent = content

local projectCardCorner = Instance.new("UICorner")
projectCardCorner.CornerRadius = UDim.new(0, 8)
projectCardCorner.Parent = projectCard

local projectInput = Instance.new("TextBox")
projectInput.Size = UDim2.new(1, -90, 1, 0)
projectInput.Position = UDim2.new(0, 30, 0, 0)
projectInput.BackgroundTransparency = 1
projectInput.Text = ""
projectInput.PlaceholderText = "project name..."
projectInput.PlaceholderColor3 = COLORS.overlay0
projectInput.TextColor3 = COLORS.text
projectInput.TextXAlignment = Enum.TextXAlignment.Left
projectInput.Font = Enum.Font.Gotham
projectInput.TextSize = 13
projectInput.ClearTextOnFocus = false
projectInput.Parent = projectCard

-- connect button
local connectBtn = Instance.new("TextButton")
connectBtn.Size = UDim2.new(0, 70, 0, 28)
connectBtn.Position = UDim2.new(1, -80, 0.5, -14)
connectBtn.BackgroundColor3 = COLORS.surface1
connectBtn.BorderSizePixel = 0
connectBtn.Text = "connect"
connectBtn.TextColor3 = COLORS.text
connectBtn.Font = Enum.Font.Gotham
connectBtn.TextSize = 12
connectBtn.AutoButtonColor = false
connectBtn.Parent = projectCard

local connectBtnCorner = Instance.new("UICorner")
connectBtnCorner.CornerRadius = UDim.new(0, 6)
connectBtnCorner.Parent = connectBtn

local connectBtnStroke = Instance.new("UIStroke")
connectBtnStroke.Color = COLORS.surface2
connectBtnStroke.Thickness = 1
connectBtnStroke.Parent = connectBtn

-- status dot
local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 8, 0, 8)
statusDot.Position = UDim2.new(0, 14, 0.5, -4)
statusDot.BackgroundColor3 = COLORS.red
statusDot.BorderSizePixel = 0
statusDot.ZIndex = 2
statusDot.Parent = projectCard

local statusDotCorner = Instance.new("UICorner")
statusDotCorner.CornerRadius = UDim.new(1, 0)
statusDotCorner.Parent = statusDot

connectBtn.MouseEnter:Connect(function()
    tweenProperty(connectBtn, {BackgroundColor3 = COLORS.surface2}, TWEEN_FAST)
end)

connectBtn.MouseLeave:Connect(function()
    if connected then
        tweenProperty(connectBtn, {BackgroundColor3 = COLORS.surface0}, TWEEN_FAST)
    else
        tweenProperty(connectBtn, {BackgroundColor3 = COLORS.surface1}, TWEEN_FAST)
    end
end)

-- hidden compat labels
local statusText = Instance.new("TextLabel")
statusText.Size = UDim2.new(0, 0, 0, 0)
statusText.BackgroundTransparency = 1
statusText.Text = "disconnected"
statusText.Visible = false
statusText.Parent = content

local statsLabel = Instance.new("TextLabel")
statsLabel.Size = UDim2.new(0, 0, 0, 0)
statsLabel.BackgroundTransparency = 1
statsLabel.Text = ""
statsLabel.Visible = false
statsLabel.Parent = content

-- (sync/pull buttons removed - connect auto-syncs)

-- ============ PROGRESS BAR ============
local progressFrame = Instance.new("Frame")
progressFrame.Size = UDim2.new(1, -40, 0, 4)
progressFrame.Position = UDim2.new(0, 20, 0, 76)
progressFrame.BackgroundColor3 = COLORS.surface0
progressFrame.BorderSizePixel = 0
progressFrame.Visible = false
progressFrame.Parent = content

local progressCorner = Instance.new("UICorner")
progressCorner.CornerRadius = UDim.new(0, 4)
progressCorner.Parent = progressFrame

local progressBar = Instance.new("Frame")
progressBar.Size = UDim2.new(0, 0, 1, 0)
progressBar.BackgroundColor3 = COLORS.accent
progressBar.BorderSizePixel = 0
progressBar.Parent = progressFrame

local progressBarCorner = Instance.new("UICorner")
progressBarCorner.CornerRadius = UDim.new(0, 4)
progressBarCorner.Parent = progressBar

local progressText = Instance.new("TextLabel")
progressText.Size = UDim2.new(1, 0, 0, 0)
progressText.BackgroundTransparency = 1
progressText.Text = ""
progressText.TextColor3 = COLORS.text
progressText.Font = Enum.Font.Gotham
progressText.TextSize = 10
progressText.ZIndex = 2
progressText.Visible = false
progressText.Parent = progressFrame

local progressTarget = 0
local progressCurrent = 0
local progressMessage = ""
local progressConnection = nil

local function updateProgressBar()
    local pct = math.clamp(progressCurrent, 0, 100)
    progressBar.Size = UDim2.new(pct / 100, 0, 1, 0)
    if progressMessage ~= "" then
        progressText.Text = progressMessage
    else
        progressText.Text = math.floor(pct) .. "%"
    end
end

local function startProgressAnimation()
    if progressConnection then return end
    progressConnection = RunService.Heartbeat:Connect(function(dt)
        if progressCurrent < progressTarget then
            local diff = progressTarget - progressCurrent
            local speed = math.max(diff * 0.8, 0.5)
            progressCurrent = math.min(progressCurrent + speed * dt * 10, progressTarget)
            updateProgressBar()
        end
    end)
end

local function stopProgressAnimation()
    if progressConnection then
        progressConnection:Disconnect()
        progressConnection = nil
    end
end

local function showProgress(percent, text)
    progressFrame.Visible = true
    progressTarget = math.clamp(percent, 0, 100)
    progressMessage = text or ""
    startProgressAnimation()
    updateProgressBar()
end

local function hideProgress()
    stopProgressAnimation()
    progressFrame.Visible = false
    progressBar.Size = UDim2.new(0, 0, 1, 0)
    progressText.Text = "0%"
    progressTarget = 0
    progressCurrent = 0
    progressMessage = ""
end

local function completeProgress()
    progressTarget = 100
    progressCurrent = 100
    progressMessage = "Done!"
    updateProgressBar()
end

-- (toggles removed - auto-sync always on, full tree mode)

-- ============ SEPARATOR ============
local sep3 = Instance.new("Frame")
sep3.Size = UDim2.new(1, -40, 0, 1)
sep3.Position = UDim2.new(0, 20, 0, 92)
sep3.BackgroundColor3 = COLORS.surface1
sep3.BackgroundTransparency = 0.6
sep3.BorderSizePixel = 0
sep3.Parent = content

-- ============ ACTIVITY LOG ============
local logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, -40, 0, 24)
logLabel.Position = UDim2.new(0, 20, 0, 100)
logLabel.BackgroundTransparency = 1
logLabel.Text = "--- activity ---"
logLabel.TextColor3 = COLORS.overlay0
logLabel.TextXAlignment = Enum.TextXAlignment.Center
logLabel.Font = Enum.Font.Gotham
logLabel.TextSize = 10
logLabel.Parent = content

local logFrame = Instance.new("ScrollingFrame")
logFrame.Size = UDim2.new(1, -40, 1, -132)
logFrame.Position = UDim2.new(0, 20, 0, 124)
logFrame.BackgroundColor3 = COLORS.mantle
logFrame.BorderSizePixel = 0
logFrame.ScrollBarThickness = 2
logFrame.ScrollBarImageColor3 = COLORS.surface1
logFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
logFrame.Parent = content

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 8)
logCorner.Parent = logFrame

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding = UDim.new(0, 2)
logLayout.Parent = logFrame

local logPadding = Instance.new("UIPadding")
logPadding.PaddingLeft = UDim.new(0, 10)
logPadding.PaddingRight = UDim.new(0, 10)
logPadding.PaddingTop = UDim.new(0, 8)
logPadding.PaddingBottom = UDim.new(0, 8)
logPadding.Parent = logFrame

-- compat refs
local projectInputBar = content

-- ============ PROJECT NAME DIALOG ============

local dialogOverlay = Instance.new("Frame")
dialogOverlay.Size = UDim2.new(1, 0, 1, 0)
dialogOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
dialogOverlay.BackgroundTransparency = 0.5
dialogOverlay.BorderSizePixel = 0
dialogOverlay.Visible = false
dialogOverlay.ZIndex = 10
dialogOverlay.Parent = main

local dialogBox = Instance.new("Frame")
dialogBox.Size = UDim2.new(0, 240, 0, 160)
dialogBox.Position = UDim2.new(0.5, -120, 0.5, -80)
dialogBox.BackgroundColor3 = COLORS.bgLight
dialogBox.BorderSizePixel = 0
dialogBox.ZIndex = 11
dialogBox.Parent = dialogOverlay

local dialogCorner = Instance.new("UICorner")
dialogCorner.CornerRadius = UDim.new(0, 12)
dialogCorner.Parent = dialogBox

local dialogTitle = Instance.new("TextLabel")
dialogTitle.Size = UDim2.new(1, -20, 0, 24)
dialogTitle.Position = UDim2.new(0, 10, 0, 12)
dialogTitle.BackgroundTransparency = 1
dialogTitle.Text = "Enter Project Name"
dialogTitle.TextColor3 = COLORS.text
dialogTitle.Font = Enum.Font.GothamBold
dialogTitle.TextSize = 14
dialogTitle.ZIndex = 12
dialogTitle.Parent = dialogBox

local dialogDesc = Instance.new("TextLabel")
dialogDesc.Size = UDim2.new(1, -20, 0, 30)
dialogDesc.Position = UDim2.new(0, 10, 0, 38)
dialogDesc.BackgroundTransparency = 1
dialogDesc.Text = "This place is unsaved. Please enter a name for your project:"
dialogDesc.TextColor3 = COLORS.textDim
dialogDesc.Font = Enum.Font.Gotham
dialogDesc.TextSize = 11
dialogDesc.TextWrapped = true
dialogDesc.ZIndex = 12
dialogDesc.Parent = dialogBox

local dialogInput = Instance.new("TextBox")
dialogInput.Size = UDim2.new(1, -20, 0, 32)
dialogInput.Position = UDim2.new(0, 10, 0, 74)
dialogInput.BackgroundColor3 = COLORS.bg
dialogInput.BorderSizePixel = 0
dialogInput.Text = ""
dialogInput.PlaceholderText = "MyProject"
dialogInput.PlaceholderColor3 = COLORS.textDim
dialogInput.TextColor3 = COLORS.text
dialogInput.Font = Enum.Font.GothamMedium
dialogInput.TextSize = 13
dialogInput.ClearTextOnFocus = false
dialogInput.ZIndex = 12
dialogInput.Parent = dialogBox

local dialogInputCorner = Instance.new("UICorner")
dialogInputCorner.CornerRadius = UDim.new(0, 6)
dialogInputCorner.Parent = dialogInput

local dialogInputPad = Instance.new("UIPadding")
dialogInputPad.PaddingLeft = UDim.new(0, 10)
dialogInputPad.PaddingRight = UDim.new(0, 10)
dialogInputPad.Parent = dialogInput

local dialogConfirm = Instance.new("TextButton")
dialogConfirm.Size = UDim2.new(0.5, -15, 0, 30)
dialogConfirm.Position = UDim2.new(0, 10, 1, -40)
dialogConfirm.BackgroundColor3 = COLORS.accent
dialogConfirm.BorderSizePixel = 0
dialogConfirm.Text = "Confirm"
dialogConfirm.TextColor3 = COLORS.crust
dialogConfirm.Font = Enum.Font.GothamBold
dialogConfirm.TextSize = 12
dialogConfirm.ZIndex = 12
dialogConfirm.Parent = dialogBox

local dialogConfirmCorner = Instance.new("UICorner")
dialogConfirmCorner.CornerRadius = UDim.new(0, 6)
dialogConfirmCorner.Parent = dialogConfirm

local dialogCancel = Instance.new("TextButton")
dialogCancel.Size = UDim2.new(0.5, -15, 0, 30)
dialogCancel.Position = UDim2.new(0.5, 5, 1, -40)
dialogCancel.BackgroundColor3 = COLORS.bgLighter
dialogCancel.BorderSizePixel = 0
dialogCancel.Text = "Cancel"
dialogCancel.TextColor3 = COLORS.text
dialogCancel.Font = Enum.Font.GothamBold
dialogCancel.TextSize = 12
dialogCancel.ZIndex = 12
dialogCancel.Parent = dialogBox

local dialogCancelCorner = Instance.new("UICorner")
dialogCancelCorner.CornerRadius = UDim.new(0, 6)
dialogCancelCorner.Parent = dialogCancel

local dialogCallback = nil

local function showProjectDialog(callback)
    dialogCallback = callback
    dialogInput.Text = ""
    dialogOverlay.Visible = true
    dialogInput:CaptureFocus()
end

local function hideProjectDialog()
    dialogOverlay.Visible = false
    dialogCallback = nil
end

dialogConfirm.MouseButton1Click:Connect(function()
    local name = dialogInput.Text
    if name and name ~= "" then
        hideProjectDialog()
        if dialogCallback then
            dialogCallback(name)
        end
    end
end)

dialogCancel.MouseButton1Click:Connect(function()
    hideProjectDialog()
end)

dialogInput.FocusLost:Connect(function(enterPressed)
    if enterPressed then
        local name = dialogInput.Text
        if name and name ~= "" then
            hideProjectDialog()
            if dialogCallback then
                dialogCallback(name)
            end
        end
    end
end)

-- ============ CONFLICT DIALOG ============

local conflictOverlay = Instance.new("Frame")
conflictOverlay.Size = UDim2.new(1, 0, 1, 0)
conflictOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
conflictOverlay.BackgroundTransparency = 0.5
conflictOverlay.BorderSizePixel = 0
conflictOverlay.Visible = false
conflictOverlay.ZIndex = 10
conflictOverlay.Parent = main

local conflictBox = Instance.new("Frame")
conflictBox.Size = UDim2.new(0, 260, 0, 200)
conflictBox.Position = UDim2.new(0.5, -130, 0.5, -100)
conflictBox.BackgroundColor3 = COLORS.bgLight
conflictBox.BorderSizePixel = 0
conflictBox.ZIndex = 11
conflictBox.Parent = conflictOverlay

local conflictCorner = Instance.new("UICorner")
conflictCorner.CornerRadius = UDim.new(0, 12)
conflictCorner.Parent = conflictBox

local conflictTitle = Instance.new("TextLabel")
conflictTitle.Size = UDim2.new(1, -20, 0, 24)
conflictTitle.Position = UDim2.new(0, 10, 0, 12)
conflictTitle.BackgroundTransparency = 1
conflictTitle.Text = "Conflict Detected!"
conflictTitle.TextColor3 = COLORS.danger
conflictTitle.Font = Enum.Font.GothamBold
conflictTitle.TextSize = 14
conflictTitle.ZIndex = 12
conflictTitle.Parent = conflictBox

local conflictDesc = Instance.new("TextLabel")
conflictDesc.Size = UDim2.new(1, -20, 0, 60)
conflictDesc.Position = UDim2.new(0, 10, 0, 40)
conflictDesc.BackgroundTransparency = 1
conflictDesc.Text = "Files have been modified in both Studio and filesystem since last sync."
conflictDesc.TextColor3 = COLORS.textDim
conflictDesc.Font = Enum.Font.Gotham
conflictDesc.TextSize = 11
conflictDesc.TextWrapped = true
conflictDesc.ZIndex = 12
conflictDesc.Parent = conflictBox

local conflictCount = Instance.new("TextLabel")
conflictCount.Size = UDim2.new(1, -20, 0, 20)
conflictCount.Position = UDim2.new(0, 10, 0, 100)
conflictCount.BackgroundTransparency = 1
conflictCount.Text = "0 files affected"
conflictCount.TextColor3 = COLORS.warning
conflictCount.Font = Enum.Font.GothamBold
conflictCount.TextSize = 12
conflictCount.ZIndex = 12
conflictCount.Parent = conflictBox

local conflictKeepStudio = Instance.new("TextButton")
conflictKeepStudio.Size = UDim2.new(0.5, -15, 0, 30)
conflictKeepStudio.Position = UDim2.new(0, 10, 1, -75)
conflictKeepStudio.BackgroundColor3 = COLORS.accent
conflictKeepStudio.BorderSizePixel = 0
conflictKeepStudio.Text = "Keep Studio"
conflictKeepStudio.TextColor3 = COLORS.crust
conflictKeepStudio.Font = Enum.Font.GothamBold
conflictKeepStudio.TextSize = 11
conflictKeepStudio.ZIndex = 12
conflictKeepStudio.Parent = conflictBox

local conflictKeepStudioCorner = Instance.new("UICorner")
conflictKeepStudioCorner.CornerRadius = UDim.new(0, 6)
conflictKeepStudioCorner.Parent = conflictKeepStudio

local conflictKeepServer = Instance.new("TextButton")
conflictKeepServer.Size = UDim2.new(0.5, -15, 0, 30)
conflictKeepServer.Position = UDim2.new(0.5, 5, 1, -75)
conflictKeepServer.BackgroundColor3 = COLORS.success
conflictKeepServer.BorderSizePixel = 0
conflictKeepServer.Text = "Keep Server"
conflictKeepServer.TextColor3 = COLORS.crust
conflictKeepServer.Font = Enum.Font.GothamBold
conflictKeepServer.TextSize = 11
conflictKeepServer.ZIndex = 12
conflictKeepServer.Parent = conflictBox

local conflictKeepServerCorner = Instance.new("UICorner")
conflictKeepServerCorner.CornerRadius = UDim.new(0, 6)
conflictKeepServerCorner.Parent = conflictKeepServer

local conflictCancel = Instance.new("TextButton")
conflictCancel.Size = UDim2.new(1, -20, 0, 28)
conflictCancel.Position = UDim2.new(0, 10, 1, -38)
conflictCancel.BackgroundColor3 = COLORS.bgLighter
conflictCancel.BorderSizePixel = 0
conflictCancel.Text = "Cancel"
conflictCancel.TextColor3 = COLORS.text
conflictCancel.Font = Enum.Font.GothamBold
conflictCancel.TextSize = 11
conflictCancel.ZIndex = 12
conflictCancel.Parent = conflictBox

local conflictCancelCorner = Instance.new("UICorner")
conflictCancelCorner.CornerRadius = UDim.new(0, 6)
conflictCancelCorner.Parent = conflictCancel

local conflictCallback = nil
local currentConflicts = {}

local function showConflictDialog(conflicts, callback)
    currentConflicts = conflicts
    conflictCallback = callback
    conflictCount.Text = #conflicts .. " file(s) affected"
    conflictOverlay.Visible = true
end

local function hideConflictDialog()
    conflictOverlay.Visible = false
    conflictCallback = nil
    currentConflicts = {}
end

conflictKeepStudio.MouseButton1Click:Connect(function()
    hideConflictDialog()
    log("Keeping Studio version (skipped pull)", COLORS.logInfo)
end)

conflictKeepServer.MouseButton1Click:Connect(function()
    hideConflictDialog()
    if conflictCallback then
        conflictCallback("server")
    end
end)

conflictCancel.MouseButton1Click:Connect(function()
    hideConflictDialog()
end)

-- ============ FUNCTIONS ============

local logCount = 0
local maxLogs = 100

local function log(message, color)
    logCount += 1

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 18)
    label.BackgroundTransparency = 1
    label.TextColor3 = color or COLORS.overlay1
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.RobotoMono
    label.TextSize = 12
    label.Text = os.date("%H:%M") .. "  " .. string.lower(message)
    label.LayoutOrder = logCount
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Parent = logFrame

    task.defer(function()
        logFrame.CanvasPosition = Vector2.new(0, logFrame.AbsoluteCanvasSize.Y)
    end)

    if logCount > maxLogs then
        local children = logFrame:GetChildren()
        for _, child in ipairs(children) do
            if child:IsA("TextLabel") and child.LayoutOrder < logCount - 80 then
                child:Destroy()
            end
        end
    end
end

local function updateProjectDisplay(projectName)
    currentProjectName = projectName
    if projectName and projectName ~= "" then
        projectInput.Text = projectName
    else
        projectInput.Text = ""
    end
end

local function getProjectName()
    local inputName = projectInput.Text
    if inputName and inputName ~= "" then
        return inputName
    end

    local placeId = game.PlaceId
    local remembered = getRememberedProject(placeId)
    if remembered then
        return remembered
    end

    local gameName = game.Name
    if isValidGameName(gameName) then
        return gameName
    end

    return nil
end

local function initProjectNameField()
    local placeId = game.PlaceId

    local remembered = getRememberedProject(placeId)
    if remembered then
        projectInput.Text = remembered
        return
    end

    local gameName = game.Name
    if isValidGameName(gameName) then
        projectInput.Text = gameName
        return
    end

    projectInput.Text = ""
end

local function updateStatus(text, isConnected, stats)
    statusText.Text = string.lower(text)
    statsLabel.Text = stats or ""

    if isConnected then
        tweenProperty(statusDot, {BackgroundColor3 = COLORS.green}, TWEEN_SMOOTH)
        tweenProperty(connectBtn, {BackgroundColor3 = COLORS.surface0}, TWEEN_SMOOTH)
        connectBtn.TextColor3 = COLORS.green
        connectBtn.Text = "disconnect"
        -- update cloud badge when connected
        cloudBadgeText.Text = "Cloud AI"
        cloudBadgeStroke.Color = COLORS.green
        cloudBadgeText.TextColor3 = COLORS.green
        cloudBadge.BackgroundColor3 = COLORS.green
    else
        tweenProperty(statusDot, {BackgroundColor3 = COLORS.red}, TWEEN_SMOOTH)
        tweenProperty(connectBtn, {BackgroundColor3 = COLORS.surface1}, TWEEN_SMOOTH)
        connectBtn.TextColor3 = COLORS.text
        connectBtn.Text = "connect"
        cloudBadgeText.Text = "Cloud AI"
        cloudBadgeStroke.Color = COLORS.accent
        cloudBadgeText.TextColor3 = COLORS.accent
        cloudBadge.BackgroundColor3 = COLORS.accent
    end
end

-- sanitize string for JSON encoding
local function sanitizeString(str)
    if type(str) ~= "string" or str == "" then return str end
    str = str:gsub("[\0-\8\11\12\14-\31\127]", "")
    if utf8.len(str) then return str end
    local clean = {}
    local i = 1
    local len = #str
    while i <= len do
        local b = string.byte(str, i)
        if b < 128 then
            table.insert(clean, string.sub(str, i, i))
            i += 1
        else
            local seqLen = b >= 240 and 4 or b >= 224 and 3 or b >= 192 and 2 or 0
            if seqLen > 0 and i + seqLen - 1 <= len then
                local seq = string.sub(str, i, i + seqLen - 1)
                if utf8.len(seq) then
                    table.insert(clean, seq)
                end
                i += seqLen
            else
                i += 1
            end
        end
    end
    return table.concat(clean)
end

-- stack-based table sanitizer (prevents stack overflow on deep trees)
local function sanitizeTable(t)
    if type(t) ~= "table" then return t end

    local root = {}
    local stack = {{src = t, dst = root}}

    while #stack > 0 do
        local frame = table.remove(stack)
        local src = frame.src
        local dst = frame.dst

        for k, v in pairs(src) do
            local kType = type(k)
            if kType ~= "string" and kType ~= "number" then
                continue
            end

            local key = kType == "string" and sanitizeString(k) or k
            local vType = type(v)

            if vType == "string" then
                dst[key] = sanitizeString(v)
            elseif vType == "number" then
                if v ~= v or v == math.huge or v == -math.huge then
                    dst[key] = 0
                else
                    dst[key] = v
                end
            elseif vType == "boolean" then
                dst[key] = v
            elseif vType == "table" then
                local child = {}
                dst[key] = child
                table.insert(stack, {src = v, dst = child})
            end
        end
    end

    return root
end

local function request(method, endpoint, body, timeout)
    local url = SERVER_URL .. endpoint

    local encodedBody = nil
    if body then
        local cleanBody = sanitizeTable(body)
        local encOk, encResult = pcall(HttpService.JSONEncode, HttpService, cleanBody)
        if not encOk then
            warn("[Reagent] JSONEncode failed: " .. tostring(encResult))
            local function findBad(tbl, path, depth)
                if depth > 4 then return end
                for k, v in pairs(tbl) do
                    local kStr = tostring(k)
                    local fullPath = path == "" and kStr or (path .. "." .. kStr)
                    local testOk, testErr = pcall(HttpService.JSONEncode, HttpService, {[kStr] = v})
                    if not testOk then
                        warn("[Reagent] Bad at: " .. fullPath .. " type=" .. typeof(v) .. " err=" .. tostring(testErr))
                        if type(v) == "table" then
                            findBad(v, fullPath, depth + 1)
                        end
                    end
                end
            end
            findBad(cleanBody, "", 0)
            return nil, "JSON encode failed: " .. tostring(encResult)
        end
        encodedBody = encResult
    end

    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = url,
            Method = method,
            Headers = { ["Content-Type"] = "application/json" },
            Body = encodedBody,
            Timeout = math.min(timeout or 120, 120),
        })
    end)

    if not success then
        return nil, tostring(response)
    end

    if response.Success then
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, response.Body)
        return ok and decoded or response.Body, nil
    end

    return nil, "HTTP " .. response.StatusCode
end

-- ============ SERIALIZATION ============

local function getProperties(instance)
    local props = {}

    if instance:IsA("BasePart") then
        local pos = instance.Position
        local size = instance.Size
        local orient = instance.Orientation
        local color = instance.Color

        props.Position = {pos.X, pos.Y, pos.Z}
        props.Size = {size.X, size.Y, size.Z}
        props.Orientation = {orient.X, orient.Y, orient.Z}
        props.Anchored = instance.Anchored
        props.CanCollide = instance.CanCollide
        props.Transparency = instance.Transparency
        props.Color = {color.R, color.G, color.B}
        props.Material = instance.Material.Name
    end

    if instance:IsA("Model") and instance.PrimaryPart then
        props.PrimaryPart = instance.PrimaryPart.Name
    end

    return props
end

-- ============ COMPREHENSIVE STRUCTURE EXPORT ============

local function getFullProperties(instance)
    local props = {}

    local function getPath(inst)
        local parts = {}
        local current = inst
        while current and current ~= game do
            table.insert(parts, 1, current.Name)
            current = current.Parent
        end
        return table.concat(parts, ".")
    end

    props.Name = instance.Name
    props.ClassName = instance.ClassName
    props.Path = getPath(instance)

    if instance:IsA("BasePart") then
        local pos = instance.Position
        local size = instance.Size
        local cframe = instance.CFrame
        local color = instance.Color

        props.Position = {X = pos.X, Y = pos.Y, Z = pos.Z}
        props.Size = {X = size.X, Y = size.Y, Z = size.Z}
        props.CFrame = {
            Position = {X = cframe.Position.X, Y = cframe.Position.Y, Z = cframe.Position.Z},
            LookVector = {X = cframe.LookVector.X, Y = cframe.LookVector.Y, Z = cframe.LookVector.Z},
            UpVector = {X = cframe.UpVector.X, Y = cframe.UpVector.Y, Z = cframe.UpVector.Z}
        }
        props.Anchored = instance.Anchored
        props.CanCollide = instance.CanCollide
        props.Massless = instance.Massless
        props.Transparency = instance.Transparency
        props.Color = {R = color.R, G = color.G, B = color.B}
        props.Material = instance.Material.Name
        props.CanQuery = instance.CanQuery
        props.CanTouch = instance.CanTouch

        if instance:IsA("Part") then
            props.Shape = instance.Shape.Name
        end

        if instance:IsA("MeshPart") then
            props.MeshId = instance.MeshId
            props.TextureID = instance.TextureID
        end
    end

    if instance:IsA("Model") then
        if instance.PrimaryPart then
            props.PrimaryPart = instance.PrimaryPart.Name
            props.PrimaryPartPath = getPath(instance.PrimaryPart)
        end
        local pivot = instance:GetPivot()
        props.WorldPivot = {X = pivot.Position.X, Y = pivot.Position.Y, Z = pivot.Position.Z}
    end

    if instance:IsA("Attachment") then
        local pos = instance.Position
        local worldPos = instance.WorldPosition
        props.Position = {X = pos.X, Y = pos.Y, Z = pos.Z}
        props.WorldPosition = {X = worldPos.X, Y = worldPos.Y, Z = worldPos.Z}
        props.Visible = instance.Visible
        local axis = instance.Axis
        local secondaryAxis = instance.SecondaryAxis
        props.Axis = {X = axis.X, Y = axis.Y, Z = axis.Z}
        props.SecondaryAxis = {X = secondaryAxis.X, Y = secondaryAxis.Y, Z = secondaryAxis.Z}
    end

    if instance:IsA("Constraint") then
        props.Enabled = instance.Enabled
        props.Visible = instance.Visible
        props.Color = instance.Color and {R = instance.Color.R, G = instance.Color.G, B = instance.Color.B} or nil
        if instance.Attachment0 then
            props.Attachment0 = getPath(instance.Attachment0)
        end
        if instance.Attachment1 then
            props.Attachment1 = getPath(instance.Attachment1)
        end
    end

    if instance:IsA("HingeConstraint") then
        props.ActuatorType = instance.ActuatorType.Name
        props.AngularVelocity = instance.AngularVelocity
        props.MotorMaxTorque = instance.MotorMaxTorque
        props.AngularSpeed = instance.AngularSpeed
        props.LimitsEnabled = instance.LimitsEnabled
        if instance.LimitsEnabled then
            props.LowerAngle = instance.LowerAngle
            props.UpperAngle = instance.UpperAngle
        end
    end

    if instance:IsA("CylindricalConstraint") then
        props.ActuatorType = instance.ActuatorType.Name
        props.AngularActuatorType = instance.AngularActuatorType.Name
        props.InclinationAngle = instance.InclinationAngle
        props.LimitsEnabled = instance.LimitsEnabled
        if instance.LimitsEnabled then
            props.LowerLimit = instance.LowerLimit
            props.UpperLimit = instance.UpperLimit
        end
    end

    if instance:IsA("SpringConstraint") then
        props.Stiffness = instance.Stiffness
        props.Damping = instance.Damping
        props.FreeLength = instance.FreeLength
        props.LimitsEnabled = instance.LimitsEnabled
        if instance.LimitsEnabled then
            props.MinLength = instance.MinLength
            props.MaxLength = instance.MaxLength
        end
    end

    if instance:IsA("PrismaticConstraint") then
        props.ActuatorType = instance.ActuatorType.Name
        props.LimitsEnabled = instance.LimitsEnabled
        if instance.LimitsEnabled then
            props.LowerLimit = instance.LowerLimit
            props.UpperLimit = instance.UpperLimit
        end
        props.Velocity = instance.Velocity
        props.MotorMaxForce = instance.MotorMaxForce
    end

    if instance:IsA("WeldConstraint") then
        if instance.Part0 then props.Part0 = getPath(instance.Part0) end
        if instance.Part1 then props.Part1 = getPath(instance.Part1) end
    end

    if instance:IsA("Motor6D") then
        if instance.Part0 then props.Part0 = getPath(instance.Part0) end
        if instance.Part1 then props.Part1 = getPath(instance.Part1) end
        props.MaxVelocity = instance.MaxVelocity
        props.DesiredAngle = instance.DesiredAngle
        props.CurrentAngle = instance.CurrentAngle
    end

    if instance:IsA("VehicleSeat") then
        props.MaxSpeed = instance.MaxSpeed
        props.Torque = instance.Torque
        props.TurnSpeed = instance.TurnSpeed
        props.Throttle = instance.Throttle
        props.Steer = instance.Steer
        props.AreHingesDetected = instance.AreHingesDetected
    end

    if instance:IsA("Seat") then
        props.Disabled = instance.Disabled
    end

    if instance:IsA("BodyVelocity") then
        local vel = instance.Velocity
        props.Velocity = {X = vel.X, Y = vel.Y, Z = vel.Z}
        props.MaxForce = {X = instance.MaxForce.X, Y = instance.MaxForce.Y, Z = instance.MaxForce.Z}
        props.P = instance.P
    end

    if instance:IsA("BodyGyro") then
        props.MaxTorque = {X = instance.MaxTorque.X, Y = instance.MaxTorque.Y, Z = instance.MaxTorque.Z}
        props.P = instance.P
        props.D = instance.D
    end

    if instance:IsA("BodyForce") then
        local force = instance.Force
        props.Force = {X = force.X, Y = force.Y, Z = force.Z}
    end

    if instance:IsA("AlignPosition") then
        props.Mode = instance.Mode.Name
        props.MaxForce = instance.MaxForce
        props.MaxVelocity = instance.MaxVelocity
        props.Responsiveness = instance.Responsiveness
        props.RigidityEnabled = instance.RigidityEnabled
    end

    if instance:IsA("AlignOrientation") then
        props.Mode = instance.Mode.Name
        props.MaxTorque = instance.MaxTorque
        props.MaxAngularVelocity = instance.MaxAngularVelocity
        props.Responsiveness = instance.Responsiveness
        props.RigidityEnabled = instance.RigidityEnabled
    end

    if instance:IsA("LinearVelocity") then
        props.VelocityConstraintMode = instance.VelocityConstraintMode.Name
        props.MaxForce = instance.MaxForce
        local vec = instance.VectorVelocity
        props.VectorVelocity = {X = vec.X, Y = vec.Y, Z = vec.Z}
    end

    if instance:IsA("AngularVelocity") then
        props.MaxTorque = instance.MaxTorque
        local angVel = instance.AngularVelocity
        props.AngularVelocity = {X = angVel.X, Y = angVel.Y, Z = angVel.Z}
    end

    if instance:IsA("VectorForce") then
        local force = instance.Force
        props.Force = {X = force.X, Y = force.Y, Z = force.Z}
        props.ApplyAtCenterOfMass = instance.ApplyAtCenterOfMass
        props.RelativeTo = instance.RelativeTo.Name
    end

    if instance:IsA("Humanoid") then
        props.Health = instance.Health
        props.MaxHealth = instance.MaxHealth
        props.WalkSpeed = instance.WalkSpeed
        props.JumpPower = instance.JumpPower
        props.JumpHeight = instance.JumpHeight
        props.UseJumpPower = instance.UseJumpPower
        props.HipHeight = instance.HipHeight
        props.AutoRotate = instance.AutoRotate
    end

    if instance:IsA("ValueBase") then
        pcall(function() props.Value = instance.Value end)
    end

    if instance:IsA("Configuration") then
        props.IsConfiguration = true
    end

    if instance:IsA("BaseScript") then
        props.Enabled = instance.Enabled
        props.RunContext = instance:IsA("Script") and instance.RunContext.Name or nil
    end

    -- UI elements
    if instance:IsA("GuiObject") then
        local pos = instance.Position
        local size = instance.Size
        local anchor = instance.AnchorPoint
        local bgColor = instance.BackgroundColor3

        props.Position = {
            X = {Scale = pos.X.Scale, Offset = pos.X.Offset},
            Y = {Scale = pos.Y.Scale, Offset = pos.Y.Offset}
        }
        props.Size = {
            X = {Scale = size.X.Scale, Offset = size.X.Offset},
            Y = {Scale = size.Y.Scale, Offset = size.Y.Offset}
        }
        props.AnchorPoint = {X = anchor.X, Y = anchor.Y}
        props.Visible = instance.Visible
        props.ZIndex = instance.ZIndex
        props.LayoutOrder = instance.LayoutOrder
        props.BackgroundColor3 = {R = bgColor.R, G = bgColor.G, B = bgColor.B}
        props.BackgroundTransparency = instance.BackgroundTransparency
        props.BorderSizePixel = instance.BorderSizePixel
        props.ClipsDescendants = instance.ClipsDescendants

        if instance.BorderSizePixel > 0 then
            local borderColor = instance.BorderColor3
            props.BorderColor3 = {R = borderColor.R, G = borderColor.G, B = borderColor.B}
        end
    end

    if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
        local textColor = instance.TextColor3
        props.Text = instance.Text
        props.TextColor3 = {R = textColor.R, G = textColor.G, B = textColor.B}
        props.TextSize = instance.TextSize
        props.Font = instance.Font.Name
        props.TextXAlignment = instance.TextXAlignment.Name
        props.TextYAlignment = instance.TextYAlignment.Name
        props.TextWrapped = instance.TextWrapped
        props.TextScaled = instance.TextScaled
        props.TextTransparency = instance.TextTransparency
        props.RichText = instance.RichText

        if instance:IsA("TextBox") then
            props.PlaceholderText = instance.PlaceholderText
            props.ClearTextOnFocus = instance.ClearTextOnFocus
            props.MultiLine = instance.MultiLine
        end

        if instance:IsA("TextButton") then
            props.AutoButtonColor = instance.AutoButtonColor
        end
    end

    if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
        props.Image = instance.Image
        props.ImageColor3 = {R = instance.ImageColor3.R, G = instance.ImageColor3.G, B = instance.ImageColor3.B}
        props.ImageTransparency = instance.ImageTransparency
        props.ScaleType = instance.ScaleType.Name

        if instance.ScaleType == Enum.ScaleType.Slice then
            local rect = instance.SliceCenter
            props.SliceCenter = {Min = {X = rect.Min.X, Y = rect.Min.Y}, Max = {X = rect.Max.X, Y = rect.Max.Y}}
        end

        if instance:IsA("ImageButton") then
            props.AutoButtonColor = instance.AutoButtonColor
            props.HoverImage = instance.HoverImage
            props.PressedImage = instance.PressedImage
        end
    end

    if instance:IsA("ScrollingFrame") then
        local canvasSize = instance.CanvasSize
        props.CanvasSize = {
            X = {Scale = canvasSize.X.Scale, Offset = canvasSize.X.Offset},
            Y = {Scale = canvasSize.Y.Scale, Offset = canvasSize.Y.Offset}
        }
        props.ScrollBarThickness = instance.ScrollBarThickness
        props.ScrollingDirection = instance.ScrollingDirection.Name
        props.ScrollBarImageColor3 = {R = instance.ScrollBarImageColor3.R, G = instance.ScrollBarImageColor3.G, B = instance.ScrollBarImageColor3.B}
        props.ElasticBehavior = instance.ElasticBehavior.Name
    end

    if instance:IsA("ViewportFrame") then
        props.Ambient = {R = instance.Ambient.R, G = instance.Ambient.G, B = instance.Ambient.B}
        props.LightColor = {R = instance.LightColor.R, G = instance.LightColor.G, B = instance.LightColor.B}
        props.LightDirection = {X = instance.LightDirection.X, Y = instance.LightDirection.Y, Z = instance.LightDirection.Z}
    end

    if instance:IsA("ScreenGui") then
        props.DisplayOrder = instance.DisplayOrder
        props.IgnoreGuiInset = instance.IgnoreGuiInset
        props.ResetOnSpawn = instance.ResetOnSpawn
        props.ZIndexBehavior = instance.ZIndexBehavior.Name
        props.ScreenInsets = instance.ScreenInsets.Name
    end

    if instance:IsA("BillboardGui") then
        props.Active = instance.Active
        props.AlwaysOnTop = instance.AlwaysOnTop
        props.MaxDistance = instance.MaxDistance
        props.Size = {
            X = {Scale = instance.Size.X.Scale, Offset = instance.Size.X.Offset},
            Y = {Scale = instance.Size.Y.Scale, Offset = instance.Size.Y.Offset}
        }
        props.StudsOffset = {X = instance.StudsOffset.X, Y = instance.StudsOffset.Y, Z = instance.StudsOffset.Z}
        props.LightInfluence = instance.LightInfluence
    end

    if instance:IsA("SurfaceGui") then
        props.Face = instance.Face.Name
        props.Active = instance.Active
        props.AlwaysOnTop = instance.AlwaysOnTop
        props.LightInfluence = instance.LightInfluence
        props.PixelsPerStud = instance.PixelsPerStud
        props.SizingMode = instance.SizingMode.Name
    end

    if instance:IsA("UIListLayout") then
        props.FillDirection = instance.FillDirection.Name
        props.HorizontalAlignment = instance.HorizontalAlignment.Name
        props.VerticalAlignment = instance.VerticalAlignment.Name
        props.SortOrder = instance.SortOrder.Name
        props.Padding = {Scale = instance.Padding.Scale, Offset = instance.Padding.Offset}
        props.Wraps = instance.Wraps
    end

    if instance:IsA("UIGridLayout") then
        props.CellSize = {
            X = {Scale = instance.CellSize.X.Scale, Offset = instance.CellSize.X.Offset},
            Y = {Scale = instance.CellSize.Y.Scale, Offset = instance.CellSize.Y.Offset}
        }
        props.CellPadding = {
            X = {Scale = instance.CellPadding.X.Scale, Offset = instance.CellPadding.X.Offset},
            Y = {Scale = instance.CellPadding.Y.Scale, Offset = instance.CellPadding.Y.Offset}
        }
        props.FillDirection = instance.FillDirection.Name
        props.FillDirectionMaxCells = instance.FillDirectionMaxCells
        props.HorizontalAlignment = instance.HorizontalAlignment.Name
        props.VerticalAlignment = instance.VerticalAlignment.Name
        props.SortOrder = instance.SortOrder.Name
    end

    if instance:IsA("UIPageLayout") then
        props.Animated = instance.Animated
        props.Circular = instance.Circular
        props.EasingDirection = instance.EasingDirection.Name
        props.EasingStyle = instance.EasingStyle.Name
        props.Padding = {Scale = instance.Padding.Scale, Offset = instance.Padding.Offset}
        props.TweenTime = instance.TweenTime
        props.FillDirection = instance.FillDirection.Name
    end

    if instance:IsA("UITableLayout") then
        props.FillEmptySpaceColumns = instance.FillEmptySpaceColumns
        props.FillEmptySpaceRows = instance.FillEmptySpaceRows
        props.FillDirection = instance.FillDirection.Name
        props.HorizontalAlignment = instance.HorizontalAlignment.Name
        props.VerticalAlignment = instance.VerticalAlignment.Name
        props.SortOrder = instance.SortOrder.Name
        props.MajorAxis = instance.MajorAxis.Name
    end

    if instance:IsA("UIPadding") then
        props.PaddingTop = {Scale = instance.PaddingTop.Scale, Offset = instance.PaddingTop.Offset}
        props.PaddingBottom = {Scale = instance.PaddingBottom.Scale, Offset = instance.PaddingBottom.Offset}
        props.PaddingLeft = {Scale = instance.PaddingLeft.Scale, Offset = instance.PaddingLeft.Offset}
        props.PaddingRight = {Scale = instance.PaddingRight.Scale, Offset = instance.PaddingRight.Offset}
    end

    if instance:IsA("UICorner") then
        props.CornerRadius = {Scale = instance.CornerRadius.Scale, Offset = instance.CornerRadius.Offset}
    end

    if instance:IsA("UIStroke") then
        props.Color = {R = instance.Color.R, G = instance.Color.G, B = instance.Color.B}
        props.Thickness = instance.Thickness
        props.Transparency = instance.Transparency
        props.ApplyStrokeMode = instance.ApplyStrokeMode.Name
        props.LineJoinMode = instance.LineJoinMode.Name
    end

    if instance:IsA("UIGradient") then
        props.Rotation = instance.Rotation
        props.Offset = {X = instance.Offset.X, Y = instance.Offset.Y}
        props.HasGradient = true
    end

    if instance:IsA("UIAspectRatioConstraint") then
        props.AspectRatio = instance.AspectRatio
        props.AspectType = instance.AspectType.Name
        props.DominantAxis = instance.DominantAxis.Name
    end

    if instance:IsA("UISizeConstraint") then
        props.MinSize = {X = instance.MinSize.X, Y = instance.MinSize.Y}
        props.MaxSize = {X = instance.MaxSize.X, Y = instance.MaxSize.Y}
    end

    if instance:IsA("UITextSizeConstraint") then
        props.MinTextSize = instance.MinTextSize
        props.MaxTextSize = instance.MaxTextSize
    end

    if instance:IsA("UIScale") then
        props.Scale = instance.Scale
    end

    return props
end

-- iterative structure export
local function exportGameStructure()
    local structure = {
        gameName = game.Name,
        placeId = game.PlaceId,
        exportTime = os.date("%Y-%m-%d %H:%M:%S"),
        services = {}
    }

    local stats = {instances = 0, parts = 0, models = 0, constraints = 0, attachments = 0, guiObjects = 0}

    local exportServices = {
        "Workspace", "ReplicatedStorage", "ServerStorage",
        "StarterGui", "StarterPack", "StarterPlayer",
        "Lighting", "SoundService"
    }

    for _, serviceName in ipairs(exportServices) do
        local ok, service = pcall(game.GetService, game, serviceName)
        if not ok or not service then continue end

        local serviceData = {
            name = serviceName,
            className = "Service",
            children = {}
        }

        local stack = {}

        for _, child in ipairs(service:GetChildren()) do
            if child.Name ~= "Terrain" and not child:IsA("Camera") then
                table.insert(stack, {instance = child, resultTable = serviceData.children})
            end
        end

        local processed = 0
        local MAX_INSTANCES = 50000

        while #stack > 0 and processed < MAX_INSTANCES do
            local item = table.remove(stack)
            local inst = item.instance
            local resultTable = item.resultTable

            if inst.Name:sub(1,1) == "_" then continue end

            local success, instData = pcall(getFullProperties, inst)
            if not success then
                instData = {
                    Name = inst.Name,
                    ClassName = inst.ClassName,
                    Error = "Failed to read properties"
                }
            end
            instData.children = {}

            stats.instances += 1
            if inst:IsA("BasePart") then stats.parts += 1 end
            if inst:IsA("Model") then stats.models += 1 end
            if inst:IsA("Constraint") then stats.constraints += 1 end
            if inst:IsA("Attachment") then stats.attachments += 1 end
            if inst:IsA("GuiObject") or inst:IsA("LayerCollector") then stats.guiObjects += 1 end

            table.insert(resultTable, instData)

            local children = inst:GetChildren()
            if #children > 0 then
                for _, child in ipairs(children) do
                    table.insert(stack, {instance = child, resultTable = instData.children})
                end
            else
                instData.children = nil
            end

            processed += 1

            if processed % 500 == 0 then
                log("Exporting... " .. processed .. " instances", COLORS.logInfo)
                task.wait()
            end
        end

        structure.services[serviceName] = serviceData

        if processed >= MAX_INSTANCES then
            log("Warning: Hit max instance limit (" .. MAX_INSTANCES .. ")", COLORS.logWarning)
            break
        end
    end

    structure.stats = stats
    log("Export scan complete: " .. stats.instances .. " instances found", COLORS.logInfo)
    return structure, stats
end

local sanitizeSource = sanitizeString

-- non-recursive serialization using stack
local function serializeInstance(rootInstance)
    local result = {}
    local stack = {{instance = rootInstance, node = result, depth = 0}}

    while #stack > 0 do
        local current = table.remove(stack)
        local instance = current.instance
        local node = current.node
        local depth = current.depth

        if depth > 100 then continue end

        node["$className"] = instance.ClassName

        if SCRIPT_CLASSES[instance.ClassName] then
            node["$source"] = sanitizeSource(instance.Source)
        else
            local props = getProperties(instance)
            if next(props) then
                node["$properties"] = props
            end
        end

        local nameCount = {}
        local children = instance:GetChildren()

        for _, child in ipairs(children) do
            if not child:IsA("Camera") and child.Name ~= "Terrain" then
                local baseName = child.Name
                nameCount[baseName] = (nameCount[baseName] or 0) + 1

                local key = baseName
                if nameCount[baseName] > 1 then
                    key = baseName .. " (" .. nameCount[baseName] .. ")"
                end

                local childNode = {}
                if key ~= baseName then
                    childNode["$originalName"] = baseName
                end

                node[key] = childNode
                table.insert(stack, {instance = child, node = childNode, depth = depth + 1})
            end
        end
    end

    return result
end

-- scripts-only serialization
local function serializeScriptsOnly()
    local scripts = {}
    local scriptCount = 0

    for _, serviceName in ipairs(SYNC_SERVICES) do
        local ok, service = pcall(game.GetService, game, serviceName)
        if ok and service then
            for _, instance in ipairs(service:GetDescendants()) do
                if SCRIPT_CLASSES[instance.ClassName] then
                    local pathParts = {}
                    local current = instance
                    while current and current ~= service do
                        table.insert(pathParts, 1, current.Name)
                        current = current.Parent
                    end

                    local path = serviceName .. "/" .. table.concat(pathParts, "/")
                    table.insert(scripts, {
                        path = path,
                        className = instance.ClassName,
                        source = sanitizeSource(instance.Source)
                    })
                    scriptCount += 1
                end
            end
        end
    end

    return {
        name = getProjectName(),
        scriptsOnly = true,
        scripts = scripts
    }, scriptCount
end

local function serializeDataModel()
    if scriptsOnlyMode then
        return serializeScriptsOnly()
    end

    local tree = {}
    local scriptCount = 0

    for _, serviceName in ipairs(SYNC_SERVICES) do
        local ok, service = pcall(game.GetService, game, serviceName)
        if ok and service then
            local node = serializeInstance(service)
            if node then
                tree[serviceName] = node
            end
        end
    end

    local function countScripts(t)
        for k, v in pairs(t) do
            if k == "$className" and SCRIPT_CLASSES[v] then
                scriptCount += 1
            elseif type(v) == "table" then
                countScripts(v)
            end
        end
    end
    countScripts(tree)

    return {
        name = getProjectName(),
        tree = tree
    }, scriptCount
end

-- ============ DESERIALIZATION ============

local function getScriptTypeFromExtension(filename)
    if filename:match("%.server%.lua$") then
        return "Script", filename:gsub("%.server%.lua$", "")
    elseif filename:match("%.client%.lua$") then
        return "LocalScript", filename:gsub("%.client%.lua$", "")
    elseif filename:match("%.module%.lua$") then
        return "ModuleScript", filename:gsub("%.module%.lua$", "")
    elseif filename:match("%.lua$") then
        return nil, filename:gsub("%.lua$", "")
    end
    return nil, filename
end

local function determineScriptTypeFromLocation(serviceName, pathParts)
    if serviceName == "ServerScriptService" or serviceName == "ServerStorage" then
        return "Script"
    elseif serviceName == "StarterPlayer" then
        local sub = pathParts[2]
        if sub == "StarterPlayerScripts" or sub == "StarterCharacterScripts" then
            return "LocalScript"
        end
    elseif serviceName == "StarterGui" or serviceName == "StarterPack" then
        return "LocalScript"
    elseif serviceName == "ReplicatedFirst" then
        return "LocalScript"
    end
    return "ModuleScript"
end

local function parseDuplicateSuffix(name)
    local baseName, indexStr = name:match("^(.+) %((%d+)%)$")
    if baseName and indexStr then
        return baseName, tonumber(indexStr)
    end
    return name, 1
end

local function findNthChild(parent, baseName, index)
    local count = 0
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == baseName then
            count = count + 1
            if count == index then
                return child
            end
        end
    end
    return nil
end

local function applyChanges(changes)
    if #changes == 0 then return 0 end

    local applied = 0
    ChangeHistoryService:SetWaypoint("Reagent: Applying " .. #changes .. " changes")

    for _, change in ipairs(changes) do
        local rawPath = change.path
        local pathParts = string.split(rawPath, "/")

        if #pathParts >= 1 then
            local serviceName = pathParts[1]
            local ok, service = pcall(game.GetService, game, serviceName)

            if ok and service then
                local parent = service

                for i = 2, #pathParts - 1 do
                    local childName = pathParts[i]
                    local baseName, dupIndex = parseDuplicateSuffix(childName)
                    local child = findNthChild(parent, baseName, dupIndex)

                    if not child then
                        child = parent:FindFirstChild(childName)
                    end

                    if not child then
                        child = Instance.new("Folder")
                        child.Name = baseName
                        child.Parent = parent
                    end

                    parent = child
                end

                local lastPart = pathParts[#pathParts]
                local scriptTypeFromExt, scriptNameWithSuffix = getScriptTypeFromExtension(lastPart)
                local baseName, dupIndex = parseDuplicateSuffix(scriptNameWithSuffix)
                local existing = findNthChild(parent, baseName, dupIndex)

                if change.type == "unlink" then
                    if existing then
                        local parentFolder = existing.Parent
                        existing:Destroy()
                        applied += 1
                        log("Deleted: " .. baseName, COLORS.logError)

                        while parentFolder and #parentFolder:GetChildren() == 0 do
                            local isService = pcall(function() return game:GetService(parentFolder.Name) end)
                            if isService and game:FindFirstChild(parentFolder.Name) == parentFolder then
                                break
                            end
                            local nextParent = parentFolder.Parent
                            local folderName = parentFolder.Name
                            parentFolder:Destroy()
                            log("Removed empty folder: " .. folderName, COLORS.logDefault)
                            parentFolder = nextParent
                        end
                    end
                else
                    local scriptType = scriptTypeFromExt or determineScriptTypeFromLocation(serviceName, pathParts)

                    if not existing then
                        existing = Instance.new(scriptType)
                        existing.Name = baseName
                        existing.Parent = parent
                        log("Created: " .. baseName .. " (" .. scriptType .. ")", COLORS.logSuccess)
                    elseif existing.ClassName == "Folder" and SCRIPT_CLASSES[scriptType] then
                        local children = existing:GetChildren()
                        local newScript = Instance.new(scriptType)
                        newScript.Name = baseName
                        newScript.Parent = parent
                        for _, child in ipairs(children) do
                            child.Parent = newScript
                        end
                        existing:Destroy()
                        existing = newScript
                        log("Converted folder to " .. scriptType .. ": " .. baseName, COLORS.logSuccess)
                    end

                    if existing and SCRIPT_CLASSES[existing.ClassName] then
                        existing.Source = change.source or ""
                        applied += 1
                    end
                end
            end
        end
    end

    ChangeHistoryService:SetWaypoint("Reagent: Applied " .. applied .. " changes")
    return applied
end

-- ============ SYNC LOGIC ============

local function checkConnection()
    local data, err = request("GET", "/ping", nil, 10)

    if data and data.status == "ok" then
        local knownToServer = false
        if data.connectedStudios and data.connectedStudios > 0 then
            knownToServer = true
        end

        if not knownToServer and currentProjectName then
            pcall(function()
                request("POST", "/studio-connect", {
                    project = currentProjectName,
                    placeId = game.PlaceId,
                    placeName = game.Name
                }, 5)
            end)
        end

        connected = true
        local pending = data.pendingChanges or 0
        local statsStr = pending > 0 and (pending .. " pending changes") or "Ready"
        updateStatus("Connected", true, statsStr)
        return true
    else
        connected = false
        updateStatus("Disconnected", false)
        return false
    end
end

local function doSync(projectName)
    syncing = true

    projectInput.Text = projectName

    showProgress(0, "Serializing...")
    log("Serializing project...", COLORS.logInfo)

    task.spawn(function()
        local data, scriptCount = serializeDataModel()
        showProgress(30, "Sending " .. scriptCount .. " scripts...")
        log("Sending " .. scriptCount .. " scripts...", COLORS.logInfo)

        local response, err = request("POST", "/sync", data)

        if response and response.success then
            local finalProjectName = response.project or projectName

            showProgress(35, "Server writing files...")
            log("Server writing " .. scriptCount .. " scripts...", COLORS.logInfo)

            local pollAttempts = 0
            local maxAttempts = 600
            local lastPercent = 0

            while pollAttempts < maxAttempts do
                task.wait(0.5)
                pollAttempts = pollAttempts + 1

                local progress = request("GET", "/sync-progress?project=" .. HttpService:UrlEncode(finalProjectName), nil, 5)

                if progress then
                    local pct = progress.percent or 0
                    if pct > lastPercent then
                        local displayPct = 35 + (pct * 0.6)
                        showProgress(displayPct, progress.message or ("Writing... " .. pct .. "%"))
                        lastPercent = pct
                    end

                    if progress.status == "complete" or not progress.active then
                        completeProgress()
                        log("Sync complete! " .. scriptCount .. " scripts", COLORS.logSuccess)
                        log("Project: " .. tostring(finalProjectName), COLORS.logInfo)
                        break
                    end
                else
                    completeProgress()
                    log("Sync complete! " .. scriptCount .. " scripts", COLORS.logSuccess)
                    break
                end
            end

            if pollAttempts >= maxAttempts then
                log("Sync timeout - check server logs", COLORS.logWarning)
            end

            statsLabel.Text = scriptCount .. " scripts synced"
            updateProjectDisplay(finalProjectName)
            rememberProject(game.PlaceId, finalProjectName)

            if not scriptsOnlyMode then
                log("Auto-exporting structure...", COLORS.logInfo)
                task.spawn(function()
                    local structure, stats = exportGameStructure()
                    structure.projectName = finalProjectName

                    local structResponse = request("POST", "/export-structure", structure)
                    if structResponse and structResponse.success then
                        log("Structure exported: " .. stats.instances .. " instances", COLORS.logSuccess)
                    else
                        log("Structure export failed", COLORS.logError)
                    end
                end)
            end
        else
            log("Sync failed: " .. tostring(err), COLORS.logError)
        end

        task.delay(0.5, hideProgress)
        syncing = false
    end)
end

local function syncToServer()
    if syncing then return end

    local projectName = getProjectName()

    if projectName then
        doSync(projectName)
    else
        log("Place is unsaved, requesting project name...", COLORS.logInfo)
        showProjectDialog(function(name)
            log("Project name set: " .. name, COLORS.logSuccess)
            doSync(name)
        end)
    end
end

local function pullFromServer()
    if syncing then return end

    local projectName = getProjectName()
    if not projectName then
        log("No project name set - sync first or enter name", COLORS.logError)
        return
    end

    syncing = true
    log("Checking for changes...", COLORS.logInfo)

    task.spawn(function()
        local data, err = request("GET", "/changes?project=" .. HttpService:UrlEncode(projectName))

        if data and data.changes then
            local count = #data.changes
            if count > 0 then
                log("Applying " .. count .. " changes...", COLORS.logInfo)
                local applied = applyChanges(data.changes)
                log("Applied " .. applied .. " changes", COLORS.logSuccess)
            else
                log("No pending changes", COLORS.logDefault)
            end
        else
            log("Pull failed: " .. tostring(err), COLORS.logError)
        end

        syncing = false
    end)
end

-- forward declaration
local applyStructureChange

local function pollForChanges()
    if not connected or syncing then return end

    local projectName = getProjectName()
    if not projectName then return end

    local now = tick()
    if now - lastPoll < POLL_INTERVAL then return end
    lastPoll = now

    task.spawn(function()
        local data = request("GET", "/changes?project=" .. HttpService:UrlEncode(projectName))

        if data and data.changes and #data.changes > 0 then
            local count = #data.changes
            log("Auto-sync: " .. count .. " script changes", COLORS.logInfo)
            applyChanges(data.changes)
        end

        local structData = request("GET", "/structure-changes?project=" .. HttpService:UrlEncode(projectName) .. "&clear=true")

        if structData and structData.changes and #structData.changes > 0 then
            local count = #structData.changes
            log("Auto-sync: " .. count .. " structure changes", COLORS.logInfo)

            local applied = 0
            local failed = 0

            for _, change in ipairs(structData.changes) do
                local success, result = applyStructureChange(change)
                if success then
                    applied = applied + 1
                else
                    failed = failed + 1
                    log("  Failed: " .. tostring(result), COLORS.logError)
                end
            end

            if applied > 0 then
                log("Applied " .. applied .. " structure changes", COLORS.logSuccess)
            end
        end
    end)
end

-- ============ EVENT HANDLERS ============

connectBtn.MouseButton1Click:Connect(function()
    if connected then
        connected = false
        updateStatus("Disconnected", false)
        log("Disconnected", COLORS.logDefault)
        pcall(function()
            request("POST", "/studio-disconnect", {
                project = getProjectName(),
                placeId = game.PlaceId
            }, 5)
        end)
    else
        log("Connecting...", COLORS.logInfo)
        connectBtn.Text = "..."
        local projectName = getProjectName()
        local data, err = request("POST", "/studio-connect", {
            project = projectName,
            placeId = game.PlaceId,
            placeName = game.Name
        }, 10)

        if data and data.status == "ok" then
            connected = true
            updateStatus("Connected", true, "Ready")
            log("Connected to Reagent server", COLORS.logSuccess)
            if projectName then
                log("Project: " .. projectName, COLORS.logInfo)
            end
            -- auto-sync on connect
            syncToServer()
        else
            connected = false
            updateStatus("Disconnected", false)
            connectBtn.Text = "connect"
            log("Connection failed - is server running?", COLORS.logError)
        end
    end
end)

-- ============ IMPORT STRUCTURE FUNCTIONALITY ============

local ENUM_MAPPINGS = {
    Font = Enum.Font,
    TextXAlignment = Enum.TextXAlignment,
    TextYAlignment = Enum.TextYAlignment,
    ScaleType = Enum.ScaleType,
    FillDirection = Enum.FillDirection,
    HorizontalAlignment = Enum.HorizontalAlignment,
    VerticalAlignment = Enum.VerticalAlignment,
    SortOrder = Enum.SortOrder,
    ScrollingDirection = Enum.ScrollingDirection,
    ElasticBehavior = Enum.ElasticBehavior,
    ZIndexBehavior = Enum.ZIndexBehavior,
    AutomaticSize = Enum.AutomaticSize,
    AspectType = Enum.AspectType,
    DominantAxis = Enum.DominantAxis,
    ApplyStrokeMode = Enum.ApplyStrokeMode,
    LineJoinMode = Enum.LineJoinMode,
    EasingDirection = Enum.EasingDirection,
    EasingStyle = Enum.EasingStyle,
    ResamplerMode = Enum.ResamplerMode,
    SizeConstraint = Enum.SizeConstraint,
    BorderMode = Enum.BorderMode,
    Material = Enum.Material,
    Shape = Enum.PartType,
    Face = Enum.NormalId,
    ActuatorType = Enum.ActuatorType,
    SurfaceType = Enum.SurfaceType,
}

local function tryConvertEnum(propName, value)
    if type(value) ~= "string" then
        return value
    end

    local enumType = ENUM_MAPPINGS[propName]
    if enumType then
        local success, enumValue = pcall(function()
            return enumType[value]
        end)
        if success and enumValue then
            return enumValue
        end
    end

    return value
end

-- structure change resolveInstancePath (more thorough service resolution)
local function resolveStructurePath(pathStr)
    local parts = string.split(pathStr, ".")
    local current = nil

    for i, part in ipairs(parts) do
        if i == 1 then
            if part == "Workspace" then
                current = workspace
            elseif part == "ReplicatedStorage" then
                current = game:GetService("ReplicatedStorage")
            elseif part == "ServerStorage" then
                current = game:GetService("ServerStorage")
            elseif part == "StarterPlayer" then
                current = game:GetService("StarterPlayer")
            elseif part == "StarterGui" then
                current = game:GetService("StarterGui")
            elseif part == "Lighting" then
                current = game:GetService("Lighting")
            else
                current = game:FindFirstChild(part)
            end
        else
            if current then
                current = current:FindFirstChild(part)
            end
        end

        if not current then
            return nil
        end
    end

    return current
end

local function createStructureInstance(change)
    local parent = resolveStructurePath(change.parent)
    if not parent then
        return false, "Parent not found: " .. tostring(change.parent)
    end

    local instanceType = change.instanceType
    local props = change.properties or {}

    local success, instance = pcall(function()
        return Instance.new(instanceType)
    end)

    if not success then
        return false, "Failed to create " .. instanceType
    end

    for propName, propValue in pairs(props) do
        if propName ~= "Parent" then
            pcall(function()
                if type(propValue) == "table" then
                    if propValue.X and propValue.Y and propValue.Z then
                        instance[propName] = Vector3.new(propValue.X, propValue.Y, propValue.Z)
                    elseif propValue.X and propValue.Y and type(propValue.X) == "table" then
                        instance[propName] = UDim2.new(
                            propValue.X.Scale or 0, propValue.X.Offset or 0,
                            propValue.Y.Scale or 0, propValue.Y.Offset or 0
                        )
                    elseif propValue.X and propValue.Y and not propValue.Z then
                        instance[propName] = Vector2.new(propValue.X, propValue.Y)
                    elseif propValue.Scale ~= nil and propValue.Offset ~= nil then
                        instance[propName] = UDim.new(propValue.Scale, propValue.Offset)
                    elseif propValue.R and propValue.G and propValue.B then
                        instance[propName] = Color3.new(propValue.R, propValue.G, propValue.B)
                    elseif propValue.Position and propValue.LookVector then
                        local pos = propValue.Position
                        local look = propValue.LookVector
                        instance[propName] = CFrame.lookAt(
                            Vector3.new(pos.X, pos.Y, pos.Z),
                            Vector3.new(pos.X + look.X, pos.Y + look.Y, pos.Z + look.Z)
                        )
                    elseif propValue._path then
                        local ref = resolveStructurePath(propValue._path)
                        if ref then
                            instance[propName] = ref
                        end
                    end
                else
                    instance[propName] = tryConvertEnum(propName, propValue)
                end
            end)
        end
    end

    instance.Parent = parent
    return true, instance
end

local function modifyStructureInstance(change)
    local target = resolveStructurePath(change.target)
    if not target then
        return false, "Target not found: " .. tostring(change.target)
    end

    local props = change.properties or {}
    local modified = 0

    for propName, propValue in pairs(props) do
        local success = pcall(function()
            if type(propValue) == "table" then
                if target:IsA("Model") and (propName == "CFrame" or propName == "Orientation") then
                    local currentPivot = target:GetPivot()
                    local pos = currentPivot.Position
                    local rot = currentPivot - currentPivot.Position

                    if propValue.Position then
                        pos = Vector3.new(
                            propValue.Position.X or pos.X,
                            propValue.Position.Y or pos.Y,
                            propValue.Position.Z or pos.Z
                        )
                    end

                    if propValue.Rotation then
                        rot = CFrame.Angles(
                            math.rad(propValue.Rotation.X or 0),
                            math.rad(propValue.Rotation.Y or 0),
                            math.rad(propValue.Rotation.Z or 0)
                        )
                    elseif propName == "Orientation" and propValue.X and propValue.Y and propValue.Z then
                        rot = CFrame.Angles(math.rad(propValue.X), math.rad(propValue.Y), math.rad(propValue.Z))
                    end

                    target:PivotTo(CFrame.new(pos) * rot)
                elseif propValue.X and propValue.Y and propValue.Z then
                    target[propName] = Vector3.new(propValue.X, propValue.Y, propValue.Z)
                elseif propValue.X and propValue.Y and type(propValue.X) == "table" then
                    target[propName] = UDim2.new(
                        propValue.X.Scale or 0, propValue.X.Offset or 0,
                        propValue.Y.Scale or 0, propValue.Y.Offset or 0
                    )
                elseif propValue.X and propValue.Y and not propValue.Z then
                    target[propName] = Vector2.new(propValue.X, propValue.Y)
                elseif propValue.Scale ~= nil and propValue.Offset ~= nil then
                    target[propName] = UDim.new(propValue.Scale, propValue.Offset)
                elseif propValue.R and propValue.G and propValue.B then
                    target[propName] = Color3.new(propValue.R, propValue.G, propValue.B)
                elseif propValue._path then
                    local ref = resolveStructurePath(propValue._path)
                    if ref then
                        target[propName] = ref
                    end
                end
            else
                target[propName] = tryConvertEnum(propName, propValue)
            end
        end)
        if success then
            modified = modified + 1
        end
    end

    return true, modified
end

local function deleteStructureInstance(change)
    local target = resolveStructurePath(change.target)
    if not target then
        return false, "Target not found: " .. tostring(change.target)
    end

    target:Destroy()
    return true
end

function applyStructureChange(change)
    if change.type == "create" then
        return createStructureInstance(change)
    elseif change.type == "modify" then
        return modifyStructureInstance(change)
    elseif change.type == "delete" then
        return deleteStructureInstance(change)
    else
        return false, "Unknown change type: " .. tostring(change.type)
    end
end

-- ============ MAIN LOOP ============

RunService.Heartbeat:Connect(function()
    if connected and autoSync then
        pollForChanges()
    end
end)

-- connection heartbeat (every 15 seconds)
task.spawn(function()
    while true do
        task.wait(15)
        if connected then
            checkConnection()
        end
    end
end)

-- mcp command polling (long poll, tight interval for cloud ai)
task.spawn(function()
    while true do
        local startTime = tick()
        local gotCommands = pollMcpCommands()
        local elapsed = tick() - startTime

        if gotCommands then
            task.wait(0.05)
        elseif elapsed < 1 then
            task.wait(0.3)
        else
            task.wait(0.05)
        end
    end
end)

-- log flushing
task.spawn(function()
    while true do
        task.wait(2)
        flushLogs()
    end
end)

-- init
initProjectNameField()

log("reagent v" .. VERSION .. " ready", COLORS.logSuccess)
log("cloud ai connector", COLORS.logInfo)
if projectInput.Text ~= "" then
    log("project: " .. projectInput.Text, COLORS.logInfo)
end
log("click connect to start", COLORS.logDefault)
