-- PartFlingerServer — LinoriaLib Version (reviewed + cursor-nuke)
-- Requires executor context for loadstring/HttpGet.

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UserInput   = game:GetService("UserInputService")
local Workspace   = workspace

-- ============================================================
-- CONFIG
-- ============================================================
local CFG = {
    FlingForce    = 900,
    FlingUp       = 250,
    FlingSpin     = 8,
    BringSpeed    = 80,
    TouchDistance = 1.5,
    MaxParts      = 120,
    MaxRange      = 250,
    SnapToTouch   = true,
    FlyForce      = 300,
    FlyLift       = 3,
    NukeForce     = 4000,
    VelocityCap   = 2000,
    RequireAdmin  = false,
    Admins        = { --[[ 123456789, ]] },
}

local META = {
    FlingForce={50,3000,50}, FlingUp={0,1000,25}, FlingSpin={0,50,2},
    BringSpeed={5,300,10}, TouchDistance={0.5,8,0.5},
    MaxParts={10,500,10}, MaxRange={50,1000,50},
    FlyForce={50,2000,50}, FlyLift={1,10,1},
    NukeForce={1000,20000,500}, VelocityCap={200,10000,200},
}

local PRESETS = {
    default = {FlingForce=900,FlingUp=250,FlingSpin=8,BringSpeed=80,TouchDistance=1.5,
               MaxParts=120,MaxRange=250,SnapToTouch=true,FlyForce=300,FlyLift=3,
               NukeForce=4000,VelocityCap=2000},
    gentle  = {FlingForce=200,FlingUp=80,FlingSpin=2,BringSpeed=40,TouchDistance=3,
               MaxParts=50,MaxRange=150,SnapToTouch=false,FlyForce=150,FlyLift=4,
               NukeForce=1500,VelocityCap=800},
    violent = {FlingForce=2500,FlingUp=800,FlingSpin=30,BringSpeed=200,TouchDistance=0.8,
               MaxParts=300,MaxRange=500,SnapToTouch=true,FlyForce=800,FlyLift=2,
               NukeForce=12000,VelocityCap=5000},
    fly     = {FlingForce=100,FlingUp=50,FlingSpin=0,BringSpeed=100,TouchDistance=2,
               MaxParts=60,MaxRange=200,SnapToTouch=true,FlyForce=350,FlyLift=3,
               NukeForce=2000,VelocityCap=1500},
}

local MODE_KEYS = {"fling","bring","fly","multi","others"}

local function applyPreset(name)
    local p = PRESETS[name]; if not p then return end
    for k, v in pairs(p) do CFG[k] = v end
end

-- ============================================================
-- STATE
-- ============================================================
local P = {}   -- [player] = {state, target, ui}

local function isAdmin(plr)
    if not CFG.RequireAdmin then return true end
    for _, id in ipairs(CFG.Admins) do if plr.UserId == id then return true end end
    return false
end

