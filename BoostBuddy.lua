-- BoostBuddy: per-customer boost run tracking for any dungeon.
-- Copyright (C) 2026 Fitz
-- Licensed under GPLv3 - see the LICENSE file. Free software, no warranty.
--
-- A run counts when the instance is RESET (the real completion signal):
--   * whoever resets sees "X has been reset." -> counts + relays to the group
--     over a hidden addon channel, so every BoostBuddy in the group counts too
--   * phantom resets (before anyone entered) are ignored
-- Ready checks stay as the loud "get back in here" alert.
-- /boost or right-click the tally text opens the management window.

local ADDON = "BoostBuddy"
local PREFIX = "BoostBdy"

-- No hardcoded dungeon list: the addon learns which instance is being
-- boosted by watching where the group actually zones in. Whatever dungeon
-- you entered last is the tracked one, and its resets count runs.

local db    -- account-wide (booster roster)
local cdb   -- per-character (your own boost + XP tracking)
local readyFlashUntil = 0
local lastResetCount = 0
local knownTrackers = {}   -- other BoostBuddy trackers we've heard state from
local resetRequestedAt = 0 -- set by the Reset instance button; gates the zone-in announce
local RESET_PATTERN  -- built on load from the client's own global string
local RESET_FAIL_PATTERNS = {}
local DIFF_RESET_PATTERN  -- difficulty-toggle reset: seen by EVERYONE in the group

local GREEN, GOLD, GREY, RED = "|cff8fe04a", "|cffe8c860", "|cff9a8fb0", "|cffff5533"

-- level cap for this client (70 on TBC, 60 on era, ...)
local MAXLEVEL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 70

local function ClassColorName(name, class)
    local cc = class and RAID_CLASS_COLORS[class]
    if cc then
        return ("|cff%02x%02x%02x%s|r"):format(
            math.floor(cc.r * 255 + 0.5), math.floor(cc.g * 255 + 0.5),
            math.floor(cc.b * 255 + 0.5), name)
    end
    return name
end

-- screenshot mode: /boost placeholder swaps displayed names for fakes so
-- addon-site screenshots don't expose real players. Display-only; data,
-- announcements and sync always use real names.
local placeholderMode = false
local PLACEHOLDER_NAMES = { "Thorgrim", "Elarielle", "Muffinz", "Padfoot",
    "Snugglez", "Gankalot", "Healbot", "Dotmaster", "Frostyboi", "Peon",
    "Zappyboi", "Stabbins" }
local placeholderMap, placeholderUsed = {}, 0
local function DisplayName(name)
    if not placeholderMode or not name or name == "self" or name == "?" then return name end
    if not placeholderMap[name] then
        placeholderUsed = placeholderUsed + 1
        placeholderMap[name] = PLACEHOLDER_NAMES[placeholderUsed] or ("Player" .. placeholderUsed)
    end
    return placeholderMap[name]
end

-- ================================================================= helpers ==
local function Print(msg) print(GREEN .. "[BoostBuddy]|r " .. msg) end

local function FmtXP(n)
    if n >= 1000 then return ("%.1fk"):format(n / 1000) end
    return tostring(math.floor(n))
end

local function FmtDur(sec)
    if not sec then return "" end
    return ("%d:%02d"):format(math.floor(sec / 60), math.floor(sec % 60))
end

local function FmtDurLong(sec)
    if not sec then return "" end
    return ("%dm %ds"):format(math.floor(sec / 60), math.floor(sec % 60))
end

local function Announce(msg)
    if db.announce and IsInGroup() then
        SendChatMessage("[BoostBuddy] " .. msg, IsInRaid() and "RAID" or "PARTY")
    else
        Print(msg)
    end
end

local function StatusOneLine()
    local parts = {}
    for name, c in pairs(db.customers) do
        table.insert(parts, ("%s %d/%d"):format(name, c.used, c.total))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function GroupUnits()
    local units = { "player" }
    if IsInRaid() then
        units = {}
        for i = 1, GetNumGroupMembers() do table.insert(units, "raid" .. i) end
    else
        for i = 1, 4 do
            if UnitExists("party" .. i) then table.insert(units, "party" .. i) end
        end
    end
    return units
end

-- The map name can carry a zone prefix ("Coilfang: The Slave Pens") while
-- other messages may use the short form -- compare on the part after the colon.
local function SameInstance(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local function tail(s) return s:match(":%s*(.+)$") or s end
    return tail(a) == tail(b)
end

-- spawn-detection state (declared here so StartingUsed can reference it)
local visitConfirmed, pendingSpawn = false, nil

-- if the group is mid-run when someone gets added, that run is their first:
-- start them at 1 so the count never trails reality by one. If we haven't yet
-- confirmed this instance's spawn id (we may be holding a stale one from a
-- previous instance), mark the current run already-counted so the first mob
-- we see adopts the new spawn as the baseline instead of counting a phantom.
local function StartingUsed()
    local _, instType = IsInInstance()
    if instType ~= "party" and instType ~= "raid" then return 0 end
    if not visitConfirmed then db.cycleCounted = true end
    return 1
end

local function GroupNames()
    local names = {}
    for _, u in ipairs(GroupUnits()) do
        local nm = UnitName(u)
        if nm then names[nm] = true end
    end
    return names
end

-- ================================================================== tally ==
local tally = CreateFrame("Frame", "BoostBuddyFrame", UIParent)
tally:SetSize(220, 48)
tally:SetPoint("CENTER", 0, 200)
tally:SetMovable(true)
tally:EnableMouse(true)
tally:RegisterForDrag("LeftButton")
tally:SetScript("OnDragStart", function(self) self:StartMoving() end)
tally:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.pos = { point, relPoint, x, y }
end)

local tallyText = tally:CreateFontString(nil, "OVERLAY")
tallyText:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE")
tallyText:SetPoint("TOPLEFT")
tallyText:SetJustifyH("LEFT")
tallyText:SetSpacing(3)

local function MyPackage()
    -- a tracker's synced state wins while that tracker is in the group
    -- (so customers can't shadow their booster's numbers), otherwise fall
    -- back to self-tracking, then to the last known synced state
    local mb = cdb.myBoost
    if mb and mb.from and GroupNames()[mb.from] then return mb end
    local mine = db.customers[UnitName("player")]
    if mine then return { used = mine.used, total = mine.total, from = "self" } end
    return mb
end

-- copy-paste CSV export of the run ledger
local exportFrame
local function ShowExport()
    if not exportFrame then
        exportFrame = CreateFrame("Frame", "BoostBuddyExport", UIParent, "BackdropTemplate")
        exportFrame:SetSize(400, 280)
        exportFrame:SetPoint("CENTER")
        exportFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        exportFrame:SetBackdropColor(0.055, 0.045, 0.09, 0.97)
        exportFrame:SetBackdropBorderColor(0.35, 0.55, 0.22, 1)
        exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        exportFrame:SetMovable(true)
        exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
        exportFrame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
        local title = exportFrame:CreateFontString(nil, "OVERLAY")
        title:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText(GREEN .. "BoostBuddy|r run export - Ctrl+C to copy")
        local close = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        local scroll = CreateFrame("ScrollFrame", "BoostBuddyExportScroll", exportFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -34)
        scroll:SetPoint("BOTTOMRIGHT", -30, 12)
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(340)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(box)
            box:ClearFocus()
            exportFrame:Hide()
        end)
        scroll:SetScrollChild(eb)
        exportFrame.eb = eb
    end
    local rows = { "run,xp,duration_seconds,completed_at" }
    for i, run in ipairs(cdb.runs) do
        table.insert(rows, ("%d,%d,%s,%s"):format(i, run.xp, run.dur or "",
            run.t and date("%Y-%m-%d %H:%M:%S", run.t) or ""))
    end
    exportFrame.eb:SetText(table.concat(rows, "\n"))
    exportFrame:Show()
    exportFrame.eb:SetFocus()
    exportFrame.eb:HighlightText()
end

