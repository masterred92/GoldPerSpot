-- LibDataBroker display (Titan Panel, ChocolateBar, Bazooka...): gold/hour of the current session.
local _, ns = ...
local FT = KennyGoldPerSpot
local C = ns.Compat
local obj

function FT.UpdateBroker()
  if not obj then return end
  local total, gph, _, state = FT.Current()
  if not total then obj.text = "no session" return end
  obj.text = C.Money(gph) .. "/hr" .. (state == "running" and "" or (" (" .. state .. ")"))
end

function FT.InstallBroker()
  if obj then return obj end
  -- One shared "Kenny's addons" entry with a menu when several of our addons are installed; our own entry when alone.
  obj = ns.Hub.Launcher("GoldPerSpot", {
    leftHint = "Show/hide window", rightHint = "Start, pause or resume",
    type = "data source", text = "GoldPerSpot", label = "Gold/hr",
    icon = "Interface\\AddOns\\GoldPerSpot\\media\\icon",
    OnClick = function(_, button)
      if button == "RightButton" then
        local _, _, _, state = FT.Current()
        if state == "running" or state == "paused" then FT.Pause() else FT.Start("") end
      else
        local shown = KennyGoldPerSpotFrame and KennyGoldPerSpotFrame:IsShown()
        SlashCmdList.KENNYGOLDPERSPOT(shown and "hide" or "show")
      end
    end,
    OnTooltipShow = function(tt)
      tt:AddLine("GoldPerSpot")
      for _, line in ipairs(FT.Lines()) do tt:AddLine(line, 1, 1, 1) end
      tt:AddLine("Left-click: show/hide the window. Right-click: start, or pause/resume.", 0.6, 0.6, 0.6, true)
    end,
  })
  FT.UpdateBroker()
  return obj
end

-- Follow every window refresh, so the text stays in step with the session.
local refresh = FT.Refresh
FT.Refresh = function(...)
  refresh(...)
  FT.UpdateBroker()
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() FT.InstallBroker() end)
-- No timer of its own: FT.Refresh runs every second while a session is running, and on every start/pause/stop.
