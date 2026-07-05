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
local plr = Players.LocalPlayer

----------------------------------------------------------------- remotes
local eventsFolder = RepStorage:WaitForChild("events")
local SellAll = eventsFolder:FindFirstChild("SellAll") or eventsFolder:FindFirstChild("selleverything")

----------------------------------------------------------------- config
local CFG = {
    autoFish      = false,
    autoEquip     = true,
    reelMode      = "hybrid",   -- "spam" | "predict" | "hybrid"
    chargeTime    = 1.0,        -- hold this long to charge, then let go. tune until it's a Perfect Cast.
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
-- time-based charge: hold for CFG.chargeTime, then let go. The bar fills to max in a
-- fixed time, so a tuned hold gives an identical (perfect) cast every time.
local castStartAt = 0
local function stepCharge()
    holdMouse()
    if castStartAt == 0 then castStartAt = tick() end
    if tick() - castStartAt >= CFG.chargeTime then
        releaseMouse(); castStartAt = 0                        -- let go -> cast fires
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

local QUESTS = {
    ["Magma Rod - Orc @ Roslit (Pufferfish)"]      = { loc = "Roslit Bay" },
    ["Fungal Rod - Agaric @ Mushgrove (Alligator)"] = { loc = "Mushgrove Swamp" },
}
local questAssist = false
local DIALOG_WORDS = { "accept","continue","give","turn in","complete","claim","yes","okay","next" }
local function firePromptsNear(range)
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    local npcs = workspace:FindFirstChild("world") and workspace.world:FindFirstChild("npcs")
    if not (hrp and npcs and type(fireproximityprompt) == "function") then return end
    for _, d in ipairs(npcs:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local p = d.Parent
            if p and p:IsA("BasePart") and (p.Position - hrp.Position).Magnitude <= (range or 30) then pcall(fireproximityprompt, d) end
        end
    end
end
local function advanceDialog()
    local pg = plr:FindFirstChildOfClass("PlayerGui"); if not pg then return end
    for _, g in ipairs(pg:GetDescendants()) do
        if (g:IsA("TextButton") or g:IsA("ImageButton")) and g.Visible then
            local txt = (g:IsA("TextButton") and type(g.Text) == "string") and g.Text:lower() or ""
            local hit = false
            for _, w in ipairs(DIALOG_WORDS) do if txt:find(w, 1, true) then hit = true break end end
            if hit then
                if type(replicatesignal) == "function" then pcall(replicatesignal, g.MouseButton1Click)
                elseif type(firesignal) == "function" then pcall(firesignal, g.MouseButton1Click) end
            end
        end
    end
end
task.spawn(function() while true do task.wait(1.5); if questAssist then pcall(function() firePromptsNear(30); advanceDialog() end) end end end)
local function startQuest(name) local q = QUESTS[name]; if q then teleport(q.loc); CFG.autoFish = true; questAssist = true end end

plr.Idled:Connect(function() if CFG.antiAfk then pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end) end end)

_G.Fisch = { on=function() CFG.autoFish=true end, off=function() CFG.autoFish=false end,
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
    Fishing:CreateSlider({ Name = "Charge time (s) - tune for Perfect Cast", Range = { 0.3, 3 }, Increment = 0.05, CurrentValue = 1, Callback = function(v) CFG.chargeTime = v end })
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
    local qn = {} for n in pairs(QUESTS) do qn[#qn+1]=n end table.sort(qn)
    local qc = qn[1]
    QuestsTab:CreateDropdown({ Name = "Quest", Options = qn, CurrentOption = { qn[1] }, MultipleOptions = false, Callback = function(o) qc=(type(o)=="table" and o[1]) or o end })
    QuestsTab:CreateButton({ Name = "Start (teleport + auto-catch)", Callback = function() if qc then startQuest(qc) end end })
    QuestsTab:CreateToggle({ Name = "Auto-talk to NPC (best-effort)", CurrentValue = false, Callback = function(v) questAssist = v end })

    local MiscTab = Window:CreateTab("Misc")
    MiscTab:CreateToggle({ Name = "Auto-sell", CurrentValue = false, Callback = function(v) CFG.autoSell = v end })
    MiscTab:CreateButton({ Name = "Sell now", Callback = function() sellAll() end })
    MiscTab:CreateToggle({ Name = "Anti-AFK", CurrentValue = true, Callback = function(v) CFG.antiAfk = v end })
else
    warn("[Fisch] Rayfield failed — use _G.Fisch.on()/off()/tp(name)/sell().")
end

print("[Fisch] loaded (matcha engine). rod=" .. tostring(_G.Fisch.rod()) .. " reelMode=" .. CFG.reelMode)
