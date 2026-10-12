--[[
    MAX HUB  |  Anime Dice  |  V1.2

    Record & Replay engine: tap RECORD, then tap the game's own button once.
    The hub captures exactly what the game sends and replays it, so it keeps
    working after game updates without hard-coded remote names.

      Luck tab : Trait / Grade / Quirk auto roll with unit (hero) selector,
                 Stop-at target, one-click luck boosts.
      Farm tab : Auto Roll units, Rebirth, Upgrade, Claim, Quest, 2 custom macros.

    Luck multipliers are calculated by the game server. This hub cannot raise
    them; it only automates the boosts you already own.

    Delta:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/wuzz-codx/Script/main/script1.lua"))()
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

local VERSION     = "1.2"
local CONFIG_FILE = "MaxHub_AnimeDice.json"
local SCAN_FILE   = "MaxHub_Scan.txt"
local CATS        = { "Grade", "Trait", "Quirk" }
local Alive       = true

------------------------------------------------------------------------
-- Game data (rarest first) - matches the in-game Traits list
------------------------------------------------------------------------
local Data = {
    Trait = {
        "Genesis", "Paradox", "Eternal", "Transcendent", "Monarch", "Shogun", "Samurai",
        "Money III", "Damage III", "Health III",
        "Money II", "Damage II", "Health II",
        "Money I", "Damage I", "Health I",
    },
    Grade = { "Z++", "Z+", "Z", "SSS", "SS", "S", "A", "B", "C", "D" },
    Quirk = {},
}
local DataSource = { Trait = "built-in", Grade = "built-in", Quirk = "none" }

local ERROR_PATTERNS = { "not enough", "insufficient", "no reroll", "out of reroll", "you need", "cannot afford", "are you sure" }
local ROLL_WORDS     = { "reroll", "re%-roll", "roll", "spin" }
local ROLL_EXCLUDE   = { "auto", "stop", "buy", "robux", "r%$", "skip", "jackpot" }
local LEARN_HINT     = { Trait = { "trait", "reroll", "roll" }, Grade = { "grade", "reroll", "roll" }, Quirk = { "quirk", "reroll", "roll" } }

local FARM_SLOTS = {
    { key = "Roll",    name = "Auto Roll Units",  interval = 0.5, fallback = "ROLL",  hint = "Tap the big ROLL dice" },
    { key = "Rebirth", name = "Auto Rebirth",     interval = 30,  hint = "Open Rebirth and tap the rebirth button" },
    { key = "Upgrade", name = "Auto Upgrade",     interval = 3,   hint = "Open UPGRADES and tap an upgrade" },
    { key = "Claim",   name = "Auto Claim",       interval = 60,  fallback = "CLAIM", hint = "Tap Claim (daily / rewards)" },
    { key = "Quest",   name = "Auto Quest",       interval = 10,  hint = "Open Quests and tap claim / start" },
    { key = "Custom1", name = "Custom Macro 1",   interval = 5,   hint = "Tap any game button to repeat" },
    { key = "Custom2", name = "Custom Macro 2",   interval = 5,   hint = "Tap any game button to repeat" },
}

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------
local Cfg = {
    Delay = 0.35, MaxUnread = 8, MaxNoChange = 10,
    AntiAFK = true, Protect = true, PauseFarm = true, Spy = false,
    BoostEvery = 0, -- minutes, 0 = only when a luck session starts
    Grade = { Target = "Z+",      OrBetter = true, MaxLuck = true, Custom = "", Unit = nil },
    Trait = { Target = "Eternal", OrBetter = true, MaxLuck = true, Custom = "", Unit = nil },
    Quirk = { Target = "",        OrBetter = true, MaxLuck = true, Custom = "", Unit = nil },
    Bind = { Grade = {}, Trait = {}, Quirk = {} }, -- Result label paths
    Recipes = {},  -- key -> serialized recipe
    Boosts = {},   -- list of serialized recipes
    Farm = {},     -- key -> { On, Interval }
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
for _, s in ipairs(FARM_SLOTS) do
    Cfg.Farm[s.key] = Cfg.Farm[s.key] or {}
    Cfg.Farm[s.key].On = false -- never auto-start farming on load
    Cfg.Farm[s.key].Interval = Cfg.Farm[s.key].Interval or s.interval
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
local Conns = {}
local function track(c) table.insert(Conns, c) return c end

local Hub
local Running = nil
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

local function exactName(s, list)
    if type(s) ~= "string" then return nil end
    local t = clean(s):lower()
    for rank, name in ipairs(list) do
        if name:lower() == t then return name, rank end
    end
end

-- Distinct exact names found anywhere inside a value (tables scanned)
local function namesIn(v, list, out, depth)
    out = out or {}
    depth = depth or 0
    if depth > 5 then return out end
    if type(v) == "string" then
        local n = exactName(v, list)
        if n then out[n] = true end
    elseif type(v) == "table" then
        for k, x in pairs(v) do
            namesIn(k, list, out, depth + 1)
            namesIn(x, list, out, depth + 1)
        end
    end
    return out
end

local function singleName(v, list)
    local found, count, only = namesIn(v, list), 0, nil
    for n in pairs(found) do count += 1 only = n end
    if count == 1 then return only, table.find(list, only) end
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

local function deepCopy(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 8 then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deepCopy(x, depth + 1) end
    return o
end

------------------------------------------------------------------------
-- Serialization (so recordings survive rejoining)
------------------------------------------------------------------------
local function instPath(inst)
    local t, cur = {}, inst
    while cur and cur ~= game do
        table.insert(t, 1, cur.Name)
        cur = cur.Parent
    end
    if cur ~= game then return nil end
    return t
end

local function instFromPath(t)
    if type(t) ~= "table" then return nil end
    local cur = game
    for _, n in ipairs(t) do
        cur = cur:FindFirstChild(n)
        if not cur then return nil end
    end
    return cur
end

local function ser(v, depth)
    depth = depth or 0
    local tv = typeof(v)
    if tv == "string" or tv == "number" or tv == "boolean" then return v end
    if tv == "nil" then return { __nil = true } end
    if tv == "Instance" then
        local p = instPath(v)
        if p then return { __inst = p } end
        return nil, "instance outside game"
    end
    if tv == "Vector3" then return { __v3 = { v.X, v.Y, v.Z } } end
    if tv == "EnumItem" then return { __enum = { tostring(v.EnumType), v.Name } } end
    if tv == "table" then
        if depth > 6 then return nil, "too deep" end
        local pairsOut = {}
        for k, x in pairs(v) do
            local sk, e1 = ser(k, depth + 1)
            local sx, e2 = ser(x, depth + 1)
            if e1 or e2 then return nil, e1 or e2 end
            table.insert(pairsOut, { sk, sx })
        end
        return { __t = pairsOut }
    end
    return nil, "unsupported " .. tv
end

local function deser(v)
    if type(v) ~= "table" then return v end
    if v.__nil then return nil end
    if v.__inst then return instFromPath(v.__inst) end
    if v.__v3 then return Vector3.new(v.__v3[1], v.__v3[2], v.__v3[3]) end
    if v.__enum then
        local ok, e = pcall(function() return Enum[v.__enum[1]][v.__enum[2]] end)
        return ok and e or nil
    end
    if v.__t then
        local o = {}
        for _, kv in ipairs(v.__t) do
            local k = deser(kv[1])
            if k ~= nil then o[k] = deser(kv[2]) end
        end
        return o
    end
    return v
end

local function serArgs(args)
    local list = {}
    for i = 1, args.n do
        local s, err = ser(args[i])
        if err then return nil, err end
        list[i] = s
    end
    return { n = args.n, list = list }
end

local function deserArgs(s)
    local out = { n = s.n }
    for i = 1, s.n do out[i] = deser(s.list[i]) end
    return out
end

local function short(v)
    local tv = typeof(v)
    if tv == "string" then return '"' .. (#v > 18 and v:sub(1, 18) .. ".." or v) .. '"' end
    if tv == "Instance" then return v.Name end
    if tv == "table" then return "{..}" end
    return tostring(v)
end

local function describeCall(remote, method, args)
    local parts = {}
    for i = 1, math.min(args.n, 5) do table.insert(parts, short(args[i])) end
    if args.n > 5 then table.insert(parts, "...") end
    return ("%s:%s(%s)"):format(remote.Name, method == "InvokeServer" and "Invoke" or "Fire", table.concat(parts, ", "))
end

------------------------------------------------------------------------
-- Logging (UI hooked up later)
------------------------------------------------------------------------
local LogLines, LogLabel, StatusBar = {}, nil, nil
local function setStatus(t) if StatusBar then StatusBar.Text = t end end
local function log(t)
    table.insert(LogLines, 1, os.date("%H:%M:%S ") .. t)
    while #LogLines > 12 do table.remove(LogLines) end
    if LogLabel then LogLabel.Text = table.concat(LogLines, "\n") end
    print("[MAX HUB] " .. t)
end
local function notify(t)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", { Title = "MAX HUB", Text = t, Duration = 5 })
    end)
end

------------------------------------------------------------------------
-- Remote capture hook (installed once per game session)
------------------------------------------------------------------------
local RemoteTimes = setmetatable({}, { __mode = "k" })
local Learn = nil
local HookOK = false
local onLearnUpdate -- set by UI

local function onOutgoing(remote, method, args)
    if not Alive then return end
    local times = RemoteTimes[remote] or {}
    table.insert(times, os.clock())
    if #times > 20 then table.remove(times, 1) end
    RemoteTimes[remote] = times
    if Cfg.Spy then log("OUT " .. describeCall(remote, method, args)) end
    if Learn then
        table.insert(Learn.calls, { remote = remote, method = method, args = args, t = os.clock() })
        if onLearnUpdate then onLearnUpdate() end
    end
end

genv.MaxHubOnCall = onOutgoing
if genv.MaxHubHooked then
    HookOK = true
elseif hookmetamethod and getnamecallmethod then
    local nc = newcclosure or function(f) return f end
    local cc = checkcaller or function() return false end
    local ok = pcall(function()
        local old
        old = hookmetamethod(game, "__namecall", nc(function(self, ...)
            local m = getnamecallmethod()
            if (m == "FireServer" or m == "InvokeServer") and not cc() then
                local cb = genv.MaxHubOnCall
                if cb then
                    local args = table.pack(...)
                    for i = 1, args.n do args[i] = deepCopy(args[i]) end
                    task.spawn(cb, self, m, args)
                end
            end
            return old(self, ...)
        end))
    end)
    HookOK = ok
    genv.MaxHubHooked = ok
end

------------------------------------------------------------------------
-- Recipes: record / save / replay
------------------------------------------------------------------------
local Recipes = {}      -- key -> live recipe
local BoostRecipes = {} -- list of live recipes
local Pools = {}        -- cat -> list of { value, inst, label }

local function recipeToCfg(rec)
    local calls = {}
    for _, c in ipairs(rec.calls) do
        local rp = instPath(c.remote)
        local sa, err = serArgs(c.args)
        if not rp or err then return nil end
        table.insert(calls, { remote = rp, method = c.method, args = sa })
    end
    local out = { calls = calls, label = rec.label }
    if rec.unit then
        local sv = ser(rec.unit.value)
        out.unit = { ci = rec.unit.ci, i = rec.unit.i, k = rec.unit.k, value = sv }
    end
    return out
end

local function recipeFromCfg(s)
    if type(s) ~= "table" or type(s.calls) ~= "table" then return nil end
    local rec = { calls = {}, label = s.label }
    for _, c in ipairs(s.calls) do
        local remote = instFromPath(c.remote)
        if not remote then return nil end
        table.insert(rec.calls, { remote = remote, method = c.method, args = deserArgs(c.args) })
    end
    if s.unit then rec.unit = { ci = s.unit.ci, i = s.unit.i, k = s.unit.k, value = deser(s.unit.value) } end
    return rec
end

local function withUnit(args, u, value)
    local copy = table.pack(table.unpack(args, 1, args.n))
    if u.k == nil then
        copy[u.i] = value
    elseif type(copy[u.i]) == "table" then
        local t = table.clone(copy[u.i])
        t[u.k] = value
        copy[u.i] = t
    end
    return copy
end

local function callRemote(remote, method, args)
    if method == "InvokeServer" then
        local done, out = false, nil
        task.spawn(function()
            out = table.pack(pcall(function() return remote:InvokeServer(table.unpack(args, 1, args.n)) end))
            done = true
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 5 do task.wait() end
        if out and out[1] then return table.pack(table.unpack(out, 2, out.n)) end
        return nil
    end
    pcall(function() remote:FireServer(table.unpack(args, 1, args.n)) end)
    return nil
end

local function playRecipe(rec, unitValue)
    local lastRet
    for ci, call in ipairs(rec.calls) do
        if not call.remote or not call.remote.Parent then return false, "remote missing (re-record)" end
        local args = call.args
        if unitValue ~= nil and rec.unit and rec.unit.ci == ci then args = withUnit(args, rec.unit, unitValue) end
        local ret = callRemote(call.remote, call.method, args)
        if ret then lastRet = ret end
        if ci < #rec.calls then task.wait(0.06) end
    end
    return true, lastRet
end

-- Units ------------------------------------------------------------------
local UNIT_LABEL_KEYS = { "DisplayName", "UnitName", "Unit", "Character", "Hero", "Name" }

local function readUnitData(cat, inst)
    if not inst or not inst.Parent then return nil end
    local list = Data[cat]
    if #list == 0 then return nil end
    local kw = cat:lower()
    local loose
    local function check(key, val)
        local n, r = exactName(val, list)
        if n then
            if key:lower():find(kw, 1, true) then return n, r end
            loose = loose or { n, r }
        end
    end
    for k, v in pairs(inst:GetAttributes()) do
        local n, r = check(k, v)
        if n then return n, r end
    end
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("StringValue") then
            local n, r = check(d.Name, d.Value)
            if n then return n, r end
        end
    end
    if loose and cat == "Trait" then return loose[1], loose[2] end
end

local function unitLabel(inst)
    local name
    for _, k in ipairs(UNIT_LABEL_KEYS) do
        local a = inst:GetAttribute(k)
        if type(a) == "string" and a ~= "" then name = a break end
        local c = inst:FindFirstChild(k)
        if c and c:IsA("StringValue") and c.Value ~= "" then name = c.Value break end
    end
    name = name or inst.Name
    if #name > 22 then name = name:sub(1, 20) .. ".." end
    local tr = readUnitData("Trait", inst)
    return tr and (name .. " [" .. tr .. "]") or name
end

local ID_ATTRS = { "Id", "ID", "UID", "Uid", "UUID", "GUID", "Guid" }

local function findUnitPool(value)
    if typeof(value) == "Instance" then
        local p = value.Parent
        if not p then return nil end
        local out = {}
        for _, c in ipairs(p:GetChildren()) do
            if c.ClassName == value.ClassName then table.insert(out, { value = c, inst = c, label = unitLabel(c) }) end
        end
        return out
    end
    if type(value) ~= "string" or #value < 3 then return nil end
    for _, root in ipairs({ LP, RS }) do
        for _, d in ipairs(root:GetDescendants()) do
            if d.Name == value and d.Parent then
                local out = {}
                for _, c in ipairs(d.Parent:GetChildren()) do table.insert(out, { value = c.Name, inst = c, label = unitLabel(c) }) end
                return out
            end
            if d:IsA("StringValue") and d.Value == value and d.Parent and d.Parent.Parent then
                local key, out = d.Name, {}
                for _, c in ipairs(d.Parent.Parent:GetChildren()) do
                    local v = c:FindFirstChild(key)
                    if v and v:IsA("StringValue") then table.insert(out, { value = v.Value, inst = c, label = unitLabel(c) }) end
                end
                return out
            end
            for _, a in ipairs(ID_ATTRS) do
                if d:GetAttribute(a) == value and d.Parent then
                    local out = {}
                    for _, c in ipairs(d.Parent:GetChildren()) do
                        local cv = c:GetAttribute(a)
                        if cv ~= nil then table.insert(out, { value = cv, inst = c, label = unitLabel(c) }) end
                    end
                    return out
                end
            end
        end
    end
end

local function looksLikeUnit(v)
    if typeof(v) == "Instance" then
        return not (v:IsA("BaseRemoteEvent") or v:IsA("RemoteFunction") or v:IsA("Player")) and v.Parent ~= nil
    end
    if type(v) == "string" then
        return #v >= 12 or (#v >= 4 and (v:find("%d") ~= nil or v:find("%-") ~= nil))
    end
    return false
end

local function detectUnit(rec)
    for ci, call in ipairs(rec.calls) do
        for i = 1, call.args.n do
            local a = call.args[i]
            if looksLikeUnit(a) then
                local pool = findUnitPool(a)
                if pool and #pool > 0 then return { ci = ci, i = i, value = a }, pool end
            elseif type(a) == "table" then
                for k, x in pairs(a) do
                    if (type(k) == "string" or type(k) == "number") and looksLikeUnit(x) then
                        local pool = findUnitPool(x)
                        if pool and #pool > 0 then return { ci = ci, i = i, k = k, value = x }, pool end
                    end
                end
            end
        end
    end
end

local function sameValue(a, b) return a == b end

local function currentUnit(cat)
    local rec = Recipes[cat]
    if not rec or not rec.unit then return nil, nil end
    local pool = Pools[cat]
    local want = deser(Cfg[cat].Unit)
    if want == nil then want = rec.unit.value end
    if pool then
        for _, e in ipairs(pool) do
            if sameValue(e.value, want) then return e.value, e.inst end
        end
    end
    return want, nil
end

local function refreshPool(cat)
    local rec = Recipes[cat]
    Pools[cat] = (rec and rec.unit and findUnitPool(rec.unit.value)) or {}
end

-- Load saved recipes
for key, s in pairs(Cfg.Recipes) do
    local rec = recipeFromCfg(s)
    if rec then Recipes[key] = rec end
end
for _, s in ipairs(Cfg.Boosts) do
    local rec = recipeFromCfg(s)
    if rec then table.insert(BoostRecipes, rec) end
end
for _, cat in ipairs(CATS) do refreshPool(cat) end

------------------------------------------------------------------------
-- UI-based fallbacks (when nothing is recorded)
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
        if pcall(firesignal, btn.MouseButton1Click) then pcall(firesignal, btn.Activated) return true end
    end
    return pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local inset = GuiService:GetGuiInset()
        local p = btn.AbsolutePosition + btn.AbsoluteSize / 2
        vim:SendMouseButtonEvent(p.X, p.Y + inset.Y, 0, true, game, 0)
        task.wait(0.03)
        vim:SendMouseButtonEvent(p.X, p.Y + inset.Y, 0, false, game, 0)
    end)
end

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

local function findButtonByText(word)
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d:IsA("GuiButton") and shown(d) then
            local t = clean(textOf(d))
            if #t <= 16 and hasToken(t, word) then return d end
        end
    end
end

local function findLuckText()
    local best
    for _, d in ipairs(PlayerGui:GetDescendants()) do
        if d:IsA("TextLabel") and shown(d) then
            local t = clean(d.Text)
            if t:match("^[xX]%d[%d%.,]*%a*$") then best = t end
        end
    end
    return best
end

------------------------------------------------------------------------
-- Learn names from the game's own modules
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
    for k, v in pairs(t) do
        if type(v) == "table" then
            local c
            for _, ck in ipairs(CHANCE_KEYS) do
                if type(v[ck]) == "number" then c = v[ck] break end
            end
            local name = (type(k) == "string" and k) or (type(v.Name) == "string" and v.Name) or nil
            if c and name then table.insert(entries, { name = name, chance = c }) end
        end
    end
    if #entries < 3 then return nil end
    table.sort(entries, function(a, b) return a.chance < b.chance end)
    local names = {}
    for _, e in ipairs(entries) do table.insert(names, e.name) end
    return names
end

local function learnGameData()
    local learned = 0
    for _, m in ipairs(RS:GetDescendants()) do
        if m:IsA("ModuleScript") then
            local n = m.Name:lower()
            for _, cat in ipairs(CATS) do
                if n:find(cat:lower(), 1, true) then
                    local t = tryRequire(m)
                    if type(t) == "table" then
                        local names = extractOdds(t)
                        if names then
                            Data[cat] = names
                            DataSource[cat] = m.Name
                            learned += 1
                            log(("Learned %d %ss from %s"):format(#names, cat, m.Name))
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
    Rec = Color3.fromRGB(200, 60, 90),
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
        Parent = parent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
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

local function hrow(parent, h)
    return new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, h or 30), BackgroundTransparency = 1 }, {
        new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    })
end

local function smallBtn(parent, text, frac, color)
    return new("TextButton", {
        Parent = parent, Size = UDim2.new(frac, -4, 1, 0), BackgroundColor3 = color or Theme.Item, Font = Enum.Font.GothamBold,
        TextSize = 11, TextColor3 = Theme.Text, Text = text, TextWrapped = true,
    }, { corner(6) })
end

local function card(parent)
    return new("Frame", {
        Parent = parent, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Panel,
    }, { corner(9), pad(10), new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })
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
        Parent = row, BackgroundTransparency = 1, Size = UDim2.new(1, -120, 1, 0), Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = title,
    })
    local val = new("TextLabel", {
        Parent = row, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -30, 0, 0),
        Size = UDim2.new(0, 58, 1, 0), Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Accent, Text = "",
    })
    local function render() val.Text = string.format(fmt or "%s", get()) end
    local minus = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -90, 0, 2), Size = UDim2.new(0, 26, 0, 24), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "-" }, { corner(6) })
    local plus = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2), Size = UDim2.new(0, 26, 0, 24), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "+" }, { corner(6) })
    minus.Activated:Connect(function() set(math.max(min, math.floor((get() - step) * 100 + 0.5) / 100)) saveCfg() render() end)
    plus.Activated:Connect(function() set(math.min(max, math.floor((get() + step) * 100 + 0.5) / 100)) saveCfg() render() end)
    render()
