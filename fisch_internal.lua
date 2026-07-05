--[[
    Fisch — Internal-Executor Auto-Fisher + Smart Leveling
    ======================================================
    FOR AN INJECTING EXECUTOR (Wave, Solara, Script-Ware, AWP, ...). NOT Matcha.

    Built from the proven cast/shake/reel logic of the prior Matcha build
    (fisch_autofish.lua), but adapted to an internal:
      - reads the reel/power GUI via AbsolutePosition (NO memory offsets, no offset URL)
      - uses task.* scheduler, Instance-based input, real remotes for selling
      - Rayfield GUI (falls back to a _G.Fisch console API if the UI lib won't load)

    Core loop: EQUIP -> CAST (charge + release) -> SHAKE (Enter) -> REEL (PID-PWM
    keeps the player bar on the fish) -> DONE -> repeat.

    Efficiency features (the "level up faster" ask): teleport + Smart Leveling that
    rotates through unvisited zones so you bank the big first-visit / first-catch XP
    bonuses instead of grinding one spot.

    NOTE: untested live (built offline from prior knowledge). The knobs most likely
    to need a tweak per game version are marked CHECK. Quest NPC dialog/turn-in and
    shop auto-buy are intentionally NOT automated here — those need the actual remotes,
    which can't be confirmed without a live client; Smart Leveling covers the XP goal.
]]

------------------------------------------------------------------ services / player
local Players    = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RepStorage  = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

-- Reel is computed client-side; ReelController.ActiveReel is the live reel session
-- while reeling. session:AddProgress(100) forces the catch instantly (no minigame).
local ReelController = nil
pcall(function()
    ReelController = require(RepStorage.client.legacyControllers.ReelController)
end)

------------------------------------------------------------------ config
local CFG = {
    -- cast
    cast_power_threshold = 95.0,   -- release the charge at this power %  (CHECK)
    cast_max_hold_ms     = 1200,   -- ...or after this long, whichever first (guarantees a cast)
    cast_min_hold_ms     = 120,    -- never release before this
    post_cast_delay_ms   = 150,
    -- shake
    shake_interval_ms    = 60,     -- how often to tap Enter while the shake prompt is up
    -- reel
    completion_threshold = 99.0,   -- progress % that counts as "caught"
    -- loop
    post_catch_delay_ms  = 400,
    cast_timeout_ms      = 12000,  -- restart a stuck cast after this
    equip_slot           = 1,      -- hotbar slot the rod sits in (CHECK)
    -- features
    anti_afk             = true,
    auto_sell            = false,
    auto_sell_interval_s = 120,
    -- smart leveling
    level_dwell_s        = 45,     -- seconds to fish each zone before rotating
    toggle_key           = Enum.KeyCode.F1,
}

------------------------------------------------------------------ small helpers
local function char()   return plr.Character end
local function hrp()    local c = char(); return c and c:FindFirstChild("HumanoidRootPart") end
local function pgui()   return plr:FindFirstChildOfClass("PlayerGui") end
local function now_ms() return tick() * 1000 end

-- 0..1 position of a frame's left edge within a container frame
local function relX(frame, container)
    local ok, v = pcall(function()
        return (frame.AbsolutePosition.X - container.AbsolutePosition.X) / container.AbsoluteSize.X
    end)
    return ok and v or nil
end
-- 0..1 width of a frame relative to a container
local function relW(frame, container)
    local ok, v = pcall(function() return frame.AbsoluteSize.X / container.AbsoluteSize.X end)
    return ok and v or nil
end
local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- recursive find of a descendant by name + class (bounded)
local function findDesc(root, name, class)
    if not root then return nil end
    local stack, i = { root }, 1
    while i <= #stack do
        local node = stack[i]; i = i + 1
        for _, ch in ipairs(node:GetChildren()) do
            if ch.Name == name and (not class or ch.ClassName == class) then return ch end
            stack[#stack + 1] = ch
        end
        if i > 6000 then break end
    end
    return nil
end

------------------------------------------------------------------ input (executor globals, VIM fallback)
local held = false
local function mDown()
    if held then return end
    held = true
    if type(mouse1press) == "function" then pcall(mouse1press)
    else pcall(function() game:GetService("VirtualInputManager"):SendMouseButtonEvent(0, 0, 0, true, game, 0) end) end
end
local function mUp()
    if not held then return end
    held = false
    if type(mouse1release) == "function" then pcall(mouse1release)
    else pcall(function() game:GetService("VirtualInputManager"):SendMouseButtonEvent(0, 0, 0, false, game, 0) end) end
end
local function tapKey(vk, keycode)
    if type(keypress) == "function" and type(keyrelease) == "function" then
        pcall(keypress, vk)
        task.delay(0.03, function() pcall(keyrelease, vk) end)
    else
        pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            VIM:SendKeyEvent(true, keycode, false, game)
            task.delay(0.03, function() VIM:SendKeyEvent(false, keycode, false, game) end)
        end)
    end
end
local function tapEnter() tapKey(0x0D, Enum.KeyCode.Return) end
local function tapSlot(n) tapKey(48 + n, Enum.KeyCode[({ "One","Two","Three","Four","Five","Six","Seven","Eight","Nine" })[n] or "One"]) end
-- shake works by "click" on mobile and Enter on PC (Fisch shake mode); do both to cover both
local function clickOnce()
    if type(mouse1click) == "function" then pcall(mouse1click)
    elseif type(mouse1press) == "function" then pcall(mouse1press); task.delay(0.03, function() pcall(mouse1release) end) end
end
local function tapShake() tapEnter(); clickOnce() end

-- find the first descendant of a class (for the shake button)
local function firstDescOfClass(root, class)
    if not root then return nil end
    local stack, i = { root }, 1
    while i <= #stack do
        local node = stack[i]; i = i + 1
        for _, ch in ipairs(node:GetChildren()) do
            if ch:IsA(class) then return ch end
            stack[#stack + 1] = ch
        end
        if i > 4000 then break end
    end
    return nil
end

-- INPUT-FREE shake: fire the shake button's click event directly (no tap/keypress).
-- Layers: firesignal (no input at all) -> VirtualInputManager virtual click -> tap fallback.
local function fireShake()
    local pg = plr:FindFirstChildOfClass("PlayerGui")
    local sui = pg and pg:FindFirstChild("shakeui")
    local btn = sui and (firstDescOfClass(sui, "ImageButton") or firstDescOfClass(sui, "TextButton"))
    if btn then
        if type(firesignal) == "function" then
            pcall(firesignal, btn.MouseButton1Click)
            pcall(firesignal, btn.Activated, nil, 1)
            return true
        end
        local okv = pcall(function()
            local VIM = game:GetService("VirtualInputManager")
            local c = btn.AbsolutePosition + btn.AbsoluteSize / 2
            VIM:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 1)
            VIM:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 1)
        end)
        if okv then return true end
    end
    tapShake()   -- last resort: virtual click + Enter
    return false
