-- GoldPerSpot (formerly Farm Tracker): gold/hour for a farming session. Read-only tracking, no automation.
-- Items are counted by diffing your bags (locale-free, and it avoids loot chat text, which can be
-- a secret value on Midnight-API clients). Coin counts only while a loot window is open.
local ADDON, ns = ...
local C, Core = ns.Compat, ns.Core
local L = Core.L
local Hub = ns.Hub

local SCHEMA = 1
local AH_CUT = 0.05
local MIN_BEST_SECONDS = 300 -- sessions shorter than 5 minutes don't count towards "best"
local MAX_SESSIONS_PER_SPOT = 50
local STALE_SECONDS = 3 * 86400 -- an AH price older than this is flagged as old in the totals
local DEFAULTS = { valuation = "ah", shown = true, locked = false }

local FT = {}
KennyGoldPerSpot = FT
local db, settings, s -- s = the current session (not saved until Stop)
local migrations = {}  -- schema 1 is the first release. No migration from FarmTracker 0.1.0: the folder rename gives a new SavedVariables file, and FarmTracker was only a GitHub pre-release.

-- ---------- pricing ----------
-- AH prices come from our shared price service (PriceLog, else MatTooltip's own scans); GoldPerSpot never scans.
function FT.AHPrice(itemID)
  local best = Hub.GetPrice(itemID, ADDON)
  return best and best.p, best and best.t
end

-- Value of one item and where it came from: "ah", "old" (AH price older than 3 days, or of unknown age) or "vendor".
function FT.ItemValue(itemID, mode)
  if mode ~= "vendor" then
    local ah, t = FT.AHPrice(itemID)
    if ah then
      local old = not t or t == 0 or (C.Now() - t) > STALE_SECONDS
      return math.floor(ah * (1 - AH_CUT)), old and "old" or "ah"
    end
  end
  local info = C.GetItemInfo(itemID)
  return (info and info.sellPrice) or 0, "vendor"
end

function FT.Totals(sess, mode)
  local itemValue, list = 0, {}
  for id, n in pairs(sess.items) do
    local v, src = FT.ItemValue(id, mode)
    itemValue = itemValue + v * n
    list[#list + 1] = { id = id, n = n, v = v * n, src = src }
  end
  table.sort(list, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
  local flagged = 0
  for _, e in ipairs(list) do if e.src ~= "ah" then flagged = flagged + 1 end end
  list.flagged = flagged
  local total = itemValue + sess.money
  local gph = sess.elapsed > 0 and total * 3600 / sess.elapsed or 0
  return total, gph, list
end

-- "this spot: Xg/hr vs your best Yg/hr (spot)"
function FT.Verdict(spot, gph, spots)
  local bestHere, bestAll, bestAllSpot
  for name, sp in pairs(spots) do
    for _, h in ipairs(sp.sessions) do
      if h.dur >= MIN_BEST_SECONDS then
        local r = h.copper * 3600 / h.dur
        if name == spot and (not bestHere or r > bestHere) then bestHere = r end
        if not bestAll or r > bestAll or (r == bestAll and name < bestAllSpot) then bestAll, bestAllSpot = r, name end
      end
    end
  end
  local g = function(c) return ("%.1fg/hr"):format(c / 10000) end
  if not bestAll then return "this spot: " .. g(gph) .. " (first saved session)" end
  local line = "this spot: " .. g(gph) .. " vs your best " .. g(bestAll) .. " (" .. bestAllSpot .. ")"
  if bestHere and bestAllSpot ~= spot then line = line .. "; best here " .. g(bestHere) end
  if gph >= bestAll then return line .. " - NEW BEST" end
  if gph < bestAll * 0.75 then return line .. " - consider " .. bestAllSpot end
  return line
end

-- ---------- bag tracking ----------
local snapshot, suspended, pendingBags, lootOpen, lastMoney = nil, 0, false, false, 0

function FT.ApplyBagDiff()
  local now = C.GetBagCounts()
  if s and s.running and not s.paused and suspended == 0 and snapshot then
    for id, n in pairs(now) do
      local d = n - (snapshot[id] or 0)
      if d > 0 then s.items[id] = (s.items[id] or 0) + d end
    end
  end
  snapshot = now
end

local function tick()
  if s and s.running and not s.paused then
    local t = C.Clock()
    s.elapsed = s.elapsed + (t - s.last)
    s.last = t
  end
end

function FT.Start(name)
  if s and s.running then Core.Print("a session is already running.") return end
  s = { running = true, paused = false, elapsed = 0, last = C.Clock(), money = 0, items = {},
        spot = (name and name ~= "") and name or (C.GetZone() or "Unknown"), started = C.Now() }
  snapshot = C.GetBagCounts()
  lastMoney = C.GetMoney() or 0
  Core.Print("session started at " .. s.spot .. ".")
  FT.Refresh()
end

function FT.Pause()
  if not (s and s.running) then return end
  tick()
  s.paused = not s.paused
  s.last = C.Clock()
  if not s.paused then snapshot = C.GetBagCounts() end -- ignore anything gained while paused
  Core.Print(s.paused and "paused." or "resumed.")
  FT.Refresh()
end

function FT.Stop()
  if not (s and s.running) then Core.Print("no session running.") return end
  tick()
  if not C.InCombat() then FT.ApplyBagDiff() end
  local total, gph = FT.Totals(s, settings.valuation)
  local verdict = FT.Verdict(s.spot, gph, db.spots)
  if s.elapsed >= 60 then
    local sp = db.spots[s.spot]
    if not sp then sp = { sessions = {} }; db.spots[s.spot] = sp end
    local items = {}
    for id, n in pairs(s.items) do items[id] = n end
    table.insert(sp.sessions, { start = s.started, dur = math.floor(s.elapsed), copper = math.floor(total),
      coin = s.money, items = items })
    while #sp.sessions > MAX_SESSIONS_PER_SPOT do table.remove(sp.sessions, 1) end
  end
  s.running = false
  Core.Print(("%s: %s in %d min. %s"):format(s.spot, C.Money(total), math.floor(s.elapsed / 60), verdict))
  FT.Refresh()
end

-- ---------- display ----------
local frame
local function fmtTime(sec)
  sec = math.floor(sec)
  return ("%d:%02d:%02d"):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

function FT.Lines()
  if not s then return { "No session. Click Start or /goldspot start" } end
  tick()
  local total, gph, list = FT.Totals(s, settings.valuation)
  local state = s.paused and " (paused)" or (s.running and "" or " (stopped)")
  local lines = {
    ("%s%s  %s"):format(s.spot, state, fmtTime(s.elapsed)),
    ("Total %s   %s/hr"):format(C.Money(total), C.Money(gph)),
    "Coin " .. C.Money(s.money),
  }
  for i = 1, math.min(5, #list) do
    local e = list[i]
    lines[#lines + 1] = ("%dx %s  %s%s%s"):format(e.n, C.GetItemName(e.id) or ("item " .. e.id), C.Money(e.v),
      e.src == "vendor" and " (v)" or (e.src == "old" and " (old)" or ""), FT.Extras(e.id))
  end
  if list.flagged > 0 and settings.valuation ~= "vendor" then
    lines[#lines + 1] = ("|cffffd100%d %s|r"):format(list.flagged, L["items valued at vendor price or an old AH price: (v) / (old)"])
  end
  lines[#lines + 1] = "|cff99ccff" .. FT.Verdict(s.spot, gph, db.spots) .. "|r"
  return lines
end

-- Data our other addons own, shown only when they have it: NeutralFlip's best flip, MatTooltip's verdict.
function FT.Extras(itemID)
  local out = ""
  local verdict = Hub.Ask("verdict", itemID)
  if verdict then out = out .. " [" .. verdict .. "]" end
  local flip = Hub.Ask("flip", itemID)
  if flip then out = out .. (" |cff33ff99%s %s>%s +%s|r"):format(L["flip"], flip.from, flip.to, C.Money(flip.profit)) end
  return out
end

-- Best gold/hour per spot (sessions of 5+ minutes), best first.
function FT.SpotBoard(spots)
  local board = {}
  for name, sp in pairs(spots) do
    local best, n = nil, 0
    for _, h in ipairs(sp.sessions) do
      if h.dur >= MIN_BEST_SECONDS then
        n = n + 1
        local r = h.copper * 3600 / h.dur
        if not best or r > best then best = r end
      end
    end
    if best then board[#board + 1] = { spot = name, gph = best, n = n } end
  end
  table.sort(board, function(a, b) if a.gph ~= b.gph then return a.gph > b.gph end return a.spot < b.spot end)
  return board
end

-- Current session for the LDB display: total, gold/hour, spot, state ("running", "paused", "stopped") or nil.
function FT.Current()
  if not s then return nil end
  tick()
  local total, gph = FT.Totals(s, settings.valuation)
  return total, gph, s.spot, s.paused and "paused" or (s.running and "running" or "stopped")
end

local function button(parent, text, x, fn)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(56, 20)
  b:SetPoint("BOTTOMLEFT", x, 8)
  b:SetText(text)
  b:SetScript("OnClick", fn)
  return b
end

function FT.StateLines()
  local n = 0
  for _ in pairs(db.spots) do n = n + 1 end
  return { "schema " .. tostring(db.schema), "saved spots " .. n, "valuation " .. settings.valuation,
    "session " .. (s and (s.spot .. ", " .. fmtTime(s.elapsed) .. (s.running and "" or " (stopped)")) or "none"),
    "PriceLog " .. tostring(KennyPriceLog ~= nil) .. ", MatTooltip " .. tostring(KennyMatTooltip ~= nil) }
end

-- Default spot: left-middle of the screen, clear of the minimap, quest tracker and guide frames
-- (top-right) and action bars (bottom). Movable, clamped, saved per account; /goldspot resetpos.
local DEFAULT_POINT = { "LEFT", 24, 40 }

function FT.Place()
  local p = db.point or DEFAULT_POINT
  frame:ClearAllPoints()
  frame:SetPoint(p[1], UIParent, p[1], p[2], p[3])
end

function FT.BuildFrame()
  frame = CreateFrame("Frame", "KennyGoldPerSpotFrame", UIParent, "BackdropTemplate")
  frame:SetSize(250, 170)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  FT.Place()
  frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  frame:SetBackdropColor(0, 0, 0, 0.75)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) if not settings.locked then self:StartMoving() end end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, _, x, y = self:GetPoint()
    db.point = { p, x, y }
  end)
  frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.text:SetPoint("TOPLEFT", 10, -10)
  frame.text:SetPoint("RIGHT", -10, 0)
  frame.text:SetJustifyH("LEFT")
  button(frame, "Start", 8, function() FT.Start() end)
  button(frame, "Pause", 66, function() FT.Pause() end)
  button(frame, "Stop", 124, function() FT.Stop() end)
  button(frame, "Bug", 186, function() Core.ShowReport(FT.StateLines()) end)
end

-- One 1-second ticker, alive only while a session is running (not paused, not stopped, no session: no timer).
local ticker
function FT.SyncTicker()
  local want = s and s.running and not s.paused
  if want and not ticker then
    ticker = C_Timer.NewTicker(1, function() Core.SafeCall("refresh", FT.Refresh) end)
  elseif not want and ticker then
    ticker:Cancel(); ticker = nil
  end
  return ticker ~= nil
end

function FT.Refresh()
  if frame and frame:IsShown() then frame.text:SetText(table.concat(FT.Lines(), "\n")) end
  if ns.panelRefresh then ns.panelRefresh() end
  FT.SyncTicker()
end

-- ---------- events ----------
local ev = CreateFrame("Frame")
local suspendOpen = { MERCHANT_SHOW = true, MAIL_SHOW = true, BANKFRAME_OPENED = true, TRADE_SHOW = true, AUCTION_HOUSE_SHOW = true }
local suspendClose = { MERCHANT_CLOSED = true, MAIL_CLOSED = true, BANKFRAME_CLOSED = true, TRADE_CLOSED = true, AUCTION_HOUSE_CLOSED = true }
for _, e in ipairs({ "ADDON_LOADED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED", "PLAYER_MONEY", "LOOT_OPENED", "LOOT_CLOSED",
  "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
  "TRADE_SHOW", "TRADE_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do ev:RegisterEvent(e) end

local function onEvent(event, arg1)
  if event == "BAG_UPDATE_DELAYED" then
    if C.InCombat() then pendingBags = true else FT.ApplyBagDiff() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if pendingBags then pendingBags = false; FT.ApplyBagDiff() end
  elseif event == "LOOT_OPENED" then lootOpen = true
  elseif event == "LOOT_CLOSED" then lootOpen = false
  elseif event == "PLAYER_MONEY" then
    local m = C.GetMoney()
    if not m then return end
    local d = m - lastMoney
    lastMoney = m
    if d > 0 and lootOpen and s and s.running and not s.paused then s.money = s.money + d end
  elseif suspendOpen[event] then
    if not C.InCombat() then FT.ApplyBagDiff() end -- count loot gained before the window opened
    suspended = suspended + 1
  elseif suspendClose[event] then
    suspended = math.max(0, suspended - 1)
    if suspended == 0 then snapshot = C.GetBagCounts() end -- buys/mail/trades don't count as loot
  end
  return arg1
end

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    db = Core.Migrate(KennyGoldPerSpotDB, migrations, SCHEMA)
    db.spots = db.spots or {}
    KennyGoldPerSpotDB = db
    settings = Core.Settings(db.settings, DEFAULTS)
    FT.BuildFrame()
    frame:SetShown(settings.shown and not Hub.HasHost()) -- inside DEB's window when DEB hosts panels
    FT.Refresh()
    lastMoney = C.GetMoney() or 0
    return
  end
  if db then Core.SafeCall(event, onEvent, event, arg1) end
end)

-- A panel in DEB's window when DEB hosts panels (the small window stays hidden then).
local panel = ns.Hub.RegisterPanel(ADDON, "Interface\\AddOns\\GoldPerSpot\\media\\icon", function(parent)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", 8, -8); fs:SetPoint("RIGHT", -8, 0); fs:SetJustifyH("LEFT")
  ns.panelRefresh = function() if parent:IsVisible() then fs:SetText(table.concat(FT.Lines(), "\n")) end end
  ns.panelRefresh()
  return ns.panelRefresh
end, { title = "Gold per spot" })
FT.Panel = panel

Core.Setup({ cmd = "/goldspot",
  required = { "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemInfo", "C_Item.GetItemInfo", "C_Timer.NewTicker" },
  optional = { "KennyPriceLog", "KennyMatTooltip", "KennyNeutralFlip", "LibStub" },
  db = function() return db end,
  firstRun = { L["Welcome! GoldPerSpot measures gold per hour at each farming spot."],
    L["/goldspot start <spot name> when you begin, stop when you are done; /goldspot spots ranks your spots."],
    L["Items are valued at AH price (from PriceLog or MatTooltip, if installed) or vendor price. /goldspot debug checks your setup."] },
  debugLines = function()
    local n = 0
    for _ in pairs(db and db.spots or {}) do n = n + 1 end
    return { ("%s: %d, %s: %s, %s: %s"):format(L["saved spots"], n, L["valuation"], settings and settings.valuation or "?",
      L["timer running"], tostring(ticker ~= nil)) }
  end })

SLASH_KENNYGOLDPERSPOT1 = "/goldspot"
SLASH_KENNYGOLDPERSPOT2 = "/kspot"
SlashCmdList.KENNYGOLDPERSPOT = function(msg)
  local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "start" then FT.Start(rest)
  elseif cmd == "pause" or cmd == "resume" then FT.Pause()
  elseif cmd == "stop" then FT.Stop()
  elseif cmd == "show" then
    settings.shown = true
    if Hub.ShowPanel(ADDON) then frame:Hide() else frame:Show() end
    FT.Refresh()
  elseif cmd == "hide" then settings.shown = false; frame:Hide()
  elseif cmd == "spots" then
    local board = FT.SpotBoard(db.spots)
    if #board == 0 then Core.Print(L["no spot has a session of 5 minutes or more yet."]) return end
    for i = 1, math.min(10, #board) do
      local e = board[i]
      Core.Print(("%d. %s  %s/hr  (%d %s)"):format(i, e.spot, C.Money(e.gph), e.n, L["sessions"]))
    end
  elseif cmd == "debug" then Core.PrintDebug()
  elseif cmd == "lock" then settings.locked = not settings.locked; Core.Print(settings.locked and "frame locked." or "frame unlocked.")
  elseif cmd == "resetpos" then db.point = nil; FT.Place()
  elseif cmd == "value" and (rest == "ah" or rest == "vendor") then settings.valuation = rest; Core.Print("valuing items at " .. rest .. " price."); FT.Refresh()
  elseif cmd == "history" then
    local all = {}
    for name, sp in pairs(db.spots) do for _, h in ipairs(sp.sessions) do all[#all + 1] = { name = name, h = h } end end
    table.sort(all, function(a, b) return a.h.start > b.h.start end)
    if #all == 0 then Core.Print("no saved sessions.") return end
    for i = 1, math.min(10, #all) do
      local e = all[i]
      Core.Print(("%s  %s  %d min  %.1fg/hr"):format(date("%m-%d %H:%M", e.h.start), e.name, math.floor(e.h.dur / 60), e.h.copper * 3600 / e.h.dur / 10000))
    end
  elseif cmd == "report" then Core.ShowReport(FT.StateLines())
  elseif cmd == "reset" and rest == "confirm" then db.spots = {}; Core.Print("history cleared.")
  else
    Core.Print("/goldspot start [spot] | pause | resume | stop | show | hide | lock | resetpos | history | spots | value ah|vendor | debug | report | reset confirm")
  end
end