-- the addon only acts when runs are actually set: an unfinished package in
-- our roster, or our own unfinished boost synced from a tracker who's here.
-- Idle means silent: no counting, no alerts, no XP tracking, zero noise.
local function Engaged()
    for _, c in pairs(db.customers) do
        if c.used < c.total then return true end
    end
    local mb = cdb.myBoost
    if mb and mb.used < mb.total and mb.from and GroupNames()[mb.from] then
        return true
    end
    return false
end

-- stats show your CURRENT form: the last 5 runs (the same ones the overlay
-- lists), never reaching across a break of an hour or more. XP rates change
-- as you level, so older runs would only muddy the numbers you act on.
local function SessionStats()
    local n = #cdb.runs
    if n == 0 then return 0, 0, 0, 0, 0 end
    local first = n
    while first > 1 and (n - first + 1) < 5 do
        local newer, older = cdb.runs[first], cdb.runs[first - 1]
        if not newer.t or not older.t or (newer.t - older.t) > 3600 then break end
        first = first - 1
    end
    local sum, cnt, dsum, dxp, dcnt = 0, 0, 0, 0, 0
    for i = first, n do
        local run = cdb.runs[i]
        sum = sum + run.xp
        cnt = cnt + 1
        if run.dur and run.dur > 0 and run.dur < 1800 then
            dsum = dsum + run.dur
            dxp = dxp + run.xp
            dcnt = dcnt + 1
        end
    end
    return sum, cnt, dsum, dxp, dcnt
end

local RefreshUI -- forward declaration
local runScroll = 0   -- window into the Previous Runs ledger (0 = newest)

local function Render()
    -- learn classes of registered customers who are in the group right now
    for _, u in ipairs(GroupUnits()) do
        local nm = UnitName(u)
        local c = nm and db.customers[nm]
        if c and not c.class then
            local _, cl = UnitClass(u)
            c.class = cl
        end
    end

    local lines = {}
    if db.paused then
        table.insert(lines, GREY .. "BoostBuddy paused - /boost pause to resume|r")
    end
    if GetTime() < readyFlashUntil then
        table.insert(lines, RED .. "** READY CHECK - GO! **|r")
    end
    local role = cdb.role
    tallyText:SetFont(STANDARD_TEXT_FONT, role == "customer" and 13 or 18, "OUTLINE")
    tallyText:SetSpacing(role == "customer" and 0 or 3)
    if not role then
        -- no role chosen yet: just point at the setup prompt
        table.insert(lines, GREEN .. "BoostBuddy|r " .. GREY .. "right-click to set up|r")
    elseif role == "booster" then
        -- booster overlay: the roster, nothing else
        local n = 0
        for name, c in pairs(db.customers) do n = n + 1 end
        table.insert(lines, GREEN .. "BoostBuddy|r " .. GREY ..
            (n > 0 and (n .. " customer" .. (n == 1 and "" or "s")) or "right-click to open") .. "|r")
        local sorted = {}
        for name in pairs(db.customers) do table.insert(sorted, name) end
        table.sort(sorted)
        for _, name in ipairs(sorted) do
            local c = db.customers[name]
            local done = c.used >= c.total
            table.insert(lines, ClassColorName(DisplayName(name), c.class) .. " " ..
                (done and GREEN or GOLD) .. c.used .. "/" .. c.total .. "|r" ..
                (done and (GREEN .. " (Last Run)|r") or ""))
        end
    else
        -- customer overlay: modeled on the classic boost-XP weakaura layout
        table.insert(lines, GREEN .. "BoostBuddy|r")
        local mypkg = MyPackage()
        if mypkg then
            table.insert(lines, GOLD .. "Your Boost: " .. mypkg.used .. "/" ..
                mypkg.total .. "|r" ..
                (mypkg.used >= mypkg.total and (GREEN .. " (Last Run)|r") or "") ..
                " " .. GREY .. "(Set by: " .. DisplayName(mypkg.from or "?") .. ")|r")
        end
        if UnitLevel("player") < MAXLEVEL then
            local hasCurrent = (cdb.runXP or 0) > 0 or (cdb.inRun and cdb.runStart ~= nil)
            local nRuns = #cdb.runs
            if mypkg and (hasCurrent or nRuns > 0) then table.insert(lines, " ") end
            if hasCurrent then
                table.insert(lines, "|cffffff00Current Run|r")
                if db.lastInstance then
                    table.insert(lines, "  " .. db.lastInstance)
                end
                local line = "  " .. GOLD .. FmtXP(cdb.runXP or 0) .. " XP|r"
                if cdb.runStart then
                    line = line .. "  -  " .. FmtDurLong(time() - cdb.runStart)
                end
                table.insert(lines, line)
            end
            if nRuns > 0 then
                if hasCurrent then table.insert(lines, " ") end
                table.insert(lines, "|cffb76b45Past Runs|r")
                for i = nRuns, math.max(1, nRuns - 4), -1 do
                    local run = cdb.runs[i]
                    local line = ("  %s#%d|r  %s%s XP|r"):format(GREY, i, GOLD, FmtXP(run.xp))
                    if run.dur then line = line .. "  -  " .. FmtDurLong(run.dur) end
                    table.insert(lines, line)
                end
                local sum, cnt, dsum, dxp, dcnt = SessionStats()
                local avg = sum / cnt
                table.insert(lines, " ")
                local avgLine = "|cff9292ffAvg:|r " .. FmtXP(avg) .. " XP"
                if dcnt > 0 then avgLine = avgLine .. "  -  " .. FmtDurLong(dsum / dcnt) end
                table.insert(lines, avgLine)
                if dcnt > 0 then
                    table.insert(lines, "|cff9292ffXP/hr:|r " .. FmtXP(dxp / dsum * 3600))
                end
                local remaining = (UnitXPMax("player") or 0) - (UnitXP("player") or 0)
                local togo = avg > 0 and math.ceil(remaining / avg) or 0
                table.insert(lines, "|cff9292ffLevel up:|r ~" .. togo .. " run" .. (togo == 1 and "" or "s"))
            end
            if not hasCurrent and nRuns == 0 then
                table.insert(lines, GREY .. "Waiting for dungeon...|r")
            end
        end
    end

    tallyText:SetText(table.concat(lines, "\n"))
    tally:SetSize(math.max(tallyText:GetStringWidth(), 60), tallyText:GetStringHeight() + 6)
    tally:SetShown(not db.tallyHide)
    if RefreshUI then RefreshUI() end
end

-- ================================================================== logic ==
-- manual corrections are ALWAYS announced to the group, ignoring the
-- announce toggle -- the tally is the customers' receipt, so nobody
-- gets to adjust it quietly
local function AnnounceAlways(msg)
    if IsInGroup() then
        SendChatMessage("[BoostBuddy] " .. msg, IsInRaid() and "RAID" or "PARTY")
    else
        Print(msg)
    end
end

-- share the roster with the group so customers running BoostBuddy see
-- their own package progress without any setup
local function BroadcastState()
    if not IsInGroup() then return end
    local parts = {}
    for name, c in pairs(db.customers) do
        table.insert(parts, name .. ":" .. c.used .. ":" .. c.total)
    end
    C_ChatInfo.SendAddonMessage(PREFIX, "STATE|" .. table.concat(parts, ";"),
        IsInRaid() and "RAID" or "PARTY")
end

-- catch-up sync: debounced rebroadcast so late joiners / reloaders get state
local stateQueued = false
local function QueueBroadcast()
    if stateQueued then return end
    stateQueued = true
    C_Timer.After(2, function()
        stateQueued = false
        if next(db.customers) then BroadcastState() end
    end)
end

-- with several trackers in one group, only one (first by name) announces;
-- the rest count silently so chat isn't spammed with duplicates
local function IAmAnnouncer()
    -- the tracker with the biggest roster announces (a booster tracking the
    -- whole group outranks a customer self-tracking one line); ties break by name
    local me = UnitName("player")
    local mySize = 0
    for _ in pairs(db.customers) do mySize = mySize + 1 end
    local present = GroupNames()
    for name, info in pairs(knownTrackers) do
        if name ~= me and present[name] and (GetTime() - info.seen) < 600 then
            if info.size > mySize or (info.size == mySize and name < me) then
                return false
            end
        end
    end
    return true
