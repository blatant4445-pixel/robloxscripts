-- PartFlingerServer — SBEUI (Orbital UI) Version
-- Requires executor context for loadstring/HttpGet (UI library limitation).

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

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
-- LOAD SBEUI (ORBITAL UI)
-- ============================================================
local function safeloadstring(url)
    local code = game:HttpGet(url)
    local func, err = loadstring(code)
    if func then
        print("[PartFlinger] SBEUI compiled, executing...")
        return func()
    else
        warn("[PartFlinger] LOADSTRING FAILED: " .. tostring(err))
        return nil
    end
end

local UILibrary = safeloadstring(
    "https://raw.githubusercontent.com/SugaBlaz/UI-Library/refs/heads/main/Orbital%20UI.lua"
)
if not UILibrary then error("Could not load SBEUI library") end

-- ============================================================
-- PHYSICS HELPERS (defined early so UI callbacks can use them)
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
    part.AssemblyAngularVelocity = Vector3.new(
        math.random()*CFG.FlingSpin,
        math.random()*CFG.FlingSpin,
        math.random()*CFG.FlingSpin
    )
    part.CanCollide = true
end

local function bringPart(part, hrp)
    local delta = part.Position - hrp.Position
    local dist = delta.Magnitude
    part.CanCollide = true
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

