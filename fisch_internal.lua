--[[
    Fisch — Internal Auto-Fisher  (Matcha-ported engine)
    ====================================================
    For an injecting executor. Ports the proven Matcha reel controller (spam/predict/
    hybrid) + input-based cast. Input goes through VirtualInputManager (virtual — does
    NOT move your real cursor / hijack touch), so the bar is driven by real hold/release,
    not client-side position hacks.

      CAST : hold to charge, read rod.values.power, release ("let go") at >= 95
      REEL : Controller:run() -> spam | predict | hybrid, holding/releasing the bar
      SHAKE: click the shake button (firesignal), no resizing
      SELL : events.SellAll:InvokeServer()
    UI = Rayfield (on-screen mobile toggle).  Console: _G.Fisch.
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RepStorage  = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local VIM         = game:GetService("VirtualInputManager")
local CollectionService = game:GetService("CollectionService")
local plr = Players.LocalPlayer

----------------------------------------------------------------- remotes
local eventsFolder = RepStorage:WaitForChild("events")
local SellAll = eventsFolder:FindFirstChild("SellAll") or eventsFolder:FindFirstChild("selleverything")

----------------------------------------------------------------- bait equip (REAL game remote — same one the [Equip] button fires)
local Net; pcall(function() Net = require(RepStorage.packages.Net) end)
local BaitEquip; if Net then pcall(function() BaitEquip = Net:RemoteEvent("Bait/Equip", -1) end) end
local AnglerGetNeeded; if Net then pcall(function() AnglerGetNeeded = Net:RemoteFunction("Angler/GetNeeded", -1) end) end
local function equipBait(name)
    if not BaitEquip then return false end
    return pcall(function() BaitEquip:FireServer(name or "None") end)   -- "None" = unequip
end
-- build a mutation -> bait map straight from the game's own bait library (bait.Mutation + MutationChance)
local MUT_BAIT = {}   -- [mutation:lower] = { bait=<name>, chance=0..1, mut=<display> }
pcall(function()
    local lib = require(RepStorage.shared.modules.library.bait)
    for baitName, info in pairs(lib) do
        if type(info) == "table" and info.Mutation then
            local chance = 1
            if type(info.MutationChance) == "table" and info.MutationChance[2] and info.MutationChance[3] then
                chance = info.MutationChance[3] / info.MutationChance[2]
            end
            MUT_BAIT[tostring(info.Mutation):lower()] = { bait = baitName, chance = chance, mut = tostring(info.Mutation) }
        end
    end
end)

----------------------------------------------------------------- config
local CFG = {
    autoFish      = false,
    autoEquip     = true,
    reelMode      = "hybrid",   -- "spam" | "predict" | "hybrid"
    castHold      = 0.2,        -- hold the button this long, then let go -> cast
    autoSell      = false,
    sellEvery     = 120,
    antiAfk       = true,
}

----------------------------------------------------------------- input (VirtualInputManager — virtual, no real cursor)
local _held = false
local function _xy()
    local cam = workspace.CurrentCamera
    local vp = (cam and cam.ViewportSize) or Vector2.new(800, 600)
    return math.floor(vp.X * 0.5), math.floor(vp.Y * 0.5)
end
local function holdMouse()
    if _held then return end
    _held = true
    local x, y = _xy()
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
end
local function releaseMouse()
    if not _held then return end
    _held = false
    local x, y = _xy()
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 0) end)
end

----------------------------------------------------------------- rod detection + auto-equip
local function isRodTool(t)
    if not (t and t:IsA("Tool")) then return false end
    if t:FindFirstChild("rod/client") then return true end
    local e = t:FindFirstChild("events")
    return e ~= nil and (e:FindFirstChild("castAsync") ~= nil or e:FindFirstChild("cast") ~= nil)
end
local function getRod()
    local char = plr.Character
    if not char then return nil end
    for _, t in ipairs(char:GetChildren()) do if isRodTool(t) then return t end end
    return nil
end
local function findRodTool()
    local char, bp = plr.Character, plr:FindFirstChildOfClass("Backpack")
    local function scan(c) if c then for _, t in ipairs(c:GetChildren()) do if isRodTool(t) then return t end end end end
    return (char and scan(char)) or (bp and scan(bp))
end
local function ensureEquipped()
    if getRod() then return end
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local rod = findRodTool()
    if hum and rod and rod.Parent ~= char then pcall(function() hum:EquipTool(rod) end) end
end

----------------------------------------------------------------- reel GUI reads (0..1, bar-relative)
local function finite(v, lo, hi)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return false end
    if lo and v < lo then return false end
    if hi and v > hi then return false end
    return true
end
local function getReelBarContext()
    local pg = plr:FindFirstChildOfClass("PlayerGui")
    local reel = pg and pg:FindFirstChild("reel")
    local bar = reel and reel:FindFirstChild("bar")
    if not bar then return nil end
    local fish = bar:FindFirstChild("fish")
    local playerbar = bar:FindFirstChild("playerbar")
    if not (fish and playerbar) then return nil end
    return { bar = bar, fish = fish, playerbar = playerbar }
