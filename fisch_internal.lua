--[[
    Fisch — Internal Auto-Fisher (remote-based, zero simulated input)
    =================================================================
    For an injecting executor (Wave/Solara/Script-Ware/AWP/...). NOT Matcha.

    Rewritten around the CORRECT game mechanics (thanks to a known-good reference):
      - Cast   : CurrentTool.events.cast:FireServer(100, 1)        (remote, no mouse)
      - Reel   : events["reelfinished "]:FireServer(100, perfect)  (instant, no minigame)
      - Shake  : replicatesignal(shakeButton.MouseButton1Click)    (server-side, no input)
      - Sell   : events.SellAll:InvokeServer()
    Rod is tracked via Character.ChildAdded/ChildRemoved. No mouse movement anywhere.
    UI = Fluent (touch-friendly, works on PC + mobile), with a _G.Fisch console fallback.
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RepStorage  = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local GuiService  = game:GetService("GuiService")
local plr = Players.LocalPlayer

----------------------------------------------------------------- remotes (defensive names)
local events = RepStorage:WaitForChild("events")
local function findEvent(...)
    for _, n in ipairs({ ... }) do
        local e = events:FindFirstChild(n)
        if e then return e end
    end
    return nil
end
local ReelFinished = findEvent("reelfinished ", "reelfinished")  -- game dev typo has a trailing space
local SellAll      = findEvent("SellAll", "selleverything", "sellall")

----------------------------------------------------------------- config
local CFG = {
    autoFish     = false,
    perfectReel  = true,
    autoEquip    = true,
    autoSell     = false,
    sellInterval = 120,
    antiAfk      = true,
}

----------------------------------------------------------------- rod / tool tracking
local CurrentTool = nil

local function isRod(t)
    if not (t and t:IsA("Tool")) then return false end
    local v = t:FindFirstChild("values")
    local e = t:FindFirstChild("events")
    return (v and v:FindFirstChild("casted") ~= nil) or (e and e:FindFirstChild("cast") ~= nil)
end

local function onChildAdded(c)   if c:IsA("Tool") then CurrentTool = c end end
local function onChildRemoved(c) if c:IsA("Tool") and c == CurrentTool then CurrentTool = nil end end
local function hookCharacter(char)
    CurrentTool = char:FindFirstChildOfClass("Tool")
    char.ChildAdded:Connect(onChildAdded)
    char.ChildRemoved:Connect(onChildRemoved)
end
plr.CharacterAdded:Connect(hookCharacter)
if plr.Character then hookCharacter(plr.Character) end

-- equip a rod from the backpack if none is held
local function equipRod()
    if CurrentTool and isRod(CurrentTool) then return end
    local char = plr.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local bp   = plr:FindFirstChildOfClass("Backpack")
    if not (hum and bp) then return end
    for _, t in ipairs(bp:GetChildren()) do
        if isRod(t) then pcall(function() hum:EquipTool(t) end); return end
    end
end

----------------------------------------------------------------- mechanics (all remote-based)
local function doCast()
    local t = CurrentTool
    if not (t and isRod(t)) then
        if CFG.autoEquip then equipRod() end
        return
    end
    local values = t:FindFirstChild("values")
    local evs    = t:FindFirstChild("events")
    local casted = values and values:FindFirstChild("casted")
    if evs and evs:FindFirstChild("cast") and casted and casted.Value == false then
        pcall(function() evs.cast:FireServer(100, 1) end)     -- full power, forward
    end
end

local function doReel()
    if not ReelFinished then return end
    local pg = plr:FindFirstChildOfClass("PlayerGui")
    local reelUI = pg and pg:FindFirstChild("reel")
    if not reelUI then return end
    local bar = reelUI:FindFirstChild("bar")
    local reelScript = bar and bar:FindFirstChild("reel")
    if reelScript and reelScript.Enabled then
        pcall(function() ReelFinished:FireServer(100, CFG.perfectReel and true or false) end)
    end
end

-- shake: fire the shake button's click to the server, no input
local _VIM
local function vim() _VIM = _VIM or Instance.new("VirtualInputManager"); return _VIM end
local function clickShakeButton(btn)
    if type(replicatesignal) == "function" then
        pcall(replicatesignal, btn.MouseButton1Click)
        task.delay(0.05, function() pcall(function() btn:Destroy() end) end)
        return
    end
    -- fallback (still no mouse movement): select the button + virtual Enter
    pcall(function()
        GuiService.SelectedObject = btn
        vim():SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        vim():SendKeyEvent(false, Enum.KeyCode.Return, false, game)
    end)
end

local function mountShake(shakeui)
    local safezone = shakeui:WaitForChild("safezone", 5)
    if not safezone then return end
    -- process any button already present, then watch for new ones
    for _, c in ipairs(safezone:GetChildren()) do
        if c:IsA("ImageButton") and CFG.autoFish then clickShakeButton(c) end
    end
    safezone.ChildAdded:Connect(function(c)
        if CFG.autoFish and c:IsA("ImageButton") then clickShakeButton(c) end
    end)
end

local function hookShake()
    local pg = plr:WaitForChild("PlayerGui")
    local existing = pg:FindFirstChild("shakeui")
    if existing then mountShake(existing) end
    pg.ChildAdded:Connect(function(c)
        if c.Name == "shakeui" and c:IsA("ScreenGui") then mountShake(c) end
    end)
end
hookShake()

local function sellAll()
    if not SellAll then return false end
    return pcall(function()
        if SellAll:IsA("RemoteFunction") then return SellAll:InvokeServer() else SellAll:FireServer() end
    end)
end

----------------------------------------------------------------- loops
-- cast loop
task.spawn(function()
    while true do
        task.wait(0.4)
        if CFG.autoFish then pcall(doCast) end
    end
end)
-- reel loop (fast)
RunService.Heartbeat:Connect(function()
    if CFG.autoFish then pcall(doReel) end
end)
-- sell loop
task.spawn(function()
    while true do
        task.wait(math.max(15, CFG.sellInterval))
        if CFG.autoSell then pcall(sellAll) end
    end
end)

----------------------------------------------------------------- teleport
local TP = {}   -- name -> Vector3
local function collectTP()
    TP = {}
    local w = workspace:FindFirstChild("world")
    local spawns = w and w:FindFirstChild("spawns")
    local spots = spawns and spawns:FindFirstChild("TpSpots")
    if spots then
        for _, s in ipairs(spots:GetChildren()) do
            local ok, pos = pcall(function() return s:IsA("Model") and s:GetPivot().Position or s.Position end)
            if ok and pos then TP[s.Name] = pos end
        end
    end
    local zones = workspace:FindFirstChild("zones")
    local fishing = zones and zones:FindFirstChild("fishing")
    if fishing then
        for _, z in ipairs(fishing:GetChildren()) do
            if z:IsA("BasePart") and not TP[z.Name] then TP[z.Name] = z.Position end
        end
    end
end
collectTP()
local function tpNames()
    local t = {}
    for n in pairs(TP) do t[#t + 1] = n end
    table.sort(t)
    return t
end
local function teleport(name)
    local pos = TP[name]
    local char = plr.Character
    if pos and char then pcall(function() char:PivotTo(CFrame.new(pos + Vector3.new(0, 6, 0))) end) end
end

----------------------------------------------------------------- anti-afk
plr.Idled:Connect(function()
    if not CFG.antiAfk then return end
    pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end)
end)

----------------------------------------------------------------- console API (always works)
_G.Fisch = {
    on    = function() CFG.autoFish = true end,
    off   = function() CFG.autoFish = false end,
    sell  = sellAll,
    tp    = teleport,
    zones = tpNames,
    cfg   = CFG,
}

----------------------------------------------------------------- UI (Fluent — PC + mobile)
local okUI, Fluent = pcall(function()
    return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
end)

if okUI and Fluent then
    local Window = Fluent:CreateWindow({
        Title = "Fisch", SubTitle = "Auto-Fisher", TabWidth = 150,
        Size = UDim2.fromOffset(500, 380), Acrylic = false, Theme = "Dark",
        MinimizeKey = Enum.KeyCode.RightControl,
    })
    local Fishing = Window:AddTab({ Title = "Fishing", Icon = "fish" })
    local Travel  = Window:AddTab({ Title = "Travel",  Icon = "map" })
    local Misc    = Window:AddTab({ Title = "Misc",    Icon = "settings" })

    Fishing:AddToggle("AutoFish", { Title = "Auto Fish", Default = false,
        Callback = function(v) CFG.autoFish = v end })
    Fishing:AddToggle("PerfectReel", { Title = "Perfect reel", Default = true,
        Callback = function(v) CFG.perfectReel = v end })
    Fishing:AddToggle("AutoEquip", { Title = "Auto-equip rod", Default = true,
        Callback = function(v) CFG.autoEquip = v end })
    local statusPara = Fishing:AddParagraph({ Title = "Status", Content = "idle" })
    task.spawn(function()
        while true do
            task.wait(0.5)
            pcall(function()
                statusPara:SetDesc(("Auto Fish: %s | rod: %s | reel: %s | sell: %s")
                    :format(tostring(CFG.autoFish),
                        (CurrentTool and isRod(CurrentTool)) and CurrentTool.Name or "none",
                        ReelFinished and "ok" or "MISSING",
                        SellAll and "ok" or "MISSING"))
            end)
        end
    end)

    local names = tpNames()
    local chosen = names[1]
    Travel:AddDropdown("TPTarget", { Title = "Location", Values = names, Multi = false,
        Default = 1, Callback = function(v) chosen = v end })
    Travel:AddButton({ Title = "Teleport", Callback = function() if chosen then teleport(chosen) end end })
    Travel:AddButton({ Title = "Refresh locations", Callback = function()
        collectTP()
        Fluent:Notify({ Title = "Fisch", Content = "Locations refreshed (" .. #tpNames() .. ")", Duration = 3 })
    end })

    Misc:AddToggle("AutoSell", { Title = "Auto-sell", Default = false,
        Callback = function(v) CFG.autoSell = v end })
    Misc:AddSlider("SellInterval", { Title = "Sell interval (s)", Default = 120, Min = 30, Max = 600,
        Rounding = 0, Callback = function(v) CFG.sellInterval = v end })
    Misc:AddButton({ Title = "Sell now", Callback = function() sellAll() end })
    Misc:AddToggle("AntiAfk", { Title = "Anti-AFK", Default = true,
        Callback = function(v) CFG.antiAfk = v end })

    Fluent:Notify({ Title = "Fisch", Content = "Loaded. Toggle Auto Fish to start.", Duration = 4 })
else
    warn("[Fisch] Fluent UI failed to load — use the console API: _G.Fisch.on()/off()/tp(name)/sell().")
    pcall(function()
        game.StarterGui:SetCore("SendNotification", { Title = "Fisch", Text = "UI failed; use _G.Fisch API", Duration = 6 })
    end)
end

print("[Fisch] loaded. Reel remote: " .. tostring(ReelFinished and ReelFinished.Name)
    .. " | Sell remote: " .. tostring(SellAll and SellAll.Name) .. " | TP spots: " .. tostring(#tpNames()))