end

local function cycler(parent, title, getText, onShift)
    local row = new("Frame", { Parent = parent, Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 })
    new("TextLabel", { Parent = row, BackgroundTransparency = 1, Size = UDim2.new(0, 70, 1, 0), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = title })
    local left = new("TextButton", { Parent = row, Position = UDim2.new(0, 70, 0, 2), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = "<" }, { corner(6) })
    local val = new("TextLabel", { Parent = row, Position = UDim2.new(0, 102, 0, 2), Size = UDim2.new(1, -136, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Accent, TextTruncate = Enum.TextTruncate.AtEnd, Text = "" }, { corner(6) })
    local right = new("TextButton", { Parent = row, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = ">" }, { corner(6) })
    local function render() val.Text = getText() end
    left.Activated:Connect(function() onShift(-1) render() end)
    right.Activated:Connect(function() onShift(1) render() end)
    render()
    return render
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
    Parent = Hub, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 370, 0, 440),
    BackgroundColor3 = Theme.Bg, ClipsDescendants = true,
}, { corner(12), new("UIStroke", { Color = Theme.Accent, Transparency = 0.6, Thickness = 1 }) })

local Top = new("Frame", { Parent = Main, Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1 })
new("TextLabel", { Parent = Top, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 6), Size = UDim2.new(1, -90, 0, 20), Font = Enum.Font.GothamBlack, TextSize = 17, TextColor3 = Theme.Accent, TextXAlignment = Enum.TextXAlignment.Left, Text = "MAX HUB" })
new("TextLabel", { Parent = Top, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 25), Size = UDim2.new(1, -90, 0, 14), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left, Text = ("Anime Dice | V%s | build %s"):format(VERSION, tostring(game.PlaceVersion)) })
local MinBtn = new("TextButton", { Parent = Top, Position = UDim2.new(1, -72, 0, 10), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, Text = "-" }, { corner(6) })
local CloseBtn = new("TextButton", { Parent = Top, Position = UDim2.new(1, -38, 0, 10), Size = UDim2.new(0, 28, 0, 26), BackgroundColor3 = Theme.Bad, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Theme.Text, Text = "X" }, { corner(6) })
draggable(Top, Main)