end
local function readFramePos(f, bar)   -- left edge, 0..1
    local ok, v = pcall(function() return (f.AbsolutePosition.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X end)
    return ok and v or 0
end
local function readFrameSize(f, bar)  -- width, 0..1
    local ok, v = pcall(function() return f.AbsoluteSize.X / bar.AbsoluteSize.X end)
    return ok and v or 0.001
end

----------------------------------------------------------------- reel controller (ported: spam / predict / hybrid)
local function clampn(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
local function posmod(v, m) m = math.max(0.001, m); local r = v % m; if r < 0 then r = r + m end return r end

local SPAM = { edge_boundary = 0.1, prediction_strength = 7.5, close_threshold = 0.01,
    neutral_duty_cycle = 0.5, proportional_gain = 0.42, derivative_gain = 0.55, velocity_damping = 38 }
local TUNE = {}
TUNE.predict = {
    Kp = 1.25, Ki = 0.06, Kd = 1.85, PdClamp = 34.0, IntegralClamp = 130.0,
    BarRatioFromSide = 0.6, CenterZoneRatio = 0.05,
    CenterPulsePeriodS = 0.024, CenterPulseHoldS = 0.1, CenterReleaseBlipS = 0.006,
    CenterWeakPeriodS = 0.026, CenterWeakHoldS = 0.006, OnThreshold = 7.0, OffThreshold = 3.5,
    UsePrediction = true, FishPredT = 0.165, BarPredT = 0.028, RightMoveLeadT = 0.085,
    FishVelAlpha = 0.82, BarVelAlpha = 0.78, PositionAlpha = 0.9, ControlAlpha = 0.94,
}
TUNE.hybrid = {
    EdgeBoundary = 0.1, CloseThreshold = 0.0055, PredictionStrength = 13.0, Resilience = 0.0, EnableHardCorrection = true,
    Kp = 2.7, Ki = 0.08, Kd = 3.6, PdClamp = 48.0, IntegralClamp = 130.0,
    BarRatioFromSide = 0.6, CenterZoneRatio = 0.05,
    CenterPulsePeriodS = 0.016, CenterPulseHoldS = 0.013, CenterReleaseBlipS = 0.006,
    CenterWeakPeriodS = 0.017, CenterWeakHoldS = 0.01, OnThreshold = 3.5, OffThreshold = 1.4,
    UsePrediction = false, FishPredT = 0.23, BarPredT = 0.045, RightMoveLeadT = 0.16,
    HoldAcceleration = 0.62, ReleaseAcceleration = -0.3, MaxVelocity = 1.05,
    FishVelAlpha = 0.9, BarVelAlpha = 0.86, PositionAlpha = 0.98, ControlAlpha = 0.99,
}

local Controller = {} Controller.__index = Controller
function Controller.new()
    return setmetatable({ lastPlayerbarPos = nil, lastFishPos = nil, pwmAcc = 0.0,
        hasLastFrame = false, lastTime = 0.0, prevFishX = 0.0, prevBarCenter = 0.0,
        fishVelEma = 0.0, barVelEma = 0.0, smoothFishX = 0.0, smoothBarCenter = 0.0, smoothControl = 0.0,
        errorIntegral = 0.0, centerPulseReleaseUntil = 0.0, wasInStableZone = false, stableHybridUntil = 0.0,
        trackingWarmupUntil = 0.0, lastBarRaw = nil, lastFishRaw = nil }, Controller)
end
function Controller:reset()
    self.lastPlayerbarPos, self.lastFishPos, self.pwmAcc = nil, nil, 0.0
    self.hasLastFrame, self.lastTime = false, 0.0
    self.prevFishX, self.prevBarCenter = 0.0, 0.0
    self.fishVelEma, self.barVelEma = 0.0, 0.0
    self.smoothFishX, self.smoothBarCenter, self.smoothControl = 0.0, 0.0, 0.0
    self.errorIntegral, self.centerPulseReleaseUntil = 0.0, 0.0
    self.trackingWarmupUntil = tick() + 0.2
    self.lastBarRaw, self.lastFishRaw = nil, nil
end
function Controller:Hold()    holdMouse()    end
function Controller:Release() releaseMouse() end
function Controller:_read(ctx)
    ctx = ctx or getReelBarContext()
    if not (ctx and ctx.fish and ctx.playerbar) then return nil end
    local fpx = readFramePos(ctx.fish, ctx.bar)
    local fsx = readFrameSize(ctx.fish, ctx.bar)
    local fishCenter = fpx + (fsx / 2)
    local pbx      = readFramePos(ctx.playerbar, ctx.bar)
    local barWidth = readFrameSize(ctx.playerbar, ctx.bar)
    if not finite(barWidth) or barWidth < 0.001 then barWidth = 0.001 end
    local barCenter = pbx + (barWidth / 2)
    if not finite(fishCenter, -0.5, 1.5) or not finite(barCenter, -0.5, 1.5) then return nil end
    return fishCenter, barCenter, barWidth
end
function Controller:update(ctx)  -- spam
    local fishPos, playerbarPos, _ = self:_read(ctx)
    if not fishPos then releaseMouse(); return end
    if self.lastPlayerbarPos == nil then self.lastPlayerbarPos = playerbarPos end
    if self.lastFishPos == nil then self.lastFishPos = fishPos end
    local playerbarVel = playerbarPos - self.lastPlayerbarPos; self.lastPlayerbarPos = playerbarPos
    local fishVel = fishPos - self.lastFishPos; self.lastFishPos = fishPos
    local err  = fishPos - playerbarPos
    local edge = SPAM.edge_boundary
    if playerbarPos < edge     then holdMouse();    return end
    if playerbarPos > 1 - edge then releaseMouse(); return end
    local predicted    = playerbarPos + (playerbarVel * SPAM.prediction_strength)
    local predictedErr = fishPos - predicted
    local close        = SPAM.close_threshold
    local sameSideAfter = (err * predictedErr) > 0
    local approaching   = (err * playerbarVel) > 0
    local remaining     = math.max(0.0, math.abs(err) - close)
    local brake         = math.abs(playerbarVel) * 8
    local needsPreSlow  = approaching and (brake >= remaining)
    if math.abs(err) > close and sameSideAfter and not needsPreSlow then
        if err > 0 then holdMouse() else releaseMouse() end; return
    end
    local neutral, targetDuty = SPAM.neutral_duty_cycle, nil
    if needsPreSlow and brake > 0 then
        local urgency = 1.0 - math.min(1.0, remaining / brake)
        if err > 0 then targetDuty = neutral * (1.0 - urgency)
        else            targetDuty = neutral + ((1.0 - neutral) * urgency) end
    else
        local adj = (SPAM.proportional_gain * err) + (SPAM.derivative_gain * fishVel) - (SPAM.velocity_damping * playerbarVel)
        targetDuty = math.max(0.0, math.min(1.0, neutral + adj))
    end
    self.pwmAcc = self.pwmAcc + targetDuty
    if self.pwmAcc >= 1.0 then self.pwmAcc = self.pwmAcc - 1.0; holdMouse() else releaseMouse() end
end
function Controller:updatePredict(ctx)
    local fishCenter, barCenter, barWidth01 = self:_read(ctx)
    if not fishCenter then self:Release(); return end
    local s, now = TUNE.predict, tick()
    local dt = self.hasLastFrame and math.max(0.001, now - self.lastTime) or 0.016
    local fishX, bar, barWidth = fishCenter * 1000.0, barCenter * 1000.0, math.max(1.0, barWidth01 * 1000.0)
    if not self.hasLastFrame then
        self.smoothFishX, self.smoothBarCenter = fishX, bar
        self.prevFishX, self.prevBarCenter = fishX, bar
        self.lastTime, self.hasLastFrame = now, true
    else
        local alpha = clampn(s.PositionAlpha, 0.2, 0.92)
        self.smoothFishX     = alpha * fishX + (1.0 - alpha) * self.smoothFishX
        self.smoothBarCenter = alpha * bar   + (1.0 - alpha) * self.smoothBarCenter
    end
    local fishVel = (self.smoothFishX - self.prevFishX) / dt
    local barVel  = (self.smoothBarCenter - self.prevBarCenter) / dt
    self.fishVelEma = s.FishVelAlpha * fishVel + (1.0 - s.FishVelAlpha) * self.fishVelEma
    self.barVelEma  = s.BarVelAlpha  * barVel  + (1.0 - s.BarVelAlpha)  * self.barVelEma
    self.prevFishX, self.prevBarCenter, self.lastTime = self.smoothFishX, self.smoothBarCenter, now
    local err
    if s.UsePrediction then
        local baseError = self.smoothFishX - self.smoothBarCenter
        local fishLead = clampn(self.fishVelEma * s.FishPredT, -math.max(2.0, barWidth * 0.18), math.max(2.0, barWidth * 0.18))
        local barLead  = clampn(self.barVelEma  * s.BarPredT,  -math.max(2.0, barWidth * 0.12), math.max(2.0, barWidth * 0.12))
        local predictedError = self.smoothFishX + 0.5 * fishLead - (self.smoothBarCenter + 0.35 * barLead)
        err = 0.65 * baseError + 0.35 * predictedError
    else err = self.smoothFishX - self.smoothBarCenter end
    if self.fishVelEma > 0 and err > -barWidth * 0.1 then
        err = err + clampn(self.fishVelEma * s.RightMoveLeadT, 0, math.max(2.0, barWidth * 0.22))
    end
    err = err + clampn(barWidth * 0.035, 1.5, 5.0)
    self.errorIntegral = clampn(self.errorIntegral + err * dt, -s.IntegralClamp, s.IntegralClamp)
    local sideMargin = barWidth * s.BarRatioFromSide
    local clampV = math.max(s.PdClamp > 0 and s.PdClamp or 30.0, s.OnThreshold + 1.0)
    local rawControl
    if self.smoothFishX < sideMargin then rawControl = -clampV
    elseif self.smoothFishX > 1000.0 - sideMargin then rawControl = clampV
    else
        local relVel = self.fishVelEma - self.barVelEma
        rawControl = s.Kp * err + s.Ki * self.errorIntegral + s.Kd * relVel
        if s.PdClamp > 0 then rawControl = clampn(rawControl, -s.PdClamp, s.PdClamp) end
    end
    self.smoothControl = s.ControlAlpha * rawControl + (1.0 - s.ControlAlpha) * self.smoothControl
    local control = self.smoothControl
    local hold
    local centerZone = math.max(2.0, barWidth * s.CenterZoneRatio)
    if math.abs(err) <= centerZone then
        if now < self.centerPulseReleaseUntil then hold = false
        elseif control > s.OnThreshold then
            hold = posmod(now, s.CenterPulsePeriodS) < math.max(0.001, s.CenterPulseHoldS)
            if hold then self.centerPulseReleaseUntil = now + math.max(0, s.CenterReleaseBlipS) end
        elseif control < -s.OnThreshold then hold = false
        elseif control > 0 then hold = posmod(now, s.CenterWeakPeriodS) < math.max(0.001, s.CenterWeakHoldS)
        else hold = false end
    else
        if control > s.OnThreshold then hold = true elseif control < -s.OnThreshold then hold = false else hold = false end
    end
    if hold then self:Hold() else self:Release() end
end
function Controller:_hybridFine(fishCenter, barCenter, barWidth01, now, s)
    local fishX, barC, barWidth = fishCenter * 1000.0, barCenter * 1000.0, math.max(1.0, barWidth01 * 1000.0)
    local dt = self.hasLastFrame and math.max(0.001, now - self.lastTime) or 0.016
    if not self.hasLastFrame then
        self.smoothFishX, self.smoothBarCenter = fishX, barC
        self.prevFishX, self.prevBarCenter = fishX, barC
        self.lastTime, self.hasLastFrame = now, true
    else
        local alpha = clampn(s.PositionAlpha, 0.2, 0.92)
        self.smoothFishX     = alpha * fishX + (1.0 - alpha) * self.smoothFishX
        self.smoothBarCenter = alpha * barC  + (1.0 - alpha) * self.smoothBarCenter
    end
    local fishVelRaw = (self.smoothFishX - self.prevFishX) / dt
    local barVelRaw  = (self.smoothBarCenter - self.prevBarCenter) / dt
    self.fishVelEma = s.FishVelAlpha * fishVelRaw + (1.0 - s.FishVelAlpha) * self.fishVelEma
    self.barVelEma  = s.BarVelAlpha  * barVelRaw  + (1.0 - s.BarVelAlpha)  * self.barVelEma
    local maxv = math.max(1.0, s.MaxVelocity * 1000.0)
    self.barVelEma = clampn(self.barVelEma, -maxv, maxv)
    self.prevFishX, self.prevBarCenter, self.lastTime = self.smoothFishX, self.smoothBarCenter, now
    local err
    if s.UsePrediction then
        local baseError = self.smoothFishX - self.smoothBarCenter
        local fishLead = clampn(self.fishVelEma * s.FishPredT, -math.max(2.0, barWidth * 0.18), math.max(2.0, barWidth * 0.18))
        local holdingForPred = self.smoothControl > 0
        local measuredAccel = (holdingForPred and s.HoldAcceleration or s.ReleaseAcceleration) * 1000.0
        local predictedBarVel = clampn(self.barVelEma + measuredAccel * s.BarPredT, -maxv, maxv)
        local barLead = clampn(predictedBarVel * s.BarPredT, -math.max(2.0, barWidth * 0.12), math.max(2.0, barWidth * 0.12))
        local predictedError = self.smoothFishX + 0.25 * fishLead - (self.smoothBarCenter + 0.175 * barLead)
        err = 0.65 * baseError + 0.35 * predictedError
    else err = self.smoothFishX - self.smoothBarCenter end
    if self.fishVelEma > 0 and err > -barWidth * 0.1 then
        err = err + clampn(self.fishVelEma * s.RightMoveLeadT, 0, math.max(2.0, barWidth * 0.22))
    end
    err = err + clampn(barWidth * 0.035, 1.5, 5.0)
    self.errorIntegral = clampn(self.errorIntegral + err * dt, -s.IntegralClamp, s.IntegralClamp)
    local sideMargin = barWidth * s.BarRatioFromSide
    local clampV = math.max(s.PdClamp > 0 and s.PdClamp or 30.0, s.OnThreshold + 1.0)
    local rawControl
    if self.smoothFishX < sideMargin then rawControl = -clampV
    elseif self.smoothFishX > 1000.0 - sideMargin then rawControl = clampV
    else
        local relVel = self.fishVelEma - self.barVelEma
        rawControl = s.Kp * err + s.Ki * self.errorIntegral + s.Kd * relVel
        if s.PdClamp > 0 then rawControl = clampn(rawControl, -s.PdClamp, s.PdClamp) end
    end
    self.smoothControl = s.ControlAlpha * rawControl + (1.0 - s.ControlAlpha) * self.smoothControl
    local control = self.smoothControl
    local centerZone = math.max(2.0, barWidth * s.CenterZoneRatio)
    local desiredHold
    if math.abs(err) <= centerZone then
        local enteringStable = not self.wasInStableZone
        self.wasInStableZone = true
        if enteringStable then self.stableHybridUntil = now + 3.0 end
        if now < self.stableHybridUntil then
            if control > s.OnThreshold then desiredHold = true elseif control < -s.OnThreshold then desiredHold = false else desiredHold = false end
        else
            if now < self.centerPulseReleaseUntil then desiredHold = false
            elseif control > s.OnThreshold then
                local h = posmod(now, s.CenterPulsePeriodS) < math.max(0.001, s.CenterPulseHoldS)
                if h then self.centerPulseReleaseUntil = now + math.max(0, s.CenterReleaseBlipS) end
                desiredHold = h
            elseif control < -s.OnThreshold then desiredHold = false
            else desiredHold = (control > 0) and (posmod(now, s.CenterWeakPeriodS) < math.max(0.001, s.CenterWeakHoldS)) end
        end
    else
        self.wasInStableZone = false
        if control > s.OnThreshold then desiredHold = true elseif control < -s.OnThreshold then desiredHold = false else desiredHold = false end
    end
    return desiredHold
end
function Controller:updateHybrid(ctx)
    local fishCenter, barCenter, barWidth01 = self:_read(ctx)
    if not fishCenter then self:Release(); return end
    local s, now = TUNE.hybrid, tick()
    if self.lastBarRaw  == nil then self.lastBarRaw  = barCenter end
    if self.lastFishRaw == nil then self.lastFishRaw = fishCenter end
    local playerbarVelocity = barCenter - self.lastBarRaw
    self.lastBarRaw, self.lastFishRaw = barCenter, fishCenter
    local err = fishCenter - barCenter
    if now < self.trackingWarmupUntil then
        local warmupDeadzone = math.max(0.015, barWidth01 * 0.04)
        if err > warmupDeadzone then self:Hold() else self:Release() end; return
    end
    if barCenter < s.EdgeBoundary then self:Hold(); return end
    if barCenter > 1.0 - s.EdgeBoundary then self:Release(); return end
    if s.EnableHardCorrection and math.abs(err) > s.CloseThreshold then
        local predicted = barCenter + playerbarVelocity * (s.PredictionStrength * (1.0 - s.Resilience))
        local predictedError = fishCenter - predicted
        local sameSide = (err * predictedError) > 0
        local approaching = (err * playerbarVelocity) > 0
        local remaining = math.max(0.0, math.abs(err) - s.CloseThreshold)
        local needsPreSlow = approaching and (math.abs(playerbarVelocity) * 8.0 >= remaining)
        if sameSide and not needsPreSlow then
            if err > 0 then self:Hold() else self:Release() end; return
        end
    end
    local hold = self:_hybridFine(fishCenter, barCenter, barWidth01, now, s)
    if hold then self:Hold() else self:Release() end
end
function Controller:run(ctx)
    local m = CFG.reelMode
    if m == "predict" then return self:updatePredict(ctx) end
    if m == "hybrid"  then return self:updateHybrid(ctx)  end
    return self:update(ctx)
end
local ctrl = Controller.new()

----------------------------------------------------------------- cast (input-based: charge, let go at >=95)
-- hold the button briefly (CFG.castHold), then let go -> cast.
local castStartAt = 0
local function stepCharge()
    holdMouse()
    if castStartAt == 0 then castStartAt = tick() end
    if tick() - castStartAt >= CFG.castHold then
        releaseMouse(); castStartAt = 0
    end
end

----------------------------------------------------------------- shake (click the button, no resize)
local _lastShake = 0
local function doShake(sui)
    local sz = sui:FindFirstChild("safezone")
    local btn = sz and (sz:FindFirstChild("button") or sz:FindFirstChildWhichIsA("ImageButton") or sz:FindFirstChildWhichIsA("TextButton"))
    if not btn then return end
    if type(firesignal) == "function" then pcall(firesignal, btn.MouseButton1Click); pcall(firesignal, btn.Activated, nil, 1) end
    if type(replicatesignal) == "function" then pcall(replicatesignal, btn.MouseButton1Click) end
end

----------------------------------------------------------------- main loop
if _G.__FischConn then pcall(function() _G.__FischConn:Disconnect() end) end
local _wasReeling = false
_G.__FischConn = RunService.Heartbeat:Connect(function()
    if not CFG.autoFish then if _held then releaseMouse() end return end
    pcall(function()
        local pg = plr:FindFirstChildOfClass("PlayerGui")
        if not pg then return end
        local reelUI  = pg:FindFirstChild("reel")
        local shakeUI = pg:FindFirstChild("shakeui")
        if reelUI and getReelBarContext() then
            if not _wasReeling then ctrl:reset(); _wasReeling = true end
            castStartAt = 0
            ctrl:run()
        else
            if _wasReeling then releaseMouse(); _wasReeling = false end
            if shakeUI then
                releaseMouse()
                if tick() - _lastShake >= 0.08 then doShake(shakeUI); _lastShake = tick() end
                castStartAt = 0
            else
                local rod = getRod()
                if CFG.autoEquip and not rod then ensureEquipped(); rod = getRod() end
                local vals   = rod and rod:FindFirstChild("values")
                local casted = vals and vals:FindFirstChild("casted")
                if casted and casted.Value == true then
                    releaseMouse(); castStartAt = 0        -- bobber out, waiting for a bite
                elseif rod then
                    stepCharge()                           -- charge for CFG.chargeTime, then let go
                else
                    releaseMouse()
                end
            end
        end
    end)
end)

----------------------------------------------------------------- sell / teleport / quests / anti-afk
local function sellAll()
    if not SellAll then return false end
    return pcall(function() if SellAll:IsA("RemoteFunction") then return SellAll:InvokeServer() else SellAll:FireServer() end end)
end
task.spawn(function() while true do task.wait(math.max(15, CFG.sellEvery)); if CFG.autoSell then pcall(sellAll) end end end)

local LOCATIONS = {
    ["Moosewood"]=Vector3.new(368.20,140.31,239.53), ["Roslit Bay"]=Vector3.new(-1456.52,149.10,634.93),
    ["Sunstone Island"]=Vector3.new(-953.45,237.10,-984.76), ["Mushgrove Swamp"]=Vector3.new(2687.99,140.72,-731.67),
    ["Terrapin Island"]=Vector3.new(-172.42,149.40,1954.48), ["Snowcap Island"]=Vector3.new(2607.62,143.21,2396.54),
    ["Statue of Sovereignty"]=Vector3.new(-3.60,428.08,-1120.39), ["Haddock Rock"]=Vector3.new(-606.35,212.82,-465.77),
    ["Earmark Island"]=Vector3.new(1228.76,160.95,504.75), ["The Arch"]=Vector3.new(1052.07,321.86,-1249.91),
}
pcall(function()
    local f = workspace:FindFirstChild("zones") and workspace.zones:FindFirstChild("fishing")
    if f then for _, z in ipairs(f:GetChildren()) do if z:IsA("BasePart") and not LOCATIONS[z.Name] then LOCATIONS[z.Name] = z.Position end end end
end)
local function locNames() local t = {} for n in pairs(LOCATIONS) do t[#t+1]=n end table.sort(t) return t end
local function teleport(name)
    local pos, hrp = LOCATIONS[name], plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if pos and hrp then pcall(function() hrp.CFrame = CFrame.new(pos + Vector3.new(0,5,0)) end) end
end

-- AUTO-QUEST engine (ban-safe: drives the game's OWN dialog UI — fires the NPC's
-- ProximityPrompt + clicks the real accept/turn-in TextButtons via firesignal. NO forged
-- quest/completion remotes.) "All quests available for your level" is handled by the game
-- itself: it only shows a quest marker (billboard) over NPCs whose quests you're eligible
-- for, so we drive off that marker instead of a hardcoded quest list.
local Quest = { on = false, status = "off" }
local anglerGrind = false   -- smart angler grind (reads needed fish from Angler/GetNeeded)
local ACCEPT_WORDS = { "accept","take quest","start quest","do it","sure","yes","okay","ok",
    "continue","next","give","turn in","turn-in","hand in","hand-in","complete","claim","deliver","reward" }
local BAD_GUI = { "shop","store","buy","sell","trade","inventory","backpack","menu","setting","market","gacha","crate","teleport" }

local function npcRoot(m) return m and (m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")) end
local function npcContainers()
    local t, w = {}, workspace:FindFirstChild("world")
    if w and w:FindFirstChild("npcs") then t[#t+1] = w.npcs end
    if workspace:FindFirstChild("npcs") then t[#t+1] = workspace.npcs end
    return t
end
local function modelHasQuestMarker(m)
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BillboardGui") and d.Enabled and d.Name:lower():find("quest") then return true end
    end
    return false
end
local function findQuestNpcs()
    local out = {}
    for _, c in ipairs(npcContainers()) do
        for _, m in ipairs(c:GetChildren()) do
            if m:IsA("Model") and npcRoot(m) and modelHasQuestMarker(m) then out[#out+1] = m end
        end
    end
    return out
end
local function nearestQuestNpc()
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local best, bd
    for _, m in ipairs(findQuestNpcs()) do
        local d = (npcRoot(m).Position - hrp.Position).Magnitude
        if not bd or d < bd then best, bd = m, d end
    end
    return best, bd
end
local function tpToPos(pos)
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if hrp and pos then pcall(function() hrp.CFrame = CFrame.new(pos + Vector3.new(0, 6, 0)) end) end
end
local function firePromptsIn(m)
    if type(fireproximityprompt) ~= "function" then return false end
    local any = false
    for _, d in ipairs(m:GetDescendants()) do if d:IsA("ProximityPrompt") then pcall(fireproximityprompt, d); any = true end end
    return any
end
local function inBadGui(inst)
    local a = inst
    while a and a ~= game do
        local n = (a.Name or ""):lower()
        for _, b in ipairs(BAD_GUI) do if n:find(b) then return true end end
        a = a.Parent
    end
    return false
end
-- click the game's own accept/turn-in dialog buttons; returns how many we clicked
local function clickDialogAccepts()
    local pg = plr:FindFirstChildOfClass("PlayerGui"); if not pg then return 0 end
    local n = 0
    for _, g in ipairs(pg:GetDescendants()) do
        if g:IsA("TextButton") and g.Visible and not inBadGui(g) then
            local txt = type(g.Text) == "string" and g.Text:lower() or ""
            local hit = false
            for _, w in ipairs(ACCEPT_WORDS) do if txt ~= "" and txt:find(w, 1, true) then hit = true break end end
            if hit then
                if type(firesignal) == "function" then pcall(firesignal, g.MouseButton1Click); pcall(firesignal, g.Activated, nil, 1) end
                if type(replicatesignal) == "function" then pcall(replicatesignal, g.MouseButton1Click) end
                n = n + 1
            end
        end
    end
    return n
end
-- engine loop: accept -> travel -> talk -> (fish to complete) -> return -> turn in -> next
task.spawn(function()
    while true do
        task.wait(0.7)
        if not Quest.on then Quest.status = "off"
        else
            pcall(function()
                -- 1) any accept/turn-in button on screen? click it (covers accept AND hand-in)
                if clickDialogAccepts() > 0 then Quest.status = "dialog — accepting / turning in"; return end
                -- 2) find an NPC currently showing a quest marker (offer or ready-to-collect)
                local m, dist = nearestQuestNpc()
                if not m then
                    Quest.status = "quest in progress — fishing"   -- no marker => quest accepted, go complete it
                    CFG.autoFish = true
                    return
                end
                local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart"); if not hrp then return end
                -- 3) travel to the NPC, then open dialog
                if (dist or 999) > 16 then
                    Quest.status = ("travel -> %s (%dm)"):format(m.Name, math.floor(dist or 0))
                    CFG.autoFish = false
                    tpToPos(npcRoot(m).Position)
                else
                    Quest.status = ("talking to %s"):format(m.Name)
                    CFG.autoFish = false
                    firePromptsIn(m)
                    task.wait(0.3)
                    clickDialogAccepts()
                end
            end)
        end
    end
end)
local function setQuests(v) Quest.on = v; if v then CFG.autoFish = true else Quest.status = "off" end end

-- researched quest knowledge (Fisch, July 2026) ------------------------------
-- ROD PATH (buy at Marc's Shop, Moosewood): Flimsy(start) -> Carbon(~800C, first buy)
--   -> Rapid(14kC, 89% lure / 49% luck = fastest XP)  | alt Steady(7kC, easy timing + huge weight = mobile-friendly)
-- ONE-TIME ROD QUESTS: talk to the NPC, catch the target fish at its zone, return & turn in for the rod.
local ROD_QUESTS = {
    { npc = "Orc",    zone = "Roslit Bay",      fish = "Pufferfish", reward = "Magma Rod"  },
    { npc = "Agaric", zone = "Mushgrove Swamp", fish = "Alligator",  reward = "Fungal Rod" },
}
-- ANGLER quests (repeatable): accept -> catch the REQUESTED fish -> hand in to any Angler -> ~2min cooldown.
-- The Depths angler always requests a Depths-local fish (ideal auto-grind) but needs the descent to reach.
local ANGLER_SPOTS = { "Moosewood", "Roslit Bay", "Sunstone Island", "Terrapin Island" }
local anglerSpot = "Moosewood"

local function parkAtSpot(name) teleport(name); anglerGrind = true; Quest.on = false; Quest.status = "smart angler grind @ " .. tostring(name) end
local function doRodQuest(rq)
    if not rq then return end
    teleport(rq.zone); CFG.autoFish = true; Quest.on = true
    Quest.status = ("rod quest: %s -> catch %s @ %s (reward %s)"):format(rq.npc, rq.fish, rq.zone, rq.reward)
end

-- MUTATION knowledge base (Fisch, July 2026): how to obtain each mutation a quest might ask for.
--   via:  bait  -> equip that bait (bot CAN force it)   | rod    -> equip that rod (CAN force, if owned)
--         weather -> wait for that weather (can't force) | event  -> only during that event (can't force)
local MUTATIONS = {
    { name="Part",         via="bait",    key="Part Bait",         mult="0.01x", note="100% w/ Part Bait — quest-only, junk value" },
    { name="Dirty",        via="bait",    key="Earthworm Bait",    mult="0.3x",  note="basic worm bait" },
    { name="Neon",         via="bait",    key="Hourglass Bait",    mult="1x",    note="" },
    { name="Nullified",    via="bait",    key="Nullbit Bait",      mult="5x",    note="" },
    { name="Galactic",     via="bait",    key="Astrolure Bait",    mult="5x",    note="" },
    { name="Colossal Ink", via="bait",    key="Colossal Ink Bait", mult="5x",    note="" },
    { name="Glowy",        via="bait",    key="Glowworm",          mult="8x",    note="bait from AFK Mine rewards" },
    { name="Aurora",       via="bait",    key="Aurora Bait",       mult="6.5x",  note="15% w/ bait (also 1% in Aurora Borealis weather)" },
    { name="Blarney",      via="bait",    key="Lucky Bait",        mult="?",     note="~50%, Lucky-event bait" },
    { name="Jolly",        via="bait",    key="Holly Berry",       mult="?",     note="~20%, from Festive Crates" },
    { name="Chocolate",    via="event",   key="Chocolate Fish",    mult="?",     note="100% but Valentine's-event bait only" },
    { name="Nova",         via="weather", key="Starfall",          mult="6x",    note="~5% during Starfall" },
    { name="Cursed",       via="weather", key="Cursed Storm",      mult="4x",    note="~8% during Cursed Storm" },
    { name="Blighted",     via="weather", key="Blizzard",          mult="3x",    note="~15% during Blizzard" },
    { name="Solarblaze",   via="weather", key="Eclipse",           mult="3x",    note="~10% during Eclipse" },
    { name="Distraught",   via="rod",     key="Dreambreaker Rod",  mult="8.5x",  note="25% day / 35% night w/ that rod" },
    { name="Tryhard",      via="rod",     key="Tryhard Rod",       mult="10x",   note="100% w/ Tryhard Rod (Lvl 999 quest)" },
}
-- FISH knowledge base (quest-relevant seed; extend as quests demand). zone must match a Travel location.
local FISH = {   -- fallback seed; the live resolver below covers everything else
    ["Pufferfish"] = { zone = "Roslit Bay",      note = "Roslit Coral Reef" },
    ["Alligator"]  = { zone = "Mushgrove Swamp", note = "swamp water" },
}
-- LIVE fish resolver from the game's own libraries (BestiaryController pattern):
--   library.fish[name].From/.FromLimited -> library.locations[key].Name = the zone
--   + per-fish FavouriteBait / Weather / FavouriteTime / Seasons
local FishLib; pcall(function() FishLib = require(RepStorage.shared.modules.library.fish) end)
local LocLib;  pcall(function() LocLib  = require(RepStorage.shared.modules.library.locations) end)
local function fishData(name)
    local f = FishLib and FishLib[name]
    if not f then return nil end
    local key = f.From or f.FromLimited
    local zoneName = (key and key ~= "None" and LocLib and LocLib[key] and LocLib[key].Name) or nil
    return { rarity = f.Rarity, zoneName = zoneName, bait = f.FavouriteBait,
             weather = f.Weather, time = f.FavouriteTime, seasons = f.Seasons, desc = f.Description }
end
-- map a region display-name to one of our teleport LOCATIONS (exact, then fuzzy)
local function matchLocation(zoneName)
    if not zoneName then return nil end
    if LOCATIONS[zoneName] then return zoneName end
    local zl = tostring(zoneName):lower()
    for n in pairs(LOCATIONS) do
        local nl = n:lower()
        if nl == zl or nl:find(zl, 1, true) or zl:find(nl, 1, true) then return n end
    end
    return nil
end
local function mutInfo(name) for _, m in ipairs(MUTATIONS) do if m.name:lower() == tostring(name):lower() then return m end end end
local function canForceMut(m) return m and (m.via == "bait" or m.via == "rod") end   -- bait/rod = bot can set up; weather/event = must wait
-- equip the bait that yields <mutation> (prefers the game's live bait library, falls back to the static table)
local function equipBaitForMutation(mutName)
    local e = MUT_BAIT[tostring(mutName):lower()]
    if e then equipBait(e.bait); return e.bait end
    local m = mutInfo(mutName)
    if m and m.via == "bait" then equipBait(m.key); return m.key end
    return nil
end
local function howTo(name)
    local live = MUT_BAIT[tostring(name):lower()]
    local m = mutInfo(name)
    if live then
        return ("mutation [bait] -> equip '%s'  (~%d%%)%s"):format(live.bait, math.floor(live.chance*100 + 0.5), m and ("  x"..m.mult) or "")
    end
    if m then
        local verb = (m.via=="bait" and "equip bait ") or (m.via=="rod" and "equip rod ") or (m.via=="weather" and "wait for weather ") or "event-only "
        return ("mutation [%s] -> %s'%s'  x%s  %s"):format(m.via, verb, m.key, m.mult, m.note)
    end
    local fd = fishData(name)
    if fd then
        local bits = { "fish -> " .. (fd.zoneName and ("go to "..fd.zoneName) or "regionless (any water)") }
        if type(fd.bait)=="string" and fd.bait~="" and fd.bait~="Any" then bits[#bits+1] = "pref bait "..fd.bait end
        if type(fd.weather)=="table" and #fd.weather>0 then bits[#bits+1] = "weather "..table.concat(fd.weather,"/") end
        if fd.time and fd.time~="Any" then bits[#bits+1] = tostring(fd.time) end
        return table.concat(bits, ", ")
    end
    local f = FISH[name]
    if f then return ("fish -> go to %s"):format(f.zone) end
    return "no record for '" .. tostring(name) .. "' yet"
end
-- plan how to satisfy a quest that wants <fish> [with <mutation>]
local function planCatch(fishName, mutName)
    local out = {}
    local fd = fishData(fishName)
    local seed = FISH[fishName or ""]
    local zone = (fd and fd.zoneName) or (seed and seed.zone)
    out[#out+1] = zone and ("fish "..fishName.." @ "..zone) or ("fish "..tostring(fishName).." (regionless / any water)")
    if fd then
        if type(fd.weather)=="table" and #fd.weather>0 then out[#out+1] = "weather "..table.concat(fd.weather,"/") end
        if fd.time and fd.time~="Any" then out[#out+1] = "time "..tostring(fd.time) end
    end
    if mutName and mutName ~= "" then
        local live = MUT_BAIT[tostring(mutName):lower()]
        local m = mutInfo(mutName)
        if live then out[#out+1] = "equip bait "..live.bait
        elseif canForceMut(m) then out[#out+1] = ((m.via=="rod") and "equip rod " or "equip bait ")..m.key
        elseif m then out[#out+1] = mutName..": "..m.via.." — can't force ("..m.key..")"
        else out[#out+1] = mutName..": no record" end
    end
    return table.concat(out, "   +   ")
end
-- one call: resolve the fish's zone, equip the right bait (mutation bait > preferred bait), start fishing
local function catchTarget(fishName, mutName)
    local fd = fishData(fishName)
    local zoneKey = (fd and fd.zoneName and matchLocation(fd.zoneName)) or (FISH[fishName or ""] and FISH[fishName].zone) or nil
    if zoneKey then teleport(zoneKey) end
    if mutName and mutName ~= "" then equipBaitForMutation(mutName)
    elseif fd and type(fd.bait)=="string" and fd.bait~="" and fd.bait~="Any" then equipBait(fd.bait) end
    CFG.autoFish = true; Quest.on = false
    Quest.status = "target: " .. planCatch(fishName, mutName)
end

-- LIVE fetch-quest database from the game's own module (shared.modules.SimpleFetchQuests):
-- each NPC -> Objectives (CatchFish/ObtainItem with Fish/Item/Rods/PlayerZones) + Rewards + dialogs.
local FetchQuests; pcall(function() FetchQuests = require(RepStorage.shared.modules.SimpleFetchQuests) end)
local function boldNames(dialogList)   -- fish/items are often named in <b>..</b> inside the ask
    local names = {}
    if type(dialogList) == "table" then
        for _, line in ipairs(dialogList) do
            if type(line) == "string" then
                for cap in line:gmatch("<b>(.-)</b>") do
                    cap = cap:gsub("<[^>]->", ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if cap ~= "" then names[#names+1] = cap end
                end
            end
        end
    end
    return names
end
-- most Divers name the fish in PLAIN dialogue text (no field, no bold). Match against the real
-- fish library so "bring me a Mastered Bigeye Houndshark" -> "Bigeye Houndshark".
local function fishNamesInText(lines)
    if not FishLib then return {} end
    local text = ""
    if type(lines) == "table" then for _, l in ipairs(lines) do if type(l) == "string" then text = text .. " " .. l end end end
    local hits = {}
    for name, info in pairs(FishLib) do
        if type(name) == "string" and type(info) == "table" and info.Rarity and #name >= 4 and text:find(name, 1, true) then
            hits[#hits+1] = name
        end
    end
    table.sort(hits, function(a, b) return #a > #b end)               -- longest first
    local out = {}
    for _, n in ipairs(hits) do                                       -- drop names contained in a longer hit
        local sub = false
        for _, m in ipairs(out) do if m ~= n and m:find(n, 1, true) then sub = true break end end
        if not sub then out[#out+1] = n end
    end
    return out
end
local function questInfo(npc)
    local q = FetchQuests and FetchQuests[npc]
    if type(q) ~= "table" then return nil end
    local fish, rods, zones = {}, {}, {}
    for _, obj in ipairs(q.Objectives or {}) do
        if type(obj) == "table" then
            for _, f in ipairs(obj.Fish or obj.Item or {}) do fish[#fish+1] = f end
            for _, r in ipairs(obj.Rods or {}) do rods[#rods+1] = r end
            for _, z in ipairs(obj.PlayerZones or {}) do zones[#zones+1] = z end
        end
    end
    if #fish == 0 then fish = boldNames(q.InitialDialog) end          -- then the bolded ask
    if #fish == 0 then fish = fishNamesInText(q.InitialDialog) end     -- then any known fish named in the text
    return { fish = fish, rods = rods, zones = zones, rewards = q.Rewards, dialog = q.InitialDialog }
end
local function questNames()
    local t = {}
    if FetchQuests then for n in pairs(FetchQuests) do if type(n)=="string" and n~="_" then t[#t+1]=n end end end
    table.sort(t); return t
end
local function rewardText(rewards)
    local out = {}
    for _, r in ipairs(rewards or {}) do
        if type(r) == "table" then
            if r[1]=="Xp" then out[#out+1] = tostring(r[2]).." XP"
            elseif r[1]=="Coin" then out[#out+1] = tostring(r[2]).." C$"
            elseif r[1]=="Rod" or r[1]=="Skin" or r[1]=="Boat" or r[1]=="Bobber" or r[1]=="Lantern" or r[1]=="Emote" then out[#out+1] = r[1]..": "..tostring(r[2])
            elseif r[1]=="ItemOrFish" then out[#out+1] = tostring(r[2])..(r[4] and (" x"..r[4]) or "")
            elseif r[1]=="Bait" then out[#out+1] = "Bait: "..tostring(r[2])..(r[3] and (" x"..r[3]) or "")
            elseif r[1]=="LocalCurrency" then out[#out+1] = tostring(r[3]).." "..tostring(r[2]) end
        end
    end
    return table.concat(out, ", ")
end
-- plan a fetch quest: each required fish -> its zone + preferred bait, plus rod/zone constraints + rewards
local function questPlan(npc)
    local qi = questInfo(npc)
    if not qi then return "no quest data for '"..tostring(npc).."'" end
    local lines = {}
    for _, f in ipairs(qi.fish) do lines[#lines+1] = "• "..planCatch(f, "") end
    if #qi.rods  > 0 then lines[#lines+1] = "needs rod: "..table.concat(qi.rods, " / ") end
    if #qi.zones > 0 then lines[#lines+1] = "zone-locked: "..table.concat(qi.zones, " / ") end
    if #lines == 0 then lines[1] = "(objective not fish-based — see dialog)" end
    local rw = rewardText(qi.rewards); if rw ~= "" then lines[#lines+1] = "reward: "..rw end
    return table.concat(lines, "\n")
end

-- SMART ANGLER GRIND: anglers are CollectionService "NewNpc" tagged, NpcType=="Angler", with a UID.
-- Angler/GetNeeded:InvokeServer(UID) returns the exact fish that angler wants (read-only query).
local function anglerNpcs()
    local out = {}
    for _, npc in ipairs(CollectionService:GetTagged("NewNpc")) do
        if npc:GetAttribute("NpcType") == "Angler" and npc:IsDescendantOf(workspace) then
            out[#out+1] = { npc = npc, uid = npc:GetAttribute("UID") }
        end
    end
    return out
end
local function anglerNeededFish(uid)
    if not (AnglerGetNeeded and uid ~= nil) then return nil end
    local ok, fish = pcall(function() return AnglerGetNeeded:InvokeServer(uid) end)
    if ok and type(fish) == "string" and fish ~= "" then return fish end
    return nil
end
local function nearestAngler()
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local best, bd
    for _, a in ipairs(anglerNpcs()) do
        local r = a.npc:FindFirstChild("HumanoidRootPart") or a.npc.PrimaryPart
        if r then local d = (r.Position - hrp.Position).Magnitude; if not bd or d < bd then best, bd = a, d end end
    end
    return best, bd
end
-- is this angler quest accepted + how many of the needed fish are in hand? (reads the game's OWN tracker:
-- legacyLocalPlayerData.fetch().Quests -> "Angler Quest*" folder -> fish-named child whose Value = progress)
local LPData; pcall(function() LPData = require(RepStorage.client.modules.legacyLocalPlayerData) end)
local function anglerQuestState(need)   -- returns nil (can't read) | accepted(bool), count(number)
    if not LPData then return nil end
    local ok, data = pcall(function() return LPData.fetch() end)
    if not ok or not data then return nil end
    local quests = data:FindFirstChild("Quests")
    if not quests then return false, 0 end
    for _, q in ipairs(quests:GetChildren()) do
        if type(q.Name) == "string" and string.find(q.Name, "Angler Quest") then
            local child = q:FindFirstChild(need)
            if child then
                local v = (child:IsA("ValueBase")) and child.Value or 1
                return true, (type(v) == "number" and v or 1)
            end
        end
    end
    return false, 0
end
-- loop: accept the angler quest -> catch the needed fish -> hand in ONLY once the fish is in hand
task.spawn(function()
    local lastTurnIn, aLastZone = 0, nil
    local function goTalk(a) local r = a.npc:FindFirstChild("HumanoidRootPart"); if r then tpToPos(r.Position); task.wait(0.4); firePromptsIn(a.npc); clickDialogAccepts() end end
    local function goFish(need)
        local fd = fishData(need); local zoneKey = fd and fd.zoneName and matchLocation(fd.zoneName)
        if zoneKey and aLastZone ~= zoneKey then
            teleport(zoneKey); aLastZone = zoneKey
            if fd and type(fd.bait)=="string" and fd.bait~="Any" and fd.bait~="" then equipBait(fd.bait) end
        end
        CFG.autoFish = true
        return zoneKey, fd
    end
    while true do
        task.wait(1.0)
        if anglerGrind then
            pcall(function()
                local a = nearestAngler()
                if not a then Quest.status = "angler: none found"; return end
                local need = anglerNeededFish(a.uid)
                if not need then Quest.status = "angler: cooldown — waiting"; CFG.autoFish = false; aLastZone = nil; return end
                local accepted, count = anglerQuestState(need)
                if accepted == nil then                              -- can't read data: fish + timed hand-in
                    if tick() - lastTurnIn > 18 then lastTurnIn, aLastZone = tick(), nil; goTalk(a)
                    else local z, fd = goFish(need); Quest.status = ("angler wants %s -> %s"):format(need, z or (fd and fd.zoneName) or "current") end
                elseif not accepted then                             -- accept the quest first
                    Quest.status = "angler: accepting -> "..need; CFG.autoFish = false; aLastZone = nil; goTalk(a)
                elseif count >= 1 then                               -- fish IS in hand -> hand in (throttled), fish between tries
                    if tick() - lastTurnIn > 8 then lastTurnIn, aLastZone = tick(), nil; Quest.status = "angler: turning in "..need.." ["..count.."]"; goTalk(a)
                    else goFish(need) end
                else                                                 -- accepted, not caught yet -> go fish
                    local z, fd = goFish(need)
                    Quest.status = ("angler wants %s -> %s"):format(need, z or (fd and fd.zoneName) or "current")
                end
            end)
        end
    end
end)

plr.Idled:Connect(function() if CFG.antiAfk then pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end) end end)

_G.Fisch = { on=function() CFG.autoFish=true end, off=function() CFG.autoFish=false end,
    quests=setQuests, questStatus=function() return Quest.status end,
    howto=howTo, plan=planCatch,   -- _G.Fisch.howto("Part") / _G.Fisch.plan("Pufferfish","Aurora")
    bait=equipBait, mutbait=equipBaitForMutation, target=catchTarget,   -- .bait("Part Bait") / .mutbait("Aurora") / .target("Pufferfish","Aurora")
    fish=fishData, quest=questPlan, quests_list=questNames,   -- .quest("Diver Billy") -> where/what to fish + rewards
    angler=function(v) anglerGrind = v end, needed=function() local a=nearestAngler() return a and anglerNeededFish(a.uid) end,
    sell=sellAll, tp=teleport, zones=locNames, cfg=CFG, rod=function() local r=getRod() return r and r.Name or "none" end }

----------------------------------------------------------------- UI (Rayfield)
local okUI, Rayfield = pcall(function() return loadstring(game:HttpGet("https://sirius.menu/rayfield"))() end)
if okUI and Rayfield then
    local Window = Rayfield:CreateWindow({ Name = "Fisch Auto-Fisher", LoadingTitle = "Fisch", LoadingSubtitle = "matcha engine",
        ConfigurationSaving = { Enabled = false }, KeySystem = false })
    local Fishing = Window:CreateTab("Fishing")
    Fishing:CreateToggle({ Name = "Auto Fish", CurrentValue = false, Callback = function(v) CFG.autoFish = v end })
    Fishing:CreateToggle({ Name = "Auto-equip rod", CurrentValue = true, Callback = function(v) CFG.autoEquip = v end })
    Fishing:CreateDropdown({ Name = "Reel mode", Options = { "hybrid","predict","spam" }, CurrentOption = { "hybrid" }, MultipleOptions = false,
        Callback = function(o) CFG.reelMode = (type(o)=="table" and o[1]) or o end })
    Fishing:CreateSlider({ Name = "Cast hold (s)", Range = { 0.05, 1 }, Increment = 0.05, CurrentValue = 0.2, Callback = function(v) CFG.castHold = v end })
    local statusLbl = Fishing:CreateLabel("status: idle")
    task.spawn(function() while true do task.wait(0.4)
        pcall(function() statusLbl:Set(("rod: %s | mode: %s | auto: %s"):format(_G.Fisch.rod(), CFG.reelMode, tostring(CFG.autoFish))) end)
    end end)

    local Travel = Window:CreateTab("Travel")
    local names, chosen = locNames(), (locNames())[1]
    Travel:CreateDropdown({ Name = "Location", Options = names, CurrentOption = { names[1] }, MultipleOptions = false,
        Callback = function(o) chosen = (type(o)=="table" and o[1]) or o end })
    Travel:CreateButton({ Name = "Teleport", Callback = function() if chosen then teleport(chosen) end end })

    local QuestsTab = Window:CreateTab("Quests")
    QuestsTab:CreateToggle({ Name = "Auto Quests (marker-driven: anglers + rod quests)", CurrentValue = false, Callback = function(v) setQuests(v) end })
    local qStatus = QuestsTab:CreateLabel("quest: off")
    task.spawn(function() while true do task.wait(0.5); pcall(function() qStatus:Set("quest: " .. tostring(Quest.status)) end) end end)
    -- repeatable angler grind
    local aspot = anglerSpot
    QuestsTab:CreateDropdown({ Name = "Angler grind spot", Options = ANGLER_SPOTS, CurrentOption = { anglerSpot }, MultipleOptions = false,
        Callback = function(o) aspot = (type(o)=="table" and o[1]) or o; anglerSpot = aspot end })
    QuestsTab:CreateButton({ Name = "Grind anglers here (park + auto)", Callback = function() parkAtSpot(aspot) end })
    QuestsTab:CreateToggle({ Name = "Smart angler grind (reads needed fish)", CurrentValue = false, Callback = function(v) anglerGrind = v end })
    -- one-time rod quests (known objective -> full auto: go to zone, catch the fish, turn in)
    local rqNames = {} for _, rq in ipairs(ROD_QUESTS) do rqNames[#rqNames+1] = rq.reward .. " — " .. rq.fish .. " @ " .. rq.zone end
    local rqSel = 1
    QuestsTab:CreateDropdown({ Name = "Rod quest", Options = rqNames, CurrentOption = { rqNames[1] }, MultipleOptions = false,
        Callback = function(o) local s=(type(o)=="table" and o[1]) or o; for i,n in ipairs(rqNames) do if n==s then rqSel=i end end end })
    QuestsTab:CreateButton({ Name = "Do rod quest (go catch the fish)", Callback = function() doRodQuest(ROD_QUESTS[rqSel]) end })
    -- NPC fetch-quest lookup (reads the game's own SimpleFetchQuests data)
    local qNpcs = questNames()
    if #qNpcs > 0 then
        local qpLbl = QuestsTab:CreateLabel("pick an NPC to see what/where to fish")
        local qpSel = qNpcs[1]
        QuestsTab:CreateDropdown({ Name = "NPC quest lookup", Options = qNpcs, CurrentOption = { qNpcs[1] }, MultipleOptions = false,
            Callback = function(o) qpSel = (type(o)=="table" and o[1]) or o; pcall(function() qpLbl:Set(qpSel..":\n"..questPlan(qpSel)) end) end })
        QuestsTab:CreateButton({ Name = "Catch first fish for this quest", Callback = function()
            local qi = questInfo(qpSel); if qi and qi.fish[1] then catchTarget(qi.fish[1], "") end end })
    end
    QuestsTab:CreateParagraph({ Title = "Rod path & how quests work", Content =
        "RODS: Flimsy -> Carbon (~800C, first buy) -> Rapid (14kC, fastest XP) | alt Steady (7kC, easy timing, mobile). "..
        "ANGLERS: repeatable — accept, catch the REQUESTED fish, hand in to any Angler (~2min cd); 25/50/75/100 completions unlock Mythical/Exotic/Secret/Apex. "..
        "ROD QUESTS: catch the target fish at its zone, turn in for the rod. Auto Quests drives the NPC dialogue for you (no forged remotes)." })

    local CodexTab = Window:CreateTab("Codex")
    local mutNames = {} for _, m in ipairs(MUTATIONS) do mutNames[#mutNames+1] = m.name end table.sort(mutNames)
    local mSel = mutNames[1]
    local mLbl = CodexTab:CreateLabel("pick a mutation to see how to get it")
    CodexTab:CreateDropdown({ Name = "Mutation", Options = mutNames, CurrentOption = { mutNames[1] }, MultipleOptions = false,
        Callback = function(o) mSel = (type(o)=="table" and o[1]) or o; pcall(function() mLbl:Set(howTo(mSel)) end) end })
    CodexTab:CreateButton({ Name = "Equip bait for this mutation", Callback = function()
        local b = equipBaitForMutation(mSel)
        pcall(function() mLbl:Set(b and ("equipped bait: " .. b) or ("can't force " .. tostring(mSel) .. " — " .. howTo(mSel))) end)
    end })
    CodexTab:CreateParagraph({ Title = "How to read this", Content =
        "Each quest wants a specific fish (+ maybe a mutation). bait/rod mutations the bot CAN set up (equip that bait/rod, then fish). "..
        "weather/event mutations can't be forced — you wait for the weather or the event. Console: _G.Fisch.howto(\"Part\") or _G.Fisch.plan(\"Pufferfish\",\"Aurora\")." })

    local MiscTab = Window:CreateTab("Misc")
    MiscTab:CreateToggle({ Name = "Auto-sell", CurrentValue = false, Callback = function(v) CFG.autoSell = v end })
    MiscTab:CreateButton({ Name = "Sell now", Callback = function() sellAll() end })
    MiscTab:CreateToggle({ Name = "Anti-AFK", CurrentValue = true, Callback = function(v) CFG.antiAfk = v end })
else
    warn("[Fisch] Rayfield failed — use _G.Fisch.on()/off()/tp(name)/sell().")
end

print("[Fisch] loaded (matcha engine). rod=" .. tostring(_G.Fisch.rod()) .. " reelMode=" .. CFG.reelMode)
