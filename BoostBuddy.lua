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

local function FmtGold(copper)
    if not copper or copper == 0 then return "" end
    local g = copper / 10000
    if g >= 1 then
        return ("%dg"):format(math.floor(g + 0.5))
    end
    return ("%ds"):format(math.floor(copper / 100 + 0.5))
end

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

local function FmtEta(sec)
    if not sec then return "" end
    if sec >= 3600 then
        return ("%dh %02dm"):format(math.floor(sec / 3600), math.floor(sec % 3600 / 60))
    end
    return ("%dm"):format(math.max(1, math.floor(sec / 60 + 0.5)))
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

local BankRunXP   -- defined in the logic section; UpdateCrew's disband backstop needs it in scope

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

-- only the group leader can reset an instance, so relayed/announced reset
-- claims are believed only when they come from the leader
local function SenderIsGroupLeader(sender)
    for _, u in ipairs(GroupUnits()) do
        if UnitName(u) == sender and UnitIsGroupLeader(u) then return true end
    end
    return false
end

local function GroupLeaderName()
    for _, u in ipairs(GroupUnits()) do
        if UnitIsGroupLeader(u) then
            local _, class = UnitClass(u)
            return UnitName(u), class
        end
    end
end

-- crew identity: the label for "who you're running with" locks in when you
-- join a group and SURVIVES leadership handoffs (the seller often passes
-- lead to a booster mid-package). Only actually leaving the group ends the
-- crew. A short grace window covers runs banked just after a disband.
local notedSeen = {}   -- names whose note was already surfaced this session

local function UpdateCrew()
    if IsInGroup() then
        if not cdb.crewLeader then
            local name, class = GroupLeaderName()
            if name then
                cdb.crewLeader, cdb.crewClass = name, class
            end
        end
        -- surface your saved notes the moment a noted player is in the
        -- group - leader, booster or customer alike, once per session
        if db.crewNotes then
            for _, u in ipairs(GroupUnits()) do
                local n = UnitName(u)
                if n and n ~= UnitName("player") and db.crewNotes[n] and not notedSeen[n] then
                    notedSeen[n] = true
                    local _, cls = UnitClass(u)
                    Print("note for " .. ClassColorName(n, cls) .. ": \"" .. db.crewNotes[n] .. "\"")
                end
            end
        end
    elseif cdb.crewLeader then
        notedSeen = {}
        cdb.crewGrace = { name = cdb.crewLeader, class = cdb.crewClass, t = time() }
        cdb.crewLeader, cdb.crewClass = nil, nil
        -- a final run still pending when the group ends: bank whatever it
        -- accrued (crewGrace above keeps the crew attribution), or stand
        -- down quietly if the run never actually happened
        if cdb.finalRunActive then
            if (cdb.runXP or 0) > 0 then
                BankRunXP()
            else
                cdb.finalRunActive, cdb.finalRunEntered = nil, nil
            end
        end
        -- leaving the group ends the session: retire FINISHED packages right
        -- away so the next crew starts clean. Unfinished packages are owed
        -- runs and survive the disband.
        local dropped, kept = 0, 0
        for name, c in pairs(db.customers) do
            if c.used >= c.total then
                db.customers[name] = nil
                dropped = dropped + 1
            else
                kept = kept + 1
            end
        end
        if cdb.myBoost and cdb.myBoost.used >= cdb.myBoost.total then
            cdb.myBoost = nil
            dropped = dropped + 1
        end
        if dropped > 0 then
            Print("session over - cleared " .. dropped .. " finished package(s)" ..
                (kept > 0 and (", kept " .. kept .. " unfinished (owed runs)") or "") ..
                ". Ready for the next crew.")
        end
    end
end

local function CrewForBanking()
    if cdb.crewLeader then return cdb.crewLeader, cdb.crewClass end
    local g = cdb.crewGrace
    if g and g.t and (time() - g.t) < 900 then return g.name, g.class end
    return GroupLeaderName()
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
    -- last-known sync is only trustworthy for a couple of hours; after that
    -- it's yesterday's booster haunting the display
    if mb and mb.t and (time() - mb.t) < 2 * 3600 then return mb end
    return nil
end

-- copy-paste CSV export of the run ledger
local exportFrame
local function ShowExport(customText)
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
    local text = customText
    if not text then
        local rows = { "run,xp,duration_seconds,completed_at" }
        for i, run in ipairs(cdb.runs) do
            table.insert(rows, ("%d,%d,%s,%s"):format(i, run.xp, run.dur or "",
                run.t and date("%Y-%m-%d %H:%M:%S", run.t) or ""))
        end
        text = table.concat(rows, "\n")
    end
    exportFrame.eb:SetText(text)
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

-- true wall-clock pace per run: the gap between consecutive run completions
-- this session. Unlike instance duration, this includes the reset/regroup
-- downtime between runs, so ETAs reflect how boosting actually flows.
local function AvgCycleSeconds()
    local n = #cdb.runs
    local gsum, gcnt = 0, 0
    for i = n, math.max(2, n - 4), -1 do
        local newer, older = cdb.runs[i], cdb.runs[i - 1]
        local gap = (newer.t and older.t) and (newer.t - older.t) or nil
        if not gap or gap > 3600 then break end
        gsum = gsum + gap
        gcnt = gcnt + 1
    end
    if gcnt > 0 then return gsum / gcnt end
    -- single run so far: fall back to its instance duration
    local _, _, dsum, _, dcnt = SessionStats()
    if dcnt > 0 then return dsum / dcnt end
end

local RefreshUI -- forward declaration
local runScroll = 0   -- window into the Previous Runs ledger (0 = newest)
local RefreshLedger = function() end   -- re-assigned once the Ledger exists