end

------------------------------------------------------------------ rod equip
local function rodEquipped()
    local c = char(); if not c then return false end
    for _, t in ipairs(c:GetChildren()) do if t:IsA("Tool") then return true end end
    return false
end
local function ensureEquipped()
    if rodEquipped() then return end
    if CFG.equip_slot and CFG.equip_slot > 0 then tapSlot(CFG.equip_slot) end
end

------------------------------------------------------------------ GUI state reads
-- reel minigame context
local function reelCtx()
    local pg = pgui(); if not pg then return nil end
    local reel = pg:FindFirstChild("reel"); if not reel then return nil end
    local ok, en = pcall(function() return reel.Enabled end)
    if ok and en == false then return nil end
    local bar = reel:FindFirstChild("bar"); if not bar then return nil end
    local fish = bar:FindFirstChild("fish"); local pbar = bar:FindFirstChild("playerbar")
    if not (fish and pbar) then return nil end
    return { reel = reel, bar = bar, fish = fish, playerbar = pbar }
end
local function reelActive()
    if ReelController and ReelController.ActiveReel then return true end
    local c = char()
    if c and c:GetAttribute("ReelActive") ~= nil then return true end
    return reelCtx() ~= nil
end

-- progress % of the current reel
local function reelProgress()
    local pg = pgui(); if not pg then return nil end
    local reel = pg:FindFirstChild("reel"); if not reel then return nil end
    local bar = reel:FindFirstChild("bar"); if not bar then return nil end
    local prog = bar:FindFirstChild("progress"); if not prog then return nil end
    local fill = prog:FindFirstChild("bar"); if not fill then return nil end
    local w = relW(fill, prog)
    if not finite(w) then return nil end
    return math.max(0, math.min(100, w * 100))
end

