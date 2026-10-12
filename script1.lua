--[[
    MAX HUB  |  Anime Dice  |  V1.1
    Priority build: Grade / Trait / Quirk roll automation with Auto Stop.

    How it works
      * Presses the game's own Roll button (same as you tapping it), reads the
        result text, and stops the moment your target (or better) appears.
      * It cannot change server odds. "Max Luck" = press your luck-boost
        button before a session so the boost is active while rolling.
      * Safety stops: target hit, menu closed, "not enough" message,
        result unreadable N times, or result unchanged N times (out of rerolls).

    Delta: paste into the editor and Execute, or put this file in Delta's
    workspace folder and run:  loadstring(readfile("script1.lua"))()
]]

------------------------------------------------------------------------
-- Re-run safety
------------------------------------------------------------------------
local genv = (getgenv and getgenv()) or _G
if genv.MaxHubCleanup then pcall(genv.MaxHubCleanup) end

------------------------------------------------------------------------
-- Services
------------------------------------------------------------------------
local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local RS           = game:GetService("ReplicatedStorage")
local HttpService  = game:GetService("HttpService")
local GuiService   = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local LP        = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

local VERSION     = "1.1"
local CONFIG_FILE = "MaxHub_AnimeDice.json"
local CATS        = { "Grade", "Trait", "Quirk" }

------------------------------------------------------------------------
-- Game data (rarest first). Auto-updated from the game's own modules on
-- load when they can be read; these are the fallbacks (Update 5/6).
------------------------------------------------------------------------
local Data = {
    Trait = {
        "Genesis", "Paradox", "Eternal", "Transcendent", "Monarch", "Shogun", "Samurai",
        "Money III", "Damage III", "Health III",
        "Money II", "Damage II", "Health II",
        "Money I", "Damage I", "Health I",
    },
    Grade = { "Z++", "Z+", "Z", "SSS", "SS", "S", "A", "B", "C", "D" },
    Quirk = {}, -- learned from the game, or use "Custom target"
}
local DataSource = { Trait = "built-in", Grade = "built-in", Quirk = "none" }

local ERROR_PATTERNS = { "not enough", "insufficient", "no reroll", "out of reroll", "you need", "cannot afford" }
local ROLL_WORDS     = { "reroll", "re%-roll", "roll", "spin" }
local ROLL_EXCLUDE   = { "auto", "stop", "buy", "robux", "r%$", "skip" }

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------
local Cfg = {
    Delay = 0.35,       -- seconds between rolls
    MaxUnread = 8,      -- stop after N unreadable results in a row
    MaxNoChange = 10,   -- stop after N identical results in a row
    AntiAFK = true,
    Protect = true,     -- don't roll if the current result already meets target
    Grade = { Target = "Z+",      OrBetter = true, MaxLuck = true,  Custom = "" },
    Trait = { Target = "Eternal", OrBetter = true, MaxLuck = true,  Custom = "" },
    Quirk = { Target = "",        OrBetter = true, MaxLuck = true,  Custom = "" },
    Bind = { Grade = {}, Trait = {}, Quirk = {} }, -- Roll / Result / Boost -> PlayerGui path
}

local function saveCfg()
    if writefile then pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(Cfg)) end
end

local function loadCfg()
    if not (isfile and readfile) then return end
    local ok, t = pcall(function()
        if isfile(CONFIG_FILE) then return HttpService:JSONDecode(readfile(CONFIG_FILE)) end
    end)
    if not ok or type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(v) == "table" and type(Cfg[k]) == "table" then
            for k2, v2 in pairs(v) do Cfg[k][k2] = v2 end
        elseif Cfg[k] ~= nil and type(v) == type(Cfg[k]) then
            Cfg[k] = v
        end
    end
end
loadCfg()

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
local Conns = {}
local function track(c) table.insert(Conns, c) return c end