local TabBar = new("Frame", { Parent = Main, Position = UDim2.new(0, 10, 0, 48), Size = UDim2.new(1, -20, 0, 30), BackgroundTransparency = 1 }, {
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }),
})
local Pages = new("Frame", { Parent = Main, Position = UDim2.new(0, 10, 0, 84), Size = UDim2.new(1, -20, 1, -116), BackgroundTransparency = 1 })
StatusBar = new("TextLabel", { Parent = Main, BackgroundTransparency = 1, Position = UDim2.new(0, 14, 1, -28), Size = UDim2.new(1, -28, 0, 22), Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "Loading..." })

local tabs, pages = {}, {}
local function selectTab(name)
    for n, p in pairs(pages) do
        p.Visible = (n == name)
        tabs[n].BackgroundColor3 = (n == name) and Theme.Accent or Theme.Item
        tabs[n].TextColor3 = (n == name) and Theme.Bg or Theme.Sub
    end
end
local function page(name)
    local sf = new("ScrollingFrame", {
        Parent = Pages, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
    }, { new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
    local tb = new("TextButton", { Parent = TabBar, Size = UDim2.new(0.25, -5, 1, 0), BackgroundColor3 = Theme.Item, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Sub, Text = name }, { corner(7) })
    tabs[name], pages[name] = tb, sf
    tb.Activated:Connect(function() selectTab(name) end)
    return sf
end

local PMain, PLuck, PFarm, PSet = page("Main"), page("Luck"), page("Farm"), page("Settings")

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

local Banner = new("TextButton", {
    Parent = Hub, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(0, 380, 0, 64),
    BackgroundColor3 = Theme.Rec, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Text, TextWrapped = true,
    Text = "", Visible = false, AutoButtonColor = true,
}, { corner(10), pad(6) })

------------------------------------------------------------------------
-- Recording flow
------------------------------------------------------------------------
local function argsKey(c) return c.remote:GetFullName() .. "|" .. describeCall(c.remote, c.method, c.args) end

local function finishLearn()
    local L = Learn
    if not L then return end
    Learn = nil
    Banner.Visible = false
    Main.Visible = true

    local calls, lastKey = {}, nil
    for _, c in ipairs(L.calls) do
        local times, noisy = RemoteTimes[c.remote] or {}, 0
        for _, t in ipairs(times) do
            if t < L.t and t > L.t - 4 then noisy += 1 end
        end
        local k = argsKey(c)
        if noisy < 2 and k ~= lastKey then
            table.insert(calls, c)
            lastKey = k
        end
    end
    if #calls == 0 then
        setStatus("Nothing captured. Tap Record, then tap the game's button.")
        log("Record " .. L.title .. ": no game action captured")
        return
    end

    -- If keywords match some calls, keep the call(s) up to and including the best match
    local hints = L.hints
    if hints then
        local bestIdx
        for i, c in ipairs(calls) do
            local nm = c.remote:GetFullName():lower() .. " " .. describeCall(c.remote, c.method, c.args):lower()
            for _, h in ipairs(hints) do
                if nm:find(h, 1, true) then bestIdx = i break end
            end
        end
        if bestIdx then
            local trimmed = {}
            for i = 1, bestIdx do table.insert(trimmed, calls[i]) end
            calls = trimmed
        end
    end
    if #calls > 4 then
        local trimmed = {}
        for i = #calls - 3, #calls do table.insert(trimmed, calls[i]) end
        calls = trimmed
    end

    local rec = { calls = calls }
    local parts = {}
    for _, c in ipairs(calls) do table.insert(parts, describeCall(c.remote, c.method, c.args)) end
    rec.label = table.concat(parts, " > ")
    if L.wantUnit then
        local u = detectUnit(rec)
        rec.unit = u
    end
    log("Recorded " .. L.title .. ": " .. rec.label)
    L.onDone(rec)
end

local function startLearn(title, hint, hints, wantUnit, onDone)
    if not HookOK then
        setStatus("Recording needs hookmetamethod (not available in this executor)")
        notify("Recording not supported by this executor")
        return
    end
    Learn = { title = title, t = os.clock(), calls = {}, hints = hints, wantUnit = wantUnit, onDone = onDone }
    Main.Visible = false
    Float.Visible = false
    Banner.Visible = true
    Banner:SetAttribute("Hint", hint)
    onLearnUpdate()
end

onLearnUpdate = function()
    if not Learn then return end
    Banner.Text = ("RECORDING %s\n%s\nCaptured: %d  -  TAP HERE WHEN DONE"):format(
        Learn.title:upper(), Banner:GetAttribute("Hint") or "Tap the game's button once", #Learn.calls)
end
Banner:SetAttribute("Hint", "")
Banner.Activated:Connect(finishLearn)

------------------------------------------------------------------------
-- Luck boosts
------------------------------------------------------------------------
local lastBoost = 0
local function useBoosts(reason)
    if #BoostRecipes == 0 then return 0 end
    local used = 0
    for _, rec in ipairs(BoostRecipes) do
        if playRecipe(rec) then used += 1 end
        task.wait(0.15)
    end
    lastBoost = os.clock()
    log(("Used %d luck boost(s)%s"):format(used, reason and (" - " .. reason) or ""))
    return used
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
    if r.Rec then
        local rec = Recipes[cat]
        r.Rec.Text = rec and ("Recorded: " .. rec.label) or "Not recorded - tap RECORD ROLL (uses on-screen button meanwhile)"
    end
    if r.Unit then r.Unit() end
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

local function readLabel(cat, lbl)
    local list = Data[cat]
    if #list > 0 then return matchName(lbl.Text, list) end
    local t = clean(lbl.Text)
    if t ~= "" and #t <= 40 then return t, nil end
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
    return c.Target .. (c.OrBetter and " or better" or "")
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

local function waitResult(cat, ctx)
    local list = Data[cat]
    if ctx.ret then
        local n, r = singleName(ctx.ret, list)
        if n then return n, r, true end
    end
    local timeout = math.max(1.2, Cfg.Delay + 1)
    while os.clock() - ctx.t0 < timeout do
        if Running ~= cat then return nil end
        for _, e in ipairs(ctx.inbox) do
            if e.t >= ctx.t0 then return e.name, e.rank, true end
        end
        if ctx.unitInst then
            local n, r = readUnitData(cat, ctx.unitInst)
            if n and n ~= ctx.unitBefore then return n, r, true end
        end
        if ctx.label then
            if ctx.label.Text ~= ctx.before[ctx.label] then
                local n, r = readLabel(cat, ctx.label)
                if n then return n, r, true end
            end
        elseif ctx.scope and #list > 0 then
            for _, d in ipairs(ctx.scope:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and ctx.before[d] ~= d.Text and shown(d) then
                    local n, r = matchName(d.Text, list)
                    if n then return n, r, true end
                end
            end
        end
        task.wait(0.08)
    end
    if ctx.unitInst then
        local n, r = readUnitData(cat, ctx.unitInst)
        if n then return n, r, false end
    end
    if ctx.label then
        local n, r = readLabel(cat, ctx.label)
        return n, r, false
    end
    return nil
end

local function runSession(cat)
    local c = Cfg[cat]
    local tgt = targetText(cat)
    if not tgt then setStatus("Pick a " .. cat .. " target first") return end

    local rec = Recipes[cat]
    local panel = findPanel(cat)
    local rollBtn
    if not rec then
        rollBtn = findRollButton(panel)
        if not rollBtn then
            setStatus("Tap RECORD ROLL first (or open the " .. cat .. " roll screen)")
            notify("Record the " .. cat .. " roll first")
            return
        end
    end
    local label_ = resolve(Cfg.Bind[cat].Result)
    refreshPool(cat)
    local unitValue, unitInst = currentUnit(cat)

    if #Data[cat] == 0 and not label_ then
        setStatus("No " .. cat .. " names known: use Custom target + Bind Result")
        return
    end

    Running = cat
    refreshCatUI(cat)
    log(("%s roll started -> %s%s"):format(cat, tgt, unitInst and (" on " .. unitLabel(unitInst)) or ""))

    if Cfg.Protect then
        local n, r
        if unitInst then n, r = readUnitData(cat, unitInst) end
        if not n and label_ then n, r = readLabel(cat, label_) end
        if n and isHit(cat, n, r) then
            stopRoll("already " .. n .. " (protected)")
            return
        end
    end

    if c.MaxLuck then useBoosts("before " .. cat .. " roll") end

    -- Listen for the server's reply on every RemoteEvent
    local inbox, inConns = {}, {}
    for _, d in ipairs(RS:GetDescendants()) do
        if d:IsA("RemoteEvent") and #inConns < 400 then
            table.insert(inConns, d.OnClientEvent:Connect(function(...)
                if Running ~= cat then return end
                local n, r = singleName(table.pack(...), Data[cat])
                if n then table.insert(inbox, { t = os.clock(), name = n, rank = r }) end
            end))
        end
    end
    local errConn = PlayerGui.DescendantAdded:Connect(function(d)
        if not isTextObj(d) then return end
        task.defer(function()
            local t = clean(d.Text):lower()
            for _, p in ipairs(ERROR_PATTERNS) do
                if t:find(p, 1, true) and Running == cat then
                    stopRoll("game says: " .. clean(d.Text):sub(1, 40))
                    return
                end
            end
        end)
    end)

    local unread, same, lastName = 0, 0, nil
    while Running == cat do
        if rollBtn and (not rollBtn.Parent or not shown(rollBtn)) then stopRoll("menu closed") break end
        if Cfg.BoostEvery > 0 and os.clock() - lastBoost > Cfg.BoostEvery * 60 then useBoosts("timer") end

        table.clear(inbox)
        local ctx = {
            t0 = os.clock(), inbox = inbox, scope = panel, label = label_, unitInst = unitInst,
            before = snapshot(panel, label_), unitBefore = unitInst and readUnitData(cat, unitInst) or nil,
        }
        if rec then
            local ok, ret = playRecipe(rec, unitValue)
            if not ok then stopRoll(tostring(ret)) break end
            ctx.ret = ret
        else
            press(rollBtn)
        end
        local name, rank, changed = waitResult(cat, ctx)
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
            if unread >= Cfg.MaxUnread then stopRoll("can't read result: tap Bind Result") break end
        end
        refreshCatUI(cat)
        task.wait(Cfg.Delay)
    end
    errConn:Disconnect()
    for _, cn in ipairs(inConns) do cn:Disconnect() end
    refreshCatUI(cat)
end

local function toggleRoll(cat)
    if Running == cat then stopRoll("stopped by you") return end
    if Running then stopRoll("switched to " .. cat) task.wait(0.2) end
    task.spawn(runSession, cat)
end

------------------------------------------------------------------------
-- Bind Result label (tap the text that shows the current trait/grade)
------------------------------------------------------------------------
local Binding = nil
local function startBind(cat)
    Binding = { cat = cat, t = os.clock() }
    Main.Visible = false
    Banner.Text = ("Tap the text that shows the unit's current %s.\nTap here to cancel."):format(cat:lower())
    Banner.Visible = true
end

local function objectsAt(p)
    local objs = PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y)
    if #objs == 0 then
        local inset = GuiService:GetGuiInset()
        objs = PlayerGui:GetGuiObjectsAtPosition(p.X, p.Y + inset.Y)
    end
    return objs
end

Banner.Activated:Connect(function()
    if Binding then
        Binding = nil
        Banner.Visible = false
        Main.Visible = true
        setStatus("Bind cancelled")
    end
end)

track(UIS.InputBegan:Connect(function(input)
    if not Binding or os.clock() - Binding.t < 0.35 then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local b = Binding
    local objs = objectsAt(input.Position)
    task.wait(0.1)
    if Binding ~= b then return end
    local found
    for _, o in ipairs(objs) do
        if not o:IsDescendantOf(Hub) and (o:IsA("TextLabel") or o:IsA("TextButton")) and clean(o.Text) ~= "" then
            if not found then found = o end
            if matchName(o.Text, Data[b.cat]) then found = o break end
        end
    end
    Binding = nil
    Banner.Visible = false
    Main.Visible = true
    if found then
        Cfg.Bind[b.cat].Result = pathOf(found)
        saveCfg()
        log(("Bound %s result -> %s (%s)"):format(b.cat, found.Name, clean(found.Text):sub(1, 24)))
    else
        setStatus("No text there; try again")
    end
    refreshCatUI(b.cat)
end))

------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------
local LuckLabel

-- MAIN
do
    local c = card(PMain)
    label(c, "Quick start", 15, Theme.Accent, true)
    label(c, "1. Luck tab > Trait > RECORD ROLL.\n2. Open the game's Traits menu, pick your unit, tap its Roll once, then tap the red banner.\n3. Choose Unit + Stop at, press START.\nSame idea for Grade, Quirk, boosts and every Farm macro.", 12, Theme.Sub)
    local s = card(PMain)
    LuckLabel = label(s, "Luck: -", 13, Theme.Text, true)
    label(s, HookOK and "Recorder: ready" or "Recorder: NOT supported here (UI fallback only)", 11, HookOK and Theme.On or Theme.Bad)
    local stopAll = button(s, "STOP EVERYTHING", Theme.Bad)
    stopAll.Activated:Connect(function()
        stopRoll("stop all")
        for _, slot in ipairs(FARM_SLOTS) do Cfg.Farm[slot.key].On = false end
        for _, f in ipairs(genv.MaxHubFarmRenders or {}) do f() end
        setStatus("Everything stopped")
    end)
    local lg = card(PMain)
    label(lg, "Log", 13, Theme.Text, true)
    LogLabel = new("TextLabel", {
        Parent = lg, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        Font = Enum.Font.Code, TextSize = 11, TextColor3 = Theme.Sub, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = table.concat(LogLines, "\n"),
    })
end

-- LUCK
local Selectors = {}
do
    local b = card(PLuck)
    label(b, "Luck Boosts", 15, Theme.Accent, true)
    local boostInfo = label(b, "", 11, Theme.Sub)
    local function renderBoost()
        boostInfo.Text = ("%d boost(s) recorded. Your luck from dice is set by the server; this uses the boosts/potions you own in one tap."):format(#BoostRecipes)
    end
    renderBoost()
    local useAll = button(b, "USE ALL BOOSTS NOW", Theme.Accent, 36)
    useAll.TextColor3 = Theme.Bg
    useAll.Activated:Connect(function()
        if #BoostRecipes == 0 then setStatus("Record a boost first (use a luck potion while recording)") return end
        task.spawn(function() setStatus(("Used %d boost(s)"):format(useBoosts("manual"))) end)
    end)
    local r = hrow(b, 30)
    smallBtn(r, "+ Record Boost", 0.5, Theme.Rec).Activated:Connect(function()
        startLearn("luck boost", "Open your potions/boosts and USE one luck boost", nil, false, function(rec)
            if #BoostRecipes >= 8 then table.remove(BoostRecipes, 1) table.remove(Cfg.Boosts, 1) end
            table.insert(BoostRecipes, rec)
            local s = recipeToCfg(rec)
            if s then table.insert(Cfg.Boosts, s) saveCfg() end
            renderBoost()
        end)
    end)
    smallBtn(r, "Clear Boosts", 0.5).Activated:Connect(function()
        table.clear(BoostRecipes)
        Cfg.Boosts = {}
        saveCfg()
        renderBoost()
    end)
    stepper(b, "Re-use boosts every (min)", function() return Cfg.BoostEvery end, function(v) Cfg.BoostEvery = v end, 1, 0, 60, "%d")
end

local function buildLuck(cat)
    local c = card(PLuck)
    label(c, cat .. " Luck", 15, Theme.Accent, true)

    -- Unit selector
    UIRefs[cat].Unit = cycler(c, "Unit", function()
        local rec = Recipes[cat]
        if not rec then return "(record a roll first)" end
        if not rec.unit then return "(as recorded - re-record to change)" end
        local _, inst = currentUnit(cat)
        if inst then return unitLabel(inst) .. "  (" .. #(Pools[cat] or {}) .. ")" end
        return short(rec.unit.value)
    end, function(d)
        local pool = Pools[cat] or {}
        if #pool == 0 then refreshPool(cat) pool = Pools[cat] end
        if #pool == 0 then return end
        local cur = currentUnit(cat)
        local idx = 1
        for i, e in ipairs(pool) do if sameValue(e.value, cur) then idx = i break end end
        idx = ((idx - 1 + d) % #pool) + 1
        Cfg[cat].Unit = ser(pool[idx].value)
        saveCfg()
    end)

    -- Target selector
    local function fixTarget()
        local list = Data[cat]
        if Cfg[cat].Target == "" or not table.find(list, Cfg[cat].Target) then
            Cfg[cat].Target = list[math.min(3, #list)] or ""
        end
    end
    fixTarget()
    Selectors[cat] = cycler(c, "Stop at", function()
        fixTarget()
        return Cfg[cat].Target ~= "" and Cfg[cat].Target or "(use Custom target)"
    end, function(d)
        local list = Data[cat]
        if #list == 0 then return end
        local i = table.find(list, Cfg[cat].Target) or 1
        Cfg[cat].Target = list[((i - 1 + d) % #list) + 1]
        saveCfg()
    end)

    toggle(c, "Or better", "Also stop on anything rarer", function() return Cfg[cat].OrBetter end, function(v) Cfg[cat].OrBetter = v end)
    toggle(c, "Max " .. cat .. " Luck", "Use all recorded boosts before rolling", function() return Cfg[cat].MaxLuck end, function(v) Cfg[cat].MaxLuck = v end)

    local box = new("TextBox", {
        Parent = c, Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = Theme.Item, Font = Enum.Font.Gotham, TextSize = 12,
        TextColor3 = Theme.Text, PlaceholderText = "Custom target (optional): Genesis, Paradox", PlaceholderColor3 = Theme.Sub,
        Text = Cfg[cat].Custom, ClearTextOnFocus = false,
    }, { corner(7), pad(6) })
    box.FocusLost:Connect(function() Cfg[cat].Custom = box.Text saveCfg() end)

    local r = hrow(c, 30)
    smallBtn(r, "RECORD ROLL", 0.4, Theme.Rec).Activated:Connect(function()
        startLearn(cat .. " roll", "Open " .. cat .. "s, select your unit, tap Roll ONCE", LEARN_HINT[cat], true, function(rec)
            Recipes[cat] = rec
            Cfg.Recipes[cat] = recipeToCfg(rec)
            Cfg[cat].Unit = nil
            if not Cfg.Recipes[cat] then log(cat .. " recording works this session only (can't be saved)") end
            saveCfg()
            refreshPool(cat)
            if rec.unit then log(("%s: found %d unit(s) to choose from"):format(cat, #(Pools[cat] or {}))) end
            refreshCatUI(cat)
        end)
    end)
    smallBtn(r, "Bind Result", 0.3).Activated:Connect(function() startBind(cat) end)
    smallBtn(r, "Units", 0.3).Activated:Connect(function()
        refreshPool(cat)
        refreshCatUI(cat)
        setStatus(("%s: %d unit(s) found"):format(cat, #(Pools[cat] or {})))
    end)

    UIRefs[cat].Rec = label(c, "", 10, Theme.Sub)
    UIRefs[cat].Start = button(c, "", Theme.On, 38)
    UIRefs[cat].Start.Activated:Connect(function() toggleRoll(cat) end)
    UIRefs[cat].Info = label(c, "", 11, Theme.Sub)
    refreshCatUI(cat)
end
for _, cat in ipairs({ "Trait", "Grade", "Quirk" }) do buildLuck(cat) end

-- FARM
local FarmRenders = {}
genv.MaxHubFarmRenders = FarmRenders
do
    local top = card(PFarm)
    label(top, "Farm & Auto", 15, Theme.Accent, true)
    label(top, "Each macro: tap REC, do the action once in-game, tap the banner. Then switch it on.", 11, Theme.Sub)
    toggle(top, "Pause farm while luck rolling", nil, function() return Cfg.PauseFarm end, function(v) Cfg.PauseFarm = v end)

    for _, slot in ipairs(FARM_SLOTS) do
        local c = card(PFarm)
        local s = Cfg.Farm[slot.key]
        local _, render = toggle(c, slot.name, "", function() return s.On end, function(v)
            if v and not Recipes[slot.key] and not slot.fallback then
                setStatus(slot.name .. ": tap REC first")
                return
            end
            s.On = v
        end)
        table.insert(FarmRenders, render)
        local info = label(c, "", 10, Theme.Sub)
        local function renderInfo()
            local rec = Recipes[slot.key]
            info.Text = rec and ("Recorded: " .. rec.label) or (slot.fallback and ("Not recorded - presses the on-screen " .. slot.fallback .. " button") or ("Not recorded - " .. slot.hint))
        end
        renderInfo()
        stepper(c, "Every (sec)", function() return s.Interval end, function(v) s.Interval = v end, slot.interval < 1 and 0.1 or 1, 0.1, 600, "%.1f")
        local r = hrow(c, 28)
        smallBtn(r, "REC", 0.5, Theme.Rec).Activated:Connect(function()
            startLearn(slot.name, slot.hint, nil, false, function(rec)
                Recipes[slot.key] = rec
                Cfg.Recipes[slot.key] = recipeToCfg(rec)
                saveCfg()
                renderInfo()
            end)
        end)
        smallBtn(r, "Clear", 0.5).Activated:Connect(function()
            Recipes[slot.key] = nil
            Cfg.Recipes[slot.key] = nil
            s.On = false
            saveCfg()
            render()
            renderInfo()
        end)
    end
end

-- SETTINGS
do
    local c = card(PSet)
    label(c, "Rolling", 13, Theme.Text, true)
    stepper(c, "Delay between rolls", function() return Cfg.Delay end, function(v) Cfg.Delay = v end, 0.05, 0.05, 3, "%.2fs")
    stepper(c, "Stop after unreadable", function() return Cfg.MaxUnread end, function(v) Cfg.MaxUnread = v end, 1, 2, 50, "%d")
    stepper(c, "Stop after unchanged", function() return Cfg.MaxNoChange end, function(v) Cfg.MaxNoChange = v end, 1, 3, 50, "%d")
    toggle(c, "Protect current result", "Won't roll if the unit already meets target", function() return Cfg.Protect end, function(v) Cfg.Protect = v end)
    toggle(c, "Anti-AFK", "Prevents the 20-minute idle kick", function() return Cfg.AntiAFK end, function(v) Cfg.AntiAFK = v end)
    toggle(c, "Remote spy (log)", "Logs every action the game sends", function() return Cfg.Spy end, function(v) Cfg.Spy = v end)

    local d = card(PSet)
    label(d, "Game data", 13, Theme.Text, true)
    local src = label(d, "", 11, Theme.Sub)
    local function renderSrc()
        src.Text = ("Grades: %d (%s)  Traits: %d (%s)  Quirks: %d (%s)"):format(
            #Data.Grade, DataSource.Grade, #Data.Trait, DataSource.Trait, #Data.Quirk, DataSource.Quirk)
    end
    renderSrc()
    genv.MaxHubRenderSrc = renderSrc
    button(d, "Re-scan game data").Activated:Connect(function()
        local n = learnGameData()
        for _, r in pairs(Selectors) do r() end
        renderSrc()
        setStatus(n > 0 and ("Updated " .. n .. " table(s)") or "No odds tables found; using built-in lists")
    end)
    button(d, "Save Scanner Dump (file + clipboard)").Activated:Connect(function()
        local lines = { ("-- MAX HUB scan %s | PlaceId %d | build %d"):format(os.date("%Y-%m-%d %H:%M"), game.PlaceId, game.PlaceVersion) }
        table.insert(lines, "") table.insert(lines, "[Recorded]")
        for k, rec in pairs(Recipes) do table.insert(lines, k .. ": " .. rec.label) end
        table.insert(lines, "") table.insert(lines, "[Remotes]")
        for _, x in ipairs(RS:GetDescendants()) do
            if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") or x.ClassName == "UnreliableRemoteEvent" then
                table.insert(lines, x.ClassName .. "  " .. x:GetFullName())
            end
        end
        table.insert(lines, "") table.insert(lines, "[Player data]")
        local function walk(inst, depth)
            if depth > 3 or #lines > 2500 then return end
            for _, ch in ipairs(inst:GetChildren()) do
                local v = ch:IsA("ValueBase") and (" = " .. tostring(ch.Value)) or ""
                local attrs = {}
                for k, a in pairs(ch:GetAttributes()) do table.insert(attrs, k .. "=" .. tostring(a)) end
                table.insert(lines, string.rep("  ", depth) .. ch.ClassName .. " " .. ch.Name .. v .. (#attrs > 0 and (" {" .. table.concat(attrs, ", ") .. "}") or ""))
                if not ch:IsA("PlayerGui") and not ch:IsA("PlayerScripts") and not ch:IsA("Backpack") then walk(ch, depth + 1) end
            end
        end
        walk(LP, 0)
        table.insert(lines, "") table.insert(lines, "[Visible buttons]")
        for _, x in ipairs(PlayerGui:GetDescendants()) do
            if x:IsA("GuiButton") and shown(x) and not x:IsDescendantOf(Hub) then
                table.insert(lines, (pathOf(x) or x.Name) .. "  |  " .. clean(textOf(x)):sub(1, 40))
            end
            if #lines > 3500 then break end
        end
        local text = table.concat(lines, "\n")
        if writefile then pcall(writefile, SCAN_FILE, text) end
        if setclipboard then pcall(setclipboard, text) end
        setStatus(("Saved %s (%d lines) in Delta's workspace"):format(SCAN_FILE, #lines))
    end)

    local m = card(PSet)
    label(m, "Hub", 13, Theme.Text, true)
    button(m, "Clear binds & recordings").Activated:Connect(function()
        Cfg.Bind = { Grade = {}, Trait = {}, Quirk = {} }
        Cfg.Recipes, Cfg.Boosts = {}, {}
        table.clear(Recipes) table.clear(BoostRecipes)
        saveCfg()
        for _, cat in ipairs(CATS) do refreshPool(cat) refreshCatUI(cat) end
        setStatus("Cleared")
    end)
    button(m, "Unload MAX HUB", Theme.Bad).Activated:Connect(function() genv.MaxHubCleanup() end)
    label(m, "Toggle UI: RightCtrl, or the MAX bubble when minimized.", 11, Theme.Sub)
end

------------------------------------------------------------------------
-- Farm scheduler
------------------------------------------------------------------------
local nextRun, busy = {}, {}
local function runSlot(slot)
    busy[slot.key] = true
    local rec = Recipes[slot.key]
    if rec then
        local ok, err = playRecipe(rec)
        if not ok then
            Cfg.Farm[slot.key].On = false
            log(slot.name .. " stopped: " .. tostring(err))
            for _, f in ipairs(FarmRenders) do f() end
        end
    elseif slot.fallback then
        local btn = findButtonByText(slot.fallback)
        if btn then press(btn) end
    end
    busy[slot.key] = false
end

task.spawn(function()
    while Alive do
        task.wait(0.1)
        if not (Running and Cfg.PauseFarm) then
            for _, slot in ipairs(FARM_SLOTS) do
                local s = Cfg.Farm[slot.key]
                if s.On and not busy[slot.key] and os.clock() >= (nextRun[slot.key] or 0) then
                    nextRun[slot.key] = os.clock() + math.max(0.1, s.Interval)
                    task.spawn(runSlot, slot)
                end
            end
        end
    end
end)

-- Luck display
task.spawn(function()
    while Alive do
        local l = findLuckText()
        if LuckLabel then LuckLabel.Text = "Luck: " .. (l or "-") end
        task.wait(2)
    end
end)

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
    Alive = false
    Running = nil
    Learn = nil
    genv.MaxHubOnCall = nil
    for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
    table.clear(Conns)
    if Hub then Hub:Destroy() end
    genv.MaxHubCleanup = nil
end
CloseBtn.Activated:Connect(function() genv.MaxHubCleanup() end)

selectTab("Luck")

task.spawn(function()
    local n = learnGameData()
    for _, r in pairs(Selectors) do r() end
    if genv.MaxHubRenderSrc then genv.MaxHubRenderSrc() end
    log(n > 0 and ("Game data synced (" .. n .. " table(s))") or "Using built-in trait/grade lists")
    if not HookOK then log("Recorder unavailable: executor lacks hookmetamethod") end
    local exec = identifyexecutor and identifyexecutor() or "executor"
    setStatus("Ready | " .. tostring(exec) .. " | build " .. game.PlaceVersion)
end)