-- ============================================================
-- BUILD UI FOR A PLAYER
-- ============================================================
local function buildUI(plr)
    local pg = plr:FindFirstChild("PlayerGui")
    if not pg then return nil end

    -- Clean up any old PartFlinger UI instance if present
    local old = pg:FindFirstChild("PartFlingerGui")
    if old then old:Destroy() end

    local ok, ui = pcall(function()
        return UILibrary.Main.new({
            TitleText = "PART FLINGER",
            Size = UDim2.new(0, 260, 0, 460),
            Position = UDim2.new(0, 20, 0.5, -230),
            SettingSize = UDim2.new(0, 260, 0, 260),
            TitleHeight = 30,
            CornerRadius = 6,
            ElementPadding = 6,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            SectionHeight = 20,
            UIStrokeThickness = 1,
            SliderColor = Color3.fromRGB(54, 54, 54),
            NotifcationSound = "",
            ResetOnSpawn = false,
            Addons = {},
            KeySystemEnabled = false,
            TabPadding = 10,
            UseOwnTheme = false,
            Theme = "Blood Moon",
            SaveOnExit = true,
        })
    end)

    if not ok or not ui then
        warn("[PartFlinger] Failed to create SBEUI window: " .. tostring(ui))
        return nil
    end

    ui:CreateUI()

    -- Rename the library-created ScreenGui so we can find/clean it up later
    local libGui
    for _, child in ipairs(pg:GetChildren()) do
        if child:IsA("ScreenGui") and child.Name ~= "PartFlingerGui" then
            -- Heuristic: the newest ScreenGui is the one SBEUI just made
            libGui = child
        end
    end
    if libGui then libGui.Name = "PartFlingerGui" end

    local state = {fling=false, bring=false, fly=false, multi=false, others=false}
    local entry = {state=state, target=nil, ui=ui, libGui=libGui}

    -- -------- Target + Status --------
    ui:AddSection("Target")
    local targetBox
    targetBox = ui:AddTextBox({
        Text = "Target username (blank = self)",
        Default = "",
        Placeholder = "username",
        Flag = "PF_Target",
        SavingEnabled = false,
        Callback = function(txt)
            local r = resolvePlayer(plr, txt)
            if txt:gsub("%s","") == "" then
                entry.target = nil; targetBox:Set("")
            elseif r then
                entry.target = r; targetBox:Set(r.Name)
            else
                entry.target = nil; targetBox:Set("")
            end
            ui:Notify({Title="Target", Text="Set to "..(entry.target and entry.target.Name or "self"), Duration=2})
        end,
    })

    local statusLabel = ui:AddLabel("Target: self | idle")

    local function refreshStatus()
        local s = state
        local tgt = entry.target and entry.target.Name or "self"
        if s.multi then tgt = "ALL" end
        if s.others then tgt = "OTHERS" end
        local modeStr = "idle"
        for _, m in ipairs({"fling","bring","fly"}) do
            if s[m] then modeStr = m; break end
        end
        statusLabel:Set("Target: "..tgt.." | "..modeStr)
    end

    -- -------- Modes --------
    ui:AddSection("Modes")
    local modeToggles = {}
    local function onMode(k, newVal)
        if newVal then
            for _, m in ipairs({"fling","bring","fly","multi","others"}) do
                if m ~= k and state[m] then
                    state[m] = false
                    if modeToggles[m] then modeToggles[m]:Set(false) end
                end
            end
        end
        state[k] = newVal
        refreshStatus()
    end

    for _, k in ipairs({"fling","bring","fly","multi","others"}) do
        modeToggles[k] = ui:AddToggle({
            Text = k:upper(),
            Default = false,
            Flag = "PF_Mode_"..k,
            SavingEnabled = false,
            Callback = function(v) onMode(k, v) end,
        })
    end

    -- -------- Actions --------
    ui:AddSection("Actions")

    local stopToggle
    stopToggle = ui:AddToggle({
        Text = "STOP ALL",
        Default = false,
        Flag = "PF_StopAll",
        SavingEnabled = false,
        Callback = function(v)
            if not v then return end
            for _, m in ipairs({"fling","bring","fly","multi","others"}) do
                state[m] = false
                if modeToggles[m] then modeToggles[m]:Set(false) end
            end
            refreshStatus()
            task.delay(0.3, function() stopToggle:Set(false) end)
        end,
    })

    local nukeToggle
    nukeToggle = ui:AddToggle({
        Text = "NUKE",
        Default = false,
        Flag = "PF_Nuke",
        SavingEnabled = false,
        Callback = function(v)
            if not v then return end
            local ref = entry.target
            local ch = (ref and ref.Character) or plr.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if not hrp then
                ui:Notify({Title="Nuke", Text="No character found", Duration=2})
                task.delay(0.3, function() nukeToggle:Set(false) end)
                return
            end
            local origin = hrp.Position
            for _, obj in ipairs(workspace:GetDescendants()) do
                if not obj:IsA("BasePart") or obj.Anchored then continue end
                local m = obj:FindFirstAncestorOfClass("Model")
                if m and m:FindFirstChildOfClass("Humanoid") then continue end
                local d = obj.Position - origin
                if d.Magnitude > CFG.MaxRange*2 then continue end
                local dir = (d.Magnitude > 0.1) and d.Unit or Vector3.new(0,1,0)
                obj.AssemblyLinearVelocity = capVel(dir*CFG.NukeForce + Vector3.new(0, CFG.NukeForce*0.5, 0))
                obj.AssemblyAngularVelocity = Vector3.new(math.random(-40,40),math.random(-40,40),math.random(-40,40))
            end
            ui:Notify({Title="Nuke", Text="Boom.", Duration=2})
            task.delay(0.3, function() nukeToggle:Set(false) end)
        end,
    })

    -- -------- Presets --------
    ui:AddSection("Presets")
    local sliderRefs = {}
    local function refreshSliders()
        for k, s in pairs(sliderRefs) do s:Set(CFG[k]) end
    end

    local presetToggles = {}
    for _, name in ipairs({"default","gentle","violent","fly"}) do
        presetToggles[name] = ui:AddToggle({
            Text = name:upper().." preset",
            Default = false,
            Flag = "PF_Preset_"..name,
            SavingEnabled = false,
            Callback = function(v)
                if not v then return end
                applyPreset(name)
                refreshSliders()
                ui:Notify({Title="Preset", Text=name:upper().." applied", Duration=2})
                task.delay(0.3, function() presetToggles[name]:Set(false) end)
            end,
        })
    end

    -- -------- Config Sliders --------
    ui:AddSection("Config")
    for _, key in ipairs({
        "FlingForce","FlingUp","FlingSpin","BringSpeed","TouchDistance",
        "MaxParts","MaxRange","FlyForce","FlyLift","NukeForce","VelocityCap"
    }) do
        local lo, hi, st = META[key][1], META[key][2], META[key][3]
        sliderRefs[key] = ui:AddSlider({
            Text = key,
            Default = CFG[key],
            Min = lo,
            Max = hi,
            Flag = "PF_Cfg_"..key,
            SavingEnabled = false,
            Callback = function(v)
                CFG[key] = math.clamp(math.floor(v / st + 0.5) * st, lo, hi)
            end,
        })
    end

    return entry