-- cast charge power % (HRP.power > Frame "bar"; fill is a Size scale)
local function readPower()
    local h = hrp(); if not h then return nil end
    local power = h:FindFirstChild("power"); if not power then return nil end
    local barFrame = findDesc(power, "bar", "Frame"); if not barFrame then return nil end
    local ok, sy = pcall(function() return barFrame.Size.Y.Scale end)
    local ok2, sx = pcall(function() return barFrame.Size.X.Scale end)
    local v
    if ok and sy and sy > 0.01 and sy <= 1.2 then v = sy
    elseif ok2 and sx and sx > 0.01 and sx <= 1.2 then v = sx end
    return v and math.min(100, v * 100) or nil
end

------------------------------------------------------------------ reel controller (ported PID-PWM, proven)
local H = {
    CloseThreshold = 0.01, DerivativeGain = 0.55, EdgeBoundary = 0.10,
    NeutralDutyCycle = 0.5, PredictionStrength = 7.5, ProportionalGain = 0.42,
    VelocityDamping = 38,
}
local Ctrl = { lastPB = nil, lastFish = nil, pwm = 0.0 }
function Ctrl.reset() Ctrl.lastPB = nil; Ctrl.lastFish = nil; Ctrl.pwm = 0.0 end

local function fishCenter(ctx) local x = relX(ctx.fish, ctx.bar); local w = relW(ctx.fish, ctx.bar); if not (finite(x) and finite(w)) then return nil end return x + w / 2 end
local function pbPos(ctx) local x = relX(ctx.playerbar, ctx.bar); return finite(x) and x or nil end
local function onTarget(ctx)
    local pbx, pbw = relX(ctx.playerbar, ctx.bar), relW(ctx.playerbar, ctx.bar)
    local fc = fishCenter(ctx)
    if not (finite(pbx) and finite(pbw) and finite(fc)) then return nil end
    local half = pbw / 2
    return fc >= pbx - half and fc <= pbx + half
end

function Ctrl.update(ctx)
    if onTarget(ctx) == nil then mUp(); return end
    local fc, pb = fishCenter(ctx), pbPos(ctx)
    if not (fc and pb) then return end
    if Ctrl.lastPB == nil then Ctrl.lastPB = pb end
    if Ctrl.lastFish == nil then Ctrl.lastFish = fc end
    local pbVel = pb - Ctrl.lastPB; Ctrl.lastPB = pb
    local fishVel = fc - Ctrl.lastFish; Ctrl.lastFish = fc
    local err = fc - pb
    local edge = H.EdgeBoundary
    if pb < edge then mDown(); return end
    if pb > 1 - edge then mUp(); return end
    local predicted = pb + pbVel * H.PredictionStrength
    local v = H.CloseThreshold
    local sameSide = (err * (fc - predicted)) > 0
    local chasing = (err * pbVel) > 0
    local absErr = math.max(0, math.abs(err) - v)
    local speed = math.abs(pbVel) * 8
    local converging = chasing and (speed >= absErr)
    if math.abs(err) > v and (sameSide and not converging) then
        if err > 0 then mDown() else mUp() end
        return
    end
    local neutral = H.NeutralDutyCycle
    local duty
    if converging and speed > 0 then
        local f = 1.0 - math.min(1.0, absErr / speed)
        if err > 0 then duty = neutral * (1.0 - f) else duty = neutral + (1.0 - neutral) * f end
    else
        local adj = (H.ProportionalGain * err) + (H.DerivativeGain * fishVel) - (H.VelocityDamping * pbVel)
        duty = math.max(0, math.min(1, neutral + adj))
    end
    Ctrl.pwm = Ctrl.pwm + duty
    if Ctrl.pwm >= 1.0 then Ctrl.pwm = Ctrl.pwm - 1.0; mDown() else mUp() end
end

------------------------------------------------------------------ fishing state machine
local S = { phase = "OFF", running = false, caught = 0, lost = 0,
            castStart = 0, castReleased = 0, castBarSeen = false,
            lastShake = 0, doneAt = 0, completion = false, status = "idle" }

local function resetCycle()
    mUp(); Ctrl.reset()
    S.castStart = now_ms(); S.castReleased = 0; S.castBarSeen = false
    S.lastShake = 0; S.doneAt = 0; S.completion = false; S.usingInstant = false
end
local function beginCast()
    resetCycle(); ensureEquipped()
    S.phase = reelActive() and "REEL" or "CAST"
end

