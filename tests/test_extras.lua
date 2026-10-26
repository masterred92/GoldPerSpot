package.path = "tests/?.lua;" .. package.path
local W = require("mock_wow"); W.install()
local check = W.check
local ldbObjs = {}
LibStub = setmetatable({}, { __call = function(_, name, silent) if name == "LibDataBroker-1.1" then return { NewDataObject = function(_, n, o) ldbObjs[n] = o; return o end } end assert(silent) end })
local tt = { lines = {} }
function tt:AddLine(s) self.lines[#self.lines + 1] = tostring(s) end
function tt:AddDoubleLine(a, b) self.lines[#self.lines + 1] = tostring(a) .. ": " .. tostring(b) end
local function ttText(o) tt.lines = {}; o.OnTooltipShow(tt); return table.concat(tt.lines, " | ") end
W.loadAddon(".", "GoldPerSpot")
W.fire("PLAYER_LOGIN")
local FT = KennyGoldPerSpot
local o = ldbObjs.GoldPerSpot
check(o and o.text == "no session", "LDB object, no session")
o.OnClick(nil, "RightButton")
check(select(4, FT.Current()) == "running", "right-click starts a session")
W.clock = W.clock + 3600; FT.Refresh()
check(o.text:find("/hr") and not o.text:find("paused"), "LDB text shows gold/hour")
o.OnClick(nil, "RightButton")
check(o.text:find("paused"), "right-click pauses")
check(ttText(o):find("Total"), "LDB tooltip shows the session")
W.done("GoldPerSpot extras")