end

local function CountRun(source)
    local present, counted = GroupNames(), {}
    for name, c in pairs(db.customers) do
        if present[name] and c.used < c.total then
            c.used = c.used + 1
            table.insert(counted, name)
        end
    end
    db.lastCounted = counted
    -- "entered since count": if we're INSIDE when this count happens (manual
    -- catch-up or mob-detection), our presence IS an entry -- keep the flag
    -- armed so the next reset message still counts. Counts taken outside
    -- (reset boundaries) consume it, preserving the phantom-reset guard.
    db.enteredSinceCount = cdb.inRun and true or false
    db.cycleCounted = true
    lastResetCount = GetTime()
    if #counted > 0 then
        table.sort(counted)
        local announcer = (source == "manual") or IAmAnnouncer()
        local function LineFor(name)
            local c = db.customers[name]
            local text = name .. " " .. c.used .. "/" .. c.total
            if c.used >= c.total then text = text .. " (Last Run!!)" end
            return text
        end
        if source == "manual" then
            AnnounceAlways("MANUAL run count by " .. UnitName("player"))
            for _, name in ipairs(counted) do
                AnnounceAlways(LineFor(name))
            end
        elseif announcer then
            Announce("New Instance Run Detected")
            for _, name in ipairs(counted) do
                Announce(LineFor(name))
            end
        else
            Print("run counted (" .. (source or "auto") .. ") - " .. StatusOneLine())
        end
        for _, name in ipairs(counted) do
            local c = db.customers[name]
            if c.used >= c.total then
                PlaySound(8959, "Master")
                break
            end
        end
        if source ~= "manual" then
            local link = "|Hgarrmission:boostbuddyundo|h" .. RED .. "[undo last count]|r|h"
            local dur = cdb.lastBankedDur
            local suspicious
            if dur and dur < 120 then
                suspicious = "that cycle lasted only " .. FmtDurLong(dur)
            elseif UnitLevel("player") < MAXLEVEL then
                -- a leveling character always earns real XP in a real run:
                -- compare this run's XP against the average of earlier ones
                local banked = cdb.lastBankedXP or 0
                local n = #cdb.runs
                local lastIdx = (banked > 0) and n or nil
                local sum, cnt = 0, 0
                for i = math.max(1, n - 10), n do
                    if i ~= lastIdx then
                        sum = sum + cdb.runs[i].xp
                        cnt = cnt + 1
                    end
                end
                if cnt >= 2 and banked < (sum / cnt) * 0.3 then
                    suspicious = "only " .. FmtXP(banked) .. " XP gained that run"
                end
            end
            if suspicious then
                Print(RED .. suspicious .. " - accidental reset?|r " .. link)
                PlaySound(8959, "Master")
            else
                Print(GREY .. "miscounted?|r " .. link)
            end
        end
    else
        Print("run counted, but no registered customers are in the group")
    end
    BroadcastState()
    Render()
end

-- reset = run complete, so that's when the run's XP gets banked into history
local function BankRunXP()
    local dur = cdb.runStart and (time() - cdb.runStart) or nil
    cdb.lastBankedDur = dur
    cdb.lastBankedXP = cdb.runXP or 0
    if (cdb.runXP or 0) > 0 then
        table.insert(cdb.runs, {
            xp = cdb.runXP,
            dur = dur,
            t = time(),
        })
        while #cdb.runs > 100 do table.remove(cdb.runs, 1) end
    end
    cdb.runStart = nil
    cdb.runXP = 0
end

local function UndoLastCount()
    if not db.lastCounted or #db.lastCounted == 0 then
        Print("nothing to undo")
        return
    end
    for _, name in ipairs(db.lastCounted) do
        local c = db.customers[name]
        if c and c.used > 0 then c.used = c.used - 1 end
    end
    db.lastCounted = nil
    -- the undone count no longer exists, so the cycle must become countable
    -- again -- otherwise the next run's detection gets swallowed by the
    -- "already counted" guard and never announces
    db.cycleCounted = false
    if cdb.inRun then db.enteredSinceCount = true end
    AnnounceAlways("MANUAL: " .. UnitName("player") .. " undid the last count - " .. StatusOneLine())
    BroadcastState()
    Render()
end

hooksecurefunc("SetItemRef", function(link)
    if link == "garrmission:boostbuddyundo" then
        UndoLastCount()
    end
end)

local function OnInstanceReset(instanceName, viaRelay)
    if db.paused then
        if db.debug then Print("debug: paused - reset ignored") end
        return
    end
    if not Engaged() then
        if db.debug then Print("debug: idle (no runs set) - reset ignored") end
        return
    end
    if not SameInstance(instanceName, db.lastInstance) then
        if db.debug then
            Print(("debug: reset of '%s' ignored - doesn't match tracked '%s'")
                :format(tostring(instanceName), tostring(db.lastInstance)))
        end
        return
    end
    if GetTime() - lastResetCount < 3 then
        if db.debug then Print("debug: reset ignored - within 3s dedupe window") end
        return
    end
    if db.cycleCounted then
        if db.debug then Print("debug: reset ignored - this cycle was already counted (waiting for fresh mobs to confirm a new instance)") end
        return
    end
    BankRunXP()
    if not db.enteredSinceCount then
        Print(instanceName .. " reset seen, but nobody entered since the last count - ignoring (use /boost count to override)")
        return
    end
    if db.debug then Print("debug: reset accepted (" .. (viaRelay and "relayed" or "local") .. "), counting") end
    CountRun(instanceName .. " reset")
end

-- ================= fresh-instance detection via creature GUIDs =================
-- (NovaInstanceTracker technique) every mob GUID carries a per-instance-spawn
-- id that changes when the instance is reset. Seeing a different id than last
-- visit proves we are in a fresh instance, so the previous run completed --
-- even if the reset message and relay were both missed.
local function OnSpawnConfirmed(spawn)
    if db.spawnID == spawn then
        if db.debug then Print("debug: same instance as before (spawn " .. spawn .. ")") end
        return
    end
    local firstEver = (db.spawnID == nil)
    db.spawnID = spawn
    if firstEver then
        db.cycleCounted = false
        if db.debug then Print("debug: instance spawn recorded (" .. spawn .. ")") end
        return
    end
    if db.cycleCounted or db.paused or not Engaged() then
        db.cycleCounted = false
        if db.debug then Print("debug: fresh instance (" .. spawn .. "), " ..
            (db.paused and "paused - not counting" or "previous run was already counted")) end
    else
        if db.debug then Print("debug: fresh instance (" .. spawn .. ") - counting the previous run now") end
        BankRunXP()
        CountRun("fresh instance")
        db.cycleCounted = false
        cdb.runStart = cdb.lastEntryTime or time()
    end
end