local function stepCast()
    if reelActive() then mUp(); S.phase = "REEL"; return end
    mDown()
    local held_ms = now_ms() - S.castStart
    local pwr = readPower()
    if pwr then S.castBarSeen = true; S.status = ("casting %d%%"):format(pwr) end
    if held_ms >= CFG.cast_min_hold_ms and ((pwr and pwr >= CFG.cast_power_threshold) or held_ms >= CFG.cast_max_hold_ms) then
        mUp(); S.castReleased = now_ms(); S.phase = "CASTED"
    elseif held_ms >= CFG.cast_timeout_ms then
        beginCast()
    end
end
local function stepCasted()
    mUp()
    if now_ms() - S.castReleased < CFG.post_cast_delay_ms then return end
    S.lastShake = 0; S.phase = "SHAKE"; S.status = "shaking"
end
local function stepShake()
    mUp()
    if reelActive() then S.phase = "REEL"; return end
    local t = now_ms()
    if S.lastShake == 0 or (t - S.lastShake) >= CFG.shake_interval_ms then
        fireShake(); S.lastShake = t
    end
    if S.castReleased > 0 and (t - S.castReleased) >= CFG.cast_timeout_ms then beginCast() end
end
local function stepReel()
    -- Preferred: INSTANT reel via the client reel session (no minigame, no input)
    local reel = ReelController and ReelController.ActiveReel
    if reel then
        mUp()
        S.usingInstant = true
        S.status = "instant-reel"
        pcall(function() reel:AddProgress(100) end)   -- progress >=100 -> EndMinigame -> catch
        return
    end
    if S.usingInstant then
        -- instant reel just completed; ignore the lingering reel GUI, finish now
        S.usingInstant = false
        mUp(); Ctrl.reset()
        S.caught = S.caught + 1
        S.phase = "DONE"; S.doneAt = now_ms(); S.status = "caught!"
        return
    end
    -- Fallback (ReelController unavailable): solve the minigame by input like before
    local ctx = reelCtx()
    if ctx then
        local prog = reelProgress()
        if prog then S.status = ("reeling %d%%"):format(prog) end
        Ctrl.update(ctx)
        return
    end
    mUp(); Ctrl.reset()
    S.caught = S.caught + 1
    S.phase = "DONE"; S.doneAt = now_ms(); S.status = "caught!"
end
local function stepDone()
    if reelActive() then S.phase = "REEL"; return end
    if now_ms() - S.doneAt < CFG.post_catch_delay_ms then return end
    beginCast()
end

local STEPS = { CAST = stepCast, CASTED = stepCasted, SHAKE = stepShake, REEL = stepReel, DONE = stepDone }

------------------------------------------------------------------ engine control
local function setRunning(on)
    on = on and true or false
    if on == S.running then return end
    S.running = on
    if on then S.phase = "OFF" else mUp(); S.phase = "OFF"; S.status = "idle" end
    if S.onRunChange then pcall(S.onRunChange, on) end
end

RunService.Heartbeat:Connect(function()
    if not S.running then return end
    if S.phase == "OFF" then beginCast() end
    local fn = STEPS[S.phase]
    if fn then local ok, err = pcall(fn); if not ok then mUp(); S.status = "err: " .. tostring(err) end end
end)

------------------------------------------------------------------ teleport + zones
local function collectZones()
    local out, seen = {}, {}
    local zones = workspace:FindFirstChild("zones")
    if zones then
        for _, folderName in ipairs({ "player", "fishing" }) do
            local f = zones:FindFirstChild(folderName)
            if f then
                for _, p in ipairs(f:GetChildren()) do
                    if p:IsA("BasePart") then
                        local nmv = p:FindFirstChild("zonename")
                        local nm = (nmv and nmv.Value) or p.Name
                        if not seen[nm] then seen[nm] = true; out[#out + 1] = { name = nm, pos = p.Position } end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
local ZONES = collectZones()
local function teleportTo(pos)
    local h = hrp(); if not h then return false end
    local ok = pcall(function() h.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0)) end)
    return ok
end
local function teleportZone(name)
    for _, z in ipairs(ZONES) do if z.name == name then return teleportTo(z.pos) end end
    return false
end

------------------------------------------------------------------ auto-sell
local function sellAll()
    local ev = RepStorage:FindFirstChild("events")
    local sell = ev and ev:FindFirstChild("selleverything")
    if sell and sell:IsA("RemoteFunction") then return pcall(function() return sell:InvokeServer() end) end
    if sell and sell:IsA("RemoteEvent") then return pcall(function() sell:FireServer() end) end
    return false
