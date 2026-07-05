--[[
    Fisch — Internal Auto-Fisher (remote-based)
    ===========================================
    For an injecting executor (Wave/Solara/Script-Ware/AWP/...). NOT Matcha.

    Mechanics = LIVE-RECON of the current game (remote NAMES) + open-source scripts
    (arg patterns, shake technique, teleport coords):
      - Rod        : the equipped Tool whose `events` folder has cast/castAsync (found by structure, name-agnostic)
      - Cast       : rod.events.castAsync:InvokeServer(100, castType)   [RemoteFunction]  (fallback: events.cast:FireServer)
      - Reel/catch : rod.events.catchfinish:FireServer(100, true) AND events.reelfinished:FireServer(100, true)
      - Shake      : enlarge PlayerGui.shakeui.safezone.button + replicatesignal(button.MouseButton1Click)
      - Sell       : events.SellAll:InvokeServer()
      - Teleport   : HumanoidRootPart.CFrame = hardcoded zone coords
    No mouse movement, no keypresses. UI = Fluent (PC + mobile). Console: _G.Fisch.
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RepStorage  = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local plr = Players.LocalPlayer

----------------------------------------------------------------- remotes
local eventsFolder = RepStorage:WaitForChild("events")
local function ev(name) return eventsFolder:FindFirstChild(name) end
local ReelFinished = ev("reelfinished ") or ev("reelfinished")
local SellAll      = ev("SellAll") or ev("selleverything")

----------------------------------------------------------------- config
local CFG = {
    autoFish    = false,
    autoEquip   = true,   -- auto-equip your rod if it isn't in hand
    castPower   = 100,
    castType    = 1,      -- 1 or 2 (open scripts use both); tweak if casts fail
    autoSell    = false,
    sellEvery   = 120,
    antiAfk     = true,
}

----------------------------------------------------------------- rod detection + auto-equip
-- a rod = a Tool with a `rod/client` script, or an `events` folder holding cast/castAsync.
local function isRodTool(t)
    if not (t and t:IsA("Tool")) then return false end
    if t:FindFirstChild("rod/client") then return true end
    local e = t:FindFirstChild("events")
    return e ~= nil and (e:FindFirstChild("castAsync") ~= nil or e:FindFirstChild("cast") ~= nil)
end
-- the equipped rod (a rod Tool inside the character) — casting needs it equipped.
-- pure structure scan (this is the version that cast reliably; do not "improve" it).
local function getRod()
    local char = plr.Character
    if not char then return nil end
    for _, t in ipairs(char:GetChildren()) do if isRodTool(t) then return t end end
    return nil
end
-- the rod Tool anywhere (character or backpack), preferring the game's CurrentRod attribute
local function findRodTool()
    local char = plr.Character
    local bp = plr:FindFirstChildOfClass("Backpack")
    local rodName = plr:GetAttribute("CurrentRod")
    if rodName then
        local t = (char and char:FindFirstChild(rodName)) or (bp and bp:FindFirstChild(rodName))
        if isRodTool(t) then return t end
    end
    local function scan(c) if c then for _, t in ipairs(c:GetChildren()) do if isRodTool(t) then return t end end end end
    return (char and scan(char)) or (bp and scan(bp))
end
-- equip the rod if it isn't already in the character (no input — uses EquipTool)
local function ensureEquipped()
    if getRod() then return end
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local rod = findRodTool()
    if hum and rod and rod.Parent ~= char then pcall(function() hum:EquipTool(rod) end) end
end

----------------------------------------------------------------- mechanics
local function doCast()
    local rod = getRod()
    if not rod then return end
    local vals = rod:FindFirstChild("values")
    local casted = vals and vals:FindFirstChild("casted")
    if casted and casted.Value == true then return end       -- already cast / bobber out
    local e = rod:FindFirstChild("events")
    local c = e and (e:FindFirstChild("castAsync") or e:FindFirstChild("cast"))
    if not c then return end
    if c:IsA("RemoteFunction") then
        task.spawn(function() pcall(function() c:InvokeServer(CFG.castPower, CFG.castType) end) end)
    else
        pcall(function() c:FireServer(CFG.castPower, CFG.castType) end)
    end
end

-- DIAGNOSTIC: pops an on-screen message with exactly what the cast finds.
local function castTest()
    local function say(m)
        warn("[Fisch] " .. m)
        pcall(function() game.StarterGui:SetCore("SendNotification", { Title = "Fisch cast test", Text = m, Duration = 8 }) end)
    end
    local rod = getRod()
    if not rod then say("NO rod detected in your character. Is a rod equipped?"); return end
    local e  = rod:FindFirstChild("events")
    local ca = e and e:FindFirstChild("castAsync")
    local c  = e and e:FindFirstChild("cast")
    local remote = ca or c
    if not remote then say("rod=" .. rod.Name .. " but events has NO cast/castAsync"); return end
    say(("rod=%s cast=%s(%s) pow=%d type=%d - firing"):format(rod.Name, remote.Name, remote.ClassName, CFG.castPower, CFG.castType))
    if remote:IsA("RemoteFunction") then
        task.spawn(function() pcall(function() remote:InvokeServer(CFG.castPower, CFG.castType) end) end)
    else
        pcall(function() remote:FireServer(CFG.castPower, CFG.castType) end)
    end
end

-- LEGIT reel: play the minigame by keeping the player bar on the fish, and let the
-- game complete it naturally. NO forged completion remote — firing catchfinish/
-- reelfinished to auto-win is the BLATANT path that got the account banned.
local function doReel(reelUI)
    local bar  = reelUI:FindFirstChild("bar")
    local pbar = bar and bar:FindFirstChild("playerbar")
    local fish = bar and bar:FindFirstChild("fish")
    if not (pbar and fish) then return end
    pcall(function()
        local target = pbar.Position:Lerp(fish.Position, 0.75)
        pbar.Position = UDim2.fromScale(math.clamp(target.X.Scale, 0.05, 0.95), pbar.Position.Y.Scale)
    end)
end

local function doShake(sui)
    local sz = sui:FindFirstChild("safezone")
    if not sz then return end
    local btn = sz:FindFirstChild("button") or sz:FindFirstChildWhichIsA("ImageButton") or sz:FindFirstChildWhichIsA("TextButton")
    if not btn then return end
    -- click the shake button for you — NO resizing, NO screen-covering.
    if type(firesignal) == "function" then
        pcall(firesignal, btn.MouseButton1Click)              -- runs the button's own click handler
        pcall(firesignal, btn.Activated, nil, 1)
    end
    if type(replicatesignal) == "function" then
        pcall(replicatesignal, btn.MouseButton1Click)
    end
end

----------------------------------------------------------------- main loop
-- Heartbeat = smooth per-frame reel tracking; cast/shake are throttled.
if _G.__FischConn then pcall(function() _G.__FischConn:Disconnect() end) end   -- kill any prior run's loop
local _lastCast, _lastShake = 0, 0
_G.__FischConn = RunService.Heartbeat:Connect(function()
    if not CFG.autoFish then return end
    pcall(function()
        local pg = plr:FindFirstChildOfClass("PlayerGui")
        if not pg then return end
        local sui = pg:FindFirstChild("shakeui")
        local reelUI = pg:FindFirstChild("reel")
        if sui then
            if tick() - _lastShake >= 0.08 then doShake(sui); _lastShake = tick() end
        elseif reelUI then
            doReel(reelUI)                                    -- per-frame fish tracking
        else
            if tick() - _lastCast >= 0.5 then
                if CFG.autoEquip then ensureEquipped() end
                doCast()
                _lastCast = tick()
            end
        end
    end)
end)

----------------------------------------------------------------- sell
local function sellAll()
    if not SellAll then return false end
    return pcall(function()
        if SellAll:IsA("RemoteFunction") then return SellAll:InvokeServer() else SellAll:FireServer() end
    end)
end
task.spawn(function()
    while true do
        task.wait(math.max(15, CFG.sellEvery))
        if CFG.autoSell then pcall(sellAll) end
    end
end)

----------------------------------------------------------------- teleport (hardcoded zone coords + a few live zones)
local LOCATIONS = {
    ["Moosewood"]              = Vector3.new(368.20, 140.31, 239.53),
    ["Roslit Bay"]             = Vector3.new(-1456.52, 149.10, 634.93),
    ["Sunstone Island"]        = Vector3.new(-953.45, 237.10, -984.76),
    ["Mushgrove Swamp"]        = Vector3.new(2687.99, 140.72, -731.67),
    ["Terrapin Island"]        = Vector3.new(-172.42, 149.40, 1954.48),
    ["Snowcap Island"]         = Vector3.new(2607.62, 143.21, 2396.54),
    ["Keepars Altar"]          = Vector3.new(1296.20, -792.95, -292.35),
    ["Desolate Pocket"]        = Vector3.new(-1653.21, -209.57, -2826.66),
    ["Harvesters Spike"]       = Vector3.new(-1294.44, 239.92, 1561.66),
    ["Statue of Sovereignty"]  = Vector3.new(-3.60, 428.08, -1120.39),
    ["Haddock Rock"]           = Vector3.new(-606.35, 212.82, -465.77),
    ["Earmark Island"]         = Vector3.new(1228.76, 160.95, 504.75),
    ["The Arch"]               = Vector3.new(1052.07, 321.86, -1249.91),
    ["Vertigo"]                = Vector3.new(-112.01, -492.90, 1040.33),
}
-- pull any live fishing zones too
pcall(function()
    local f = workspace:FindFirstChild("zones") and workspace.zones:FindFirstChild("fishing")
    if f then for _, z in ipairs(f:GetChildren()) do if z:IsA("BasePart") and not LOCATIONS[z.Name] then LOCATIONS[z.Name] = z.Position end end end
end)
local function locNames()
    local t = {} for n in pairs(LOCATIONS) do t[#t + 1] = n end table.sort(t) return t
end
local function teleport(name)
    local pos = LOCATIONS[name]
    local char = plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if pos and hrp then pcall(function() hrp.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0)) end) end
end

----------------------------------------------------------------- quests (best-effort; no game recon available)
-- RELIABLE = teleport + auto-catch the target fish. BEST-EFFORT = NPC dialog (a guess).
local QUESTS = {
    ["Magma Rod - Orc @ Roslit (Pufferfish)"]      = { loc = "Roslit Bay",     fish = "Pufferfish" },
    ["Fungal Rod - Agaric @ Mushgrove (Alligator)"] = { loc = "Mushgrove Swamp", fish = "Alligator" },
}
local questAssist = false   -- fire nearby NPC prompts + advance dialog

local function firePromptsNear(range)
    local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
    if not hrp or type(fireproximityprompt) ~= "function" then return end
    local world = workspace:FindFirstChild("world")
    local npcs = world and world:FindFirstChild("npcs")
    if not npcs then return end
    for _, d in ipairs(npcs:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local p = d.Parent
            if p and p:IsA("BasePart") and (p.Position - hrp.Position).Magnitude <= (range or 30) then
                pcall(fireproximityprompt, d)
            end
        end
    end
end

local DIALOG_WORDS = { "accept", "continue", "give", "turn in", "complete", "claim", "yes", "okay", "next" }
local function advanceDialog()
    local pg = plr:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    for _, g in ipairs(pg:GetDescendants()) do
        if (g:IsA("TextButton") or g:IsA("ImageButton")) and g.Visible then
            local txt = (g:IsA("TextButton") and type(g.Text) == "string") and g.Text:lower() or ""
            local hit = false
            for _, w in ipairs(DIALOG_WORDS) do if txt:find(w, 1, true) then hit = true break end end
            if not hit then
                local a = g
                for _ = 1, 6 do a = a and a.Parent; if a and type(a.Name) == "string" and a.Name:lower():find("dialog") then hit = true break end end
            end
            if hit then
                if type(replicatesignal) == "function" then pcall(replicatesignal, g.MouseButton1Click)
                elseif type(firesignal) == "function" then pcall(firesignal, g.MouseButton1Click) end
            end
        end
    end
end

task.spawn(function()
    while true do
        task.wait(1.5)
        if questAssist then pcall(function() firePromptsNear(30); advanceDialog() end) end
    end
end)

local function startQuest(name)
    local q = QUESTS[name]; if not q then return end
    teleport(q.loc)
    CFG.autoFish = true
    questAssist = true
end

----------------------------------------------------------------- anti-afk
plr.Idled:Connect(function()
    if CFG.antiAfk then pcall(function() VirtualUser:CaptureController(); VirtualUser:ClickButton2(Vector2.new()) end) end
end)

----------------------------------------------------------------- console API
_G.Fisch = {
    on = function() CFG.autoFish = true end,
    off = function() CFG.autoFish = false end,
    sell = sellAll, tp = teleport, zones = locNames, cfg = CFG,
    rod = function() local r = getRod() return r and r.Name or "none" end,
}

----------------------------------------------------------------- UI (Rayfield — has a built-in on-screen toggle button, works on mobile)
local okUI, Rayfield = pcall(function() return loadstring(game:HttpGet("https://sirius.menu/rayfield"))() end)
if okUI and Rayfield then
    local Window = Rayfield:CreateWindow({
        Name = "Fisch Auto-Fisher",
        LoadingTitle = "Fisch",
        LoadingSubtitle = "auto-fisher",
        ConfigurationSaving = { Enabled = false },
        KeySystem = false,
    })

    local Fishing = Window:CreateTab("Fishing")
    Fishing:CreateToggle({ Name = "Auto Fish", CurrentValue = false, Flag = "AutoFish", Callback = function(v) CFG.autoFish = v end })
    Fishing:CreateToggle({ Name = "Auto-equip rod", CurrentValue = true, Callback = function(v) CFG.autoEquip = v end })
    Fishing:CreateSlider({ Name = "Cast type (try 1 or 2)", Range = { 1, 2 }, Increment = 1, CurrentValue = 1, Callback = function(v) CFG.castType = v end })
    Fishing:CreateButton({ Name = "Cast now (test)", Callback = function() castTest() end })
    local statusLbl = Fishing:CreateLabel("status: idle")
    task.spawn(function()
        while true do task.wait(0.5)
            pcall(function()
                statusLbl:Set(("rod: %s | auto: %s | reel: %s | sell: %s"):format(
                    _G.Fisch.rod(), tostring(CFG.autoFish),
                    ReelFinished and "ok" or "none", SellAll and "ok" or "none"))
            end)
        end
    end)

    local Travel = Window:CreateTab("Travel")
    local names = locNames()
    local chosen = names[1]
    Travel:CreateDropdown({ Name = "Location", Options = names, CurrentOption = { names[1] }, MultipleOptions = false,
        Callback = function(o) chosen = (type(o) == "table" and o[1]) or o end })
    Travel:CreateButton({ Name = "Teleport", Callback = function() if chosen then teleport(chosen) end end })
    Travel:CreateButton({ Name = "Go to Roslit Bay (Orc/Magma quest)", Callback = function() teleport("Roslit Bay") end })

    local QuestsTab = Window:CreateTab("Quests")
    local qnames = {} for n in pairs(QUESTS) do qnames[#qnames + 1] = n end table.sort(qnames)
    local qchosen = qnames[1]
    QuestsTab:CreateDropdown({ Name = "Quest", Options = qnames, CurrentOption = { qnames[1] }, MultipleOptions = false,
        Callback = function(o) qchosen = (type(o) == "table" and o[1]) or o end })
    QuestsTab:CreateButton({ Name = "Start (teleport + auto-catch target)", Callback = function() if qchosen then startQuest(qchosen) end end })
    QuestsTab:CreateToggle({ Name = "Auto-talk to NPC (best-effort)", CurrentValue = false, Callback = function(v) questAssist = v end })
    QuestsTab:CreateParagraph({ Title = "How it works", Content = "Teleport + auto-catch are reliable. NPC dialog auto-click is a best-effort guess - if it doesn't turn the quest in, talk to the NPC yourself." })

    local MiscTab = Window:CreateTab("Misc")
    MiscTab:CreateToggle({ Name = "Auto-sell", CurrentValue = false, Callback = function(v) CFG.autoSell = v end })
    MiscTab:CreateButton({ Name = "Sell now", Callback = function() sellAll() end })
    MiscTab:CreateToggle({ Name = "Anti-AFK", CurrentValue = true, Callback = function(v) CFG.antiAfk = v end })
else
    warn("[Fisch] Rayfield failed — use _G.Fisch.on()/off()/tp(name)/sell().")
end

print("[Fisch] loaded. rod=" .. tostring(_G.Fisch.rod()) .. " reelRemote=" .. tostring(ReelFinished and ReelFinished.Name) .. " sell=" .. tostring(SellAll and SellAll.Name))