-- runs folded into boost sessions: consecutive runs on the same day under
-- the same group leader (with <1h gaps) are one session - which matches how
-- boosts are actually bought: a package from one crew, then a break
local function BuildSessions()
    local sessions = {}
    for i = 1, #cdb.runs do
        local run = cdb.runs[i]
        local day = run.t and date("%b %d", run.t) or "?"
        local leader = run.leader or "?"
        local last = sessions[#sessions]
        local sameSession = last and last.day == day and last.leader == leader
            and run.t and last.lastT and (run.t - last.lastT) < 3600
        if not sameSession then
            last = { day = day, leader = leader, leaderClass = run.leaderClass,
                     runs = 0, xp = 0,
                     firstT = run.t, lvl0 = run.lvl, runIdxs = {}, insts = {} }
            table.insert(sessions, last)
        end
        last.leaderClass = last.leaderClass or run.leaderClass
        last.runs = last.runs + 1
        last.xp = last.xp + (run.xp or 0)
        last.lastT = run.t
        last.lvl1 = run.lvl
        table.insert(last.runIdxs, i)
        if run.inst then
            local short = run.inst:match("([^:]+)$"):gsub("^%s+", "")
            last.insts[short] = true
        end
    end
    return sessions
end

-- net gold moved during a session: positive = you paid the crew (customer),
-- negative = the crew paid you (booster earnings). Trades are tagged with
-- the crew label at trade time and matched to the session's time window.
local function SessionMoney(s)
    if not cdb.trades or not s.firstT then return 0 end
    local net = 0
    for _, tr in ipairs(cdb.trades) do
        if tr.crew and tr.crew == s.leader
                and tr.t >= (s.firstT - 3600)
                and tr.t <= ((s.lastT or s.firstT) + 1800) then
            net = net + (tr.give or 0) - (tr.get or 0)
        end
    end
    return net
end

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
                local rested = GetXPExhaustion() or 0
                if rested > 0 and avg > 0 then
                    -- rested doubles kill XP; the pool drains by the bonus,
                    -- which is roughly half of each boosted run's XP
                    local rrs = math.floor(rested / (avg / 2) + 0.5)
                    table.insert(lines, "|cff9292ffRested:|r ~" .. rrs .. " boosted run" .. (rrs == 1 and "" or "s") .. " left")
                end
                local remaining = (UnitXPMax("player") or 0) - (UnitXP("player") or 0)
                local togo = avg > 0 and math.ceil(remaining / avg) or 0
                local lvlLine = "|cff9292ffLevel up:|r ~" .. togo .. " run" .. (togo == 1 and "" or "s")
                local cycle = AvgCycleSeconds()
                if togo > 0 and cycle then
                    lvlLine = lvlLine .. GREY .. "  (~" .. FmtEta(togo * cycle) .. ")|r"
                end
                table.insert(lines, lvlLine)
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
            c.lastCount = time()
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
            if c.used >= c.total then
                return name .. " - FINAL Run " .. c.used .. "/" .. c.total .. " Begins Now!"
            end
            return name .. " - Run " .. c.used .. "/" .. c.total
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
                -- the run now starting is a FINAL run: the package reads
                -- complete, but XP tracking must stay alive until the run
                -- actually ends. finalRunEntered marks whether the CURRENT
                -- instance is that run (GUID counts fire inside it) or the
                -- final run is the NEXT instance entered (reset counts).
                cdb.finalRunActive = true
                cdb.finalRunEntered = (source == "fresh instance")
                    or (source == "manual" and cdb.inRun) or nil
                PlaySound(8959, "Master")
                break
            end
        end
        -- the professional goodbye: when this count completes every tracked
        -- package, say so once (announcer only, real counts only)
        if source ~= "manual" and announcer then
            local anyLeft = false
            for _, c in pairs(db.customers) do
                if c.used < c.total then anyLeft = true break end
            end
            if not anyLeft and cdb.role == "booster" then
                Announce("All packages complete after this run - pleasure boosting with you!")
            end
        end
        if source ~= "manual" then
            if source == "fresh instance" then
                Print(GREY .. "counted on first mob contact - the reset itself never reached your addon|r")
            end
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
                Print(GREY .. "undo available:|r " .. link)
            end
        end
    else
        Print("run counted, but no registered customers are in the group")
    end
    BroadcastState()
    Render()
end

-- reset = run complete, so that's when the run's XP gets banked into history
function BankRunXP()
    local dur = cdb.runStart and (time() - cdb.runStart) or nil
    cdb.lastBankedDur = dur
    cdb.lastBankedXP = cdb.runXP or 0
    -- customers bank runs that earned XP; boosters bank every counted run
    -- (their XP is 0 at max level, but the Ledger still wants the history)
    if (cdb.runXP or 0) > 0 or (cdb.role == "booster" and (Engaged() or cdb.finalRunActive)) then
        table.insert(cdb.runs, {
            xp = cdb.runXP,
            dur = dur,
            t = time(),
            -- context for the history view: who ran it, where, at what level
            leader = nil,   -- filled below
            inst = db.lastInstance,
            lvl = UnitLevel("player"),
        })
        local rec = cdb.runs[#cdb.runs]
        rec.leader, rec.leaderClass = CrewForBanking()
        while #cdb.runs > 400 do table.remove(cdb.runs, 1) end
    end
    cdb.runStart = nil
    cdb.runXP = 0
    cdb.finalRunActive = nil   -- a banked run is an ended run
    cdb.finalRunEntered = nil
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

-- ==================== Nova addon (NIT / NWB) reset interop ====================
-- NovaInstanceTracker (and NovaWorldBuffs) relay the group leader's instance
-- resets to the whole group on addon prefix "NIT", so crews that reset with a
-- Nova addon give us the same instant counts as crews running BoostBuddy.
-- Wire format: AceSerializer string -> LibDeflate deflate -> addon-channel
-- encode. Decoded text is "instanceReset <version> <instance>" (variants:
-- instanceResetNoMsg, instanceResetOther).
local NOVA_PREFIX = "NIT"
local function DecodeNovaMessage(text)
    local LD = LibStub and LibStub:GetLibrary("LibDeflate", true)
    if not LD or type(text) ~= "string" or text == "" then return end
    local first = text:byte(1)
    if first and first <= 3 then return end        -- AceComm multi-part chunk (big data sync, never a reset)
    if first == 4 then text = text:sub(2) end      -- AceComm escape byte before a control character
    local decoded = LD:DecodeForWoWAddonChannel(text)
    local decompressed = decoded and LD:DecompressDeflate(decoded)
    if not decompressed then return end
    -- current Nova versions serialize with LibSerialize (binary format)
    local LS = LibStub:GetLibrary("LibSerialize", true)
    if LS then
        local ok, success, value = pcall(LS.Deserialize, LS, decompressed)
        if ok and success and type(value) == "string" then return value end
    end
    -- older Nova versions used AceSerializer: a single plain string comes
    -- through as "^1^S<escaped>^^" with "~"-escapes for nonprintables
    local s = decompressed:match("^%^1%^S(.-)%^%^%s*$")
    if not s then return end
    return (s:gsub("~(.)", function(c)
        local b = c:byte()
        if b == 122 then return "\030"
        elseif b == 123 then return "\127"
        elseif b == 124 then return "\126"
        elseif b == 125 then return "\94"
        elseif b >= 64 and b <= 96 then return string.char(b - 64)
        end
        return ""
    end))
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
    -- every new spawn id = a distinct instance visited: log it for the
    -- 5-per-hour lockout display (account-wide, like the cap itself)
    db.instanceLog = db.instanceLog or {}
    table.insert(db.instanceLog, time())
    for i = #db.instanceLog, 1, -1 do
        if time() - db.instanceLog[i] > 3600 then table.remove(db.instanceLog, i) end
    end
    if #db.instanceLog == 5 then
        local oldest = db.instanceLog[1]
        Print("|cffe05c4cthat's 5 instances inside an hour - the next fresh one unlocks in ~" ..
            math.max(1, math.ceil((3600 - (time() - oldest)) / 60)) .. "m|r")
    end
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
ui:SetToplevel(true)   -- clicking a window brings it to the front
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

-- ================================================================ ledger ==
-- The detailed history window: wider than the main window, sessions grouped
-- by day, each expandable down to individual runs. NIT-style depth, but with
-- real rows instead of a text wall.
local ledger
local ledgerRows = {}
local ledgerOpenDay = {}       -- [day] = explicit open/closed (nil = default)
local ledgerOpenSession = {}   -- [day .. "#" .. n] = expanded
local ledgerBuiltFor = -1

local LCOLS = {
    { x = 8,   w = 118 },   -- time / day
    { x = 128, w = 128 },   -- crew - instance
    { x = 258, w = 38 },    -- runs
    { x = 298, w = 74 },    -- xp
    { x = 374, w = 64 },    -- avg
    { x = 440, w = 62 },    -- length
    { x = 504, w = 40 },    -- level
    { x = 546, w = 60 },    -- gold
    { x = 610, w = 160 },   -- note
}

local function GetLedgerRow(i)
    if ledgerRows[i] then return ledgerRows[i] end
    local row = CreateFrame("Button", nil, ledger.content)
    row:SetSize(792, 20)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.cols = {}
    for c, def in ipairs(LCOLS) do
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12)
        fs:SetPoint("LEFT", def.x, 0)
        fs:SetWidth(def.w)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.cols[c] = fs
    end
    row.del = CreateFrame("Button", nil, row)
    row.del:SetSize(16, 16)
    row.del:SetPoint("RIGHT", -4, 0)
    row.del.label = row.del:CreateFontString(nil, "OVERLAY")
    row.del.label:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    row.del.label:SetAllPoints()
    row.del.label:SetText("|cffe05c4cx|r")
    row.del:SetScript("OnEnter", function(b) b.label:SetText("|cffff2020X|r") end)
    row.del:SetScript("OnLeave", function(b) b.label:SetText("|cffe05c4cx|r") end)
    -- the GOLD column itself is the click target for entering gold
    row.pay = CreateFrame("Button", nil, row)
    row.pay:SetSize(60, 20)
    row.pay:SetPoint("LEFT", 544, 0)
    row.pay:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    row.pay:GetHighlightTexture():SetVertexColor(1, 0.9, 0.5, 0.10)
    row.noteBtn = CreateFrame("Button", nil, row)
    row.noteBtn:SetSize(160, 20)
    row.noteBtn:SetPoint("LEFT", 608, 0)
    row.noteBtn:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
    row.noteBtn:GetHighlightTexture():SetVertexColor(1, 0.9, 0.5, 0.10)
    ledgerRows[i] = row
    return row
end

local function RenderLedger()
    if not ledger then return end
    local sessions = BuildSessions()
    local days, dayOrder = {}, {}
    for i = #sessions, 1, -1 do
        local s = sessions[i]
        if not days[s.day] then
            days[s.day] = { sessions = {}, runs = 0, xp = 0 }
            table.insert(dayOrder, s.day)
        end
        local d = days[s.day]
        table.insert(d.sessions, s)
        d.runs = d.runs + s.runs
        d.xp = d.xp + s.xp
    end

    local idx, yy = 0, 0
    local function place()
        idx = idx + 1
        local row = GetLedgerRow(idx)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, yy)
        for _, fs in ipairs(row.cols) do fs:SetText("") end
        row.del:Hide()
        row.del:SetScript("OnClick", nil)
        row.pay:Hide()
        row.pay:SetScript("OnClick", nil)
        row.pay:SetScript("OnEnter", nil)
        row.pay:SetScript("OnLeave", nil)
        row.noteBtn:Hide()
        row.noteBtn:SetScript("OnClick", nil)
        row.noteBtn:SetScript("OnEnter", nil)
        row.noteBtn:SetScript("OnLeave", nil)
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:Show()
        yy = yy - 21
        return row
    end

    -- a freshly joined (and possibly freshly paid) crew shows up right away,
    -- before its first run banks - so paying never looks like a black hole
    if cdb.crewLeader then
        local now = time()
        local pending = 0
        for _, tr in ipairs(cdb.trades or {}) do
            if tr.crew == cdb.crewLeader and (now - tr.t) < 3600 then
                pending = pending + (tr.give or 0) - (tr.get or 0)
            end
        end
        local latest = sessions[#sessions]
        local hasLive = latest and latest.leader == cdb.crewLeader
            and latest.lastT and (now - latest.lastT) < 3600
        if not hasLive then
            local r = place()
            r.bg:SetColorTexture(0.9, 0.78, 0.38, 0.07)
            r.cols[1]:SetText(GREEN .. "now|r")
            r.cols[2]:SetText(ClassColorName(DisplayName(cdb.crewLeader), cdb.crewClass) ..
                GREY .. " - session forming|r")
            if pending > 0 then
                r.cols[8]:SetText(GOLD .. FmtGold(pending) .. "|r")
            end
            r.cols[9]:SetText(GREY .. "first run starts the session|r")
        end
    end

    for dn, day in ipairs(dayOrder) do
        local d = days[day]
        local open = ledgerOpenDay[day]
        if open == nil then open = (dn == 1) end
        local r = place()
        r.bg:SetColorTexture(0.35, 0.55, 0.22, 0.16)
        r.cols[1]:SetText((open and GREEN .. "-|r  " or GREEN .. "+|r  ") .. GOLD .. day .. "|r")
        r.cols[2]:SetText(GREY .. #d.sessions .. " session" .. (#d.sessions == 1 and "" or "s") .. "|r")
        r.cols[3]:SetText(GREY .. "x|r" .. d.runs)
        r.cols[4]:SetText(GOLD .. FmtXP(d.xp) .. "|r")
        local dayMoney = 0
        for _, ds in ipairs(d.sessions) do dayMoney = dayMoney + SessionMoney(ds) end
        if dayMoney > 0 then
            r.cols[8]:SetText(GOLD .. FmtGold(dayMoney) .. "|r")
        elseif dayMoney < 0 then
            r.cols[8]:SetText(GREEN .. "+" .. FmtGold(-dayMoney) .. "|r")
        end
        r:SetScript("OnClick", function()
            ledgerOpenDay[day] = not open
            RenderLedger()
        end)
        if open then
            for sn, s in ipairs(d.sessions) do
                local skey = day .. "#" .. sn
                local sopen = ledgerOpenSession[skey]
                local sr = place()
                sr.bg:SetColorTexture(1, 1, 1, sn % 2 == 0 and 0.03 or 0.06)
                local t1 = s.firstT and date("%H:%M", s.firstT) or "?"
                local t2 = s.lastT and date("%H:%M", s.lastT) or t1
                sr.cols[1]:SetText("   " .. (sopen and GREEN .. "v|r " or GREY .. ">|r ") ..
                    GREY .. t1 .. "-" .. t2 .. "|r")
                local instNames = {}
                for k in pairs(s.insts or {}) do table.insert(instNames, k) end
                table.sort(instNames)
                local inst = table.concat(instNames, ", ")
                local lc = s.leaderClass
                if not lc then
                    -- runs recorded before class-stamping existed: if that
                    -- player is in the group right now, ask the client live
                    for _, u in ipairs(GroupUnits()) do
                        if UnitName(u) == s.leader then
                            local _, cls = UnitClass(u)
                            lc = cls
                            break
                        end
                    end
                end
                local note = db.crewNotes and db.crewNotes[s.leader]
                sr.cols[2]:SetText(ClassColorName(DisplayName(s.leader), lc) ..
                    (inst ~= "" and (GREY .. " - " .. inst .. "|r") or ""))
                local money = SessionMoney(s)
                if money > 0 then
                    sr.cols[8]:SetText(GOLD .. FmtGold(money) .. "|r")
                elseif money < 0 then
                    sr.cols[8]:SetText(GREEN .. "+" .. FmtGold(-money) .. "|r")
                end
                sr.cols[9]:SetText(note and (GOLD .. note .. "|r") or "")
                sr:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if note then
                        GameTooltip:SetText(DisplayName(s.leader), 1, 0.82, 0)
                        GameTooltip:AddLine(note, 1, 1, 1, true)
                        GameTooltip:AddLine(" ")
                    else
                        GameTooltip:SetText(DisplayName(s.leader), 1, 0.82, 0)
                    end
                    GameTooltip:AddLine("right-click to " .. (note and "edit" or "add") .. " a crew note", 0.6, 0.6, 0.6)
                    GameTooltip:Show()
                end)
                sr:SetScript("OnLeave", function() GameTooltip:Hide() end)
                sr.cols[3]:SetText(GREY .. "x|r" .. s.runs)
                sr.cols[4]:SetText(FmtXP(s.xp))
                sr.cols[5]:SetText(GREY .. FmtXP(s.xp / s.runs) .. "|r")
                sr.cols[6]:SetText(GREY .. ((s.firstT and s.lastT and s.lastT > s.firstT)
                    and FmtEta(s.lastT - s.firstT) or "") .. "|r")
                local lvltext = ""
                if s.lvl0 and s.lvl1 and s.lvl1 > s.lvl0 then
                    lvltext = GREEN .. s.lvl0 .. ">" .. s.lvl1 .. "|r"   -- dinged this session
                elseif s.lvl1 or s.lvl0 then
                    lvltext = GREY .. (s.lvl1 or s.lvl0) .. "|r"
                end
                sr.cols[7]:SetText(lvltext)
                sr.pay:SetScript("OnClick", function()
                    if s.leader == "?" then
                        Print("no crew was recorded for that session")
                        return
                    end
                    StaticPopup_Show("BOOSTBUDDY_SESSION_GOLD", DisplayName(s.leader), nil,
                        { leader = s.leader, lastT = s.lastT or s.firstT, current = money })
                end)
                sr.pay:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if money > 0 then
                        GameTooltip:SetText(FmtGold(money) .. " paid", 1, 0.82, 0)
                        GameTooltip:AddLine(FmtGold(money / s.runs) .. " per run", 1, 1, 1)
                        GameTooltip:AddLine("click to adjust", 0.6, 0.6, 0.6)
                    else
                        GameTooltip:SetText("no gold recorded", 0.6, 0.6, 0.6)
                        GameTooltip:AddLine("click to enter what you paid", 0.6, 0.6, 0.6)
                    end
                    GameTooltip:Show()
                end)
                sr.pay:SetScript("OnLeave", function() GameTooltip:Hide() end)
                sr.pay:Show()
                sr.noteBtn:SetScript("OnClick", function()
                    if s.leader ~= "?" then
                        StaticPopup_Show("BOOSTBUDDY_CREW_NOTE", DisplayName(s.leader), nil, s.leader)
                    else
                        Print("no crew was recorded for that session")
                    end
                end)
                sr.noteBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if note then
                        GameTooltip:SetText(note, 1, 1, 1, 1, true)
                        GameTooltip:AddLine("click to edit", 0.6, 0.6, 0.6)
                    else
                        GameTooltip:SetText("no note", 0.6, 0.6, 0.6)
                        GameTooltip:AddLine("click to write one about this crew", 0.6, 0.6, 0.6)
                    end
                    GameTooltip:Show()
                end)
                sr.noteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                sr.noteBtn:Show()
                sr.del:SetScript("OnClick", function()
                    local idxs = {}
                    for _, ri in ipairs(s.runIdxs or {}) do table.insert(idxs, ri) end
                    local desc = DisplayName(s.leader) .. " - " .. s.day .. " - " ..
                        s.runs .. " run" .. (s.runs == 1 and "" or "s") .. ", " .. FmtXP(s.xp) .. " XP"
                    StaticPopup_Show("BOOSTBUDDY_DELETE_SESSION", desc, nil, { idxs = idxs, desc = desc })
                end)
                sr.del:Show()
                sr:SetScript("OnClick", function(_, button)
                    if button == "RightButton" then
                        if s.leader ~= "?" then
                            -- data goes IN the Show call so OnShow can prefill
                            StaticPopup_Show("BOOSTBUDDY_CREW_NOTE", s.leader, nil, s.leader)
                        else
                            Print("no crew was recorded for that session")
                        end
                        return
                    end
                    ledgerOpenSession[skey] = not sopen
                    RenderLedger()
                end)
                if sopen then
                    for j, ri in ipairs(s.runIdxs or {}) do
                        local run = cdb.runs[ri]
                        if run then
                            local rr = place()
                            rr.bg:SetColorTexture(0, 0, 0, 0)
                            -- numbered within THIS session, matching how the
                            -- package was counted with that crew
                            rr.cols[1]:SetText(GREY .. "        run " .. j .. "|r")
                            rr.cols[2]:SetText(GREY .. (run.t and date("%H:%M", run.t) or "") .. "|r")
                            rr.cols[4]:SetText(GREY .. FmtXP(run.xp) .. "|r")
                            rr.cols[6]:SetText(GREY .. (run.dur and FmtDur(run.dur) or "") .. "|r")
                            if money > 0 then
                                rr.cols[8]:SetText(GREY .. FmtGold(money / s.runs) .. "|r")
                            end
                        end
                    end
                end
            end
        end
    end
    if idx == 0 then
        local r = place()
        r.bg:SetColorTexture(0, 0, 0, 0)
        r.cols[1]:SetText(GREY .. "no runs recorded yet|r")
    end
    for i = idx + 1, #ledgerRows do ledgerRows[i]:Hide() end
    ledger.content:SetHeight(math.max(1, -yy))
    local totalRuns, totalXP, totalMoney = 0, 0, 0
    for _, s in ipairs(sessions) do
        totalRuns = totalRuns + s.runs
        totalXP = totalXP + s.xp
        totalMoney = totalMoney + SessionMoney(s)
    end
    local moneyText = ""
    if totalMoney > 0 then
        moneyText = GREY .. " - |r" .. GOLD .. FmtGold(totalMoney) .. " spent|r"
    elseif totalMoney < 0 then
        moneyText = GREY .. " - |r" .. GREEN .. FmtGold(-totalMoney) .. " earned|r"
    end
    ledger.totals:SetText(GREY .. #sessions .. " sessions - " .. totalRuns .. " runs - |r" ..
        GOLD .. FmtXP(totalXP) .. " XP|r" .. moneyText)
    ledgerBuiltFor = #cdb.runs