end

-- ============================================================
-- SETUP
-- ============================================================
local MODES = {"fling","bring","fly","multi","others"}
local function clearModes(s, keep)
    for _, m in ipairs(MODES) do if m ~= keep then s[m] = false end end
end

local function setupPlayer(plr)
    if not isAdmin(plr) then return end
    local e = buildUI(plr)
    if not e then return end
    P[plr] = e

    plr.CharacterAdded:Connect(function()
        task.wait(0.5)
        local pg = plr:FindFirstChild("PlayerGui")
        if pg and not pg:FindFirstChild("PartFlingerGui") then
            local old = P[plr]
            if old then
                if old.libGui then old.libGui:Destroy() end
                if old.ui and type(old.ui.Destroy) == "function" then
                    pcall(function() old.ui:Destroy() end)
                end
            end
            P[plr] = nil
            setupPlayer(plr)
        end
    end)
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

    for owner, e in pairs(P) do
        local s = e.state
        if not (s.fling or s.bring or s.fly or s.multi or s.others) then continue end

        local ref = e.target
        if ref and not ref.Parent then ref=nil; e.target=nil end
        local targetCh = (ref and ref.Character) or owner.Character
        local targetHrp = targetCh and targetCh:FindFirstChild("HumanoidRootPart")

        -- Multi / Others distribution
        if (s.multi or s.others) and #alive > 0 then
            local recipients = {}
            for _, p in ipairs(alive) do
                if (not s.others) or p ~= owner then recipients[#recipients+1] = p end
            end
            if #recipients > 0 then
                local idx = 0
                local count = 0
                for _, obj in ipairs(workspace:GetDescendants()) do
                    if count >= CFG.MaxParts then break end
                    if not obj:IsA("BasePart") or obj.Anchored then continue end
                    local m = obj:FindFirstAncestorOfClass("Model")
                    if m and m:FindFirstChildOfClass("Humanoid") then continue end

                    idx = (idx % #recipients) + 1
                    local targetPlr = recipients[idx]
                    local ch = targetPlr.Character
                    local h = ch and ch:FindFirstChild("HumanoidRootPart")
                    if not h then continue end
                    if (obj.Position - h.Position).Magnitude > CFG.MaxRange then continue end

                    count += 1
                    bringPart(obj, h)
                end
            end
            continue
        end

        if not targetHrp then continue end

        if s.fly then
            local count = 0
            local up = Vector3.new(0,1,0)
            for _, obj in ipairs(workspace:GetDescendants()) do
                if count >= CFG.MaxParts then break end
                if not obj:IsA("BasePart") or obj.Anchored then continue end
                local m = obj:FindFirstAncestorOfClass("Model")
                if m and m:FindFirstChildOfClass("Humanoid") then continue end
                local d = obj.Position - targetHrp.Position
                if d.Magnitude > CFG.MaxRange then continue end
                count += 1
                if d.Y < 1 then
                    obj.CanCollide = true
                    obj.AssemblyLinearVelocity = up * CFG.FlyForce
                    local desired = Vector3.new(targetHrp.Position.X, targetHrp.Position.Y-CFG.FlyLift, targetHrp.Position.Z)
                    if (desired - obj.Position).Magnitude > 8 then obj.CFrame = CFrame.new(desired) end
                end
            end
            continue
        end

        local count = 0
        for _, obj in ipairs(workspace:GetDescendants()) do
            if count >= CFG.MaxParts then break end
            if not obj:IsA("BasePart") or obj.Anchored then continue end
            local m = obj:FindFirstAncestorOfClass("Model")
            if m and m:FindFirstChildOfClass("Humanoid") then continue end
            local d = obj.Position - targetHrp.Position
            if d.Magnitude > CFG.MaxRange then continue end
            count += 1

            if s.fling then
                betterFling(obj, targetHrp.Position, targetHrp.AssemblyLinearVelocity)
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
    local e = P[p]
    if e then
        if e.libGui then e.libGui:Destroy() end
        if e.ui and type(e.ui.Destroy) == "function" then
            pcall(function() e.ui:Destroy() end)
        end
    end
    P[p] = nil
end)