end

------------------------------------------------------------------ smart leveling (zone rotation for first-visit/first-catch XP)
local level = { on = false, gen = 0 }
local function smartLevelStart()
    if level.on then return end
    level.on = true; level.gen = level.gen + 1
    local myGen = level.gen
    task.spawn(function()
        setRunning(true)
        for _, z in ipairs(ZONES) do
            if not level.on or level.gen ~= myGen then break end
            S.status = "leveling: " .. z.name
            teleportTo(z.pos)
            task.wait(1.0)                 -- settle after teleport
            local t0 = os.clock()
            while (os.clock() - t0) < CFG.level_dwell_s do
                if not level.on or level.gen ~= myGen then break end
                task.wait(0.5)
            end
        end
        S.status = "leveling done"
    end)
end
local function smartLevelStop() level.on = false; level.gen = level.gen + 1 end

------------------------------------------------------------------ anti-afk
if CFG.anti_afk then
    plr.Idled:Connect(function()
        if not CFG.anti_afk then return end
        pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
    end)
end

------------------------------------------------------------------ auto-sell loop
task.spawn(function()
    while true do
        task.wait(math.max(15, CFG.auto_sell_interval_s))
        if CFG.auto_sell then pcall(sellAll) end
    end
end)

------------------------------------------------------------------ F1 keybind
local UIS = game:GetService("UserInputService")
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == CFG.toggle_key then setRunning(not S.running) end
end)

