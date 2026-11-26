-- PartFlingerServer — LinoriaLib Version (debug nuke, no CFrame teleport)
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
    NukeOrbitTime = 2.5,
    NukeRadius    = 250,
    NukeOrbitSpeed = 200,
    NukeSlamForce = 500,   -- much smaller than before; no teleport
    RequireAdmin  = false,
    Admins        = { --[[ 123456789, ]] },
}

local META = {
    FlingForce={50,3000,50}, FlingUp={0,1000,25}, FlingSpin={0,50,2},
    BringSpeed={5,300,10}, TouchDistance={0.5,8,0.5},
    MaxParts={10,500,10}, MaxRange={50,1000,50},
    FlyForce={50,2000,50}, FlyLift={1,10,1},
    NukeForce={1000,20000,500}, VelocityCap={200,10000,200},
    NukeOrbitTime={0.5,8,0.5}, NukeRadius={50,1000,50},
    NukeOrbitSpeed={50,1000,50}, NukeSlamForce={100,5000,100},
}

local PRESETS = {
    default = {FlingForce=900,FlingUp=250,FlingSpin=8,BringSpeed=80,TouchDistance=1.5,
               MaxParts=120,MaxRange=250,SnapToTouch=true,FlyForce=300,FlyLift=3,
               NukeForce=4000,VelocityCap=2000,NukeOrbitTime=2.5,NukeRadius=250,
               NukeOrbitSpeed=200,NukeSlamForce=500},
    gentle  = {FlingForce=200,FlingUp=80,FlingSpin=2,BringSpeed=40,TouchDistance=3,
               MaxParts=50,MaxRange=150,SnapToTouch=false,FlyForce=150,FlyLift=4,
               NukeForce=1500,VelocityCap=800,NukeOrbitTime=2,NukeRadius=150,
               NukeOrbitSpeed=100,NukeSlamForce=300},
    violent = {FlingForce=2500,FlingUp=800,FlingSpin=30,BringSpeed=200,TouchDistance=0.8,
               MaxParts=300,MaxRange=500,SnapToTouch=true,FlyForce=800,FlyLift=2,
               NukeForce=12000,VelocityCap=5000,NukeOrbitTime=3.5,NukeRadius=500,
               NukeOrbitSpeed=400,NukeSlamForce=2000},
    fly     = {FlingForce=100,FlingUp=50,FlingSpin=0,BringSpeed=100,TouchDistance=2,
               MaxParts=60,MaxRange=200,SnapToTouch=true,FlyForce=350,FlyLift=3,
               NukeForce=2000,VelocityCap=1500,NukeOrbitTime=2,NukeRadius=200,
               NukeOrbitSpeed=150,NukeSlamForce=800},
}

local MODE_KEYS = {"fling","bring","fly","multi","others"}

local function applyPreset(name)
    local p = PRESETS[name]; if not p then return end
    for k, v in pairs(p) do CFG[k] = v end
end

-- ============================================================
-- STATE
-- ============================================================
local P = {}   -- [player] = {state, target, ui, nukeArmed}

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

local function getHrp(plr)
    local ch = plr and plr.Character
    return ch and ch:FindFirstChild("HumanoidRootPart") or nil
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
    local mag = v.Magnitude
    if mag ~= mag then return Vector3.zero end  -- NaN guard
    if mag > CFG.VelocityCap then return v.Unit * CFG.VelocityCap end
    return v
end

