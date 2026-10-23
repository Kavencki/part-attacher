-- Part Attacher Experimental (vehicle side) - mod author: Kavencki - Giedrius P. (c) 2026. settle time after a spawn / reset of a car with swapped parts.
-- The GE side loaded every beam unbreakable and undeformable (originals kept in upaDeform /
-- upaStrength); once the car has settled on its new parts, the original values come back.
-- Loads for every vehicle (extensions/auto) and does nothing on cars without partAttacherExpSettle.

local M = {}

local timer

local function original(value, optionValue)
  if type(value) == 'number' then return value end
  local n = tonumber(value)
  if n then return n end
  return tonumber(optionValue)
end

local function forEachSettleBeam(fn)
  local count = 0
  for _, b in pairs(v.data.beams or {}) do
    if type(b) == 'table' and type(b.cid) == 'number' and b.upaDeform ~= nil then
      fn(b)
      count = count + 1
    end
  end
  return count
end

local function restore()
  local options = type(v.data.options) == 'table' and v.data.options or {}
  local count = forEachSettleBeam(function(b)
    local deform = original(b.upaDeform, options.beamDeform)
    local strength = original(b.upaStrength, options.beamStrength) or math.huge
    if deform then obj:setBeamDeform(b.cid, deform) end
    obj:setBeamStrength(b.cid, strength)
  end)
  log('I', 'partAttacherExp', 'settle time over, damage back on for ' .. count .. ' beams')
end

local function settleTime()
  return v.data and tonumber(v.data.partAttacherExpSettle) or nil
end

local function onExtensionLoaded()
  timer = settleTime()
end

-- R puts the car back as it spawned: protect it again while it settles
local function onReset()
  timer = settleTime()
  if timer then
    forEachSettleBeam(function(b)
      obj:setBeamDeform(b.cid, math.huge)
      obj:setBeamStrength(b.cid, math.huge)
    end)
  end
end

local function updateGFX(dt)
  if not timer then return end
  timer = timer - dt
  if timer <= 0 then
    timer = nil
    restore()
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

return M
