-- Part Attacher (vehicle side) - mod author: Kavencki - Giedrius P. (c) 2026. lowrider hydraulics.
-- The GE side gave every wheel a hydraulic cylinder (a hydro on electrics upa_hyd_<wheel>, -1..1 of
-- its travel) and listed the wheels in v.data.upaHydraulics. The keys (input actions, while held)
-- set upaHydFront / upaHydRear / upaHydRoll / upaHydAll to -1 or 1 and upaHydHop to 1; every
-- corner's height moves by them, a hop pushes all cylinders out at once until the key is let go.
-- The sound is the game's own lowrider hydraulics' (Bluebuck, Grand Marshal): the pump whines
-- while a cylinder goes out, the release valve hisses while one comes in - from the trunk.
-- upaHydDance = 1 starts the Maybach dance (the bounce of an active suspension's "free driving"
-- mode): 5 s of the whole body bouncing, then the corners go back where they were.
-- Loads for every vehicle (extensions/auto) and does nothing on cars without upaHydraulics.

local M = {}

local cfg
local height = {} -- wheel name -> its cylinder's place, -1..1

-- the sound: the cylinders (the game's hydros) and where each was the last frame
local pumpSound, releaseSound, pumping
local releaseSmoother
local cylinders, lastState, searches = {}, {}, 0

-- the Maybach dance: seconds left, time into it; a beat is one smooth up and down (a sine wave),
-- all four corners together (the body stays level), easing in from the corners' heights and back
-- to them over DANCE_FADE seconds. Meanwhile the fastest cylinder may move at DANCE_RATE (the
-- others in the same proportion, the GE side made them equally fast in m/s): enough to follow the
-- wave, so the cylinders never hit their speed limit and jerk
local DANCE_TIME, DANCE_BEAT, DANCE_RATE, DANCE_FADE = 5, 0.9, 8, 0.4
local dance, danceT = 0, 0

local function clear()
  height = {}
  for _, w in ipairs(cfg and cfg.wheels or {}) do
    height[w.name] = 0
    electrics.values['upa_hyd_' .. w.name] = 0
  end
  for _, key in ipairs({'upaHydFront', 'upaHydRear', 'upaHydRoll', 'upaHydAll', 'upaHydHop', 'upaHydReset', 'upaHydDance'}) do
    electrics.values[key] = 0
  end
end

-- a beat is too short for the cylinders' own speed: the game's hydros module reads inRate / outRate
-- every frame, so they go faster while the dance lasts and get their own speed back after it
local function setDanceRates(on)
  local fastest = 0
  for _, h in ipairs(cylinders) do
    local r = h.upaRates or {h.inRate, h.outRate}
    fastest = math.max(fastest, tonumber(r[1]) or 0, tonumber(r[2]) or 0)
  end
  local k = fastest > 0 and math.max(1, DANCE_RATE / fastest) or 1
  for _, h in ipairs(cylinders) do
    if on then
      h.upaRates = h.upaRates or {h.inRate, h.outRate}
      h.inRate = (tonumber(h.upaRates[1]) or 0) * k
      h.outRate = (tonumber(h.upaRates[2]) or 0) * k
    elseif h.upaRates then
      h.inRate, h.outRate = h.upaRates[1], h.upaRates[2]
      h.upaRates = nil
    end
  end
end

local function stopDance()
  dance, danceT = 0, 0
  setDanceRates(false)
end

local function stopSounds()
  if pumpSound and pumping then obj:stopSFX(pumpSound) end
  pumping = false
  if releaseSound then obj:setVolumePitch(releaseSound, 0, 1) end
  if releaseSmoother then releaseSmoother:reset() end
  lastState = {}
end

local function initSounds()
  local node = cfg and tonumber(cfg.soundNode)
  if not node then return end
  local ok = pcall(function()
    pumpSound = obj:createSFXSource2('event:>Vehicle>Hydraulics>Pump_01', 'AudioDefaultLoop3D', '', node, 0)
    releaseSound = obj:createSFXSource('event:>Vehicle>Hydraulics>Release_01', 'AudioDefaultLoop3D', '', node)
    obj:setVolumePitch(releaseSound, 0, 1)
  end)
  if not ok then pumpSound, releaseSound = nil, nil end
  releaseSmoother = newTemporalSmoothing(4, 3)
  pumping = false
end

-- our cylinders among the game's hydros (by their input): their state is the cylinder's real length,
-- so a hop, the relief valve giving way and the end of the travel sound right too
local function findCylinders()
  cylinders = {}
  local mine = {}
  for _, w in ipairs(cfg.wheels) do mine['upa_hyd_' .. w.name] = true end
  for _, h in ipairs(hydros and type(hydros.hydros) == 'table' and hydros.hydros or {}) do
    if type(h) == 'table' and mine[h.inputSource] then cylinders[#cylinders + 1] = h end
  end
end

local function onExtensionLoaded()
  cfg = v.data and type(v.data.upaHydraulics) == 'table' and v.data.upaHydraulics or nil
  clear()
  if cfg then initSounds() end
end

-- R puts the car back as it spawned: the cylinders too
local function onReset()
  stopDance()
  clear()
  stopSounds()
end

local function updateSounds(dt)
  if not (pumpSound or releaseSound) then return end
  local up, down, count = 0, 0, #cylinders
  for _, h in ipairs(cylinders) do
    local s = tonumber(h.state) or 1
    local last = lastState[h] or s
    if s > last + 1e-5 then up = up + 1 elseif s < last - 1e-5 then down = down + 1 end
    lastState[h] = s
  end
  if count == 0 then return end
  if pumpSound then
    if up > 0 then
      obj:setVolumePitch(pumpSound, 0.6, 0.4 + 0.6 * up / count)
      if not pumping then
        obj:cutSFX(pumpSound)
        obj:playSFX(pumpSound)
        pumping = true
      end
    elseif pumping then
      obj:stopSFX(pumpSound)
      pumping = false
    end
  end
  if releaseSound and releaseSmoother then
    local vol = releaseSmoother:getUncapped(down > 0 and math.sqrt(down / count) or 0, dt)
    obj:setVolumePitch(releaseSound, vol, 1)
  end
end

local function updateGFX(dt)
  if not cfg then return end
  if #cylinders == 0 and searches < 120 then
    searches = searches + 1
    findCylinders()
  end
  local e = electrics.values
  if (e.upaHydReset or 0) > 0 then
    stopDance()
    clear()
  end
  -- the dance key / button: starts it, pressed again while it lasts stops it
  if (e.upaHydDance or 0) > 0 then
    e.upaHydDance = 0
    if dance > 0 then
      stopDance()
    else
      dance, danceT = DANCE_TIME, 0
      setDanceRates(true)
    end
  end
  if dance > 0 then
    dance = dance - dt
    danceT = danceT + dt
    if dance <= 0 then stopDance() end
  end
  local rate = (tonumber(cfg.rate) or 0.6) * dt
  local hop = (e.upaHydHop or 0) > 0
  local front, rear, roll, all = e.upaHydFront or 0, e.upaHydRear or 0, e.upaHydRoll or 0, e.upaHydAll or 0
  for _, w in ipairs(cfg.wheels) do
    -- roll + leans to the left: the right side comes up, the left one goes down
    local want = (w.front and front or rear) + (w.left and -roll or roll) + all
    local h = math.max(-1, math.min(1, (height[w.name] or 0) + want * rate))
    height[w.name] = h
    local out = hop and 1 or h
    if dance > 0 then
      -- a smooth wave, faded in from the corner's height and back to it at the end (no jumps)
      local env = math.max(0, math.min(1, danceT / DANCE_FADE, dance / DANCE_FADE))
      local wave = math.sin(2 * math.pi * danceT / DANCE_BEAT)
      out = out + (wave - out) * env
    end
    e['upa_hyd_' .. w.name] = out
  end
  updateSounds(dt)
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

return M