------------------------------------------------------------------ console API (always available)
_G.Fisch = {
    start = function() setRunning(true) end,
    stop  = function() setRunning(false) end,
    toggle = function() setRunning(not S.running) end,
    sell = sellAll,
    tp = teleportZone,
    zones = function() local t = {} for _, z in ipairs(ZONES) do t[#t + 1] = z.name end return t end,
    levelStart = smartLevelStart,
    levelStop  = smartLevelStop,
    status = function() return ("run=%s phase=%s %s caught=%d lost=%d"):format(tostring(S.running), S.phase, S.status, S.caught, S.lost) end,
    cfg = CFG,
}

------------------------------------------------------------------ GUI (self-contained, touch + mouse; PC + mobile)
local function buildUI()
    local function mk(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props or {}) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    local ACCENT = Color3.fromRGB(64, 156, 255)
    local BG, BG2, TXT = Color3.fromRGB(26, 28, 34), Color3.fromRGB(40, 43, 51), Color3.fromRGB(235, 238, 245)
    local OFF = Color3.fromRGB(70, 74, 84)

    -- host: gethui/CoreGui so the game can't wipe it; PlayerGui fallback
    local screen = mk("ScreenGui", { Name = "FischUI", ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true, DisplayOrder = 999 })
    local host = (gethui and gethui()) or (game:FindService("CoreGui"))
    local okHost = host and pcall(function() screen.Parent = host end)
    if not okHost or not screen.Parent then screen.Parent = plr:WaitForChild("PlayerGui") end

    local cam = workspace.CurrentCamera
    local vp = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
    local mobile = vp.X < 700
    local UIS = game:GetService("UserInputService")

    -- shared drag helper (mouse + touch)
    local function draggable(handle, target, onClick)
        local dragging, moved, startPos, origin
        handle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging, moved = true, false
                startPos, origin = input.Position, target.Position
                local moveConn, endConn
                moveConn = UIS.InputChanged:Connect(function(i2)
                    if dragging and (i2.UserInputType == Enum.UserInputType.MouseMovement or i2.UserInputType == Enum.UserInputType.Touch) then
                        local d = i2.Position - startPos
                        if math.abs(d.X) + math.abs(d.Y) > 6 then moved = true end
                        target.Position = UDim2.fromOffset(origin.X.Offset + d.X, origin.Y.Offset + d.Y)
                    end
                end)
                endConn = input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false; moveConn:Disconnect(); endConn:Disconnect()
                        if not moved and onClick then onClick() end
                    end
                end)
            end
        end)
    end

    -- floating open/close button (draggable) — the mobile entry point
    local fab = mk("TextButton", { Name = "FAB", Size = UDim2.fromOffset(50, 50),
        Position = UDim2.fromOffset(14, 130), BackgroundColor3 = ACCENT, Text = "🎣",
        TextSize = 22, TextColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AutoButtonColor = true }, screen)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, fab)

    -- panel
    local pW = mobile and math.min(300, vp.X - 20) or 310
    local pH = mobile and math.min(vp.Y - 150, 420) or 440
    local panel = mk("Frame", { Name = "Panel", Size = UDim2.fromOffset(pW, pH),
        Position = UDim2.fromOffset(14, 190), BackgroundColor3 = BG, BorderSizePixel = 0, Visible = true }, screen)
    mk("UICorner", { CornerRadius = UDim.new(0, 12) }, panel)
    mk("UIStroke", { Color = Color3.fromRGB(58, 62, 72), Thickness = 1 }, panel)

    local title = mk("TextButton", { Name = "Title", Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = BG2,
        Text = "  🎣  Fisch", TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = TXT, TextSize = 16,
        Font = Enum.Font.GothamBold, BorderSizePixel = 0, AutoButtonColor = false }, panel)
    mk("UICorner", { CornerRadius = UDim.new(0, 12) }, title)
    local closeBtn = mk("TextButton", { Size = UDim2.fromOffset(34, 34), Position = UDim2.new(1, -38, 0, 3),
        BackgroundTransparency = 1, Text = "✕", TextColor3 = TXT, TextSize = 18 }, title)
    draggable(title, panel)

    local content = mk("ScrollingFrame", { Name = "Content", Size = UDim2.new(1, -12, 1, -48),
        Position = UDim2.fromOffset(6, 44), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 4, ScrollBarImageColor3 = ACCENT, CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y }, panel)
    mk("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, content)
    mk("UIPadding", { PaddingRight = UDim.new(0, 2) }, content)

    -- tap the FAB to toggle the panel; drag to reposition (handled inside draggable)
    draggable(fab, fab, function() panel.Visible = not panel.Visible end)
    closeBtn.Activated:Connect(function() panel.Visible = false end)

    local order = 0
    local function ord() order = order + 1; return order end
    local function rowFrame(h) return mk("Frame", { Size = UDim2.new(1, 0, 0, h or 40), BackgroundColor3 = BG2,
        BorderSizePixel = 0, LayoutOrder = ord() }, content) end

    local U = {}
    function U.section(t) mk("TextLabel", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Text = t,
        TextColor3 = ACCENT, TextSize = 12, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = ord() }, content) end
    function U.toggle(text, init, cb)
        local r = rowFrame(42); mk("UICorner", { CornerRadius = UDim.new(0, 8) }, r)
        mk("TextLabel", { Size = UDim2.new(1, -66, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
            Text = text, TextColor3 = TXT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham }, r)
        local pill = mk("TextButton", { Size = UDim2.fromOffset(48, 26), Position = UDim2.new(1, -58, 0.5, -13),
            BackgroundColor3 = init and ACCENT or OFF, Text = "", BorderSizePixel = 0 }, r)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, pill)
        local knob = mk("Frame", { Size = UDim2.fromOffset(20, 20),
            Position = init and UDim2.new(1, -23, 0.5, -10) or UDim2.fromOffset(3, 3),
            BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, pill)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)
        local st = init
        local function render() pill.BackgroundColor3 = st and ACCENT or OFF
            knob.Position = st and UDim2.new(1, -23, 0.5, -10) or UDim2.fromOffset(3, 3) end
        pill.Activated:Connect(function() st = not st; render(); cb(st) end)
        return function(v) if v ~= st then st = v; render() end end
    end
    function U.button(text, cb)
        local b = mk("TextButton", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = ACCENT, Text = text,
            TextColor3 = Color3.new(1, 1, 1), TextSize = 14, Font = Enum.Font.GothamMedium, BorderSizePixel = 0,
            LayoutOrder = ord(), AutoButtonColor = true }, content)
        mk("UICorner", { CornerRadius = UDim.new(0, 8) }, b)
        b.Activated:Connect(cb)
    end
    function U.stepper(text, get, set, lo, hi, step)
        local r = rowFrame(42); mk("UICorner", { CornerRadius = UDim.new(0, 8) }, r)
        local lbl = mk("TextLabel", { Size = UDim2.new(1, -108, 1, 0), Position = UDim2.fromOffset(12, 0),
            BackgroundTransparency = 1, TextColor3 = TXT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham }, r)
        local function refresh() lbl.Text = text .. ": " .. tostring(get()) end
        local minus = mk("TextButton", { Size = UDim2.fromOffset(34, 30), Position = UDim2.new(1, -98, 0.5, -15),
            BackgroundColor3 = BG, Text = "−", TextColor3 = TXT, TextSize = 20, BorderSizePixel = 0 }, r)
        mk("UICorner", { CornerRadius = UDim.new(0, 6) }, minus)
        local plus = mk("TextButton", { Size = UDim2.fromOffset(34, 30), Position = UDim2.new(1, -40, 0.5, -15),
            BackgroundColor3 = BG, Text = "+", TextColor3 = TXT, TextSize = 20, BorderSizePixel = 0 }, r)
        mk("UICorner", { CornerRadius = UDim.new(0, 6) }, plus)
        minus.Activated:Connect(function() set(math.max(lo, get() - step)); refresh() end)
        plus.Activated:Connect(function() set(math.min(hi, get() + step)); refresh() end)
        refresh()
    end
    function U.dropdown(text, options, cb)
        local r = rowFrame(42); mk("UICorner", { CornerRadius = UDim.new(0, 8) }, r)
        local btn = mk("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
            Text = "  " .. text .. ": " .. (options[1] or "-"), TextColor3 = TXT, TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham }, r)
        local fullH = math.min(#options, 5) * 32
        local list = mk("Frame", { Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = BG,
            BorderSizePixel = 0, Visible = false, LayoutOrder = ord(), ClipsDescendants = true }, content)
        mk("UICorner", { CornerRadius = UDim.new(0, 8) }, list)
        local sc = mk("ScrollingFrame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
            ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }, list)
        mk("UIListLayout", {}, sc)
        local function setOpen(open)
            list.Visible = open
            list.Size = open and UDim2.new(1, 0, 0, fullH) or UDim2.new(1, 0, 0, 0)
        end
        for _, opt in ipairs(options) do
            local ob = mk("TextButton", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Text = "  " .. opt,
                TextColor3 = TXT, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Gotham }, sc)
            ob.Activated:Connect(function() btn.Text = "  " .. text .. ": " .. opt; setOpen(false); cb(opt) end)
        end
        btn.Activated:Connect(function() setOpen(not list.Visible) end)
    end
    function U.label(t)
        local l = mk("TextLabel", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Text = t,
            TextColor3 = Color3.fromRGB(170, 176, 188), TextSize = 12, Font = Enum.Font.Gotham,
            TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = ord() }, content)
        return function(x) l.Text = x end
    end
    return U
