-- Part Attacher (vehicle side) - mod author: Kavencki - Giedrius P. (c) 2026. indestructible engine,
-- unkillable clutch, extreme radiator (the GE side's switches: v.data.upaIndestructibleEngine,
-- upaUnkillableClutch, upaExtremeRadiator).
-- Engine: the game damages an engine through four of its device's functions: lockUp (over-revving,
-- over-torque, water / hydrolock, friction over its torque), onBreak (a crash breaking its trigger
-- beam), scaleOutputTorque (valve hits, a blown head gasket, damaged piston rings) and scaleFriction /
-- scaleFrictionInitial (overheated oil, a melted block or cylinder walls, oil starvation). For these
-- engines they do nothing. Running out of fuel and the ignition still stop the engine.
-- Clutch: a friction clutch slips once the torque through it passes its lockTorque (less when hot,
-- worn or damaged) and burns at 500 C. Its lockTorque goes up to 3x the engine's top torque (plus
-- the engine's spin), its sticking angle with it (as the game sizes it), and it never heats, wears or
-- gets damaged. A DCT's two clutches too. A torque converter slips by design (that is how an
-- automatic pulls away): it stays.
-- Radiator: the engine's coolant, oil, block and cylinder walls never get hotter than a healthy
-- warm engine, whatever the load, the damage or the lost coolant.
-- Loads for every vehicle (extensions/auto) and does nothing on cars without these switches.

local M = {}

local wantEngine, wantClutch, wantRadiator = false, false, false
local engines, clutches = {}, {} -- device -> true
local engineCount = 0
local searchTimer = 0

local function noop() end

local function getEngines()
  if not (powertrain and powertrain.getDevicesByCategory) then return {} end
  local ok, devs = pcall(powertrain.getDevicesByCategory, 'engine')
  return ok and type(devs) == 'table' and devs or {}
end

-- the strongest engine's torque and spin: what a clutch behind it has to hold
local function engineLoad()
  local top = 0
  for _, e in pairs(getEngines()) do
    if type(e) == 'table' then
      local t = type(e.torqueData) == 'table' and tonumber(e.torqueData.maxTorque) or tonumber(e.maxTorque) or 0
      local spin = (tonumber(e.maxRPM) or 0) * (tonumber(e.inertia) or 0) * math.pi / 30
      top = math.max(top, t * 3 + spin)
    end
  end
  return top
end

local function guardEngines()
  for _, d in pairs(getEngines()) do
    if type(d) == 'table' and d.lockUp ~= noop then
      d.lockUp, d.onBreak = noop, noop
      d.scaleOutputTorque, d.scaleFriction, d.scaleFrictionInitial = noop, noop, noop
      if not engines[d] then
        engines[d] = true
        engineCount = engineCount + 1
        log('I', 'partAttacher', 'indestructible engine: ' .. tostring(d.name))
      end
    end
  end
end

local function guardClutches()
  if not (powertrain and powertrain.getDevices) then return end
  local ok, devs = pcall(powertrain.getDevices)
  if not ok or type(devs) ~= 'table' then return end
  local load = engineLoad()
  if load <= 0 then return end -- the engine's torque isn't known yet: next time
  for _, d in pairs(devs) do
    if type(d) == 'table' and (d.type == 'frictionClutch' or d.type == 'dctGearbox') and type(d.lockTorque) == 'number' then
      d.applyDeformGroupDamage = noop
      if d.lockTorque < load then
        d.lockTorque = load
        -- the angle it sticks within grows with its torque, as the game sizes it
        if d.type == 'frictionClutch' and type(d.lockSpring) == 'number' and d.lockSpring > 0 then
          local r = load / d.lockSpring
          d.maxClutchAngle = math.sqrt(r) + math.max(r - 1, 0)
        elseif d.type == 'dctGearbox' then
          if type(d.lockSpring1) == 'number' and d.lockSpring1 > 0 then d.maxClutchAngle1 = load / d.lockSpring1 end
          if type(d.lockSpring2) == 'number' and d.lockSpring2 > 0 then d.maxClutchAngle2 = load / d.lockSpring2 end
        end
        log('I', 'partAttacher', string.format('unkillable clutch: %s holds %d Nm', tostring(d.name), math.floor(load)))
      end
      clutches[d] = true
    end
  end
end

local function onExtensionLoaded()
  local data = v.data or {}
  wantEngine = data.upaIndestructibleEngine == true
  wantClutch = data.upaUnkillableClutch == true
  wantRadiator = data.upaExtremeRadiator == true
  engines, clutches, engineCount, searchTimer = {}, {}, 0, 0
end

-- R puts the car back as it spawned: the guards stay on its devices, looked over again
local function onReset()
  searchTimer = 0
end

local function updateGFX(dt)
  if not (wantEngine or wantClutch or wantRadiator) then return end
  -- the devices may come after this extension, or anew: looked for now and then
  searchTimer = searchTimer - dt
  if searchTimer <= 0 then
    searchTimer = 1
    if wantEngine then guardEngines() end
    if wantClutch then guardClutches() end
  end
  if wantEngine then
    -- what damage piled up (over-revving, over-torque, water in it) goes back to none
    for d, _ in pairs(engines) do
      if type(d.overRevDamage) == 'number' then d.overRevDamage = 0 end
      if type(d.overTorqueDamage) == 'number' then d.overTorqueDamage = 0 end
      if type(d.floodLevel) == 'number' then d.floodLevel = 0 end
    end
  end
  if wantClutch then
    for d, _ in pairs(clutches) do
      if type(d.clutchTemperature) == 'number' and d.clutchTemperature > 120 then d.clutchTemperature = 120 end
      d.clutchPermanentlyDamaged = false
      for _, key in ipairs({'damageLockTorqueCoef', 'damageClutchFreePlayCoef', 'wearLockTorqueCoef', 'wearClutchFreePlayCoef'}) do
        if type(d[key]) == 'number' then d[key] = 1 end
      end
    end
  end
  if wantRadiator then
    for _, e in pairs(getEngines()) do
      local th = type(e) == 'table' and e.thermals
      if type(th) == 'table' then
        -- a healthy warm engine at most (the game damages it from 120 C coolant, 140 C block,
        -- 150 C oil, 160 C cylinder walls)
        if type(th.coolantTemperature) == 'number' and th.coolantTemperature > 95 then th.coolantTemperature = 95 end
        if type(th.oilTemperature) == 'number' and th.oilTemperature > 110 then th.oilTemperature = 110 end
        if type(th.engineBlockTemperature) == 'number' and th.engineBlockTemperature > 105 then th.engineBlockTemperature = 105 end
        if type(th.cylinderWallTemperature) == 'number' and th.cylinderWallTemperature > 130 then th.cylinderWallTemperature = 130 end
        for _, key in ipairs({'engineBlockOverheatDamage', 'oilOverheatDamage', 'cylinderWallOverheatDamage'}) do
          if type(th[key]) == 'number' then th[key] = 0 end
        end
      end
    end
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX

return M