local function betterFling(part, fromPos, refVel)
    local delta = part.Position - fromPos
    local dist = delta.Magnitude
    local dir = (dist > 0.1) and delta.Unit or Vector3.new(0,1,0)
    local relVel = (refVel or Vector3.zero) * 0.5
    local v = dir * CFG.FlingForce + Vector3.new(0, CFG.FlingUp, 0) + relVel
    part.AssemblyLinearVelocity = capVel(v)
    local spin = CFG.FlingSpin
    part.AssemblyAngularVelocity = Vector3.new(
        math.random(-spin, spin), math.random(-spin, spin), math.random(-spin, spin)
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

local function nearbyUnanchoredParts(origin, radius, limit)
    local out = {}
    local radiusSq = radius * radius
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and not obj.Anchored then
            local m = obj:FindFirstAncestorOfClass("Model")
            if not (m and m:FindFirstChildOfClass("Humanoid")) then
                if (obj.Position - origin).MagnitudeSquared <= radiusSq then
                    out[#out+1] = obj
                    if #out >= limit then break end
                end
            end
        end
    end
    return out
end

-- ============================================================
-- CURSOR HELPERS
-- ============================================================
local function getCursorWorldPoint(plr, ignoreList)
    local camera = Workspace.CurrentCamera
    if not camera then
        print("[Nuke] No camera")
        return nil
    end

    local screenPoint
    if UserInput.MouseEnabled then
        screenPoint = UserInput:GetMouseLocation()
    else
        local vp = camera.ViewportSize
        screenPoint = Vector2.new(vp.X / 2, vp.Y / 2)
    end
    print("[Nuke] screen point:", screenPoint)

    local ray = camera:ScreenPointToRay(screenPoint.X, screenPoint.Y)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignoreList or {}
    params.IgnoreWater = true

    local result = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
    if result and result.Position then
        print("[Nuke] raycast hit:", result.Position, "part:", result.Instance and result.Instance:GetFullName())
        return result.Position
    end
    print("[Nuke] raycast MISS")

    local mouse = plr:GetMouse()
    if mouse and mouse.Hit then
        print("[Nuke] using mouse.Hit:", mouse.Hit.Position)
        return mouse.Hit.Position
    end
    print("[Nuke] no fallback hit")
    return nil
end

-- ============================================================
-- NUKE SEQUENCE (velocity-only, no CFrame teleport)
-- ============================================================
-- Per-part orbit state: { part, center, angle, radius, speed, born, life, state, slamStart }
local activeNukes = {}

local function startNuke(origin)
    local parts = nearbyUnanchoredParts(origin, CFG.NukeRadius, math.huge)
    print("[Nuke] found", #parts, "unanchored parts within", CFG.NukeRadius, "of", origin)
    if #parts == 0 then return 0 end

    local orbitTime  = CFG.NukeOrbitTime
    local orbitSpeed = CFG.NukeOrbitSpeed
    local center     = origin + Vector3.new(0, 10, 0)

    for _, part in ipairs(parts) do
        local delta = part.Position - center
        local flat  = Vector3.new(delta.X, 0, delta.Z)
        local r     = math.max(flat.Magnitude, 4 + math.random() * 6)
        local ang   = math.atan2(delta.Z, delta.X) + math.random() * 0.4
        local h     = math.max(delta.Y, 2 + math.random() * 6)

        if not part.CanCollide then part.CanCollide = true end

        activeNukes[#activeNukes + 1] = {
            part    = part,
            center  = center,
            angle   = ang,
            radius  = r,
            height  = h,
            speed   = orbitSpeed * (0.6 + math.random() * 0.8),
            born    = os.clock(),
            life    = orbitTime,
            state   = "orbit",
            lastPos = part.Position,
        }
    end
    print("[Nuke] launched", #activeNukes, "orbiters")
    return #parts
end

RunService.Heartbeat:Connect(function(dt)
    if #activeNukes == 0 then return end
    local now = os.clock()

    local i = 1
    while i <= #activeNukes do
        local n = activeNukes[i]
        local part = n.part
        if not part or not part.Parent then
            table.remove(activeNukes, i)
            continue
        end

        if n.state == "orbit" then
            n.angle = n.angle + n.speed * dt
            local t = math.clamp((now - n.born) / n.life, 0, 1)
            local height = n.height + 15 * t
            local target = n.center + Vector3.new(
                math.cos(n.angle) * n.radius,
                height,
                math.sin(n.angle) * n.radius
            )
            -- Velocity pulls toward the orbit target, but we do not teleport.
            local vel = (target - part.Position) * 4
            if vel.Magnitude > 300 then vel = vel.Unit * 300 end
            part.AssemblyLinearVelocity = vel
            part.AssemblyAngularVelocity = Vector3.new(n.speed, n.speed, 0)

            -- If part has stopped responding (CFrame unchanged), bail out so
            -- it does not keep "disappearing" into the void.
            if (part.Position - n.lastPos).Magnitude < 0.05 and t > 0.2 then
                print("[Nuke] part unresponsive, removing from orbit:", part:GetFullName())
                table.remove(activeNukes, i)
                continue
            end
            n.lastPos = part.Position

            if t >= 1 then
                n.state = "slam"
                n.slamStart = now
                part.AssemblyLinearVelocity = Vector3.new(0, -CFG.NukeSlamForce, 0)
                part.AssemblyAngularVelocity = Vector3.zero
                print("[Nuke] slam:", part:GetFullName())
            end
        elseif n.state == "slam" then
            local elapsed = now - n.slamStart
            if elapsed < 0.3 then
                part.AssemblyLinearVelocity = Vector3.new(0, -CFG.NukeSlamForce, 0)
            end
            if elapsed > 1.5 then
                table.remove(activeNukes, i)
                continue
            end
        end

        i += 1
    end
end)

-- ============================================================
-- BUILD UI
-- ============================================================
local uiBuilt = {}

local function buildUI(plr)
    if uiBuilt[plr] then return P[plr] end
    uiBuilt[plr] = true

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
    local entry = {state=state, target=nil, ui=Window, nukeArmed=false}

    -- ===== Status groupbox (isolated so it can't overlap anything) =====
    local statusBox = Tabs.Controls:AddLeftGroupbox('Status')
    local statusLabel = statusBox:AddLabel('Target = self | idle')

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
        statusLabel:SetText('Target = ' .. tgt .. ' | ' .. modeStr)
    end

    -- ===== Target groupbox (input only, no label above it) =====
    local targetBox = Tabs.Controls:AddRightGroupbox('Target')
    targetBox:AddInput('PF_Target', {
        Default = '',
        Numeric = false,
        Finished = true,
        Text = 'Username (blank = self)',
        Placeholder = 'username',
        Tooltip = 'Leave blank to target yourself',
        Callback = function(txt)
            entry.target = resolvePlayer(plr, txt)
            refreshStatus()
        end,
    })

    -- ===== Modes =====
    local modeBox = Tabs.Controls:AddLeftGroupbox('Modes')
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
        local tooltip = ({
            fling = 'Fling parts around your target',
            bring = 'Pull parts toward your target',
            fly = 'Launch parts under your target',
            multi = 'Apply fling/bring/fly to EVERYONE (including you)',
            others = 'Apply fling/bring/fly to everyone EXCEPT you',
        })[k] or ''
        modeBox:AddToggle('PF_Mode_' .. k, {
            Text = k:upper(),
            Default = false,
            Tooltip = tooltip,
        })
        Toggles['PF_Mode_' .. k]:OnChanged(function(v) onMode(k, v) end)
    end

    -- ===== Actions =====
    local actionBox = Tabs.Controls:AddRightGroupbox('Actions')

    actionBox:AddButton('STOP ALL', function()
        for _, m in ipairs(MODE_KEYS) do
            state[m] = false
            local t = Toggles['PF_Mode_' .. m]
            if t then t:SetValue(false) end
        end
        refreshStatus()
        Library:Notify('Stopped', 2)
    end)

    local nukeToggle
    nukeToggle = actionBox:AddToggle('PF_NukeArmed', {
        Text = 'NUKE ARM',
        Default = false,
        Tooltip = 'While armed, click any part in the world. Nearby parts orbit, then slam down.',
        Callback = function(v)
            entry.nukeArmed = v
            print("[Nuke] armed =", v)
            if v then Library:Notify('Nuke armed — click a part', 2) end
        end,
    })

    -- Primary click detector: Mouse.Button1Down (fires reliably in executors)
    local mouse = plr:GetMouse()
    if mouse then
        mouse.Button1Down:Connect(function()
            print("[Nuke] Button1Down fired, armed =", entry.nukeArmed)
            if not entry.nukeArmed then return end

            local myChar = plr.Character
            local origin = getCursorWorldPoint(plr, myChar and {myChar} or {})
            if not origin then
                Library:Notify('Nuke: could not resolve world point', 2)
                return
            end

            local count = startNuke(origin)
            Library:Notify(string.format('Nuke: %d parts orbiting', count), 2)

            entry.nukeArmed = false
            if nukeToggle then nukeToggle:SetValue(false) end
        end)
    else
        print("[Nuke] player:GetMouse() returned nil — will rely on InputBegan only")
    end

    -- Fallback: InputBegan in case Button1Down doesn't fire
    UserInput.InputBegan:Connect(function(input, processed)
        print("[Nuke] InputBegan: type =", input.UserInputType.Name, "| processed =", processed, "| armed =", entry.nukeArmed)
        if processed then return end
        if not entry.nukeArmed then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end

        local myChar = plr.Character
        local origin = getCursorWorldPoint(plr, myChar and {myChar} or {})
        if not origin then
            Library:Notify('Nuke: could not resolve world point', 2)
            return
        end

        local count = startNuke(origin)
        Library:Notify(string.format('Nuke: %d parts orbiting', count), 2)

        entry.nukeArmed = false
        if nukeToggle then nukeToggle:SetValue(false) end
    end)

    -- ===== Presets =====
    local presetBox = Tabs.Presets:AddLeftGroupbox('Presets')
    local sliderRefs = {}

    for _, name in ipairs({'default','gentle','violent','fly'}) do
        presetBox:AddButton(name:upper() .. ' preset', function()
            applyPreset(name)
            for k, s in pairs(sliderRefs) do s:SetValue(CFG[k]) end
            Library:Notify(name:upper() .. ' applied', 2)
        end)
    end

    -- ===== Config =====
    local configBox = Tabs.Config:AddLeftGroupbox('Config Sliders')

    for _, key in ipairs({
        'FlingForce','FlingUp','FlingSpin','BringSpeed','TouchDistance',
        'MaxParts','MaxRange','FlyForce','FlyLift','NukeForce','VelocityCap',
        'NukeOrbitTime','NukeRadius','NukeOrbitSpeed','NukeSlamForce'
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

    P[plr] = entry
    refreshStatus()
    return entry
end

-- ============================================================
-- SETUP
-- ============================================================
local function setupPlayer(plr)
    if not isAdmin(plr) then return end
    buildUI(plr)
end

Players.PlayerAdded:Connect(setupPlayer)
if #Players:GetPlayers() > 0 then
    for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
end
Players.PlayerRemoving:Connect(function(p)
    P[p] = nil
    uiBuilt[p] = nil
end)

-- ============================================================
-- MAIN LOOP (fling/bring/fly/multi/others)
-- ============================================================
local acc = 0
RunService.Heartbeat:Connect(function(dt)
    acc += dt
    if acc < 1/30 then return end
    acc = 0

    local alive    = alivePlayers()
    local maxParts = CFG.MaxParts
    local maxRange = CFG.MaxRange

    for owner, e in pairs(P) do
        local s = e.state
        if not (s.fling or s.bring or s.fly or s.multi or s.others) then continue end

        local ref = e.target
        if ref and not ref.Parent then ref=nil; e.target=nil end

        if s.multi or s.others then
            local recipients = {}
            if s.multi then
                recipients = alive
            else
                for _, p in ipairs(alive) do
                    if p ~= owner then recipients[#recipients+1] = p end
                end
            end

            if #recipients > 0 then
                local scanOrigin = getHrp(owner) or (getHrp(recipients[1]) or Vector3.zero)
                local parts = nearbyUnanchoredParts(scanOrigin, maxRange, maxParts)
                local i = 0
                for _, obj in ipairs(parts) do
                    local tries, targetHrp = 0, nil
                    while tries < #recipients do
                        i = (i % #recipients) + 1
                        local h = getHrp(recipients[i])
                        if h and (obj.Position - h.Position).Magnitude <= maxRange then
                            targetHrp = h; break
                        end
                        tries += 1
                    end
                    if not targetHrp then continue end

                    if s.fling then
                        betterFling(obj, targetHrp.Position, targetHrp.AssemblyLinearVelocity)
                    elseif s.bring then
                        bringPart(obj, targetHrp)
                    elseif s.fly then
                        local d = obj.Position - targetHrp.Position
                        if d.Y < 1 then
                            if not obj.CanCollide then obj.CanCollide = true end
                            obj.AssemblyLinearVelocity = Vector3.new(0, CFG.FlyForce, 0)
                            local desired = Vector3.new(targetHrp.Position.X, targetHrp.Position.Y - CFG.FlyLift, targetHrp.Position.Z)
                            if (desired - obj.Position).Magnitude > 8 then
                                obj.CFrame = CFrame.new(desired)
                            end
                        end
                    end
                end
            end
            continue
        end

        local targetHrp = getHrp(ref or owner)
        if not targetHrp then continue end
        local origin = targetHrp.Position

        if s.fly then
            local parts = nearbyUnanchoredParts(origin, maxRange, maxParts)
            for _, obj in ipairs(parts) do
                if obj.Position.Y < origin.Y + 1 then
                    if not obj.CanCollide then obj.CanCollide = true end
                    obj.AssemblyLinearVelocity = Vector3.new(0, CFG.FlyForce, 0)
                    local desired = Vector3.new(origin.X, origin.Y - CFG.FlyLift, origin.Z)
                    if (desired - obj.Position).Magnitude > 8 then
                        obj.CFrame = CFrame.new(desired)
                    end
                end
            end
            continue
        end

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