end

local function BuildLedger()
    ledger = CreateFrame("Frame", "BoostBuddyLedger", UIParent, "BackdropTemplate")
    ledger:SetSize(838, 400)
    if db.ledgerPos then
        ledger:SetPoint(db.ledgerPos[1], UIParent, db.ledgerPos[2], db.ledgerPos[3], db.ledgerPos[4])
    else
        ledger:SetPoint("CENTER", 140, 0)
    end
    ledger:SetMovable(true)
    ledger:EnableMouse(true)
    ledger:RegisterForDrag("LeftButton")
    ledger:SetScript("OnDragStart", function(self) self:StartMoving() end)
    ledger:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.ledgerPos = { point, relPoint, x, y }
    end)
    ledger:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    ledger:SetBackdropColor(0.055, 0.045, 0.09, 0.96)
    ledger:SetBackdropBorderColor(0.35, 0.55, 0.22, 1)
    ledger:SetFrameStrata("DIALOG")
    ledger:SetToplevel(true)

    local ltitle = ledger:CreateFontString(nil, "OVERLAY")
    ltitle:SetFont(STANDARD_TEXT_FONT, 15, "OUTLINE")
    ltitle:SetPoint("TOPLEFT", 12, -10)
    ltitle:SetText(GREEN .. "BoostBuddy|r" .. GREY .. " - Ledger|r")

    local hint = ledger:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 11)
    hint:SetPoint("TOPLEFT", ltitle, "TOPRIGHT", 10, -2)
    hint:SetText(GREY .. "click to expand - right-click a session for crew notes|r")

    local lclose = CreateFrame("Button", nil, ledger, "UIPanelCloseButton")
    lclose:SetPoint("TOPRIGHT", 2, 2)
    lclose:SetScript("OnClick", function() ledger:Hide() end)

    local heads = { "TIME", "CREW - INSTANCE", "RUNS", "XP", "AVG", "LENGTH", "LVL", "GOLD", "NOTE" }
    for c, def in ipairs(LCOLS) do
        local fs = ledger:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 10)
        fs:SetPoint("TOPLEFT", def.x + 8, -34)
        fs:SetWidth(def.w)
        fs:SetJustifyH("LEFT")
        fs:SetText(GREY .. heads[c] .. "|r")
    end

    local scroll = CreateFrame("ScrollFrame", "BoostBuddyLedgerScroll", ledger, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -50)
    scroll:SetPoint("BOTTOMRIGHT", -30, 30)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(792, 1)
    scroll:SetScrollChild(content)
    ledger.content = content

    ledger.totals = ledger:CreateFontString(nil, "OVERLAY")
    ledger.totals:SetFont(STANDARD_TEXT_FONT, 11)
    ledger.totals:SetPoint("BOTTOMLEFT", 12, 10)

    local csvBtn = CreateFrame("Button", nil, ledger, "UIPanelButtonTemplate")
    csvBtn:SetSize(50, 20)
    csvBtn:SetPoint("BOTTOMRIGHT", -8, 6)
    csvBtn:GetFontString():SetFont(STANDARD_TEXT_FONT, 10)
    csvBtn:SetText("CSV")
    csvBtn:SetScript("OnClick", function()
        local function esc(v)
            v = tostring(v or "")
            if v:find('[",\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
            return v
        end
        local rows = { "date,start,crew,runs,xp,avg_xp,length_minutes,level_start,level_end,gold,note" }
        for _, sess in ipairs(BuildSessions()) do
            local money = SessionMoney(sess)
            table.insert(rows, table.concat({
                sess.firstT and date("%Y-%m-%d", sess.firstT) or "",
                sess.firstT and date("%H:%M", sess.firstT) or "",
                esc(sess.leader),
                sess.runs,
                sess.xp,
                math.floor(sess.xp / math.max(1, sess.runs) + 0.5),
                (sess.firstT and sess.lastT and sess.lastT > sess.firstT)
                    and math.floor((sess.lastT - sess.firstT) / 60 + 0.5) or "",
                sess.lvl0 or "",
                sess.lvl1 or "",
                money ~= 0 and math.floor(money / 10000 + 0.5) or "",
                esc(db.crewNotes and db.crewNotes[sess.leader] or ""),
            }, ","))
        end
        ShowExport(table.concat(rows, "\n"))
    end)

    ledger:Hide()   -- frames spawn visible; the toggle expects hidden
end

local function ToggleLedger()
    if not ledger then BuildLedger() end
    if ledger:IsShown() then
        ledger:Hide()
    else
        RenderLedger()
        ledger:Show()
        ledger:Raise()   -- open on top of the main window
    end
end

RefreshLedger = function()
    if ledger and ledger:IsShown() then RenderLedger() end
end

ui.historyBtn = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
ui.historyBtn:SetSize(58, 18)
ui.historyBtn:SetPoint("RIGHT", ui.overlayBtn, "LEFT", -5, 0)
ui.historyBtn:GetFontString():SetFont(STANDARD_TEXT_FONT, 10)
ui.historyBtn:SetText("History")
ui.historyBtn:SetScript("OnClick", ToggleLedger)

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
        row:EnableMouse(false)
        row:SetScript("OnMouseUp", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
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
            local cycle = AvgCycleSeconds()
            local eta = (togo > 0 and cycle) and (" - about " .. FmtEta(togo * cycle)) or ""
            r2.name:SetText(GREEN .. ("level %d in ~%d run%s%s|r"):format(level + 1, togo, togo == 1 and "" or "s", eta))
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
        -- stop short of the History button so the footer never overlaps it
        ui.footerNote:SetWidth(160)
        ui.footerNote:SetText("a run banks its XP when the dungeon gets reset")
        y = y - 30
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
        local paidText
        if c.paid and c.paid > 0 then
            paidText = GREY .. " " .. FmtGold(c.paid) .. "|r"
        else
            paidText = " |cffe05c4cunpaid|r"
        end
        local rnote = db.crewNotes and db.crewNotes[name]
        row.name:SetText(ClassColorName(DisplayName(name), c.class) ..
            (rnote and (GOLD .. "*|r") or "") ..
            "  " .. (done and GREEN or GOLD) .. c.used .. "/" .. c.total .. "|r" ..
            paidText ..
            (done and (GREEN .. " (Last Run)|r") or ""))
        row.name:SetTextColor(1, 1, 1)
        row.name:SetWidth(150)
        -- right-click: note about this customer; hover: read it
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(_, btn)
            if btn == "RightButton" then
                StaticPopup_Show("BOOSTBUDDY_CREW_NOTE", name, nil, name)
            end
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(DisplayName(name), 1, 0.82, 0)
            if rnote then GameTooltip:AddLine(rnote, 1, 1, 1, true) GameTooltip:AddLine(" ") end
            GameTooltip:AddLine("paid: " .. ((c.paid and c.paid > 0) and FmtGold(c.paid) or "nothing yet") ..
                "  (/boost paid " .. name .. " <gold> to set)", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("right-click to " .. (rnote and "edit" or "add") .. " a note", 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
    -- stop short of the History button so the footer never overlaps it
    ui.footerNote:SetWidth(160)
    ui.footerNote:SetText("counts are automatic - manual corrections are always announced to the group")
    y = y - 30

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

StaticPopupDialogs["BOOSTBUDDY_SESSION_GOLD"] = {
    text = "Total gold paid to %s for this session:\n\n(enter the full amount - the ledger adjusts itself; 0 clears it)",
    button1 = SAVE,
    button2 = CANCEL,
    hasEditBox = true,
    editBoxWidth = 120,
    maxLetters = 8,
    OnShow = function(self)
        local eb = PopupEditBox(self)
        if eb then
            local cur = self.data and self.data.current or 0
            eb:SetText(cur > 0 and tostring(math.floor(cur / 10000 + 0.5)) or "")
            eb:HighlightText()
        end
    end,
    OnAccept = function(self)
        local d = self.data
        if not d or not cdb then return end
        local eb = PopupEditBox(self)
        local entered = math.floor((tonumber(eb and eb:GetText() or "") or 0) * 10000)
        local delta = entered - (d.current or 0)
        if delta == 0 then return end
        cdb.trades = cdb.trades or {}
        table.insert(cdb.trades, {
            t = d.lastT or time(),
            who = "(manual)",
            give = delta > 0 and delta or 0,
            get = delta < 0 and -delta or 0,
            crew = d.leader,
        })
        while #cdb.trades > 300 do table.remove(cdb.trades, 1) end
        Print(d.leader .. "'s session set to " .. (entered > 0 and FmtGold(entered) or "no gold") .. " paid")
        Render()
        RefreshLedger()
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["BOOSTBUDDY_SESSION_GOLD"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BOOSTBUDDY_DELETE_SESSION"] = {
    text = "Delete this session?\n\n%s\n\nThese runs are removed from your XP history permanently.",
    button1 = ACCEPT,
    button2 = CANCEL,
    showAlert = true,
    OnAccept = function(self)
        local d = self.data
        if not d or not d.idxs or not cdb then return end
        table.sort(d.idxs, function(a, b) return a > b end)
        for _, i in ipairs(d.idxs) do table.remove(cdb.runs, i) end
        for k in pairs(ledgerOpenSession) do ledgerOpenSession[k] = nil end
        Print("deleted session: " .. d.desc)
        Render()
        RefreshLedger()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BOOSTBUDDY_CREW_NOTE"] = {
    text = "Note for crew %s:\n\n(who's good, who's sketchy, prices - saved account-wide)",
    button1 = SAVE,
    button2 = CANCEL,
    hasEditBox = true,
    editBoxWidth = 260,
    maxLetters = 150,
    OnShow = function(self)
        local eb = PopupEditBox(self)
        if eb then
            eb:SetText((db and db.crewNotes and db.crewNotes[self.data]) or "")
            eb:HighlightText()
        end
    end,
    OnAccept = function(self)
        if not db then return end
        db.crewNotes = db.crewNotes or {}
        local eb = PopupEditBox(self)
        local text = eb and eb:GetText() or ""
        if text:match("^%s*$") then
            db.crewNotes[self.data] = nil
            Print("note for " .. self.data .. " removed")
        else
            db.crewNotes[self.data] = text
            Print("note saved for " .. self.data)
        end
        Render()
        RefreshLedger()
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["BOOSTBUDDY_CREW_NOTE"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["BOOSTBUDDY_FRESH_SESSION"] = {
    text = "Start a fresh session?\n\nThis clears ALL tracked packages and synced boost state. Your run history and XP stats are kept.",
    button1 = ACCEPT,
    button2 = CANCEL,
    OnAccept = function()
        if not db then return end
        db.customers = {}
        db.lastCounted = nil
        cdb.myBoost = nil
        cdb.finalRunActive = nil
        cdb.finalRunEntered = nil
        if IsInGroup() then
            AnnounceAlways("MANUAL: " .. UnitName("player") ..
                " started a fresh session - all packages cleared")
        else
            Print("fresh session - all packages cleared")
        end
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
-- ========================================================= trade capture ==
-- Gold changing hands is recorded and tagged with the current crew, so the
-- Ledger can price sessions and the roster knows who has paid. Commit only
-- on the "Trade complete." system message; a cancelled trade records nothing.
local tradePartner, tradePartnerClass
local tradeGive, tradeGet = 0, 0
local tradePending

local function TradeEvent(event, arg1, arg2)
    if event == "TRADE_SHOW" then
        tradePartner = UnitName("NPC")
        tradePartnerClass = tradePartner and select(2, UnitClass("NPC")) or nil
        tradeGive, tradeGet = 0, 0
        tradePending = nil
    elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" then
        tradeGive = GetPlayerTradeMoney() or tradeGive
        tradeGet = GetTargetTradeMoney() or tradeGet
    elseif event == "TRADE_CLOSED" then
        if tradePartner and (tradeGive > 0 or tradeGet > 0) then
            tradePending = { who = tradePartner, class = tradePartnerClass,
                give = tradeGive, get = tradeGet, t = time() }
        end
        tradePartner = nil
    elseif event == "UI_INFO_MESSAGE" then
        local msg = arg2 or arg1
        if msg == ERR_TRADE_COMPLETE and tradePending and (time() - tradePending.t) < 10 then
            local p = tradePending
            tradePending = nil
            cdb.trades = cdb.trades or {}
            local crew = cdb.crewLeader
            if not crew and cdb.crewGrace and (time() - (cdb.crewGrace.t or 0)) < 900 then
                crew = cdb.crewGrace.name
            end
            table.insert(cdb.trades, { t = time(), who = p.who, class = p.class,
                give = p.give, get = p.get, crew = crew })
            while #cdb.trades > 300 do table.remove(cdb.trades, 1) end
            if p.give > 0 then
                Print("gave " .. FmtGold(p.give) .. " to " .. ClassColorName(p.who, p.class) ..
                    (crew and (GREY .. " - logged to " .. crew .. "'s session|r") or ""))
            end
            if p.get > 0 then
                Print("received " .. FmtGold(p.get) .. " from " .. ClassColorName(p.who, p.class))
                local c = db.customers[p.who]
                if c then
                    c.paid = (c.paid or 0) + p.get
                end
            end
            Render()
            RefreshLedger()
        elseif msg == ERR_TRADE_CANCELLED then
            tradePending = nil
        end
    end
end

tally:RegisterEvent("ADDON_LOADED")
tally:RegisterEvent("TRADE_SHOW")
tally:RegisterEvent("TRADE_MONEY_CHANGED")
tally:RegisterEvent("TRADE_ACCEPT_UPDATE")
tally:RegisterEvent("TRADE_CLOSED")
tally:RegisterEvent("UI_INFO_MESSAGE")
tally:RegisterEvent("PLAYER_ENTERING_WORLD")
tally:RegisterEvent("ZONE_CHANGED_NEW_AREA")
tally:RegisterEvent("READY_CHECK")
tally:RegisterEvent("READY_CHECK_FINISHED")
tally:RegisterEvent("GROUP_ROSTER_UPDATE")
tally:RegisterEvent("CHAT_MSG_SYSTEM")
tally:RegisterEvent("CHAT_MSG_ADDON")
tally:RegisterEvent("CHAT_MSG_PARTY")
tally:RegisterEvent("CHAT_MSG_PARTY_LEADER")
tally:RegisterEvent("CHAT_MSG_RAID")
tally:RegisterEvent("CHAT_MSG_RAID_LEADER")
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
        C_ChatInfo.RegisterAddonMessagePrefix(NOVA_PREFIX)   -- listen for NIT/NWB reset relays
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
    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
            or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
        -- NIT announces "[NIT] <instance> has been reset..." in group chat.
        -- Only the resetter's NIT posts this and only leaders can reset, so
        -- the leader saying it is as trustworthy as an addon relay -- and it
        -- works no matter what NIT version the leader runs.
        local instance = (arg1 or ""):match("^%[NIT%] (.+) has been reset")
        if instance then
            local sender = Ambiguate(arg2 or "", "none")
            if sender ~= UnitName("player") and SenderIsGroupLeader(sender) then
                if db.debug then Print("debug: NIT chat line from leader " .. sender .. " - reset of " .. instance) end
                OnInstanceReset(instance, true)
            end
        end
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 ~= PREFIX and arg1 ~= NOVA_PREFIX then return end
        local sender = Ambiguate(arg4 or "", "none")
        if sender == UnitName("player") then return end
        if arg1 == NOVA_PREFIX then
            -- reset relayed by NovaInstanceTracker / NovaWorldBuffs. Same trust
            -- rule as our own relay: only the group leader can reset, so only
            -- the leader's relay is believed.
            local senderIsLeader = SenderIsGroupLeader(sender)
            local msg = DecodeNovaMessage(arg2)
            if db.debug then
                Print(("debug: NIT comm from %s%s (%d bytes) -> %s"):format(
                    sender, senderIsLeader and " (leader)" or " (not leader)",
                    #(arg2 or ""), msg and ("'" .. msg .. "'") or "no decode"))
            end
            if not senderIsLeader then return end
            local cmd, instance = (msg or ""):match("^(%S+) %S+ (.+)$")
            if instance and (cmd == "instanceReset" or cmd == "instanceResetNoMsg"
                    or cmd == "instanceResetOther") then
                OnInstanceReset(instance, true)
            end
            return
        end
        if db.debug then
            Print(("debug: addon msg from %s: %s"):format(sender, tostring(arg2):sub(1, 60)))
        end
        local kind, payload = strsplit("|", arg2 or "")
        if kind == "RESET" and payload then
            if not SenderIsGroupLeader(sender) then return end
            OnInstanceReset(payload, true)
        elseif kind == "STATE" then
            local size = 0
            for _ in (payload or ""):gmatch("[^;]+") do size = size + 1 end
            knownTrackers[sender] = { seen = GetTime(), size = size }
            local me, found = UnitName("player"), nil
            for entry in (payload or ""):gmatch("[^;]+") do
                local name, used, total = entry:match("^(.-):(%d+):(%d+)$")
                if name == me then
                    found = { used = tonumber(used), total = tonumber(total), from = sender, t = time() }
                end
            end
            if found then
                local old = cdb.myBoost
                if not old or old.used ~= found.used or old.total ~= found.total then
                    Print(("package sync: %d/%d (from %s)"):format(found.used, found.total, sender))
                end
                -- booster-tracked final run: keep XP alive through it
                if found.used >= found.total and (not old or old.used < found.used) then
                    cdb.finalRunActive = true
                    cdb.finalRunEntered = nil
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
        if cdb.inRun and delta > 0 and not db.paused and (Engaged() or cdb.finalRunActive) then
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
        local wasInRun = cdb.inRun
        cdb.inRun = inside
        if inside then
            cdb.lastEntryTime = time()
            visitConfirmed, pendingSpawn = false, nil
            if cdb.finalRunActive and not cdb.finalRunEntered then
                cdb.finalRunEntered = true   -- this zone-in IS the final run
            end
        elseif wasInRun and cdb.finalRunActive then
            -- bank only when the final run itself ends - NOT on the hop out
            -- of the previous instance right after an inside-the-dungeon
            -- final count (that hop was eating the whole last run's XP).
            -- Any stray XP from that hop carries into the final run's total.
            if cdb.finalRunEntered then
                BankRunXP()
            end
        end
        -- arg1/arg2 = isInitialLogin/isReloadingUi (PLAYER_ENTERING_WORLD only):
        -- a reload or login is NOT a fresh zone-in, so the run clock keeps ticking
        local isLoginOrReload = (event == "PLAYER_ENTERING_WORLD") and (arg1 or arg2)
        -- session hygiene: on a true login (not a reload), retire FINISHED
        -- packages from earlier sessions. Unfinished packages are owed runs
        -- and never expire on their own.
        if event == "PLAYER_ENTERING_WORLD" and arg1 then
            local dropped = 0
            for name, c in pairs(db.customers) do
                if c.used >= c.total and (not c.lastCount or time() - c.lastCount > 8 * 3600) then
                    db.customers[name] = nil
                    dropped = dropped + 1
                end
            end
            if cdb.myBoost and cdb.myBoost.used >= cdb.myBoost.total
                    and (not cdb.myBoost.t or time() - cdb.myBoost.t > 8 * 3600) then
                cdb.myBoost = nil
                dropped = dropped + 1
            end
            if dropped > 0 then
                Print("cleared " .. dropped .. " finished package(s) from an earlier session - /boost reset clears everything")
            end
        end
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
                    c.lastCount = time()
                    table.insert(started, name)
                end
            end
            if #started > 0 then
                db.cycleCounted = true
                cdb.runStart = time()
                cdb.runXP = 0
                table.sort(started)
                for _, name in ipairs(started) do
                    local c = db.customers[name]
                    if c.used >= c.total then
                        cdb.finalRunActive = true
                        cdb.finalRunEntered = true
                        break
                    end
                end
                if IAmAnnouncer() then
                    Announce("New Instance Run Detected")
                    for _, name in ipairs(started) do
                        local c = db.customers[name]
                        Announce(c.used >= c.total
                            and (name .. " - FINAL Run " .. c.used .. "/" .. c.total .. " Begins Now!")
                            or (name .. " - Run " .. c.used .. "/" .. c.total))
                    end
                end
                BroadcastState()
            end
        end
        UpdateCrew()   -- catch the crew label on login/zone if roster events were missed
        if db.uiShown and not ui:IsShown() then ui:Show() end   -- survive zoning
        Render()
    elseif event == "TRADE_SHOW" or event == "TRADE_MONEY_CHANGED"
            or event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_CLOSED"
            or event == "UI_INFO_MESSAGE" then
        TradeEvent(event, arg1, arg2)
    elseif event == "GROUP_ROSTER_UPDATE" then
        UpdateCrew()
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
        { "/boost paid Name 300", "record what someone paid (auto-filled by trades)" },
        { "/boost set Name 3", "correct someone's runs done" },
        { "/boost remove Name", "stop tracking someone" },
        { "/boost count", "count a run manually (mid-run catch-up)" },
        { "/boost undo", "take the last counted run back" },
        { "/boost ready", "start a ready check" },
        { "/boost list", "print the roster to chat" },
        { "/boost reset", "fresh session: clear all packages and synced state (asks first)" },
        "for customers",
        { "/boost export", "your run history as copyable CSV" },
        { "/boost spent 280", "manually record gold you paid (trades log automatically)" },
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
    elseif cmd == "role" then
        cdb.role = nil
        db.uiShown = true
        ui:Show()
    elseif cmd == "reset" or cmd == "clear" or cmd == "newsession" then
        StaticPopup_Show("BOOSTBUDDY_FRESH_SESSION")
    elseif cmd == "spent" and tonumber(a) then
        local amt = math.floor(tonumber(a) * 10000)
        if amt > 0 then
            cdb.trades = cdb.trades or {}
            local crew = (b ~= "" and Cap(b)) or cdb.crewLeader
            if not crew and cdb.crewGrace and (time() - (cdb.crewGrace.t or 0)) < 900 then
                crew = cdb.crewGrace.name
            end
            table.insert(cdb.trades, { t = time(), who = "(manual)", give = amt, get = 0, crew = crew })
            while #cdb.trades > 300 do table.remove(cdb.trades, 1) end
            if crew then
                Print("recorded " .. FmtGold(amt) .. " paid - logged to " .. crew .. "'s session")
            else
                Print("recorded " .. FmtGold(amt) .. " paid - no crew to tie it to; use /boost spent " .. a .. " CrewName")
            end
            Render()
            RefreshLedger()
        end
    elseif cmd == "paid" and a ~= "" then
        local c = db.customers[Cap(a)]
        if not c then
            Print(Cap(a) .. " is not tracked")
        else
            local amt = math.floor((tonumber(b) or 0) * 10000)
            c.paid = amt > 0 and amt or nil
            Print(Cap(a) .. " marked as " ..
                (amt > 0 and ("paid " .. FmtGold(amt)) or "unpaid"))
            Render()
        end
    elseif cmd == "total" and a ~= "" and tonumber(b) then
        local c = db.customers[Cap(a)]
        if c then
            c.total = tonumber(b)
            AnnounceAlways("MANUAL: " .. UnitName("player") .. " set " .. Cap(a) ..
                "'s package to " .. c.used .. "/" .. c.total)
            BroadcastState()
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

-- keep the lockout countdown and an open ledger fresh
C_Timer.NewTicker(30, function()
    if not db then return end
    if ui and ui:IsShown() then Render() end
    if ledger and ledger:IsShown() and ledgerBuiltFor ~= #cdb.runs then RenderLedger() end
end)