end

local ok, err = pcall(function()
    local U = buildUI()

    U.section("FISHING")
    local syncAF = U.toggle("Auto Fish", false, function(v) setRunning(v) end)
    S.onRunChange = syncAF        -- keep the pill in sync when F1 toggles
    U.stepper("Cast power %", function() return CFG.cast_power_threshold end,
        function(v) CFG.cast_power_threshold = v end, 30, 100, 5)
    U.stepper("Equip slot", function() return CFG.equip_slot end,
        function(v) CFG.equip_slot = v end, 1, 9, 1)

    U.section("TRAVEL / LEVELING")
    local znames = _G.Fisch.zones()
    if #znames > 0 then
        local chosen = znames[1]
        U.dropdown("Zone", znames, function(o) chosen = o end)
        U.button("Teleport", function() teleportZone(chosen) end)
    else
        U.label("No zones found (Workspace.zones empty here).")
    end
    U.toggle("Smart Leveling (rotate zones)", false, function(v) if v then smartLevelStart() else smartLevelStop() end end)
    U.stepper("Seconds / zone", function() return CFG.level_dwell_s end,
        function(v) CFG.level_dwell_s = v end, 15, 180, 5)

    U.section("ACTIONS")
    U.toggle("Auto-sell", CFG.auto_sell, function(v) CFG.auto_sell = v end)
    U.button("Sell now", function() sellAll() end)
    U.toggle("Anti-AFK", CFG.anti_afk, function(v) CFG.anti_afk = v end)

    U.section("STATUS")
    local setStatus = U.label("idle")
    task.spawn(function() while true do task.wait(0.4); pcall(function() setStatus(_G.Fisch.status()) end) end end)
end)
if not ok then
    warn("[Fisch] GUI build failed (" .. tostring(err) .. ") — use the _G.Fisch console API: start()/stop()/tp(name)/status().")
end

print("[Fisch] loaded. Tap the 🎣 button (or F1) to open/toggle. Zones found: " .. tostring(#ZONES) .. ".")