-- =============================================================== management ==
local ui = CreateFrame("Frame", "BoostBuddyUI", UIParent, "BackdropTemplate")
ui:SetSize(340, 120)
ui:SetPoint("CENTER")
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetScript("OnDragStart", function(self) self:StartMoving() end)
ui:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.uiPos = { point, relPoint, x, y }
end)
ui:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
ui:SetBackdropColor(0.055, 0.045, 0.09, 0.96)
ui:SetBackdropBorderColor(0.35, 0.55, 0.22, 1)
ui:SetFrameStrata("DIALOG")
ui:Hide()
ui:EnableMouseWheel(true)
ui:SetScript("OnMouseWheel", function(_, delta)
    if cdb and cdb.role == "customer" and #cdb.runs > 5 then
        runScroll = math.max(0, math.min(runScroll + (delta < 0 and 1 or -1), #cdb.runs - 5))
        RefreshUI()
    end
end)
-- deliberately NOT in UISpecialFrames: the game's close-all-windows sweep
-- (ESC, zoning) must not hide it -- visibility is remembered across /reload

local title = ui:CreateFontString(nil, "OVERLAY")
title:SetFont(STANDARD_TEXT_FONT, 15, "OUTLINE")
title:SetPoint("TOPLEFT", 12, -10)
title:SetText(GREEN .. "BoostBuddy|r")

local closeBtn = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", 2, 2)
closeBtn:SetScript("OnClick", function()
    db.uiShown = false
    ui:Hide()
end)

ui.overlayBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.overlayBtn:SetSize(90, 18)
ui.overlayBtn:SetPoint("BOTTOMRIGHT", -10, 9)
ui.overlayBtn:GetFontString():SetFont(STANDARD_TEXT_FONT, 10)
ui.overlayBtn:SetScript("OnClick", function()
    db.tallyHide = not db.tallyHide
    Render()
end)

-- first-run role chooser buttons
ui.pickCustomer = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.pickCustomer:SetSize(316, 26)
ui.pickCustomer:SetText("I'm a customer - I'm being boosted")
ui.pickCustomer:SetScript("OnClick", function()
    cdb.role = "customer"
    Print("customer view locked in - /boost role to change later")
    RefreshUI()
end)

ui.pickBooster = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.pickBooster:SetSize(316, 26)
ui.pickBooster:SetText("I'm a booster - I track the runs")
ui.pickBooster:SetScript("OnClick", function()
    cdb.role = "booster"
    Print("booster view locked in - /boost role to change later")
    RefreshUI()
end)

local hint = ui:CreateFontString(nil, "OVERLAY")
hint:SetFont(STANDARD_TEXT_FONT, 10)
hint:SetTextColor(0.6, 0.56, 0.7)
hint:SetPoint("TOPLEFT", 13, -30)
hint:SetJustifyH("LEFT")
hint:SetWidth(312)
hint:SetWordWrap(true)
hint:SetText("Runs count automatically when your dungeon gets reset.")

local rows = {}   -- pooled row frames

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Frame", nil, ui)
    row:SetSize(316, 22)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.04)

    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFont(STANDARD_TEXT_FONT, 13)
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWidth(120)

    row.buttons = {}
    for b = 1, 4 do
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(30, 19)
        if b == 1 then
            btn:SetPoint("RIGHT", -4, 0)
        else
            btn:SetPoint("RIGHT", row.buttons[b - 1], "LEFT", -3, 0)
        end
        btn:GetFontString():SetFont(STANDARD_TEXT_FONT, 11)
        row.buttons[b] = btn
    end
    rows[i] = row
    return row
end

local function SectionHeader(fs, text)
    fs:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    fs:SetTextColor(0.56, 0.88, 0.29)
    fs:SetText(text)
end

local headers = {}
local function GetHeader(i)
    if headers[i] then return headers[i] end
    local fs = ui:CreateFontString(nil, "OVERLAY")
    headers[i] = fs
    return fs
end

RefreshUI = function()
    if not ui:IsShown() then return end
    for _, r in ipairs(rows) do r:Hide() end
    for _, h in ipairs(headers) do h:Hide() end
    ui.readyBtn:Hide()
    ui.resetBtn:Hide()
    ui.undoBtn:Hide()
    ui.pickCustomer:Hide()
    ui.pickBooster:Hide()

    -- first open: pick a side; the choice sticks (per character)
    local role = cdb.role
    title:SetText(GREEN .. "BoostBuddy|r" .. (role and
        (GREY .. " - " .. (role == "booster" and "Booster" or "Customer") .. "|r") or ""))
    ui.overlayBtn:SetText("Overlay: " .. (db.tallyHide and "off" or "on"))
    if not role then
        hint:SetText(GOLD .. "Are you a customer or a booster?|r")
        ui.pickCustomer:ClearAllPoints()
        ui.pickCustomer:SetPoint("TOPLEFT", 12, -54)
        ui.pickCustomer:Show()
        ui.pickBooster:ClearAllPoints()
        ui.pickBooster:SetPoint("TOPLEFT", 12, -86)
        ui.pickBooster:Show()
        ui.footerNote:ClearAllPoints()
        ui.footerNote:SetPoint("TOPLEFT", 13, -120)
        ui.footerNote:SetWidth(212)
        ui.footerNote:SetText("picked wrong? type /boost role to choose again")
        ui:SetHeight(152)
        return
    end

    if role == "booster" then
        hint:SetText("Runs count automatically when " .. GREEN ..
            (db.lastInstance or "your dungeon") .. "|r gets reset.")
    else
        hint:SetText("Your package and XP are tracked automatically - nothing to click.")
    end

    local y = -(32 + hint:GetStringHeight() + 10)
    local rowIdx, headIdx = 0, 0

    local function PlaceHeader(text)
        headIdx = headIdx + 1
        local h = GetHeader(headIdx)
        SectionHeader(h, text)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", 13, y)
        h:Show()
        y = y - 16
    end

    local function PlaceRow()
        rowIdx = rowIdx + 1
        local row = GetRow(rowIdx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 10, y)
        row.bg:SetColorTexture(1, 1, 1, rowIdx % 2 == 0 and 0.03 or 0.06)
        for _, b in ipairs(row.buttons) do b:Hide() end
        row.name:SetTextColor(0.93, 0.9, 0.96)
        row.name:SetWidth(150)
        row:Show()
        y = y - 23
        return row
    end

    if role == "customer" then
        -- ======================= customer view =======================
        PlaceHeader("YOUR PACKAGE")
        local row = PlaceRow()
        row.name:SetWidth(290)
        local mypkg = MyPackage()
        local me = UnitName("player")
        if mypkg then
            local done = mypkg.used >= mypkg.total
            row.name:SetText((done and GREEN or GOLD) .. mypkg.used .. "/" ..
                mypkg.total .. " runs|r" .. (done and GREEN .. " (Last Run)|r" or "") ..
                "  " .. GREY .. "Set by: " .. DisplayName(mypkg.from or "?") .. "|r")
            if mypkg.from == "self" then
                row.name:SetWidth(230)
                local btn = row.buttons[1]
                btn:SetText("Edit")
                btn:SetWidth(44)
                btn:SetScript("OnClick", function()
                    StaticPopup_Show("BOOSTBUDDY_EDIT_TOTAL")
                end)
                btn:Show()
            end
        else
            -- nobody tracking you? runs are still detected on your own client
            row.name:SetText(GREY .. "no tracker in group - track it yourself:|r")
            row.name:SetWidth(150)
            local packages = { 5, 10, 20 }
            for b = 1, 3 do
                local btn = row.buttons[b]
                local runs = packages[4 - b]
                btn:SetText(tostring(runs))
                btn:SetWidth(30)
                btn:SetScript("OnClick", function()
                    local _, myclass = UnitClass("player")
                    local su = StartingUsed()
                    db.customers[me] = { total = runs, used = su, class = myclass }
                    Print("tracking your own package - " .. su .. "/" .. runs .. " (runs auto-count)")
                    Render()
                end)
                btn:Show()
            end
            local custom = row.buttons[4]
            custom:SetText("...")
            custom:SetWidth(30)
            custom:SetScript("OnClick", function()
                StaticPopup_Show("BOOSTBUDDY_EDIT_TOTAL")
            end)
            custom:Show()
        end

        y = y - 12
        PlaceHeader("CURRENT RUN")
        do
            local r = PlaceRow()
            r.name:SetWidth(290)
            if (cdb.runXP or 0) > 0 then
                local line = GOLD .. FmtXP(cdb.runXP) .. " XP|r"
                if cdb.runStart then
                    line = line .. GREY .. "  " .. FmtDur(time() - cdb.runStart) .. "|r"
                end
                r.name:SetText(line)
            else
                r.name:SetText(GREY .. "waiting for the run to start...|r")
            end
        end

        y = y - 12
        local nRuns = #cdb.runs
        local maxScroll = math.max(0, nRuns - 5)
        if runScroll > maxScroll then runScroll = maxScroll end
        PlaceHeader("PREVIOUS RUNS" .. (nRuns > 5 and
            (" (" .. nRuns .. " total - mousewheel to scroll)") or ""))
        if nRuns == 0 then
            local r = PlaceRow()
            r.name:SetWidth(290)
            r.name:SetText(GREY .. "no runs recorded yet|r")
        end
        local first = nRuns - runScroll
        for i = first, math.max(1, first - 4), -1 do
            local run = cdb.runs[i]
            local r = PlaceRow()
            r.name:SetWidth(290)
            local line = GREY .. ("run %d|r  "):format(i) .. GOLD .. FmtXP(run.xp) .. "|r"
            if run.dur then line = line .. "  " .. FmtDur(run.dur) end
            if run.t then line = line .. "  " .. GREY .. date("%H:%M", run.t) .. "|r" end
            r.name:SetText(line)
        end

        y = y - 12
        PlaceHeader("STATS (last 5 runs)")
        local level, xp, xpMax = UnitLevel("player"), UnitXP("player") or 0, UnitXPMax("player") or 1
        local lrow = PlaceRow()
        lrow.name:SetWidth(290)
        lrow.name:SetText(GREY .. "level " .. level .. " - |r" .. FmtXP(xp) .. GREY .. " / |r" ..
            FmtXP(xpMax) .. GREY .. (" (%d%%)|r"):format(xp / xpMax * 100))
        if nRuns > 0 then
            local sum, cnt, dsum, dxp, dcnt = SessionStats()
            local avg = sum / cnt
            local togo = avg > 0 and math.ceil((xpMax - xp) / avg) or 0
            local r = PlaceRow()
            r.name:SetWidth(290)
            local text = GREEN .. ("avg %s/run"):format(FmtXP(avg))
            if dcnt > 0 then
                text = text .. (" - %s/run - %s/hr"):format(FmtDur(dsum / dcnt), FmtXP(dxp / dsum * 3600))
            end
            r.name:SetText(text .. "|r")
            local r2 = PlaceRow()
            r2.name:SetWidth(250)
            r2.name:SetText(GREEN .. ("level %d in ~%d run%s|r"):format(level + 1, togo, togo == 1 and "" or "s"))
            local btn = r2.buttons[1]
            btn:SetText("X")
            btn:SetWidth(26)
            btn:SetScript("OnClick", function()
                StaticPopup_Show("BOOSTBUDDY_WIPE_XP", tostring(#cdb.runs))
            end)
            btn:Show()
            local csv = r2.buttons[2]
            csv:SetText("CSV")
            csv:SetWidth(40)
            csv:SetScript("OnClick", ShowExport)
            csv:Show()
        end

        y = y - 6
        ui.footerNote:ClearAllPoints()
        ui.footerNote:SetPoint("TOPLEFT", 13, y)
        ui.footerNote:SetWidth(212)
        ui.footerNote:SetText("a run banks its XP when the dungeon gets reset")
        y = y - 24
        ui:SetHeight(-y + 10)
        return
    end

    -- ========================= booster view ==========================
    -- group members not yet registered
    PlaceHeader("GROUP - click a package to add")
    local any = false
    for _, unit in ipairs(GroupUnits()) do
        local name = UnitName(unit)
        if name and not db.customers[name] then
            any = true
            local row = PlaceRow()
            local _, class = UnitClass(unit)
            local color = class and RAID_CLASS_COLORS[class]
            row.name:SetText(DisplayName(name))
            row.name:SetTextColor(color and color.r or 0.9, color and color.g or 0.9, color and color.b or 0.9)
            local packages = { 5, 10, 20 }
            for b = 1, 3 do
                local btn = row.buttons[b]
                local runs = packages[4 - b]        -- rightmost = 5
                btn:SetText(tostring(runs))
                btn:SetWidth(30)
                btn:SetScript("OnClick", function()
                    local su = StartingUsed()
                    db.customers[name] = { total = runs, used = su, class = class }
                    Announce("Added " .. name .. " - " .. su .. "/" .. runs ..
                        (su > 0 and " (current run counts)" or ""))
                    BroadcastState()
                    Render()
                end)
                btn:Show()
            end
            local custom = row.buttons[4]
            custom:SetText("...")
            custom:SetWidth(30)
            custom:SetScript("OnClick", function()
                local dialog = StaticPopup_Show("BOOSTBUDDY_ADD_CUSTOM", name)
                if dialog then dialog.data = { name = name, class = class } end
            end)
            custom:Show()
        end
    end
    if not any then
        local row = PlaceRow()
        row.name:SetText(GREY .. (IsInGroup() and "everyone's registered" or "not in a group") .. "|r")
        row.name:SetWidth(290)
    end

    -- registered customers
    y = y - 12
    PlaceHeader("CUSTOMERS")
    local names = {}
    for name in pairs(db.customers) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then
        local row = PlaceRow()
        row.name:SetText(GREY .. "none yet|r")
        row.name:SetWidth(290)
    end
    for _, name in ipairs(names) do
        local c = db.customers[name]
        local row = PlaceRow()
        local done = c.used >= c.total
        row.name:SetText(ClassColorName(DisplayName(name), c.class) .. "  " .. (done and GREEN or GOLD) .. c.used .. "/" .. c.total .. "|r" ..
            (done and (GREEN .. " (Last Run)|r") or ""))
        row.name:SetTextColor(1, 1, 1)
        row.name:SetWidth(150)
        local defs = {
            { "X",  "remove " .. name, function()
                local dialog = StaticPopup_Show("BOOSTBUDDY_REMOVE", name,
                    c.used .. "/" .. c.total)
                if dialog then dialog.data = name end
            end },
            { "+5", "extend package by 5 (rebuy)", function()
                c.total = c.total + 5
                AnnounceAlways(name .. " extended - now " .. c.used .. "/" .. c.total)
            end },
        }
        for b, def in ipairs(defs) do
            local btn = row.buttons[b]
            btn:SetText(def[1])
            btn:SetWidth(b == 2 and 34 or 26)
            btn:SetScript("OnClick", function() def[3](); BroadcastState(); Render() end)
            btn:Show()
        end
    end

    -- footer
    y = y - 6
    ui.readyBtn:ClearAllPoints()
    ui.readyBtn:SetPoint("TOPLEFT", 10, y)
    ui.readyBtn:Show()
    ui.resetBtn:ClearAllPoints()
    ui.resetBtn:SetPoint("LEFT", ui.readyBtn, "RIGHT", 5, 0)
    ui.resetBtn:Show()
    ui.undoBtn:ClearAllPoints()
    ui.undoBtn:SetPoint("LEFT", ui.resetBtn, "RIGHT", 5, 0)
    ui.undoBtn:Show()
    y = y - 27
    ui.footerNote:ClearAllPoints()
    ui.footerNote:SetPoint("TOPLEFT", 13, y)
    ui.footerNote:SetWidth(212)
    ui.footerNote:SetText("counts are automatic - manual corrections are always announced to the group")
    y = y - 24

    ui:SetHeight(-y + 10)
end

ui.readyBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.readyBtn:SetSize(100, 22)
ui.readyBtn:SetText("Ready check")
ui.readyBtn:SetScript("OnClick", function()
    if not IsInGroup() then
        Print("not in a group")
    elseif UnitIsGroupLeader("player") or UnitIsGroupAssistant("player") then
        DoReadyCheck()
    else
        Print("only the leader or an assistant can start a ready check")
    end
end)

ui.undoBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.undoBtn:SetSize(78, 22)
ui.undoBtn:SetText("Undo last")
ui.undoBtn:SetScript("OnClick", function()
    local preview = UndoPreview()
    if not preview then
        Print("nothing to undo")
        return
    end
    StaticPopup_Show("BOOSTBUDDY_UNDO", "would become:  " .. preview)
end)

ui.resetBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.resetBtn:SetSize(110, 22)
ui.resetBtn:SetText("Reset instance")
ui.resetBtn:SetScript("OnClick", function()
    if not IsInGroup() or UnitIsGroupLeader("player") then
        ResetInstances()
        resetRequestedAt = GetTime()
        Print("reset requested - confirmation will announce when it lands")
    else
        Print("only the group leader can reset instances")
    end
end)

ui.footerNote = ui:CreateFontString(nil, "OVERLAY")
ui.footerNote:SetFont(STANDARD_TEXT_FONT, 10)
ui.footerNote:SetTextColor(0.6, 0.56, 0.7)
ui.footerNote:SetJustifyH("LEFT")
ui.footerNote:SetWidth(192)
ui.footerNote:SetWordWrap(true)
ui.footerNote:SetText("counts are automatic - manual corrections are always announced to the group")

StaticPopupDialogs["BOOSTBUDDY_WIPE_XP"] = {
    text = "Wipe your ENTIRE run history?\n\n%s recorded runs will be cleared, along with your averages and XP/hr stats.\n\nYou can undo this with /boost xprestore (until the next wipe).",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        cdb.trashedRuns = cdb.runs
        cdb.runs = {}
        cdb.runXP = 0
        Print("run history wiped - /boost xprestore to undo")
        Render()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function PopupEditBox(self)
    return self.editBox or self.EditBox or _G[self:GetName() .. "EditBox"]
end

StaticPopupDialogs["BOOSTBUDDY_REMOVE"] = {
    text = "Remove %s from tracking?\n\nTheir count (%s) will be deleted. The removal is announced to the group.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function(self)
        local name = self.data
        local c = db and name and db.customers[name]
        if not c then return end
        db.customers[name] = nil
        AnnounceAlways(UnitName("player") .. " removed " .. name ..
            " (was " .. c.used .. "/" .. c.total .. ")")
        BroadcastState()
        Render()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BOOSTBUDDY_ADD_CUSTOM"] = {
    text = "How many runs for %s?",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    OnShow = function(self)
        local eb = PopupEditBox(self)
        if eb then eb:SetText("") end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["BOOSTBUDDY_ADD_CUSTOM"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    OnAccept = function(self)
        local d = self.data
        local eb = PopupEditBox(self)
        local n = eb and tonumber(eb:GetText())
        if not d or not db or not n or n <= 0 then
            Print("that wasn't a valid number - nobody added")
            return
        end
        n = math.floor(n)
        local su = StartingUsed()
        db.customers[d.name] = { total = n, used = su, class = d.class }
        AnnounceAlways("Added " .. d.name .. " - " .. su .. "/" .. n ..
            (su > 0 and " (current run counts)" or ""))
        BroadcastState()
        Render()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}



StaticPopupDialogs["BOOSTBUDDY_EDIT_TOTAL"] = {
    text = "Set your total package runs.\n\nHeads up: this change is announced to your group, and if a booster is tracking you, their numbers override yours.\n\nEnter 0 to stop self-tracking.",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    OnShow = function(self)
        local eb = PopupEditBox(self)
        local c = db and db.customers[UnitName("player")]
        if eb then
            eb:SetText(c and tostring(c.total) or "")
            eb:HighlightText()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["BOOSTBUDDY_EDIT_TOTAL"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    OnAccept = function(self)
        local me = UnitName("player")
        local c = db and db.customers[me]
        local eb = PopupEditBox(self)
        local n = eb and tonumber(eb:GetText())
        if not db then return end
        if not n then
            Print("that wasn't a number - package unchanged")
            return
        end
        if n <= 0 then
            if c then
                db.customers[me] = nil
                AnnounceAlways(me .. " stopped self-tracking their package")
            end
        elseif c then
            c.total = math.max(math.floor(n), c.used)
            AnnounceAlways(me .. " set their self-tracked package to " .. c.used .. "/" .. c.total)
        else
            local _, myclass = UnitClass("player")
            local su = StartingUsed()
            db.customers[me] = { total = math.floor(n), used = su, class = myclass }
            AnnounceAlways(me .. " started self-tracking their package - " .. su .. "/" .. math.floor(n) ..
                (su > 0 and " (current run counts)" or ""))
        end
        BroadcastState()
        Render()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BOOSTBUDDY_UNDO"] = {
    text = "Undo the last counted run for everyone?\n\n%s\n\nThis lowers each customer's count by 1 and announces it to the group. Re-add it with /boost count if needed.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function() UndoLastCount() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- what the last count would revert to, shown in the confirm dialog
local function UndoPreview()
    if not db.lastCounted or #db.lastCounted == 0 then return nil end
    local parts = {}
    for _, name in ipairs(db.lastCounted) do
        local c = db.customers[name]
        if c then table.insert(parts, name .. " " .. math.max(c.used - 1, 0) .. "/" .. c.total) end
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function ToggleUI()
    if ui:IsShown() then
        db.uiShown = false
        ui:Hide()
    else
        db.uiShown = true
        runScroll = 0
        ui:Show()
        RefreshUI()
    end
end

tally:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then ToggleUI() end
end)

-- ============================================================ minimap button ==
local mmb = CreateFrame("Button", "BoostBuddyMinimapButton", Minimap)
mmb:SetSize(31, 31)
mmb:SetFrameStrata("MEDIUM")
mmb:SetFrameLevel(8)
mmb:RegisterForClicks("LeftButtonUp")
mmb:RegisterForDrag("LeftButton")
mmb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local mmbOverlay = mmb:CreateTexture(nil, "OVERLAY")
mmbOverlay:SetSize(53, 53)
mmbOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmbOverlay:SetPoint("TOPLEFT")

local mmbIcon = mmb:CreateTexture(nil, "BACKGROUND")
mmbIcon:SetSize(20, 20)
mmbIcon:SetTexture("Interface\\Icons\\Ability_Rogue_Sprint")
mmbIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
mmbIcon:SetPoint("TOPLEFT", 7, -5)

local function UpdateMinimapPos()
    -- WoW's math.cos/sin/atan2 work in degrees, not radians
    local angle = (db and db.minimapPos) or 220
    mmb:ClearAllPoints()
    mmb:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

mmb:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        if not db then return end
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        db.minimapPos = math.atan2(cy / scale - my, cx / scale - mx)
        UpdateMinimapPos()
    end)
end)
mmb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mmb:SetScript("OnClick", function() if db then ToggleUI() end end)
mmb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("BoostBuddy")
    GameTooltip:AddLine("click to open, drag to move", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
mmb:SetScript("OnLeave", function() GameTooltip:Hide() end)
BoostBuddyUpdateMinimapPos = UpdateMinimapPos

-- ================================================================= events ==
tally:RegisterEvent("ADDON_LOADED")
tally:RegisterEvent("PLAYER_ENTERING_WORLD")
tally:RegisterEvent("ZONE_CHANGED_NEW_AREA")
tally:RegisterEvent("READY_CHECK")
tally:RegisterEvent("READY_CHECK_FINISHED")
tally:RegisterEvent("GROUP_ROSTER_UPDATE")
tally:RegisterEvent("CHAT_MSG_SYSTEM")
tally:RegisterEvent("CHAT_MSG_ADDON")
tally:RegisterEvent("PLAYER_XP_UPDATE")
tally:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
tally:RegisterEvent("PLAYER_TARGET_CHANGED")
tally:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

C_Timer.NewTicker(1, function()
    if db and cdb and cdb.runStart then Render() end
end)

tally:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        BoostBuddyDB = BoostBuddyDB or BoostCounterDB or {}   -- adopts old BoostCounter data
        db = BoostBuddyDB
        db.customers = db.customers or {}
        BoostBuddyCharDB = BoostBuddyCharDB or {}
        cdb = BoostBuddyCharDB
        cdb.runs = cdb.runs or {}
        for i, v in ipairs(cdb.runs) do
            if type(v) == "number" then cdb.runs[i] = { xp = v } end
        end
        if db.announce == nil then db.announce = true end
        db.enteredSinceCount = db.enteredSinceCount or false
        db.armed, db.wasInside = nil, nil   -- v1 leftovers
        if db.pos then
            tally:ClearAllPoints()
            tally:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
        end
        if db.uiPos then
            ui:ClearAllPoints()
            ui:SetPoint(db.uiPos[1], UIParent, db.uiPos[2], db.uiPos[3], db.uiPos[4])
        end
        if db.uiShown then
            ui:Show()
            RefreshUI()
        end
        db.uiAlpha = nil
        BoostBuddyUpdateMinimapPos()
        if db.minimapHide then BoostBuddyMinimapButton:Hide() end
        RESET_PATTERN = "^" .. INSTANCE_RESET_SUCCESS:gsub("%%s", "(.+)") .. "$"
        for _, gs in ipairs({ INSTANCE_RESET_FAILED, INSTANCE_RESET_FAILED_OFFLINE, INSTANCE_RESET_FAILED_ZONING }) do
            if gs then
                table.insert(RESET_FAIL_PATTERNS, "^" .. gs:gsub("%%s", "(.+)") .. "$")
            end
        end
        local diffMsg = ERR_DUNGEON_DIFFICULTY_CHANGED_S
        if diffMsg then
            DIFF_RESET_PATTERN = "^" .. diffMsg:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%%%s", "(.+)") .. "$"
        end
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if IsInGroup() then
            C_ChatInfo.SendAddonMessage(PREFIX, "HELLO|", IsInRaid() and "RAID" or "PARTY")
        end
        Render()
    elseif not db then
        return
    elseif event == "CHAT_MSG_SYSTEM" then
        if db.debug and arg1:lower():find("reset") then
            Print(("debug: system msg '%s' | pattern match: %s | tracked: %s | entered: %s")
                :format(arg1, tostring(arg1:match(RESET_PATTERN)),
                    tostring(db.lastInstance), tostring(db.enteredSinceCount)))
        end
        local instance = arg1:match(RESET_PATTERN)
        if instance then
            if SameInstance(instance, db.lastInstance) and IsInGroup() and not db.paused then
                C_ChatInfo.SendAddonMessage(PREFIX, "RESET|" .. instance,
                    IsInRaid() and "RAID" or "PARTY")
            end
            OnInstanceReset(instance)
            if SameInstance(instance, db.lastInstance)
                    and (GetTime() - resetRequestedAt) < 10 then
                resetRequestedAt = 0
                Announce("Instance reset - zone out and back in for your next run!")
            end
        else
            for _, pat in ipairs(RESET_FAIL_PATTERNS) do
                local failed = arg1:match(pat)
                if failed and SameInstance(failed, db.lastInstance) then
                    Announce("Reset FAILED - someone is still inside " .. failed .. ", zone out!")
                    break
                end
            end
            if (DIFF_RESET_PATTERN and arg1:match(DIFF_RESET_PATTERN))
                    or arg1:find("All saved instances have been reset", 1, true) then
                if db.debug then Print("debug: difficulty-toggle reset detected") end
                if db.lastInstance then
                    OnInstanceReset(db.lastInstance)
                    if (GetTime() - resetRequestedAt) < 10 then
                        resetRequestedAt = 0
                        Announce("Instance reset - zone out and back in for your next run!")
                    end
                end
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 ~= PREFIX then return end
        local sender = Ambiguate(arg4 or "", "none")
        if db.debug then
            Print(("debug: addon msg from %s: %s"):format(sender, tostring(arg2):sub(1, 60)))
        end
        if sender == UnitName("player") then return end
        local kind, payload = strsplit("|", arg2 or "")
        if kind == "RESET" and payload then
            local senderIsLeader = false
            for _, u in ipairs(GroupUnits()) do
                if UnitName(u) == sender and UnitIsGroupLeader(u) then
                    senderIsLeader = true
                    break
                end
            end
            if not senderIsLeader then return end
            OnInstanceReset(payload, true)
        elseif kind == "STATE" then
            local size = 0
            for _ in (payload or ""):gmatch("[^;]+") do size = size + 1 end
            knownTrackers[sender] = { seen = GetTime(), size = size }
            local me, found = UnitName("player"), nil
            for entry in (payload or ""):gmatch("[^;]+") do
                local name, used, total = entry:match("^(.-):(%d+):(%d+)$")
                if name == me then
                    found = { used = tonumber(used), total = tonumber(total), from = sender }
                end
            end
            if found then
                local old = cdb.myBoost
                if not old or old.used ~= found.used or old.total ~= found.total then
                    Print(("package sync: %d/%d (from %s)"):format(found.used, found.total, sender))
                end
                cdb.myBoost = found
            elseif cdb.myBoost and cdb.myBoost.from == sender then
                cdb.myBoost = nil   -- that tracker no longer lists us
                Print("your tracker removed you from their list")
            end
            Render()
        elseif kind == "HELLO" then
            QueueBroadcast()   -- someone's addon just loaded; offer them state
        end
    elseif event == "READY_CHECK" then
        if not db.paused and Engaged() then
            readyFlashUntil = GetTime() + 10
            for i = 0, 2 do
                C_Timer.After(i * 1.5, function() PlaySound(8959, "Master") end)
            end
            C_Timer.After(10, Render)
        end
        Render()
    elseif event == "READY_CHECK_FINISHED" then
        readyFlashUntil = 0
        Render()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" or event == "PLAYER_TARGET_CHANGED"
            or event == "UPDATE_MOUSEOVER_UNIT" then
        if visitConfirmed or not cdb.inRun then return end
        local guids
        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            if time() - (cdb.lastEntryTime or 0) < 2 then return end
            local _, _, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
            guids = { sourceGUID, destGUID }
        else
            guids = { UnitGUID(event == "PLAYER_TARGET_CHANGED" and "target" or "mouseover") }
        end
        for _, guid in ipairs(guids) do
            local unitType, _, _, _, spawnZone = strsplit("-", guid or "")
            spawnZone = tonumber(spawnZone)
            if unitType == "Creature" and spawnZone and spawnZone > 0 then
                if pendingSpawn == spawnZone then
                    visitConfirmed = true
                    OnSpawnConfirmed(spawnZone)
                    break
                end
                pendingSpawn = spawnZone
            end
        end
    elseif event == "PLAYER_XP_UPDATE" then
        local cur, curMax = UnitXP("player"), UnitXPMax("player")
        local delta = cur - (cdb.lastXP or cur)
        if delta < 0 then delta = delta + (cdb.lastXPMax or curMax) end   -- leveled up mid-gain
        cdb.lastXP, cdb.lastXPMax = cur, curMax
        if cdb.inRun and delta > 0 and not db.paused and Engaged() then
            cdb.runXP = (cdb.runXP or 0) + delta
        end
        Render()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local instName, instType = GetInstanceInfo()
        local inside = (instType == "party" or instType == "raid")
        if inside then
            db.lastInstance = instName
            db.enteredSinceCount = true
        end
        -- XP accrues while inside; banking happens on reset, not on zoning
        if not cdb.lastXP then
            cdb.lastXP, cdb.lastXPMax = UnitXP("player"), UnitXPMax("player")
        end
        cdb.inRun = inside
        if inside then
            cdb.lastEntryTime = time()
            visitConfirmed, pendingSpawn = false, nil
        end
        -- arg1/arg2 = isInitialLogin/isReloadingUi (PLAYER_ENTERING_WORLD only):
        -- a reload or login is NOT a fresh zone-in, so the run clock keeps ticking
        local isLoginOrReload = (event == "PLAYER_ENTERING_WORLD") and (arg1 or arg2)
        if inside and not isLoginOrReload and (not cdb.runStart or (cdb.runXP or 0) == 0) then
            cdb.runStart = time()   -- fresh cycle: clock starts at this zone-in
        end
        -- entering a tracked instance is the start of run 1 for anyone still at
        -- 0 (e.g. registered while standing outside). Promote them and adopt
        -- this instance as the baseline so the first pull doesn't count again.
        if inside and not isLoginOrReload and Engaged() then
            local present, started = GroupNames(), {}
            for name, c in pairs(db.customers) do
                if present[name] and c.used == 0 then
                    c.used = 1
                    table.insert(started, name)
                end
            end
            if #started > 0 then
                db.cycleCounted = true
                cdb.runStart = time()
                cdb.runXP = 0
                table.sort(started)
                if IAmAnnouncer() then
                    Announce("New Instance Run Detected")
                    for _, name in ipairs(started) do
                        local c = db.customers[name]
                        Announce(name .. " " .. c.used .. "/" .. c.total ..
                            (c.used >= c.total and " (Last Run!!)" or ""))
                    end
                end
                BroadcastState()
            end
        end
        if db.uiShown and not ui:IsShown() then ui:Show() end   -- survive zoning
        Render()
    elseif event == "GROUP_ROSTER_UPDATE" then
        QueueBroadcast()
        Render()
    else
        Render()
    end
end)

-- ================================================================== slash ==
local function Cap(s) return s:sub(1, 1):upper() .. s:sub(2):lower() end

local function ShowHelp()
    Print("commands  " .. GREY .. "(/bb works everywhere too)|r")
    local entries = {
        { "/boost", "open or close the window (also: minimap button)" },
        { "/boost overlay", "toggle the floating overlay (hide / show set it directly)" },
        { "/boost role", "pick booster or customer view again" },
        { "/boost pause", "silence counting, alerts and XP tracking until toggled back" },
        "for boosters",
        { "/boost add Name 10", "track a customer - or just click names in the window" },
        { "/boost total Name 20", "change someone's package size" },
        { "/boost set Name 3", "correct someone's runs done" },
        { "/boost remove Name", "stop tracking someone" },
        { "/boost count", "count a run manually (mid-run catch-up)" },
        { "/boost undo", "take the last counted run back" },
        { "/boost ready", "start a ready check" },
        { "/boost list", "print the roster to chat" },
        { "/boost clear", "wipe the whole roster" },
        "for customers",
        { "/boost export", "your run history as copyable CSV" },
        { "/boost xpreset", "wipe XP run history (xprestore undoes it)" },
        "misc",
        { "/boost announce", "toggle routine group announcements" },
        { "/boost minimap", "hide or show the minimap button" },
        { "/boost placeholder", "fake names on displays, for screenshots" },
        { "/boost ping", "ask trackers in the group to resend your package" },
        { "/boost debug", "narrate run detection, for troubleshooting" },
    }
    for _, e in ipairs(entries) do
        if type(e) == "string" then
            print(GREEN .. "-- " .. e .. " --|r")
        else
            print("   " .. GOLD .. e[1] .. "|r  " .. GREY .. e[2] .. "|r")
        end
    end
    print(GREY .. "   every roster change and correction is announced to your group|r")
end

SLASH_BOOSTBUDDY1 = "/boost"
SLASH_BOOSTBUDDY2 = "/bb"
SlashCmdList["BOOSTBUDDY"] = function(input)
    local cmd, a, b = input:match("^%s*(%S*)%s*(%S*)%s*(%S*)")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "ui" then
        ToggleUI()
    elseif cmd == "add" and a ~= "" then
        local su = StartingUsed()
        db.customers[Cap(a)] = { total = tonumber(b) or 10, used = su }
        AnnounceAlways("Added " .. Cap(a) .. " - " .. su .. "/" .. (tonumber(b) or 10) ..
            (su > 0 and " (current run counts)" or ""))
    elseif cmd == "remove" and a ~= "" then
        local c = db.customers[Cap(a)]
        db.customers[Cap(a)] = nil
        AnnounceAlways(UnitName("player") .. " removed " .. Cap(a) ..
            (c and (" (was " .. c.used .. "/" .. c.total .. ")") or ""))
    elseif cmd == "set" and a ~= "" and tonumber(b) then
        local c = db.customers[Cap(a)]
        if c then
            c.used = tonumber(b)
            AnnounceAlways("MANUAL: " .. UnitName("player") .. " set " .. Cap(a) ..
                " to " .. c.used .. "/" .. c.total)
        else
            Print(Cap(a) .. " is not registered")
        end
    elseif cmd == "debug" then
        db.debug = not db.debug
        Print("debug mode " .. (db.debug and "ON - reset triggers will be narrated" or "OFF"))
    elseif cmd == "pause" then
        db.paused = not db.paused
        Print(db.paused
            and "PAUSED - no counting, alerts, or XP tracking until you /boost pause again"
            or "resumed - counting and alerts are back on")
    elseif cmd == "overlay" then
        db.tallyHide = not db.tallyHide
        Print("overlay " .. (db.tallyHide and "hidden" or "shown"))
    elseif cmd == "hide" then
        db.tallyHide = true
        Print("overlay hidden")
    elseif cmd == "show" then
        db.tallyHide = false
        Print("overlay shown")
    elseif cmd == "placeholder" then
        placeholderMode = not placeholderMode
        if not placeholderMode then
            placeholderMap, placeholderUsed = {}, 0
        end
        Print("placeholder names " .. (placeholderMode
            and "ON - displays show fake names for screenshots" or "OFF"))
    elseif cmd == "minimap" then
        db.minimapHide = not db.minimapHide
        BoostBuddyMinimapButton:SetShown(not db.minimapHide)
        Print("minimap button " .. (db.minimapHide and "hidden" or "shown"))
    elseif cmd == "role" or cmd == "reset" then
        cdb.role = nil
        db.uiShown = true
        ui:Show()
    elseif cmd == "total" and a ~= "" and tonumber(b) then
        local c = db.customers[Cap(a)]
        if c then
            c.total = tonumber(b)
            AnnounceAlways("MANUAL: " .. UnitName("player") .. " set " .. Cap(a) ..
                "'s package to " .. c.used .. "/" .. c.total)
        else
            Print(Cap(a) .. " is not registered")
        end
    elseif cmd == "ping" then
        if IsInGroup() then
            C_ChatInfo.SendAddonMessage(PREFIX, "HELLO|", IsInRaid() and "RAID" or "PARTY")
            Print("ping sent - any tracker on v3.4+ will push your package within ~2s")
        else
            Print("not in a group")
        end
    elseif cmd == "ready" then
        ui.readyBtn:GetScript("OnClick")()
    elseif cmd == "count" then
        BankRunXP()
        if cdb.inRun then cdb.runStart = time() end   -- new run's clock starts now
        CountRun("manual")
        -- a mid-run catch-up (inside, mobs confirmed) must NOT block the next
        -- boundary's automatic tick; only a between-runs manual count needs to
        -- guard against the imminent re-detection of the same boundary
        db.cycleCounted = not (cdb.inRun and visitConfirmed)
    elseif cmd == "undo" then
        UndoLastCount()
    elseif cmd == "announce" then
        db.announce = not db.announce
        Print("party announcements: " .. (db.announce and "ON" or "OFF"))
    elseif cmd == "clear" then
        local was = StatusOneLine()
        db.customers = {}
        AnnounceAlways(UnitName("player") .. " cleared all customers" ..
            (was ~= "" and (" (was: " .. was .. ")") or ""))
    elseif cmd == "list" then
        Print(next(db.customers) and StatusOneLine() or "no customers")
    elseif cmd == "xpreset" then
        cdb.trashedRuns = cdb.runs
        cdb.runs = {}
        cdb.runXP = 0
        Print("XP run history cleared - /boost xprestore to undo")
    elseif cmd == "xprestore" then
        if cdb.trashedRuns then
            local restored = cdb.trashedRuns
            for _, r in ipairs(cdb.runs) do table.insert(restored, r) end
            cdb.runs = restored
            cdb.trashedRuns = nil
            Print("run history restored (" .. #cdb.runs .. " runs)")
        else
            Print("nothing to restore")
        end
    elseif cmd == "export" then
        ShowExport()
    else
        ShowHelp()
    end
    BroadcastState()
    Render()
end
