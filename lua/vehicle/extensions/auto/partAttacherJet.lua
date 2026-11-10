-- Part Attacher (vehicle side) - mod author: Kavencki - Giedrius P. (c) 2026. jet car.
-- With the GE side's jet car on (v.data.upaJet), the attached rocket (the game's JATO controller)
-- burns with the throttle, like the 1950s jet and turbine cars: its input (electrics jatoInput,
-- 0..1, the thrust goes with it) follows W, forward gears and neutral only (not in reverse). The
-- rocket key (Alt+J, electrics upaRocketKey) still fires it at full while held.
-- Loads for every vehicle (extensions/auto) and does nothing on cars without upaJet.

local M = {}

local on = false
local last = 0 -- the input the last frame

local function onExtensionLoaded()
  on = v.data ~= nil and type(v.data.upaJet) == 'table' and v.data.upaJet.on == true
  last = 0
  electrics.values.upaRocketKey = 0
end

local function onReset()
  last = 0
  electrics.values.upaRocketKey = 0
end

-- runs after the controllers: the JATO takes this input on the next frame
local function updateGFX(dt)
  if not on then return end
  local e = electrics.values
  local t = 0
  if (tonumber(e.gearIndex) or 0) >= 0 then t = math.max(0, math.min(1, tonumber(input.throttle) or 0)) end
  if t < 0.02 then t = 0 end
  local want = math.max(t, (e.upaRocketKey or 0) > 0 and 1 or 0)
  -- the JATO sets its sound's volume once, when it lights: it lights at full (one frame), then
  -- follows the pedal - else a gently pressed W would light it almost silent for the whole burn
  if want > 0 and last <= 0 then want = 1 end
  e.jatoInput = want
  last = want
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

return M