local Hub -- ScreenGui, set later
local Running = nil -- category currently rolling
local Stats = { Grade = { rolls = 0, last = "-" }, Trait = { rolls = 0, last = "-" }, Quirk = { rolls = 0, last = "-" } }

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function clean(s)
    s = tostring(s or "")
    s = s:gsub("<[^>]->", "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function hasToken(hay, needle)
    local h, n = hay:lower(), needle:lower()
    if n == "" then return false end
    local i = 1
    while true do
        local s, e = string.find(h, n, i, true)
        if not s then return false end
        local pre = s > 1 and h:sub(s - 1, s - 1) or ""
        local post = h:sub(e + 1, e + 1)
        if not pre:match("[%w%+]") and not post:match("[%w%+]") then return true end
        i = s + 1
    end
end

-- Longest known name contained in text; returns name, rank (1 = rarest)
local function matchName(text, list)
    text = clean(text)
    if #text == 0 or #text > 40 then return nil end
    local best, bestRank, bestLen
    for rank, name in ipairs(list) do
        if hasToken(text, name) and (not bestLen or #name > bestLen) then
            best, bestRank, bestLen = name, rank, #name
        end
    end
    return best, bestRank
end

local function shown(o)
    local cur = o
    while cur and cur ~= PlayerGui and cur ~= game do
        if cur:IsA("GuiObject") and not cur.Visible then return false end
        if cur:IsA("LayerCollector") and not cur.Enabled then return false end
        cur = cur.Parent
    end
    return true
end

local function isTextObj(o)
    return o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")
end

local function textOf(o)
    local parts = {}
    if isTextObj(o) then table.insert(parts, clean(o.Text)) end
    for _, d in ipairs(o:GetDescendants()) do
        if d:IsA("TextLabel") then table.insert(parts, clean(d.Text)) end
    end
    return table.concat(parts, " ")
end

local function pathOf(inst)
    local parts, cur = {}, inst
    while cur and cur ~= PlayerGui do
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    if cur ~= PlayerGui then return nil end
    return table.concat(parts, "/")
end

local function resolve(path)
    if type(path) ~= "string" or path == "" then return nil end
    local cur = PlayerGui
    for seg in string.gmatch(path, "[^/]+") do
        cur = cur:FindFirstChild(seg)
        if not cur then return nil end
    end
    return cur
end

local function splitTargets(s)
    local out = {}
    for part in string.gmatch(s or "", "[^,]+") do
        local p = clean(part)
        if p ~= "" then table.insert(out, p) end
    end
    return out
end

------------------------------------------------------------------------
-- Pressing game buttons (Delta: getconnections / firesignal, VIM fallback)
------------------------------------------------------------------------
local function press(btn)
    if not btn then return false end
    if getconnections then
        for _, sigName in ipairs({ "Activated", "MouseButton1Click", "MouseButton1Down" }) do
            local okSig, sig = pcall(function() return btn[sigName] end)
            if okSig and sig then
                local ok, cons = pcall(getconnections, sig)
                if ok and cons and #cons > 0 then
                    for _, c in ipairs(cons) do
                        pcall(function()
                            if c.Fire then c:Fire() elseif c.Function then c.Function() end
                        end)
                    end
                    return true
                end
            end
        end
    end
    if firesignal then
        local ok = pcall(firesignal, btn.MouseButton1Click)
        if ok then pcall(firesignal, btn.Activated) return true end
    end
    local ok = pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local inset = GuiService:GetGuiInset()
        local p = btn.AbsolutePosition + btn.AbsoluteSize / 2
        local x, y = p.X, p.Y + inset.Y
        vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.03)
        vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    return ok
end

------------------------------------------------------------------------
-- Finding the game's Grade / Trait / Quirk menus
------------------------------------------------------------------------
local function findPanel(cat)
    local kw, best, bestArea = cat:lower(), nil, 0
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d:IsA("GuiObject") and d.Name:lower():find(kw, 1, true) and shown(d) then
            local a = d.AbsoluteSize.X * d.AbsoluteSize.Y
            if a > bestArea then best, bestArea = d, a end
        end
    end
    return best
end

local function findRollButton(scope)
    if not scope then return nil end
    local best, bestScore = nil, 0
    for _, d in ipairs(scope:GetDescendants()) do
        if d:IsA("GuiButton") and shown(d) then
            local t = (d.Name .. " " .. textOf(d)):lower()
            local bad = false
            for _, w in ipairs(ROLL_EXCLUDE) do if t:find(w) then bad = true break end end
            if not bad then
                for i, w in ipairs(ROLL_WORDS) do
                    if t:find(w) then
                        local score = #ROLL_WORDS - i + 1
                        if score > bestScore then best, bestScore = d, score end
                        break
                    end
                end
            end
        end
    end
    return best
end

------------------------------------------------------------------------
-- Learn names straight from the game's modules (keeps data current with
-- the game version). Only accepts tables that look like odds tables.
------------------------------------------------------------------------
local function tryRequire(m)
    local done, result = false, nil
    task.spawn(function()
        local ok, r = pcall(require, m)
        if ok then result = r end
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < 2 do task.wait() end
    return result
end

local CHANCE_KEYS = { "Chance", "chance", "Rarity", "rarity", "Weight", "weight", "Percent", "percent", "Odds", "odds", "Probability" }

local function extractOdds(t)
    local entries = {}
    local function chanceOf(v)
        if type(v) ~= "table" then return nil end
        for _, k in ipairs(CHANCE_KEYS) do
            if type(v[k]) == "number" then return v[k] end
        end
    end
    for k, v in pairs(t) do
        local c = chanceOf(v)
        if c then
            local name = (type(k) == "string" and k) or (type(v.Name) == "string" and v.Name) or nil
            if name then table.insert(entries, { name = name, chance = c }) end
        end
    end
    if #entries < 3 then return nil end
    table.sort(entries, function(a, b) return a.chance < b.chance end)
    local names = {}
    for _, e in ipairs(entries) do table.insert(names, e.name) end
    return names
end

local function learnGameData(log)
    local learned = 0
    for _, m in ipairs(RS:GetDescendants()) do
        if m:IsA("ModuleScript") then
            local n = m.Name:lower()
            for _, cat in ipairs(CATS) do
                if n:find(cat:lower(), 1, true) then
                    local t = tryRequire(m)
                    if type(t) == "table" then
                        local names = extractOdds(t)
                        if names and #names >= 3 then
                            Data[cat] = names
                            DataSource[cat] = m:GetFullName()
                            learned += 1
                            if log then log(("Learned %d %ss from %s"):format(#names, cat, m.Name)) end
                        end
                    end
                end
            end
        end
    end
    return learned
end

------------------------------------------------------------------------
-- UI kit
------------------------------------------------------------------------
local Theme = {
    Bg = Color3.fromRGB(14, 15, 21), Panel = Color3.fromRGB(22, 24, 33), Item = Color3.fromRGB(31, 34, 46),
    Accent = Color3.fromRGB(255, 176, 46), Text = Color3.fromRGB(236, 239, 246), Sub = Color3.fromRGB(138, 145, 166),
    On = Color3.fromRGB(78, 208, 120), Off = Color3.fromRGB(66, 70, 88), Bad = Color3.fromRGB(235, 86, 86),
}

local function new(class, props, children)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do if k ~= "Parent" then o[k] = v end end
    for _, c in ipairs(children or {}) do c.Parent = o end
    if props and props.Parent then o.Parent = props.Parent end
    return o
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }) end
local function pad(p) return new("UIPadding", { PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p), PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p) }) end