local function resolvePlayer(plr, txt)
    txt = (txt or ""):gsub("^%s+",""):gsub("%s+$",""):lower()
    if txt == "" or txt == "me" or txt == "self" then return plr end
    for _, p in ipairs(Players:GetPlayers()) do if p.Name:lower()==txt then return p end end
    for _, p in ipairs(Players:GetPlayers()) do if p.Name:lower():sub(1,#txt)==txt then return p end end
    return nil
end

local function alivePlayers()
    local t = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local ch = p.Character
        if ch and ch:FindFirstChild("HumanoidRootPart") then
            local h = ch:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then t[#t+1] = p end
        end
    end
    return t
end

-- ============================================================
-- LOAD LINORIALIB
-- ============================================================
local repo = 'https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/'

local function safeloadstring(url)
    local code = game:HttpGet(url)
    local func, err = loadstring(code)
    if func then
        print("[PartFlinger] LinoriaLib compiled, executing...")
        return func()
    else
        warn("[PartFlinger] LOADSTRING FAILED: " .. tostring(err))
        return nil
    end
end

local Library = safeloadstring(repo .. 'Library.lua')
if not Library then error("Could not load LinoriaLib") end

-- ============================================================
-- PHYSICS HELPERS
-- ============================================================
local function capVel(v)
    if v.Magnitude > CFG.VelocityCap then return v.Unit * CFG.VelocityCap end
    return v
end

local function betterFling(part, fromPos, refVel)
    local delta = part.Position - fromPos
    local dist = delta.Magnitude
    local dir = (dist > 0.1) and delta.Unit or Vector3.new(0,1,0)
    local relVel = (refVel or Vector3.zero) * 0.5
    local v = dir * CFG.FlingForce
        + Vector3.new(0, CFG.FlingUp, 0)
        + relVel
    part.AssemblyLinearVelocity = capVel(v)
    local spin = CFG.FlingSpin
    part.AssemblyAngularVelocity = Vector3.new(
        math.random(-spin, spin),
        math.random(-spin, spin),
        math.random(-spin, spin)
    )
    if not part.CanCollide then part.CanCollide = true end
end

local function bringPart(part, hrp)
    local delta = part.Position - hrp.Position
    local dist = delta.Magnitude
    if not part.CanCollide then part.CanCollide = true end
    if dist > CFG.TouchDistance then
        part.AssemblyLinearVelocity = capVel((-delta).Unit * CFG.BringSpeed)
        if CFG.SnapToTouch and dist < 30 then
            part.CFrame = CFrame.new(hrp.Position + delta.Unit*CFG.TouchDistance) * part.CFrame.Rotation
        end
    else
        local dir = (dist > 0.05) and delta.Unit or Vector3.new(0,1,0)
        part.CFrame = CFrame.new(hrp.Position + dir*CFG.TouchDistance) * part.CFrame.Rotation
        part.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity
    end
end

-- Collect unanchored, non-humanoid parts within radius of origin.
-- Single shared scan used by fling/bring/multi/others.
local function nearbyUnanchoredParts(origin, radius, limit)
    local out = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and not obj.Anchored then
            local m = obj:FindFirstAncestorOfClass("Model")
            if not (m and m:FindFirstChildOfClass("Humanoid")) then
                if (obj.Position - origin).Magnitude <= radius then
                    out[#out+1] = obj
                    if #out >= limit then break end
                end
            end
        end
    end
    return out
end

-- ============================================================
-- CURSOR / MOUSE HELPERS
-- ============================================================
-- Returns a 3D world point representing "where the user is pointing",
-- accounting for desktop mouse, mobile touch, and fallback to character.
local function getCursorWorldPoint(plr)
    local camera = Workspace.CurrentCamera
    local ch = plr.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local fallback = hrp and hrp.Position or camera.CFrame.Position + camera.CFrame.LookVector * 100

    if not camera then return fallback end

    -- Screen point: mouse on desktop, screen center on touch-only devices
    local screenPoint
    if UserInput.MouseEnabled then
        screenPoint = UserInput:GetMouseLocation()
    else
        local vp = camera.ViewportSize
        screenPoint = Vector2.new(vp.X / 2, vp.Y / 2)
    end

    local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)

    -- Raycast against world geometry (ignoring the player's own character)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ch and {ch} or {}
    params.IgnoreWater = true

    local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
    if result and result.Position then
        return result.Position
    end

    -- Fallback: mouse.Hit (works in some executors where UIS raycast is odd)
    local mouse = plr:GetMouse()
    if mouse and mouse.Hit then
        return mouse.Hit.Position
    end

    return fallback
end

-- Nuke all parts within `radius` of `origin`.
local function nukeAt(origin, radius)
    local nukeForce  = CFG.NukeForce
    local spin       = CFG.FlingSpin
    local upBias     = Vector3.new(0, nukeForce * 0.5, 0)
    local candidates = nearbyUnanchoredParts(origin, radius, math.huge)
    for _, obj in ipairs(candidates) do
        local d = obj.Position - origin
        local dir = (d.Magnitude > 0.1) and d.Unit or Vector3.new(0,1,0)
        obj.AssemblyLinearVelocity = capVel(dir * nukeForce + upBias)
        obj.AssemblyAngularVelocity = Vector3.new(
            math.random(-spin, spin),
            math.random(-spin, spin),
            math.random(-spin, spin)
        )
    end
    return #candidates
end

-- ============================================================
-- BUILD UI
-- ============================================================
local function buildUI(plr)
    local Window = Library:CreateWindow({
        Title = 'PART FLINGER',
        Center = true,
        AutoShow = true,
        TabPadding = 8,
        MenuFadeTime = 0.2,
    })

    local Tabs = {
        Controls = Window:AddTab('Controls'),
        Config   = Window:AddTab('Config'),
        Presets  = Window:AddTab('Presets'),
    }

    local state = {fling=false, bring=false, fly=false, multi=false, others=false}
    local entry = {state=state, target=nil, ui=Window}

    -- -------- Controls Tab --------
    local ctrlLeft  = Tabs.Controls:AddLeftGroupbox('Target')
    local ctrlRight = Tabs.Controls:AddRightGroupbox('Modes')

    -- Define label BEFORE the input callback that references it.
    local statusLabel = ctrlLeft:AddLabel('Status: Target = self | idle')

    ctrlLeft:AddInput('PF_Target', {
        Default = '',
        Numeric = false,
        Finished = false,
        Text = 'Username (blank = self)',
        Placeholder = 'username',
        Tooltip = 'Leave blank to target yourself',
        Callback = function(txt)
            local r = resolvePlayer(plr, txt)
            if txt:gsub('%s','') == '' then
                entry.target = nil
            elseif r then
                entry.target = r
            else
                entry.target = nil
            end
            local tgt = entry.target and entry.target.Name or 'self'
            statusLabel:SetText('Status: Target = ' .. tgt)
        end,
    })

    local function refreshStatus()
        local s = state
        local tgt = entry.target and entry.target.Name or 'self'
        if s.multi then tgt = 'ALL' end
        if s.others then tgt = 'OTHERS' end

        local modeStr = 'idle'
        if s.multi then modeStr = 'multi'
        elseif s.others then modeStr = 'others'
        else
            for _, m in ipairs({'fling','bring','fly'}) do
                if s[m] then modeStr = m; break end
            end
        end

        statusLabel:SetText('Status: Target = ' .. tgt .. ' | ' .. modeStr)
    end

    -- Mode toggles, guarded against re-entrancy from SetValue
    local switching = false
    local function onMode(k, newVal)
        if switching then return end
        if newVal then
            switching = true
            for _, m in ipairs(MODE_KEYS) do
                if m ~= k and state[m] then
                    state[m] = false
                    local t = Toggles['PF_Mode_' .. m]
                    if t then t:SetValue(false) end
                end
            end
            switching = false
        end
        state[k] = newVal
        refreshStatus()
    end

    for _, k in ipairs(MODE_KEYS) do
        ctrlRight:AddToggle('PF_Mode_' .. k, {
            Text = k:upper(),
            Default = false,
            Tooltip = 'Enable ' .. k .. ' mode',
        })
        Toggles['PF_Mode_' .. k]:OnChanged(function(v) onMode(k, v) end)
    end

    -- Actions
    local actionBox = Tabs.Controls:AddLeftGroupbox('Actions')

    actionBox:AddButton('STOP ALL', function()
        for _, m in ipairs(MODE_KEYS) do
            state[m] = false
            local t = Toggles['PF_Mode_' .. m]
            if t then t:SetValue(false) end
        end
        refreshStatus()
        Library:Notify('Stopped', 2)
    end)

    -- NUKE: cursor-targeted, radius = MaxRange * 2
    actionBox:AddButton('NUKE (at cursor)', function()
        -- Require a target with a character? No — nuke is a world action,
        -- so it doesn't need a target. It uses your cursor location.
        local origin = getCursorWorldPoint(plr)
        local count  = nukeAt(origin, CFG.MaxRange * 2)
        Library:Notify(string.format('Nuke: %d parts flung', count), 2)
    end)

    -- -------- Presets Tab --------
    local presetBox = Tabs.Presets:AddLeftGroupbox('Presets')
    local sliderRefs = {}

    for _, name in ipairs({'default','gentle','violent','fly'}) do
        presetBox:AddButton(name:upper() .. ' preset', function()
            applyPreset(name)
            for k, s in pairs(sliderRefs) do s:SetValue(CFG[k]) end
            Library:Notify(name:upper() .. ' applied', 2)
        end)
    end

    -- -------- Config Tab --------
    local configBox = Tabs.Config:AddLeftGroupbox('Config Sliders')

    for _, key in ipairs({
        'FlingForce','FlingUp','FlingSpin','BringSpeed','TouchDistance',
        'MaxParts','MaxRange','FlyForce','FlyLift','NukeForce','VelocityCap'
    }) do
        local lo, hi, st = META[key][1], META[key][2], META[key][3]
        local rounding = (st < 1) and 1 or 0
        configBox:AddSlider('PF_Cfg_' .. key, {
            Text = key,
            Default = CFG[key],
            Min = lo,
            Max = hi,
            Rounding = rounding,
            Compact = false,
            Callback = function(v)
                CFG[key] = math.clamp(math.floor(v / st + 0.5) * st, lo, hi)
            end,
        })
        sliderRefs[key] = Options['PF_Cfg_' .. key]
    end

    return entry
end

-- ============================================================
-- SETUP
-- ============================================================
local function setupPlayer(plr)
    if not isAdmin(plr) then return end
    local e = buildUI(plr)
    if not e then return end
    P[plr] = e
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local acc = 0
RunService.Heartbeat:Connect(function(dt)
    acc += dt
    if acc < 1/30 then return end
    acc = 0

    local alive = alivePlayers()

    -- Hoist per-tick constants out of inner loops
    local maxParts = CFG.MaxParts
    local maxRange = CFG.MaxRange

    for owner, e in pairs(P) do
        local s = e.state
        if not (s.fling or s.bring or s.fly or s.multi or s.others) then continue end

        local ref = e.target
        if ref and not ref.Parent then ref=nil; e.target=nil end
        local targetCh = (ref and ref.Character) or owner.Character
        local targetHrp = targetCh and targetCh:FindFirstChild('HumanoidRootPart')

        -- Multi / others distribution
        if (s.multi or s.others) and #alive > 0 then
            local recipients = {}
            for _, p in ipairs(alive) do
                if (not s.others) or p ~= owner then recipients[#recipients+1] = p end
            end
            if #recipients > 0 then
                -- Pick an arbitrary recipient as scan origin; anything is fine
                -- since we redistribute to all of them.
                local scanOrigin = targetHrp and targetHrp.Position
                    or (recipients[1].Character and recipients[1].Character:FindFirstChild('HumanoidRootPart')
                        and recipients[1].Character.HumanoidRootPart.Position)
                    or owner.Character.HumanoidRootPart.Position

                local parts = nearbyUnanchoredParts(scanOrigin, maxRange, maxParts)
                for i, obj in ipairs(parts) do
                    local targetPlr = recipients[(i - 1) % #recipients + 1]
                    local ch = targetPlr.Character
                    local h = ch and ch:FindFirstChild('HumanoidRootPart')
                    if h and (obj.Position - h.Position).Magnitude <= maxRange then
                        bringPart(obj, h)
                    end
                end
            end
            continue
        end

        if not targetHrp then continue end
        local origin = targetHrp.Position

        if s.fly then
            local up = Vector3.new(0,1,0)
            local parts = nearbyUnanchoredParts(origin, maxRange, maxParts)
            for _, obj in ipairs(parts) do
                if obj.Position.Y < origin.Y + 1 then
                    if not obj.CanCollide then obj.CanCollide = true end
                    obj.AssemblyLinearVelocity = up * CFG.FlyForce
                    local desired = Vector3.new(origin.X, origin.Y - CFG.FlyLift, origin.Z)
                    if (desired - obj.Position).Magnitude > 8 then
                        obj.CFrame = CFrame.new(desired)
                    end
                end
            end
            continue
        end

        -- Fling / bring: single scan, dispatch per mode
        local parts = nearbyUnanchoredParts(origin, maxRange, maxParts)
        for _, obj in ipairs(parts) do
            if s.fling then
                betterFling(obj, origin, targetHrp.AssemblyLinearVelocity)
            elseif s.bring then
                bringPart(obj, targetHrp)
            end
        end
    end
end)

-- ============================================================
-- LIFECYCLE
-- ============================================================
Players.PlayerAdded:Connect(setupPlayer)
for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
Players.PlayerRemoving:Connect(function(p)
    P[p] = nil
end)