local function label(parent, text, size, color, bold)
    return new("TextLabel", {
        Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, size + 6),
        Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham, TextSize = size, TextColor3 = color or Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, Text = text,
    })
end

local function button(parent, text, color, h)
    return new("TextButton", {
        Parent = parent, Size = UDim2.new(1, 0, 0, h or 32), BackgroundColor3 = color or Theme.Item,
        Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Text, Text = text, AutoButtonColor = true,
    }, { corner(7) })
end

local function card(parent)
    local f = new("Frame", {
        Parent = parent, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Panel,
    }, { corner(9), pad(10), new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
    return f
end

local function toggle(parent, title, sub, get, set)
    local row = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, sub and 40 or 28), BackgroundTransparency = 1 })
    new("TextLabel", {
        Parent = row, BackgroundTransparency = 1, Size = UDim2.new(1, -56, 0, 18), Font = Enum.Font.GothamBold,
        TextSize = 13, TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = title,
    })
    if sub then
        new("TextLabel", {
            Parent = row, BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 19), Size = UDim2.new(1, -56, 0, 16),
            Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Text = sub,
        })
    end
    local sw = new("TextButton", {
        Parent = row, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.new(0, 44, 0, 22),
        BackgroundColor3 = Theme.Off, Text = "", AutoButtonColor = false,
    }, { corner(11) })
    local knob = new("Frame", { Parent = sw, Size = UDim2.new(0, 18, 0, 18), Position = UDim2.new(0, 2, 0.5, -9), BackgroundColor3 = Theme.Text }, { corner(9) })
    local function render()
        local on = get()
        TweenService:Create(sw, TweenInfo.new(0.15), { BackgroundColor3 = on and Theme.On or Theme.Off }):Play()
        TweenService:Create(knob, TweenInfo.new(0.15), { Position = on and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9) }):Play()
    end
    sw.Activated:Connect(function() set(not get()) saveCfg() render() end)
    render()
    return row, render
end

local function stepper(parent, title, get, set, step, min, max, fmt)
    local row = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1 })
    new("TextLabel", {
        Parent = row, BackgroundTransparency = 1, Size = UDim2.new(1, -120, 1, 0), Font = Enum.Font.GothamBold, TextSize = 13,
        TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = title,
    })
    local val = new("TextLabel", {
        Parent = row, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -32, 0, 0),
        Size = UDim2.new(0, 56, 1, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Accent, Text = "",
    })
    local function render() val.Text = string.format(fmt or "%s", get()) end
    local minus = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -90, 0, 2), Size = UDim2.new(0, 26, 0, 24), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "-" }, { corner(6) })
    local plus = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2), Size = UDim2.new(0, 26, 0, 24), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "+" }, { corner(6) })
    minus.Activated:Connect(function() set(math.max(min, math.floor((get() - step) * 100 + 0.5) / 100)) saveCfg() render() end)
    plus.Activated:Connect(function() set(math.min(max, math.floor((get() + step) * 100 + 0.5) / 100)) saveCfg() render() end)
    render()
end

local function draggable(handle, target)
    local dragging, startInput, startPos, moved = false, nil, nil, 0
    handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startInput, startPos, moved = true, i.Position, target.Position, 0
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    track(UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startInput
            moved = math.max(moved, d.Magnitude)
            target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    return function() return moved end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
Hub = new("ScreenGui", { Name = "MaxHub_" .. HttpService:GenerateGUID(false):sub(1, 8), ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
local okParent = pcall(function() Hub.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not okParent or not Hub.Parent then Hub.Parent = PlayerGui end

local Main = new("Frame", {
    Parent = Hub, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 360, 0, 420),
    BackgroundColor3 = Theme.Bg, ClipsDescendants = true,
}, { corner(12), new("UIStroke", { Color = Theme.Accent, Transparency = 0.6, Thickness = 1 }) })

local Top = new("Frame", { Parent = Main, Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1 })
new("TextLabel", { Parent = Top, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 6), Size = UDim2.new(1, -90, 0, 20), Font = Enum.Font.GothamBlack, TextSize = 17, TextColor3 = Theme.Accent, TextXAlignment = Enum.TextXAlignment.Left, Text = "MAX HUB" })
new("TextLabel", { Parent = Top, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 25), Size = UDim2.new(1, -90, 0, 14), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left, Text = ("Anime Dice | V%s | game build %s"):format(VERSION, tostring(game.PlaceVersion)) })
local MinBtn = new("TextButton", { Parent = Top, Position = UDim2.new(1, -72, 0, 10), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "-" }, { corner(6) })
local CloseBtn = new("TextButton", { Parent = Top, Position = UDim2.new(1, -38, 0, 10), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Bad, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = "X" }, { corner(6) })
draggable(Top, Main)

local TabBar = new("Frame", { Parent = Main, Position = UDim2.new(0, 10, 0, 48), Size = UDim2.new(1, -20, 0, 30), BackgroundTransparency = 1 }, {
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
})
local Pages = new("Frame", { Parent = Main, Position = UDim2.new(0, 10, 0, 84), Size = UDim2.new(1, -20, 1, -116), BackgroundTransparency = 1 })
local StatusBar = new("TextLabel", { Parent = Main, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 1, -28), Size = UDim2.new(1, -28, 0, 22), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "Idle" })

local tabs, pages = {}, {}
local function page(name)
    local sf = new("ScrollingFrame", {
        Parent = Pages, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
    }, { new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
    local tb = new("TextButton", { Parent = TabBar, Size = UDim2.new(0.25, -5, 1, 0), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Sub, Text = name }, { corner(7) })
    tabs[name], pages[name] = tb, sf
    tb.Activated:Connect(function()
        for n, p in pairs(pages) do
            p.Visible = (n == name)
            tabs[n].BackgroundColor3 = (n == name) and Theme.Accent or Theme.Item
            tabs[n].TextColor3 = (n == name) and Theme.Bg or Theme.Sub
        end
    end)
    return sf
end

local PMain, PLuck, PFarm, PSet = page("Main"), page("Luck"), page("Farm"), page("Settings")

-- Floating reopen button (needed on LDPlayer / mobile)
local Float = new("TextButton", {
    Parent = Hub, Position = UDim2.new(0, 12, 0.4, 0), Size = UDim2.new(0, 52, 0, 52), BackgroundColor3 = Theme.Bg,
    Font = Enum.Font.GothamBlack, TextSize = 14, TextColor3 = Theme.Accent, Text = "MAX", Visible = false,
}, { corner(26), new("UIStroke", { Color = Theme.Accent, Thickness = 2 }) })
local floatMoved = draggable(Float, Float)
Float.Activated:Connect(function()
    if floatMoved() < 8 then Main.Visible = true Float.Visible = false end
end)
MinBtn.Activated:Connect(function() Main.Visible = false Float.Visible = true end)
track(UIS.InputBegan:Connect(function(i, gpe)
    if not gpe and i.KeyCode == Enum.KeyCode.RightControl then
        Main.Visible = not Main.Visible
        Float.Visible = not Main.Visible
    end
end))

-- Bind banner
local Banner = new("TextButton", {
    Parent = Hub, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.new(0, 340, 0, 46),
    BackgroundColor3 = Theme.Accent, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Bg, TextWrapped = true,
    Text = "", Visible = false,
}, { corner(10) })

------------------------------------------------------------------------
-- Logging / status
------------------------------------------------------------------------
local LogLines = {}
local LogLabel -- set in Main page
local function setStatus(t) StatusBar.Text = t end
local function log(t)
    table.insert(LogLines, 1, os.date("%H:%M:%S ") .. t)
    while #LogLines > 10 do table.remove(LogLines) end
    if LogLabel then LogLabel.Text = table.concat(LogLines, "\n") end
    print("[MAX HUB] " .. t)
end
local function notify(t)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = "MAX HUB", Text = t, Duration = 5 })
    end)
end

------------------------------------------------------------------------
-- Roll engine
------------------------------------------------------------------------
local UIRefs = { Grade = {}, Trait = {}, Quirk = {} }

local function refreshCatUI(cat)
    local r = UIRefs[cat]
    if r.Start then
        local on = (Running == cat)
        r.Start.Text = on and ("STOP " .. cat:upper() .. " ROLL") or ("START " .. cat:upper() .. " ROLL")
        r.Start.BackgroundColor3 = on and Theme.Bad or Theme.On
    end
    if r.Info then
        r.Info.Text = ("Last: %s   |   Rolls: %d"):format(Stats[cat].last, Stats[cat].rolls)
    end
    if r.Binds then
        local b = Cfg.Bind[cat]
        r.Binds.Text = ("Roll: %s  |  Result: %s  |  Boost: %s"):format(
            resolve(b.Roll) and "bound" or "auto", resolve(b.Result) and "bound" or "auto", resolve(b.Boost) and "bound" or "none")
    end
end

local function snapshot(scope, extra)
    local snap = {}
    if scope then
        for _, d in ipairs(scope:GetDescendants()) do
            if isTextObj(d) then snap[d] = d.Text end
        end
    end
    if extra then snap[extra] = extra.Text end
    return snap
end

local function readResult(cat, lbl)
    local list = Data[cat]
    if #list > 0 then return matchName(lbl.Text, list) end
    local t = clean(lbl.Text)
    if t ~= "" and #t <= 40 then return t, nil end
end

local function waitResult(cat, scope, before, resultLbl)
    local timeout = math.max(1.2, Cfg.Delay + 1)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        task.wait(0.08)
        if Running ~= cat then return nil end
        if resultLbl then
            if resultLbl.Text ~= before[resultLbl] then
                local n, r = readResult(cat, resultLbl)
                if n then return n, r, true end
            end
        elseif scope and #Data[cat] > 0 then
            for _, d in ipairs(scope:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and before[d] ~= d.Text and shown(d) then
                    local n, r = matchName(d.Text, Data[cat])
                    if n then return n, r, true end
                end
            end
        end
    end
    if resultLbl then
        local n, r = readResult(cat, resultLbl)
        return n, r, false
    end
    return nil
end

local function isHit(cat, name, rank)
    if not name then return false end
    local c = Cfg[cat]
    local custom = splitTargets(c.Custom)
    if #custom > 0 then
        for _, t in ipairs(custom) do
            if hasToken(name, t) or name:lower() == t:lower() then return true end
        end
        return false
    end
    if c.Target == "" then return false end
    if name == c.Target then return true end
    if c.OrBetter and rank then
        local tr = table.find(Data[cat], c.Target)
        return tr ~= nil and rank <= tr
    end
    return false
end

local function targetText(cat)
    local c = Cfg[cat]
    if clean(c.Custom) ~= "" then return c.Custom end
    if c.Target == "" then return nil end
    return c.Target .. (c.OrBetter and "+" or "")
end

local function stopRoll(reason)
    local cat = Running
    Running = nil
    if cat then
        log(cat .. " stopped: " .. reason)
        setStatus(cat .. " stopped: " .. reason)
        refreshCatUI(cat)
    end
end

local function runSession(cat)
    local c = Cfg[cat]
    local tgt = targetText(cat)
    if not tgt then
        setStatus("Pick a " .. cat .. " target first (Luck tab)")
        return
    end

    local panel = findPanel(cat)
    local rollBtn = resolve(Cfg.Bind[cat].Roll) or findRollButton(panel)
    if not rollBtn or not shown(rollBtn) then
        setStatus("Open the " .. cat .. " menu in-game, or Bind its Roll button")
        notify("Open the " .. cat .. " menu first")
        return
    end
    local scope = panel or rollBtn:FindFirstAncestorWhichIsA("LayerCollector")
    local resultLbl = resolve(Cfg.Bind[cat].Result)

    if #Data[cat] == 0 and not resultLbl then
        setStatus("No " .. cat .. " names known: bind the Result label first")
        return
    end

    Running = cat
    refreshCatUI(cat)
    log(("%s roll started -> target %s"):format(cat, tgt))

    -- Protect an existing good result
    if Cfg.Protect and resultLbl then
        local n, r = readResult(cat, resultLbl)
        if isHit(cat, n, r) then
            stopRoll("current " .. cat .. " already " .. n .. " (protected)")
            return
        end
    end

    -- Max Luck: activate the bound boost before rolling
    if c.MaxLuck then
        local boost = resolve(Cfg.Bind[cat].Boost)
        if boost and shown(boost) then
            press(boost)
            log(cat .. " luck boost pressed")
            task.wait(0.4)
        end
    end

    -- Watch for "not enough" style popups
    local errConn = PlayerGui.DescendantAdded:Connect(function(d)
        if not isTextObj(d) then return end
        task.defer(function()
            local t = clean(d.Text):lower()
            for _, p in ipairs(ERROR_PATTERNS) do
                if t:find(p, 1, true) and Running == cat then
                    stopRoll("game says: " .. clean(d.Text))
                    return
                end
            end
        end)
    end)

    local unread, same, lastName = 0, 0, nil
    while Running == cat do
        if not rollBtn.Parent or not shown(rollBtn) then stopRoll("menu closed") break end

        local before = snapshot(scope, resultLbl)
        press(rollBtn)
        local name, rank, changed = waitResult(cat, scope, before, resultLbl)
        if Running ~= cat then break end

        Stats[cat].rolls += 1
        if name then
            unread = 0
            Stats[cat].last = name
            if changed or name ~= lastName then same = 0 else same += 1 end
            lastName = name
            setStatus(("%s #%d -> %s"):format(cat, Stats[cat].rolls, name))
            if isHit(cat, name, rank) then
                refreshCatUI(cat)
                log(("HIT %s: %s after %d rolls"):format(cat, name, Stats[cat].rolls))
                notify(cat .. " HIT: " .. name)
                stopRoll("got " .. name)
                break
            end
            if same >= Cfg.MaxNoChange then stopRoll("result not changing (out of rerolls?)") break end
        else
            unread += 1
            setStatus(("%s #%d -> unreadable (%d/%d)"):format(cat, Stats[cat].rolls, unread, Cfg.MaxUnread))
            if unread >= Cfg.MaxUnread then stopRoll("can't read result: bind the Result label") break end
        end
        refreshCatUI(cat)
        task.wait(Cfg.Delay)
    end
    errConn:Disconnect()
    refreshCatUI(cat)
end

local function toggleRoll(cat)
    if Running == cat then stopRoll("stopped by you") return end
    if Running then stopRoll("switched to " .. cat) task.wait(0.2) end
    task.spawn(runSession, cat)
end

------------------------------------------------------------------------
-- Bind mode: tap a game element to record it
------------------------------------------------------------------------
local Binding = nil
local function startBind(cat, kind)
    local what = ({ Roll = "ROLL button", Result = "result text (the current " .. cat:lower() .. " name)", Boost = "luck boost button" })[kind]
    Binding = { cat = cat, kind = kind, t = os.clock() }
    Main.Visible = false
    Banner.Text = ("Open the %s menu and tap its %s.\nTap this banner to cancel."):format(cat, what)
    Banner.Visible = true
end
local function endBind()
    Binding = nil
    Banner.Visible = false
    Main.Visible = true
end
Banner.Activated:Connect(function() endBind() setStatus("Bind cancelled") end)

local function objectsAt(p)
    local objs = PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y)
    if #objs == 0 then
        local inset = GuiService:GetGuiInset()
        objs = PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y + inset.Y)
    end
    return objs
end

track(UIS.InputBegan:Connect(function(input)
    if not Binding or os.clock() - Binding.t < 0.35 then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local b = Binding
    local objs = objectsAt(input.Position)
    task.wait(0.1)
    if Binding ~= b then return end -- cancelled via banner

    local found
    for _, o in ipairs(objs) do
        if not o:IsDescendantOf(Hub) then
            if b.kind == "Result" then
                if (o:IsA("TextLabel") or o:IsA("TextButton")) and clean(o.Text) ~= "" then
                    if not found or matchName(o.Text, Data[b.cat]) then found = o end
                    if matchName(o.Text, Data[b.cat]) then break end
                end
            else
                local btn = o:IsA("GuiButton") and o or o:FindFirstAncestorWhichIsA("GuiButton")
                if btn then found = btn break end
            end
        end
    end

    if found then
        Cfg.Bind[b.cat][b.kind] = pathOf(found)
        saveCfg()
        log(("Bound %s %s -> %s (%s)"):format(b.cat, b.kind, found.Name, clean(textOf(found)):sub(1, 24)))
        setStatus(("Bound %s %s"):format(b.cat, b.kind))
    else
        setStatus("Nothing usable there; try again")
    end
    endBind()
    refreshCatUI(b.cat)
end))

------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------
-- MAIN
do
    local c = card(PMain)
    label(c, "Welcome to MAX HUB", 15, Theme.Accent, true)
    label(c, "1. Open the Grade, Trait or Quirk menu in-game.\n2. Luck tab -> pick a target -> START.\n3. If it can't find the button or result, use the Bind buttons once; binds are saved.", 12, Theme.Sub)
    local s = card(PMain)
    label(s, "Status", 13, Theme.Text, true)
    local stopAll = button(s, "STOP ALL", Theme.Bad)
    stopAll.Activated:Connect(function() stopRoll("stop all") end)
    local lg = card(PMain)
    label(lg, "Log", 13, Theme.Text, true)
    LogLabel = new("TextLabel", {
        Parent = lg, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        Font = Enum.Font.Code, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = "",
    })
end

-- LUCK (priority)
local Selectors = {}
local function buildLuck(cat)
    local c = card(PLuck)
    label(c, cat .. " Luck", 15, Theme.Accent, true)

    toggle(c, "Max " .. cat .. " Luck", "Use your bound luck boost before rolling",
        function() return Cfg[cat].MaxLuck end, function(v) Cfg[cat].MaxLuck = v end)

    -- target selector
    local row = new("Frame", { Parent = c, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 })
    new("TextLabel", { Parent = row, BackgroundTransparency = 1, Size = UDim2.new(0, 90, 1, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "Stop at" })
    local left = new("TextButton", { Parent = row, Position = UDim2.new(0, 90, 0, 2), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = "<" }, { corner(6) })
    local val = new("TextLabel", { Parent = row, Position = UDim2.new(0, 122, 0, 2), Size = UDim2.new(1, -156, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Accent, Text = "" }, { corner(6) })
    local right = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = ">" }, { corner(6) })
    local function render()
        local list = Data[cat]
        if Cfg[cat].Target == "" or not table.find(list, Cfg[cat].Target) then
            Cfg[cat].Target = list[math.min(3, #list)] or ""
        end
        val.Text = Cfg[cat].Target ~= "" and Cfg[cat].Target or "(use Custom target)"
    end
    local function shift(d)
        local list = Data[cat]
        if #list == 0 then return end
        local i = table.find(list, Cfg[cat].Target) or 1
        i = ((i - 1 + d) % #list) + 1
        Cfg[cat].Target = list[i]
        saveCfg()
        render()
    end
    left.Activated:Connect(function() shift(-1) end)
    right.Activated:Connect(function() shift(1) end)
    render()
    Selectors[cat] = render

    toggle(c, "Or better", "Also stop on anything rarer than the target",
        function() return Cfg[cat].OrBetter end, function(v) Cfg[cat].OrBetter = v end)

    local box = new("TextBox", {
        Parent = c, Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Theme.Item, Font = Enum.Font.Gotham, TextSize = 12,
        TextColor3 = Theme.Text, PlaceholderText = "Custom target (optional, e.g. Genesis, Paradox)", PlaceholderColor3 = Theme.Sub,
        Text = Cfg[cat].Custom, ClearTextOnFocus = false,
    }, { corner(7), pad(6) })
    box.FocusLost:Connect(function() Cfg[cat].Custom = box.Text saveCfg() end)

    local bindRow = new("Frame", { Parent = c, Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1 }, {
        new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
    })
    for _, kind in ipairs({ "Roll", "Result", "Boost" }) do
        local b = new("TextButton", { Parent = bindRow, Size = UDim2.new(1 / 3, -4, 1, 0), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Theme.Text, Text = "Bind " .. kind }, { corner(6) })
        b.Activated:Connect(function() startBind(cat, kind) end)
    end
    UIRefs[cat].Binds = label(c, "", 11, Theme.Sub)

    UIRefs[cat].Start = button(c, "", Theme.On, 36)
    UIRefs[cat].Start.Activated:Connect(function() toggleRoll(cat) end)
    UIRefs[cat].Info = label(c, "", 11, Theme.Sub)
    refreshCatUI(cat)
end
for _, cat in ipairs(CATS) do buildLuck(cat) end

-- FARM (phase 5, wired after a scan)
do
    local c = card(PFarm)
    label(c, "Farm", 15, Theme.Accent, true)
    label(c, "Auto Farm / Quest / Collect come next (phase 5). Run Settings -> Copy Scanner Dump in the game and send it over so they can be wired to the real game buttons.", 12, Theme.Sub)
end

-- SETTINGS
do
    local c = card(PSet)
    label(c, "Rolling", 13, Theme.Text, true)
    stepper(c, "Delay between rolls", function() return Cfg.Delay end, function(v) Cfg.Delay = v end, 0.05, 0.05, 3, "%.2fs")
    stepper(c, "Stop after unreadable", function() return Cfg.MaxUnread end, function(v) Cfg.MaxUnread = v end, 1, 2, 50, "%d")
    stepper(c, "Stop after unchanged", function() return Cfg.MaxNoChange end, function(v) Cfg.MaxNoChange = v end, 1, 3, 50, "%d")
    toggle(c, "Protect current result", "Won't roll if it already meets target",
        function() return Cfg.Protect end, function(v) Cfg.Protect = v end)
    toggle(c, "Anti-AFK", "Prevents the 20-minute idle kick",
        function() return Cfg.AntiAFK end, function(v) Cfg.AntiAFK = v end)

    local d = card(PSet)
    label(d, "Game data", 13, Theme.Text, true)
    local src = label(d, "", 11, Theme.Sub)
    local function renderSrc()
        src.Text = ("Grades: %d (%s)\nTraits: %d (%s)\nQuirks: %d (%s)"):format(
            #Data.Grade, DataSource.Grade, #Data.Trait, DataSource.Trait, #Data.Quirk, DataSource.Quirk)
    end
    renderSrc()
    local rescan = button(d, "Re-scan game data")
    rescan.Activated:Connect(function()
        local n = learnGameData(log)
        for _, r in pairs(Selectors) do r() end
        renderSrc()
        setStatus(n > 0 and ("Updated " .. n .. " table(s) from game") or "No odds tables found; using built-in lists")
    end)
    local dump = button(d, "Copy Scanner Dump")
    dump.Activated:Connect(function()
        local lines = { ("-- MAX HUB scan %s | PlaceId %d | build %d"):format(os.date("%Y-%m-%d %H:%M"), game.PlaceId, game.PlaceVersion), "", "[Remotes]" }
        for _, x in ipairs(RS:GetDescendants()) do
            if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") or x.ClassName == "UnreliableRemoteEvent" then
                table.insert(lines, x.ClassName .. "  " .. x:GetFullName())
            end
        end
        table.insert(lines, "") table.insert(lines, "[Modules]")
        for _, x in ipairs(RS:GetDescendants()) do
            if x:IsA("ModuleScript") then table.insert(lines, x:GetFullName()) end
        end
        table.insert(lines, "") table.insert(lines, "[Visible buttons]")
        for _, x in ipairs(PlayerGui:GetDescendants()) do
            if x:IsA("GuiButton") and shown(x) then
                table.insert(lines, (pathOf(x) or x.Name) .. "  |  " .. clean(textOf(x)):sub(1, 40))
            end
            if #lines > 1500 then break end
        end
        local text = table.concat(lines, "\n")
        if setclipboard then setclipboard(text) setStatus("Scanner dump copied (" .. #lines .. " lines)")
        else print(text) setStatus("No clipboard: dump printed to console") end
    end)

    local m = card(PSet)
    label(m, "Hub", 13, Theme.Text, true)
    local clr = button(m, "Clear all binds")
    clr.Activated:Connect(function()
        Cfg.Bind = { Grade = {}, Trait = {}, Quirk = {} }
        saveCfg()
        for _, cat in ipairs(CATS) do refreshCatUI(cat) end
        setStatus("Binds cleared")
    end)
    local unload = button(m, "Unload MAX HUB", Theme.Bad)
    unload.Activated:Connect(function() genv.MaxHubCleanup() end)
    label(m, "Toggle UI: RightCtrl, or the MAX bubble when minimized.", 11, Theme.Sub)
end

------------------------------------------------------------------------
-- Anti-AFK
------------------------------------------------------------------------
track(LP.Idled:Connect(function()
    if not Cfg.AntiAFK then return end
    pcall(function()
        local vu = game:GetService("VirtualUser")
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
    end)
end))

------------------------------------------------------------------------
-- Cleanup / boot
------------------------------------------------------------------------
genv.MaxHubCleanup = function()
    Running = nil
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    table.clear(Conns)
    if Hub then Hub:Destroy() end
    genv.MaxHubCleanup = nil
end
CloseBtn.Activated:Connect(function() genv.MaxHubCleanup() end)

for n, p in pairs(pages) do
    p.Visible = (n == "Luck")
    tabs[n].BackgroundColor3 = (n == "Luck") and Theme.Accent or Theme.Item
    tabs[n].TextColor3 = (n == "Luck") and Theme.Bg or Theme.Sub
end

task.spawn(function()
    local n = learnGameData(log)
    for _, r in pairs(Selectors) do r() end
    log(n > 0 and ("Game data synced (" .. n .. " table(s))") or "Using built-in Update 5/6 lists")
    local exec = identifyexecutor and identifyexecutor() or "unknown executor"
    setStatus("Ready | " .. tostring(exec) .. " | build " .. game.PlaceVersion)
end)
