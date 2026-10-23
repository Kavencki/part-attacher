-- Part Attacher Experimental (GE side) - mod author: Kavencki - Giedrius P. (c) 2026, all rights reserved
-- Put any jbeam part of any vehicle model onto any vehicle.
--
-- 1. Preview: the part is spawned as a temporary "ghost" object (config.mainPartName = part) and
--    held in the air relative to your car while you move it with the sliders.
-- 2. Attach: the ghost is deleted and your car is respawned with the part merged INTO its own
--    jbeam: an extra slot on the main part (moved/rotated with jbeam nodeMove/nodeRotate) plus
--    weld beams to the nearest body nodes, created at their current length so nothing is pulled.
--    The part is then a real part of the car (survives reset, shows in the parts tree).
--
-- Open/close the window: Ctrl+Shift+U (rebindable in Options > Controls > Gameplay)
-- or from the console: partAttacherExp.toggleWindow()

local M = {}
M.dependencies = {'ui_imgui'}

local logTag = 'partAttacherExp'
-- ImGui, with every text that reaches the screen going through the translation (see L below)
local im = setmetatable({}, {__index = ui_imgui})
local ffi = require('ffi')
local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')

local maxListedParts = 400
local extraSlotPrefix = 'upa_extra_'
local extraSlotType = 'upa_extra'
local swapAlias = 'upa_engine_swap' -- part name the swapped-in engine gets inside the car
local gearboxAlias = 'upa_gearbox_swap' -- same for a swapped-in gearbox

-- UI state
-- UI and list state lives in one table: Lua allows at most 200 locals in a chunk
local S = {}

-- everything the mod logs while a modded car loads also goes to its own file
-- (settings/partAttacherExp/last_load.log): an exploding car can fill the game log past its limit, and
-- the game then cuts exactly the part that tells what went wrong
local gameLog = log
local function log(level, tag, text)
  gameLog(level, tag, text)
  if S.diag then S.diag[#S.diag + 1] = string.format('%s %s', tostring(level), tostring(text)) end
end

--------------------------------------------------------------------------------
-- language: the UI is written in Lithuanian, English comes from partAttacherExp/lang.lua. Every text
-- that reaches the screen (ImGui labels, tooltips, messages) goes through L(). A text with values
-- in it matches a key with %s / %d placeholders; the values are kept (and translated when they are
-- UI words themselves). ImGui "##id" endings stay as they are. Results are cached.
--------------------------------------------------------------------------------

S.version = 'v1.1 experimental MP test'
S.settingsFile = '/settings/partAttacherExp/settings.json'
S.lang = 'en' -- English by default
pcall(function()
  local saved = jsonReadFile(S.settingsFile)
  if type(saved) == 'table' and (saved.lang == 'en' or saved.lang == 'lt') then S.lang = saved.lang end
end)
S.trExact, S.trPatterns, S.trCache, S.trCacheSize = {}, {}, {}, 0
pcall(function()
  local okLang, dict = pcall(require, 'ge/extensions/partAttacherExp/lang')
  for key, en in pairs(okLang and type(dict) == 'table' and dict.en or {}) do
    if key:find('%', 1, true) then
      -- format string -> anchored Lua pattern, every placeholder a capture
      local pat, i = {'^'}, 1
      while i <= #key do
        local c = key:sub(i, i)
        if c == '%' and key:sub(i + 1, i + 1) == '%' then
          pat[#pat + 1] = '%%'
          i = i + 2
        elseif c == '%' then
          local _, e = key:find('^[-+ #0-9.]*[a-zA-Z]', i + 1)
          pat[#pat + 1] = e and '(.-)' or '%%'
          i = (e or i) + 1
        else
          pat[#pat + 1] = c:find('[%^%$%(%)%.%[%]%*%+%-%?]') and ('%' .. c) or c
          i = i + 1
        end
      end
      pat[#pat + 1] = '$'
      -- the English text takes the captured texts back in, in the same order
      local fmt = en:gsub('%%%%', '\1'):gsub('%%[-+ #0-9.]*[a-zA-Z]', '%%s'):gsub('\1', '%%%%')
      S.trPatterns[#S.trPatterns + 1] = {pat = table.concat(pat), fmt = fmt, len = #key}
    else
      S.trExact[key] = en
    end
  end
  -- the longer (more specific) keys first
  table.sort(S.trPatterns, function(a, b) return a.len > b.len end)
end)

S.translate = function(text, depth)
  local exact = S.trExact[text]
  if exact then return exact end
  for _, p in ipairs(S.trPatterns) do
    local caps = {text:match(p.pat)}
    if caps[1] ~= nil then
      if depth < 2 then
        for i, c in ipairs(caps) do caps[i] = S.translate(c, depth + 1) end
      end
      local ok, res = pcall(string.format, p.fmt, unpack(caps))
      if ok then return res end
    end
  end
  return text
end

local function L(text)
  if S.lang ~= 'en' or type(text) ~= 'string' or text == '' then return text end
  local cached = S.trCache[text]
  if cached then return cached end
  local visible, id = text:match('^(.-)(##.*)$')
  if not visible then visible, id = text, '' end
  local res = (visible ~= '' and S.translate(visible, 0) or visible) .. id
  if S.trCacheSize > 5000 then S.trCache, S.trCacheSize = {}, 0 end
  S.trCache[text] = res
  S.trCacheSize = S.trCacheSize + 1
  return res
end

-- the ImGui calls that put a label on screen
for _, name in ipairs({'Button', 'SmallButton', 'Checkbox', 'TreeNode1', 'CollapsingHeader1', 'SetTooltip',
    'SliderFloat', 'InputFloat', 'InputInt', 'InputText', 'RadioButton2', 'Selectable1'}) do
  im[name] = function(label, ...) return ui_imgui[name](L(label), ...) end
end
im.BeginCombo = function(label, preview, ...) return ui_imgui.BeginCombo(L(label), L(preview), ...) end
im.TextColored = function(col, text, ...) return ui_imgui.TextColored(col, L(text), ...) end

S.setLanguage = function(lang)
  S.lang = lang
  S.trCache, S.trCacheSize = {}, 0
  pcall(function()
    if not FS:directoryExists('/settings/partAttacherExp/') then FS:directoryCreate('/settings/partAttacherExp/', true) end
    jsonWriteFile(S.settingsFile, {lang = lang}, true)
  end)
end

local showWindow = im.BoolPtr(false)
S.partSearchPtr = im.ArrayChar(128)
S.modelSearchPtr = im.ArrayChar(64)
S.noCollisionPtr = im.BoolPtr(false)
S.copyPaintPtr = im.BoolPtr(true)
S.maxWeldsPtr = im.IntPtr(10)
S.maxGapPtr = im.FloatPtr(0.3)
S.strengthPtr = im.FloatPtr(40000) -- per weld beam; BeamNG's own bumper mounts: 28000 N
S.unbreakablePtr = im.BoolPtr(false)
S.stepPtr = im.FloatPtr(0.02)
S.keepTransmissionPtr = im.BoolPtr(true)
S.engineMeshPtr = im.BoolPtr(true) -- logic engine swap: also show the donor engine mesh
S.autoDrivetrainPtr = im.BoolPtr(true)
S.dtLockFPtr, S.dtLockRPtr, S.dtLockCPtr = im.BoolPtr(false), im.BoolPtr(false), im.BoolPtr(false) -- lockable diffs
S.dtPartTimePtr, S.dtLowRangePtr, S.dtLowRatioPtr = im.BoolPtr(false), im.BoolPtr(false), im.FloatPtr(2.72) -- 2WD/4WD, low range
S.meshOnlyPtr = im.BoolPtr(false) -- extra part as its model only (static mesh, no physics)
S.autoFitPtr = im.BoolPtr(true) -- a new part goes where the car's own part of the same kind sits
S.settlePtr = im.BoolPtr(true) -- settle time after spawn / reset: no damage while new parts settle
S.settleSeconds = 2.5

-- universal drivetrain settings
local layouts = {'RWD', 'FWD', 'AWD'}
local diffTypes = {'open', 'lsd', 'viscous', 'locked'}
S.dtLayoutPtr = im.IntPtr(0)
S.dtDiffPtr = im.IntPtr(1)
S.dtCenterPtr = im.IntPtr(2)
S.dtSplitPtr = im.FloatPtr(0.4)
S.dtFinalPtr = im.FloatPtr(3.7)
local dtLoadedFor               -- vehicle id the UI settings were last read from

-- logic suspension settings per axle
local function newSuspUI() return {lift = im.FloatPtr(0), spring = im.FloatPtr(1), damp = im.FloatPtr(1), sway = im.FloatPtr(1), donor = nil} end
local suspUI = {F = newSuspUI(), R = newSuspUI()}
local suspLoadedFor            -- vehicle id the suspension sliders were last read from

-- S.modelList -- sorted array of {key, label}
-- S.selectedModel
-- S.partList -- sorted array of {name, label, lower}
-- S.partCategories -- folders of slots the model offers: {label, parts}
-- S.otherCategories -- folders of other (mostly /vehicles/common) slots
-- S.engineList -- engines of the model for the swap folder: {name, label}
-- S.gearboxList -- gearboxes of the model for the gearbox swap folder
-- S.suspLists -- {susp_F = {...}, susp_R = {...}} suspensions of the model
-- S.partListModel
-- S.selectedPartName
-- S.selectedIsEngine

local entries = {}         -- ghosts being positioned: [ghostVehId] = entry
local selectedEntryId
local pendingSpawn         -- {partName, model, targetId, time, preset} of the ghost being spawned

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function msg(text, ttl)
  text = L(text)
  ui_message(text, ttl or 5, 'partAttacherExp')
  log('I', logTag, text)
end

local function getVeh(id)
  return id and getObjectByID(id) or nil
end

local function getVData(id)
  local d = core_vehicle_manager.getVehicleData(id)
  return d and d.vdata
end

local function imText(s)
  im.Text((L(tostring(s)):gsub('%%', '%%%%')))
end

local function isWheelNode(vdata, cid)
  local n = vdata and vdata.nodes and vdata.nodes[cid]
  return type(n) == 'table' and n.wheelID ~= nil
end

-- same rotation jbeam "nodeRotate" uses (MatrixF euler of -x,-y,-z degrees), as a BeamNG quat
local function eulerToQuat(rx, ry, rz)
  local m = MatrixF(true)
  m:setFromEuler(vec3(math.rad(-rx), math.rad(-ry), math.rad(-rz)))
  local f = vec3(m:mulP3F(vec3(0, 1, 0)))
  local u = vec3(m:mulP3F(vec3(0, 0, 1)))
  return quatFromDir(f, u)
end

-- orthonormal frame quat from three points (dir = a->b, up = a->c)
local function frameQuat(pa, pb, pc)
  local d = (pb - pa):normalized()
  local u = pc - pa
  u = (u - d * u:dot(d)):normalized()
  return quatFromDir(d, u)
end

-- rotation that maps the vehicle's jbeam (initial) frame to its current world frame,
-- measured from three nodes. BeamNG quat order: (a * b) applies a first, then b.
local function nodeFrameRot(veh, a, b, c)
  local ia = vec3(veh:getInitialNodePosition(a))
  local ib = vec3(veh:getInitialNodePosition(b))
  local ic = vec3(veh:getInitialNodePosition(c))
  local wa = vec3(veh:getNodeAbsPosition(a))
  local wb = vec3(veh:getNodeAbsPosition(b))
  local wc = vec3(veh:getNodeAbsPosition(c))
  return frameQuat(ia, ib, ic):inversed() * frameQuat(wa, wb, wc), wa, ia
end

-- three well spread, non collinear nodes out of cids (initial positions)
local function pickAnchors(veh, cids)
  if #cids < 3 then return nil end
  local pos = {}
  local centroid = vec3()
  for _, cid in ipairs(cids) do
    local p = vec3(veh:getInitialNodePosition(cid))
    pos[cid] = p
    centroid = centroid + p
  end
  centroid = centroid / #cids

  local a, b, c
  local best = -1
  for cid, p in pairs(pos) do
    local d = p:squaredDistance(centroid)
    if d > best then best, a = d, cid end
  end
  best = -1
  for cid, p in pairs(pos) do
    local d = p:squaredDistance(pos[a])
    if d > best then best, b = d, cid end
  end
  if a == b or best < 1e-4 then return nil end
  local ab = (pos[b] - pos[a]):normalized()
  best = -1
  for cid, p in pairs(pos) do
    local r = p - pos[a]
    local perp = (r - ab * r:dot(ab)):squaredLength()
    if perp > best then best, c = perp, cid end
  end
  if best < 1e-4 then return nil end
  return a, b, c
end

local function validAnchors(veh, a, b, c, nodeCount)
  if type(a) ~= 'number' or type(b) ~= 'number' or type(c) ~= 'number' then return false end
  if a == b or a == c or b == c then return false end
  if a < 0 or b < 0 or c < 0 or a >= nodeCount or b >= nodeCount or c >= nodeCount then return false end
  local pa, pb, pc = vec3(veh:getInitialNodePosition(a)), vec3(veh:getInitialNodePosition(b)), vec3(veh:getInitialNodePosition(c))
  if pa:distance(pb) < 0.05 then return false end
  local ab = (pb - pa):normalized()
  local r = pc - pa
  return (r - ab * r:dot(ab)):length() > 0.05
end

--------------------------------------------------------------------------------
-- merging parts into a vehicle's jbeam (runs inside the jbeam loader)
--------------------------------------------------------------------------------

local origFindParts, origGetPart, origUnifyPartJournal
local pendingUnifySwaps     -- part swaps of the vehicle being loaded, used between findParts and unify
local pendingUnifyEngine    -- same for an engine swap (version 2, renamed tree)
local pendingUnifyLogic     -- logic engine swap (version 4+): donor tuning parts to strip
local injectCtx            -- set while findParts runs for a vehicle that has extra parts
local loadedMaterialDirs = {}

local function extraAlias(i)
  return 'upa_extra_part_' .. i
end

local function loadMaterialsDir(dir)
  if loadedMaterialDirs[dir] then return end
  loadedMaterialDirs[dir] = true
  for _, filename in ipairs(FS:findFiles(dir, '*materials.json\t*.cs', -1, true, false) or {}) do
    if filename:find('.json', 1, true) then
      loadJsonMaterialsFile(filename)
    elseif TorqueScriptLua then
      TorqueScriptLua.exec(filename)
    end
  end
end

-- rename the part's own nodes / groups / break groups so they can't clash with the car's
local noRenameKeys = {information = true, slotType = true, partName = true, slots = true, slots2 = true, variables = true, components = true}
-- columns never renamed: mesh names, and powertrain type / device name / input device
local meshColumns = {flexbodies = {[1] = true}, props = {[1] = true, [2] = true}, powertrain = {[1] = true, [2] = true, [3] = true}}

-- sections whose array rows start with node references (id1:, id2:, ...)
local nodeRefSections = {beams = true, hydros = true, triangles = true, quads = true, torsionbars = true}
local droppedRef = '__upa_dropped__'
-- values never renamed: coupler tags match another vehicle's tag (a pintle hitch's couplerTag
-- "pintle" is also its node and group name, a renamed one finds no trailer)
S.keepNameKeys = {couplerTag = true, tag = true, fifthwheelKey = true, kingpinKey = true}

S.wheelSections = {pressureWheels = true, wheels = true, hubWheels = true, monoHubWheels = true,
  hubWheelsTSV = true, hubWheelsTSI = true, pressureWheelsTSV = true}
-- wheel row columns / options naming the groups of the nodes the wheel generator makes
S.wheelGroupKeys = {group = true, hubGroup = true, hubcapGroup = true, hubcapBreakGroup = true, breakGroup = true}

-- own node / group / break group names of a part go into names
local function collectPartNames(part, names)
  local function collectName(v)
    if type(v) == 'string' and v ~= '' then names[v] = true
    elseif type(v) == 'table' then for _, s in ipairs(v) do if type(s) == 'string' and s ~= '' then names[s] = true end end end
  end
  -- the hub / tire / hubcap groups of generated wheels ("wheel_RR", "tire_RR"): with two axles of
  -- the same donor, a tire mesh would grab the other wheel's tire nodes too (stretched tires)
  for sectionName, _ in pairs(S.wheelSections) do
    local section = part[sectionName]
    if type(section) == 'table' and type(section[1]) == 'table' then
      local cols = {}
      for i, colName in ipairs(section[1]) do
        if S.wheelGroupKeys[colName] then cols[#cols + 1] = i end
      end
      for r = 2, #section do
        local row = section[r]
        if type(row) == 'table' then
          if type(row[1]) == 'string' then
            for _, i in ipairs(cols) do collectName(row[i]) end
          end
          for k, v in pairs(row) do
            if S.wheelGroupKeys[k] then collectName(v)
            elseif type(v) == 'table' and not v[1] then
              for ok, ov in pairs(v) do if S.wheelGroupKeys[ok] then collectName(ov) end end
            end
          end
        end
      end
    end
  end
  for _, row in ipairs(part.nodes or {}) do
    if type(row) == 'table' then
      if type(row[1]) == 'string' and type(row[2]) == 'number' then names[row[1]] = true end
      for k, v in pairs(row) do
        if type(v) == 'table' and not v[1] then
          collectName(v.group) collectName(v.breakGroup) collectName(v.deformGroup)
        end
        if k == 'group' or k == 'breakGroup' or k == 'deformGroup' then collectName(v) end
      end
    end
  end
  for _, row in ipairs(part.beams or {}) do
    if type(row) == 'table' then
      for k, v in pairs(row) do
        if type(v) == 'table' and not v[1] then collectName(v.breakGroup) collectName(v.deformGroup) end
        if k == 'breakGroup' or k == 'deformGroup' then collectName(v) end
      end
    end
  end
end

-- prefix every reference to a name in names; with stripExternal, node references in beams /
-- hydros / triangles... that point outside the set are cut (the part then hangs only on our welds).
-- aliasMap: foreign names to point at one of the car's own nodes instead (donor body point -> car node)
local function renamePartRefs(part, prefix, names, stripExternal, aliasMap)
  aliasMap = aliasMap or {}
  local function walk(t, skipCols)
    for k, v in pairs(t) do
      if type(v) == 'string' then
        local skip = (skipCols and type(k) == 'number' and skipCols[k]) or k == 'mesh' or S.keepNameKeys[k]
        if aliasMap[v] and not skip then
          t[k] = aliasMap[v]
        elseif names[v] and not skip then
          t[k] = prefix .. v
        elseif stripExternal and type(k) == 'string' and k:sub(-1) == ':' then
          -- optional link option ("torqueJointNode1:" etc.) to a foreign node: a missing link
          -- target would make the loader throw the whole row (e.g. a wheel) away
          t[k] = nil
        end
      elseif type(v) == 'table' then
        walk(v, nil)
      end
    end
  end
  for sectionName, section in pairs(part) do
    if type(section) == 'table' and not noRenameKeys[sectionName] and section[1] == nil then
      -- a data section (a controller's settings): its own values name nodes too - the fifth wheel
      -- controller looks up "fifthwheelNode": "fwk2" by name and fails on a renamed node
      walk(section, nil)
    elseif type(section) == 'table' and not noRenameKeys[sectionName] then
      local cols = meshColumns[sectionName]
      local isRefSection = stripExternal and nodeRefSections[sectionName]
      for _, row in pairs(section) do
        if type(row) == 'table' then
          if isRefSection and type(row[1]) == 'string' and not row[1]:find(':', 1, true) then
            -- leading strings are node names: snapped -> car node, own -> prefixed, foreign -> dropped
            local i = 1
            local own, dropped = {}, false
            while type(row[i]) == 'string' do
              local ref = aliasMap[row[i]] or (names[row[i]] and (prefix .. row[i]))
              if not ref and S.droppedRefs then S.droppedRefs[row[i]] = (S.droppedRefs[row[i]] or 0) + 1 end
              if ref then own[#own + 1] = ref else dropped = true end
              row[i] = ref or droppedRef
              i = i + 1
            end
            -- the part's nodes that held on to the donor's body: its mount points (S.mountRefs)
            if dropped and S.mountRefs then
              for _, ref in ipairs(own) do S.mountRefs[ref] = true end
            end
            for k = i, #row do
              if type(row[k]) == 'table' then walk(row[k], nil) end
            end
          else
            walk(row, cols)
          end
        end
      end
    end
  end
  -- vehicle level sections that must stay the car's own
  part.refNodes = nil
  part.cameraExternal = nil
  part.cameraChase = nil
end

-- names is shared by an extra part and its sub parts, so a sub part's references to its parent's
-- (already renamed) nodes get renamed too
local function prefixPart(part, prefix, names)
  collectPartNames(part, names)
  renamePartRefs(part, prefix, names, false)
end

local function addExtraSlots(rootPart, extras)
  local slots = rootPart.slots2 or rootPart.slots
  if not slots then
    rootPart.slots2 = {}
    slots = rootPart.slots2
  end
  for i, ex in ipairs(extras) do
    local mv, rt, pv = ex.move or {0, 0, 0}, ex.rot or {0, 0, 0}, ex.pivot or {0, 0, 0}
    table.insert(slots, {
      name = extraSlotPrefix .. i,
      allowTypes = {extraSlotType},
      denyTypes = {},
      default = extraAlias(i),
      description = 'Part Attacher Experimental: ' .. tostring(ex.part),
      -- jbeam applies higher indices first: rotate around the pivot, then move
      nodeMove = {x = mv[1], y = mv[2], z = mv[3]},
      nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]},
    })
  end
end

-- an added suspension (second rear axle) has no slot of the car to go into: one more slot on the
-- main part, holding the swap's alias part
S.addSwapSlots = function(rootPart, partSwaps)
  for kind, spec in pairs(type(partSwaps) == 'table' and partSwaps or {}) do
    if type(spec) == 'table' and spec.added then
      rootPart.slots2 = rootPart.slots2 or rootPart.slots or {}
      table.insert(rootPart.slots2, {
        name = 'upa_slot_' .. kind,
        allowTypes = {'upa_swap_' .. kind},
        denyTypes = {},
        default = 'upa_swap_' .. kind,
        description = 'Part Attacher Experimental: ' .. tostring(spec.part),
      })
    end
  end
end

-- slot name / type looks like a gearbox slot ("transmission", "gearbox", "transaxle")
local function isTransmissionSlot(s)
  if type(s) ~= 'table' then return false end
  local txt = tostring(s.name) .. ' ' .. tostring(s.type) .. ' ' .. (type(s.allowTypes) == 'table' and table.concat(s.allowTypes, ' ') or '')
  txt = txt:lower()
  return txt:find('transmission', 1, true) ~= nil or txt:find('gearbox', 1, true) ~= nil or txt:find('transaxle', 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- engine swap v3 ("logic swap"): the car keeps its own engine block physics (nodes, beams, mounts,
-- gearbox links - nothing can break), only the engine DATA (torque curve, rpm, inertia, turbo /
-- supercharger, sounds) and the engine block MESH come from the donor
--------------------------------------------------------------------------------

-- data sections the combustion engine reads through names given in mainEngine
local engineRefKeys = {'soundConfig', 'soundConfigExhaust', 'turbocharger', 'supercharger', 'nitrousOxideInjection'}

-- keys holding node references (resolved to the donor's node numbers): these stay the car's own
local function isNodeKey(k)
  return type(k) == 'string' and (k:find(':', 1, true) ~= nil or k:lower():find('node', 1, true) ~= nil)
end

-- plain data copy (no cdata / functions), so it can live in the vehicle config
local function cleanCopy(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == 'number' or t == 'string' or t == 'boolean' then return v end
  if t ~= 'table' or depth > 10 then return nil end
  local out = {}
  for k, x in pairs(v) do
    if type(k) == 'number' or type(k) == 'string' then
      local c = cleanCopy(x, depth + 1)
      if c ~= nil then out[k] = c end
    end
  end
  return out
end

-- the donor engine's final data, from a fully loaded vehicle (the ghost): ECU / internals / intake
-- parts have already been merged into mainEngine by the game's own loader
local function captureEngineData(vd)
  if type(vd) ~= 'table' or type(vd.mainEngine) ~= 'table' then return nil end
  local main = {}
  -- like powertrain init: the device row's inline options first, the section overrides them
  for _, d in pairs(vd.powertrain or {}) do
    if type(d) == 'table' and d.name == 'mainEngine' then
      for k, x in pairs(d) do
        if k ~= 'type' and k ~= 'name' and k ~= 'inputName' and k ~= 'inputIndex' and k ~= 'cid' and k ~= 'partOrigin' and k ~= 'partPath' and not isNodeKey(k) then
          main[k] = cleanCopy(x)
        end
      end
    end
  end
  for k, x in pairs(vd.mainEngine) do
    if not isNodeKey(k) then main[k] = cleanCopy(x) end
  end
  local data = {mainEngine = main}
  for _, key in ipairs(engineRefKeys) do
    local ref = main[key]
    if type(ref) == 'string' and type(vd[ref]) == 'table' then data[ref] = cleanCopy(vd[ref]) end
  end
  return data
end

-- put the donor engine data into the car (phase 2): keep the car's node references and fuel
local function applyEngineData(vehicle, data)
  if type(data) ~= 'table' or type(data.mainEngine) ~= 'table' then return false end
  -- start from the car's own data (radiator / cooling / fuel come from the car's other parts),
  -- then every engine characteristic of the donor on top; node references and fuel stay the car's
  local newMain = type(vehicle.mainEngine) == 'table' and deepcopy(vehicle.mainEngine) or {}
  for k, v in pairs(data.mainEngine) do
    if not isNodeKey(k) and k ~= 'energyStorage' and k ~= 'requiredEnergyType' then newMain[k] = deepcopy(v) end
  end
  -- the car's turbo / supercharger / nitrous don't belong to the donor engine
  for _, key in ipairs(engineRefKeys) do
    if data.mainEngine[key] == nil and key ~= 'soundConfig' and key ~= 'soundConfigExhaust' then newMain[key] = nil end
  end
  vehicle.mainEngine = newMain
  for k, v in pairs(data) do
    if k ~= 'mainEngine' then vehicle[k] = deepcopy(v) end
  end
  return true
end

-- part defines a gearbox powertrain device (manualGearbox, automaticGearbox, dctGearbox, cvtGearbox, sequentialGearbox)
local function isGearboxPart(part)
  if type(part) ~= 'table' or type(part.powertrain) ~= 'table' then return false end
  for _, row in ipairs(part.powertrain) do
    if type(row) == 'table' and type(row[1]) == 'string' and row[1]:find('Gearbox$') then return true end
  end
  return false
end

-- slot that holds the gearbox, judged by its name or by what its default part contains
local function slotHoldsGearbox(s, getPart)
  if isTransmissionSlot(s) then return true end
  if type(s) == 'table' and type(s.default) == 'string' and s.default ~= '' and getPart then
    local ok, part = pcall(getPart, s.default)
    return ok and isGearboxPart(part)
  end
  return false
end

-- the mod moves a donor part with nodeMove (index 0) and turns it with nodeRotate1 (index 1). jbeam
-- applies the higher index to a node first, so the donor's own moves / offsets / rotations (a wheel
-- slot's nodeOffset puts the wheels at the hubs) go 2 up and act before ours: left at index 0, a
-- wheel offset landed after our rotation, unrotated, and the wheels sat off their hubs (the brake
-- disc meshes drifted away from them)
S.shiftTransforms = function(t)
  if type(t) ~= 'table' then return end
  local renamed = {}
  for k, v in pairs(t) do
    local base, idx = type(k) == 'string' and k:match('^(node%u%l+)(%d*)$')
    if base == 'nodeOffset' or base == 'nodeMove' or base == 'nodeRotate' then
      renamed[#renamed + 1] = {k, base .. ((tonumber(idx) or 0) + 2), v}
    end
  end
  for _, r in ipairs(renamed) do t[r[1]] = nil end
  for _, r in ipairs(renamed) do t[r[2]] = r[3] end
end

-- every slot of a part, and the property rows of its node / mesh / prop sections
S.shiftPartTransforms = function(part)
  if type(part) ~= 'table' then return end
  for _, s in ipairs(part.slots2 or part.slots or {}) do S.shiftTransforms(s) end
  for sectionName, _ in pairs({nodes = true, flexbodies = true, props = true}) do
    for _, row in ipairs(type(part[sectionName]) == 'table' and part[sectionName] or {}) do
      if type(row) == 'table' and row[1] == nil then S.shiftTransforms(row) end
    end
  end
end

-- jbeam property rows that move/rotate every following row of this part (reset at the end so
-- other parts merged after it are not affected)
local transformSections = {nodes = true, flexbodies = true, props = true}
local function addTransformRows(part, spec)
  local mv, rt, pv = spec.move or {0, 0, 0}, spec.rot or {0, 0, 0}, spec.pivot or {0, 0, 0}
  S.shiftPartTransforms(part)
  for sectionName, section in pairs(part) do
    if transformSections[sectionName] and type(section) == 'table' and type(section[1]) == 'table' and type(section[1][1]) == 'string' then
      table.insert(section, 2, {
        nodeMove = {x = mv[1], y = mv[2], z = mv[3]},
        nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]},
      })
      table.insert(section, {nodeMove = '', nodeRotate1 = ''})
    end
  end
end

-- the donor engine, dressed up to sit in the car's engine slot, keep the car's gearbox and fuel
local function buildSwapEngine(ioCtx, swap)
  local donor, filename = origGetPart(ioCtx, swap.part)
  local orig = origGetPart(ioCtx, swap.replaces)
  if type(donor) ~= 'table' then
    log('E', logTag, 'engine swap: donor engine ' .. tostring(swap.part) .. ' not found, keeping the original')
    return orig
  end
  donor.partName = swapAlias
  local keptSlots = {}
  local function get(name) return origGetPart(ioCtx, name) end
  if type(orig) == 'table' then
    donor.slotType = orig.slotType
    if swap.keepTransmission ~= false then
      local dslots = donor.slots2 or donor.slots
      if not dslots then
        donor.slots2 = {}
        dslots = donor.slots2
      end
      for i = #dslots, 1, -1 do
        if slotHoldsGearbox(dslots[i], get) then table.remove(dslots, i) end
      end
      for _, s in ipairs(orig.slots2 or orig.slots or {}) do
        if slotHoldsGearbox(s, get) then
          local copy = deepcopy(s)
          keptSlots[copy] = true
          table.insert(dslots, copy)
        end
      end
    end
    -- run on the car's own tank / fuel type
    if type(donor.mainEngine) == 'table' and type(orig.mainEngine) == 'table' then
      donor.mainEngine.energyStorage = orig.mainEngine.energyStorage or donor.mainEngine.energyStorage
      donor.mainEngine.requiredEnergyType = orig.mainEngine.requiredEnergyType or donor.mainEngine.requiredEnergyType
    end
  end
  -- the block itself moves via property rows; everything that goes into its slots (intake, ECU,
  -- headers... whatever is picked later in the parts menu) gets the same move/rotate as slot options,
  -- which jbeam hands down to every sub part. The car's own gearbox slot stays untouched.
  local imports = type(swap.importNodes) == 'table' and #swap.importNodes > 0 and swap.importNodes or nil
  if imports and type(donor.nodes) ~= 'table' then donor.nodes = {{'id', 'posX', 'posY', 'posZ'}} end
  addTransformRows(donor, swap)
  if imports then
    -- the donor's body points its engine mounts hang on, as own nodes (welded to the car later)
    local at = 3
    for _, n in ipairs(imports) do
      if type(n) == 'table' and type(n[1]) == 'string' and type(n[2]) == 'number' then
        local weight = n[7] and 2 or math.min(40, math.max(8, tonumber(n[5]) or 10))
        local group = (type(n[6]) == 'string' or type(n[6]) == 'table') and n[6] or ''
        table.insert(donor.nodes, at, {n[1], n[2], n[3], n[4], {nodeWeight = weight, collision = false, selfCollision = false, group = group}})
        at = at + 1
      end
    end
  end
  local mv, rt, pv = swap.move or {0, 0, 0}, swap.rot or {0, 0, 0}, swap.pivot or {0, 0, 0}
  for _, s in ipairs(donor.slots2 or donor.slots or {}) do
    if type(s) == 'table' and not keptSlots[s] then
      s.nodeMove = {x = mv[1], y = mv[2], z = mv[3]}
      s.nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]}
    end
  end
  return donor, filename
end

local function partSwapAlias(kind)
  return 'upa_swap_' .. tostring(kind)
end

-- a donor part in the car's slot of the part it replaces (gearbox, suspension...); its own sub slots
-- (transfer case, struts, wheels...) come along and get the same move/rotate
local function buildSwapGearbox(ioCtx, swap, alias)
  local donor, filename = origGetPart(ioCtx, swap.part)
  local orig = origGetPart(ioCtx, swap.replaces)
  if type(donor) ~= 'table' then
    log('E', logTag, 'part swap: donor part ' .. tostring(swap.part) .. ' not found, keeping the original')
    return orig
  end
  donor.partName = alias or gearboxAlias
  if type(orig) == 'table' then
    donor.slotType = orig.slotType
  elseif swap.added and alias then
    donor.slotType = alias -- the slot the mod added for it
  end
  local hasImports = type(swap.importNodes) == 'table' and #swap.importNodes > 0
  if hasImports and type(donor.nodes) ~= 'table' then
    donor.nodes = {{'id', 'posX', 'posY', 'posZ'}}
  end
  addTransformRows(donor, swap)
  if hasImports then
    -- the donor's body points the tree hangs on, as own (light, non colliding) nodes right after the
    -- move/rotate row so they sit where the donor had them; they get welded to the car's body
    local at = 3
    for _, n in ipairs(swap.importNodes) do
      if type(n) == 'table' and type(n[1]) == 'string' and type(n[2]) == 'number' then
        -- the donor's own node mass (2..25 kg): the donor's beams on it are made for that mass, and the
        -- virtual frame beams get scaled to it; 8 kg minimum hung hundreds of kg on a small car
        local weight = n[7] and 2 or math.min(25, math.max(2, tonumber(n[5]) or 5)) -- mesh-only points are light
        -- keep the donor's groups: shock / spring / subframe meshes bind to them (shock tops etc.)
        local group = (type(n[6]) == 'string' or type(n[6]) == 'table') and n[6] or ''
        table.insert(donor.nodes, at, {n[1], n[2], n[3], n[4], {nodeWeight = weight, collision = false, selfCollision = false, group = group}})
        at = at + 1
      end
    end
  end
  -- the beams the donor's frame / body held the tree's own nodes with (link mounts, shock tops...),
  -- each with its full properties inline after a reset row, so nothing leaks between them and the
  -- part's own beams
  if type(swap.frameBeams) == 'table' and #swap.frameBeams > 0 then
    if type(donor.beams) ~= 'table' then donor.beams = {{'id1:', 'id2:'}} end
    local reset = {beamType = '|NORMAL', beamPrecompression = 1, beamLongBound = 1, beamShortBound = 1,
      breakGroup = '', deformGroup = '', deformLimitExpansion = ''}
    donor.beams[#donor.beams + 1] = deepcopy(reset)
    for _, fb in ipairs(swap.frameBeams) do
      if type(fb) == 'table' and type(fb[1]) == 'string' and type(fb[2]) == 'string' then
        donor.beams[#donor.beams + 1] = {fb[1], fb[2], type(fb[3]) == 'table' and deepcopy(fb[3]) or {}}
      end
    end
    donor.beams[#donor.beams + 1] = deepcopy(reset)
  end
  local mv, rt, pv = swap.move or {0, 0, 0}, swap.rot or {0, 0, 0}, swap.pivot or {0, 0, 0}
  for _, s in ipairs(donor.slots2 or donor.slots or {}) do
    if type(s) == 'table' then
      s.nodeMove = {x = mv[1], y = mv[2], z = mv[3]}
      s.nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]}
    end
  end
  return donor, filename
end

-- node groups used by a raw part's nodes (meshes of other parts can be hung on these)
local function partNodeGroups(part)
  local groups, seen, current = {}, {}, nil
  for _, row in ipairs(type(part) == 'table' and type(part.nodes) == 'table' and part.nodes or {}) do
    if type(row) == 'table' then
      if row[1] == nil and row.group ~= nil then current = row.group end
      if type(row[1]) == 'string' and type(row[2]) == 'number' then
        local g = current
        if type(row[5]) == 'table' and row[5].group ~= nil then g = row[5].group end
        for _, s in ipairs(type(g) == 'table' and g or {g}) do
          if type(s) == 'string' and s ~= '' and not seen[s] then
            seen[s] = true
            groups[#groups + 1] = s
          end
        end
      end
    end
  end
  return groups
end

-- logic swap: the car's own engine part (physics untouched) wearing the donor engine's mesh, hung on
-- the groups of the car's engine block nodes and placed like the preview showed it
local function buildMeshSwapEngine(ioCtx, spec)
  local part, filename = origGetPart(ioCtx, spec.replaces)
  if type(part) ~= 'table' or spec.meshSwap == false then return part, filename end
  local donor = origGetPart(ioCtx, spec.part)
  if type(donor) ~= 'table' or type(donor.flexbodies) ~= 'table' then return part, filename end

  local groups = partNodeGroups(part)
  if #groups == 0 then return part, filename end

  local mv, rt, pv = spec.move or {0, 0, 0}, spec.rot or {0, 0, 0}, spec.pivot or {0, 0, 0}
  local header = donor.flexbodies[1]
  local fb = {type(header) == 'table' and type(header[1]) == 'string' and deepcopy(header) or {'mesh', '[group]:', 'nonFlexMaterials'}}
  fb[#fb + 1] = {
    nodeMove = {x = mv[1], y = mv[2], z = mv[3]},
    nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]},
  }
  local meshes = 0
  for i = 2, #donor.flexbodies do
    local row = donor.flexbodies[i]
    if type(row) == 'table' and type(row[1]) == 'string' then
      local copy = deepcopy(row)
      copy[2] = deepcopy(groups)
      fb[#fb + 1] = copy
      meshes = meshes + 1
    elseif type(row) == 'table' and row[1] == nil then
      fb[#fb + 1] = deepcopy(row) -- property rows of the donor's list
    end
  end
  fb[#fb + 1] = {nodeMove = '', nodeRotate1 = ''}
  if meshes > 0 then part.flexbodies = fb end
  return part, filename
end

local tuneSlotPrefix = 'upat_' -- donor engine tuning slots inside the car's engine part

-- does a slot hold engine data (ECU, internals, intake / turbo, supercharger, nitrous)?
local function slotHoldsEngineData(s, getPart)
  if type(s) ~= 'table' or slotHoldsGearbox(s, getPart) then return false end
  local txt = (tostring(s.name) .. ' ' .. (type(s.allowTypes) == 'table' and table.concat(s.allowTypes, ' ') or '')):lower()
  -- oil pans / mounts / headers belong to the block: they stay the car's own
  for _, w in ipairs({'oilpan', 'oil_pan', 'mount', 'header', 'exhaust', 'manifold'}) do
    if txt:find(w, 1, true) then return false end
  end
  local def = type(s.default) == 'string' and s.default ~= '' and getPart(s.default) or nil
  if type(def) == 'table' then
    -- engine data that points at nodes (oil pan nodes, torque reaction...) is part of the block
    if type(def.mainEngine) == 'table' then
      for k, _ in pairs(def.mainEngine) do
        if isNodeKey(k) then return false end
      end
    end
    return type(def.mainEngine) == 'table' or type(def.turbocharger) == 'table' or type(def.supercharger) == 'table'
      or type(def.nitrousOxideInjection) == 'table'
  end
  -- empty by default (nitrous, supercharger...): judge by the slot's name
  for _, w in ipairs({'ecu', 'intake', 'internals', 'turbo', 'supercharger', 'n2o', 'nitrous'}) do
    if txt:find(w, 1, true) then return true end
  end
  return false
end

-- logic swap v4: the car's engine part keeps its physics (nodes, beams, mounts, gearbox links),
-- takes the donor engine's base data and sounds, and swaps its tuning slots for the donor's, so the
-- donor ECU / internals / turbos can be picked in the normal parts menu (they come in physics-free)
local function buildLogicEngine(ioCtx, spec)
  local part, filename = buildMeshSwapEngine(ioCtx, spec)
  if (tonumber(spec.version) or 0) < 4 or type(part) ~= 'table' then return part, filename end
  local donor = origGetPart(ioCtx, spec.part)
  if type(donor) ~= 'table' then return part, filename end
  local function get(name)
    local ok, p = pcall(origGetPart, ioCtx, name)
    return ok and p or nil
  end

  -- base engine data: the donor's, with the car's node references and fuel
  if type(donor.mainEngine) == 'table' then
    local carMain = type(part.mainEngine) == 'table' and part.mainEngine or {}
    local newMain = {}
    for k, v in pairs(donor.mainEngine) do
      if not isNodeKey(k) then newMain[k] = deepcopy(v) end
    end
    -- the car's wiring stays the car's: its node / group references, fuel, the beams and deform
    -- groups of its own block, and the engine outputs its other devices hang on (the MD-Series air
    -- compressor and PTO sit on outputs 2 and 3: with the donor's single output the compressor got
    -- no speed and the vehicle Lua died)
    local carKeys = {energyStorage = true, requiredEnergyType = true, breakTriggerBeam = true,
      waterDamage = true, radiator = true, engineBlock = true}
    local function refsGroups(v)
      if type(v) ~= 'table' then return false end
      for key, _ in pairs(v) do
        if type(key) == 'string' and key:sub(-1) == ':' then return true end
      end
      return false
    end
    for k, v in pairs(carMain) do
      if isNodeKey(k) or carKeys[k] or (type(k) == 'string' and k:find('^deformGroups')) or refsGroups(v) then
        newMain[k] = deepcopy(v)
      end
    end
    local carPorts, donorPorts = tonumber(carMain.numberOfOutputPorts), tonumber(donor.mainEngine.numberOfOutputPorts)
    if carPorts or donorPorts then newMain.numberOfOutputPorts = math.max(carPorts or 1, donorPorts or 1) end
    -- the car's compression brake (truck controller) needs a curve the donor may not have
    if carMain.torqueCompressionBrake ~= nil and newMain.torqueCompressionBrake == nil then
      newMain.torqueCompressionBrake = deepcopy(carMain.torqueCompressionBrake)
    end
    part.mainEngine = newMain
    for _, key in ipairs({'soundConfig', 'soundConfigExhaust'}) do
      local ref = donor.mainEngine[key]
      if type(ref) == 'string' and type(donor[ref]) == 'table' then part[ref] = deepcopy(donor[ref]) end
    end
    -- the donor's tuning variables ($revLimiterRPM...) its data uses
    if type(donor.variables) == 'table' then
      if type(part.variables) ~= 'table' then
        part.variables = deepcopy(donor.variables)
      else
        for i, row in ipairs(donor.variables) do
          if i > 1 or not (type(row) == 'table' and row[1] == 'name') then table.insert(part.variables, deepcopy(row)) end
        end
      end
    end
  end

  -- slots: the car's structural ones stay (mounts, oil pan, headers, gearbox), its tuning ones go;
  -- the donor's tuning slots come in, moved like the donor mesh so their meshes sit on the block
  local mv, rt, pv = spec.move or {0, 0, 0}, spec.rot or {0, 0, 0}, spec.pivot or {0, 0, 0}
  local slots = {}
  for _, s in ipairs(part.slots2 or part.slots or {}) do
    if not slotHoldsEngineData(s, get) then slots[#slots + 1] = s end
  end
  local added = 0
  for _, s in ipairs(donor.slots2 or donor.slots or {}) do
    if slotHoldsEngineData(s, get) then
      local copy = deepcopy(s)
      copy.name = tuneSlotPrefix .. tostring(s.name or s.type)
      copy.allowTypes = copy.allowTypes or (s.type and {s.type}) or {}
      copy.denyTypes = copy.denyTypes or {}
      copy.type = nil
      copy.nodeMove = {x = mv[1], y = mv[2], z = mv[3]}
      copy.nodeRotate1 = {x = rt[1], y = rt[2], z = rt[3], px = pv[1], py = pv[2], pz = pv[3]}
      slots[#slots + 1] = copy
      added = added + 1
    end
  end
  part.slots2 = slots
  part.slots = nil
  log('I', logTag, string.format('engine logic swap: %d donor tuning slots in %s', added, tostring(spec.replaces)))
  return part, filename
end

--------------------------------------------------------------------------------
-- mesh only ("static mesh"): just a part's model, no physics of its own. The model needs nodes of
-- its groups to hang on (a radiator's mesh hangs on its own car's radiator support): those come
-- along as light, non colliding points, glued softly to each other and later to the car's body.
--------------------------------------------------------------------------------

-- the points a part's meshes hang on: its own nodes, and the donor car's nodes of the mesh groups
-- (default parts), as {name, x, y, z, group}; at most 80, nearest to the middle
S.meshNodesFor = function(model, partName)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, {'/vehicles/' .. tostring(model) .. '/', '/vehicles/common/'})
  if not okCtx or not ioCtx then return {} end
  local part = jbeamIO.getPart(ioCtx, partName)
  if type(part) ~= 'table' then return {} end
  local groups = {}
  for _, row in ipairs(type(part.flexbodies) == 'table' and part.flexbodies or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= 'mesh' and type(row[2]) == 'table' then
      for _, g in ipairs(row[2]) do if type(g) == 'string' then groups[g] = true end end
    end
  end
  if next(groups) == nil then return {} end
  local out, seen, ownCount = {}, {}, 0
  local function take(p, all)
    local group, engineGroup
    for _, row in ipairs(type(p.nodes) == 'table' and p.nodes or {}) do
      if type(row) == 'table' then
        if row[1] == nil and row.group ~= nil then group = row.group end
        if row[1] == nil and row.engineGroup ~= nil then engineGroup = row.engineGroup end
        if type(row[1]) == 'string' and type(row[2]) == 'number' and type(row[3]) == 'number' and type(row[4]) == 'number' then
          local g = (type(row[5]) == 'table' and row[5].group ~= nil) and row[5].group or group
          local eg = (type(row[5]) == 'table' and row[5].engineGroup ~= nil) and row[5].engineGroup or engineGroup
          local inGroup = false
          for _, s in ipairs(type(g) == 'table' and g or {g}) do if groups[s] then inGroup = true end end
          if (all or inGroup) and not seen[row[1]] then
            seen[row[1]] = true
            -- the part's own air intake points (snorkel) stay intake points as a model only part too
            out[#out + 1] = {row[1], row[2], row[3], row[4], inGroup and deepcopy(g) or '', (all and S.isIntakeGroup(eg)) and deepcopy(eg) or nil}
          end
        end
      end
    end
  end
  take(part, true)
  ownCount = #out
  local visited = {}
  local function rec(name, depth)
    if depth > 30 or visited[name] then return end
    visited[name] = true
    local p = jbeamIO.getPart(ioCtx, name)
    if type(p) ~= 'table' then return end
    if name ~= partName then take(p, false) end
    for _, s in ipairs(p.slots2 or p.slots or {}) do
      if type(s) == 'table' and type(s.default) == 'string' and s.default ~= '' then rec(s.default, depth + 1) end
    end
  end
  local main = jbeamIO.getMainPartName(ioCtx)
  if main then rec(main, 0) end
  if #out > 80 then
    local c = vec3()
    for _, n in ipairs(out) do c = c + vec3(n[2], n[3], n[4]) end
    c = c / #out
    local own, rest = {}, {}
    for i, n in ipairs(out) do
      if i <= ownCount then own[#own + 1] = n else rest[#rest + 1] = n end
    end
    table.sort(rest, function(a, b) return vec3(a[2], a[3], a[4]):squaredDistance(c) < vec3(b[2], b[3], b[4]):squaredDistance(c) end)
    out = own
    for i = 1, math.max(0, 80 - #own) do if rest[i] then out[#out + 1] = rest[i] end end
  end
  return out
end

-- the part itself, cut down to its meshes on those points (no beams, data or slots of its own)
S.buildMeshOnlyPart = function(ioCtx, partName, meshNodes)
  local part, filename = origGetPart(ioCtx, partName)
  if type(part) ~= 'table' then return part, filename end
  local out = {partName = part.partName, slotType = part.slotType, information = part.information, flexbodies = part.flexbodies}
  local nodes = {{'id', 'posX', 'posY', 'posZ'}, {collision = false, selfCollision = false, staticCollision = false, nodeWeight = 1}}
  local list = {}
  for _, n in ipairs(type(meshNodes) == 'table' and meshNodes or {}) do
    if type(n) == 'table' and type(n[1]) == 'string' and type(n[2]) == 'number' then
      nodes[#nodes + 1] = {n[1], n[2], n[3], n[4], {group = n[5] or '', engineGroup = n[6]}}
      list[#list + 1] = {name = n[1], pos = vec3(n[2], n[3], n[4])}
    end
  end
  out.nodes = nodes
  -- every point glued to its 6 nearest: soft, never breaking, the model just follows
  local beams = {{'id1:', 'id2:'}, {beamType = '|NORMAL', beamSpring = 200000, beamDamp = 10, beamDeform = math.huge, beamStrength = math.huge}}
  local seenPair = {}
  for i, a in ipairs(list) do
    local near = {}
    for j, b in ipairs(list) do
      local d = a.pos:distance(b.pos)
      if j ~= i and d > 0.01 then near[#near + 1] = {j = j, d = d} end
    end
    table.sort(near, function(x, y) return x.d < y.d end)
    for m = 1, math.min(6, #near) do
      local j = near[m].j
      local key = math.min(i, j) .. ':' .. math.max(i, j)
      if not seenPair[key] then
        seenPair[key] = true
        beams[#beams + 1] = {a.name, list[j].name}
      end
    end
  end
  out.beams = beams
  return out, filename
end

-- grow / shrink a part around a point (sc = {factor, x, y, z}): its node positions and its meshes
-- (flexbody pos / scale), before the slot's own rotate / move. Beams get their new lengths at spawn.
S.scalePart = function(part, sc)
  local s = type(sc) == 'table' and tonumber(sc[1])
  if type(part) ~= 'table' or not s or s <= 0 or math.abs(s - 1) < 1e-4 then return end
  local p = {tonumber(sc[2]) or 0, tonumber(sc[3]) or 0, tonumber(sc[4]) or 0}
  -- a number, or a jbeam expression / variable ("$=...", "$name") wrapped into a new expression
  local function exprOf(v)
    if type(v) == 'string' and v:sub(1, 1) == '$' then return v:sub(1, 2) == '$=' and v:sub(3) or v end
  end
  local function scaled(v, axis)
    local c = p[axis] * (1 - s)
    if type(v) == 'number' then return v * s + c end
    local expr = exprOf(v)
    return expr and string.format('$=(%s)*%.6g+%.6g', expr, s, c) or v
  end
  local function times(v)
    if type(v) == 'number' then return v * s end
    local expr = exprOf(v)
    return expr and string.format('$=(%s)*%.6g', expr, s) or s
  end
  for _, row in ipairs(type(part.nodes) == 'table' and part.nodes or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= 'id' then
      for axis = 1, 3 do row[axis + 1] = scaled(row[axis + 1], axis) end
    end
  end
  -- mesh: vertex -> pos + rot * (scale * vertex), so around p: pos' = s * pos + (1 - s) * p, scale' = s * scale
  local fb = part.flexbodies
  if type(fb) == 'table' and type(fb[1]) == 'table' and type(fb[1][1]) == 'string' then
    local headerSize = #fb[1]
    local curPos, curScale
    for r = 2, #fb do
      local row = fb[r]
      if type(row) == 'table' then
        if row[1] == nil then
          -- a property row: its pos / scale count for the rows below it
          if row.pos ~= nil then curPos = type(row.pos) == 'table' and row.pos or nil end
          if row.scale ~= nil then curScale = type(row.scale) == 'table' and row.scale or nil end
        elseif type(row[1]) == 'string' then
          for i = #row + 1, headerSize do row[i] = {} end
          local opts = row[headerSize + 1]
          if type(opts) ~= 'table' then
            opts = {}
            row[headerSize + 1] = opts
          end
          local pos = type(opts.pos) == 'table' and opts.pos or curPos or {}
          local scl = type(opts.scale) == 'table' and opts.scale or curScale or {}
          opts.pos = {x = scaled(pos.x or 0, 1), y = scaled(pos.y or 0, 2), z = scaled(pos.z or 0, 3)}
          opts.scale = {x = times(scl.x or 1), y = times(scl.y or 1), z = times(scl.z or 1)}
        end
      end
    end
  end
end

-- the scale of an installed extra part ({factor, pivot}), nil at its own size
S.extraScale = function(ex)
  local s = type(ex) == 'table' and tonumber(ex.scale)
  if not s or math.abs(s - 1) < 1e-4 or type(ex.pivot) ~= 'table' then return nil end
  return {s, ex.pivot[1], ex.pivot[2], ex.pivot[3]}
end

-- front end swap: a made-up part holding another car's front parts (bumper, fenders, hood, lights...)
-- in its slots, each at the place it has on its own car (the offsets its slots there add up to). As
-- a preview it is the main part; installed it sits in an extra slot, so its parts come as sub parts
-- of that extra (one virtual mount for the whole front end).
S.buildFrontEndPart = function(ioCtx, name, spec)
  local slots, filename = {}, nil
  for i, p in ipairs(type(spec) == 'table' and type(spec.parts) == 'table' and spec.parts or {}) do
    local okP, part, file = pcall(origGetPart, ioCtx, p.name)
    if okP and type(part) == 'table' then
      filename = filename or file
      local st = part.slotType
      local slot = {
        name = 'upa_fe_' .. i,
        allowTypes = type(st) == 'table' and deepcopy(st) or {tostring(st or p.name)},
        denyTypes = {},
        default = p.name,
        description = 'Part Attacher front end: ' .. tostring(p.name),
      }
      local o = type(p.offset) == 'table' and p.offset or {}
      if (tonumber(o[1]) or 0) ~= 0 or (tonumber(o[2]) or 0) ~= 0 or (tonumber(o[3]) or 0) ~= 0 then
        slot.nodeOffset = {x = tonumber(o[1]) or 0, y = tonumber(o[2]) or 0, z = tonumber(o[3]) or 0}
      end
      slots[#slots + 1] = slot
    end
  end
  return {partName = name, slotType = 'main', information = {name = 'Front end', authors = 'Part Attacher'}, slots2 = slots}, filename
end

local function wrappedGetPart(ioCtx, partName)
  local ctx = injectCtx
  -- a front end preview's made-up main part (S.loadFrontEnds, set by wrappedFindParts)
  local frontEnd = type(S.loadFrontEnds) == 'table' and S.loadFrontEnds[partName]
  if frontEnd then return S.buildFrontEndPart(ioCtx, partName, frontEnd) end
  -- preview of a scaled part: every part of it, as it would load otherwise, grown / shrunk
  if ctx and ctx.ghostScale and not ctx.scaleBusy then
    ctx.scaleBusy = true
    local okS, part, filename = pcall(wrappedGetPart, ioCtx, partName)
    ctx.scaleBusy = false
    if okS then
      S.scalePart(part, ctx.ghostScale)
      return part, filename
    end
  end
  -- turbo / supercharger (logic): the car's engine part, as it would load otherwise, plus the donor's
  -- forced induction section and tuning variables
  if ctx and ctx.fiSwap and partName == ctx.fiSwap.enginePart and not ctx.fiBusy then
    ctx.fiBusy = true
    local okFi, part, filename = pcall(wrappedGetPart, ioCtx, partName)
    ctx.fiBusy = false
    if okFi then
      S.injectForcedInduction(part, ctx.fiSwap)
      return part, filename
    end
  end
  if ctx and ctx.meshOnlyMain and partName == ctx.meshOnlyMain.name then
    -- preview of a mesh only part
    return S.buildMeshOnlyPart(ioCtx, partName, ctx.meshOnlyMain.nodes)
  end
  if ctx and ctx.meshSwap and partName == ctx.meshSwap.replaces then
    return buildLogicEngine(ioCtx, ctx.meshSwap)
  end
  if ctx and ctx.swap and (partName == ctx.swap.replaces or partName == swapAlias) then
    return buildSwapEngine(ioCtx, ctx.swap)
  end
  if ctx and ctx.gbSwap and (partName == ctx.gbSwap.replaces or partName == gearboxAlias) then
    return buildSwapGearbox(ioCtx, ctx.gbSwap, gearboxAlias)
  end
  if ctx and ctx.partSwaps then
    for kind, spec in pairs(ctx.partSwaps) do
      local alias = partSwapAlias(kind)
      if partName == spec.replaces or partName == alias then
        -- a swap's tree is never a sub part of an extra (its parts must keep their own names)
        ctx.current = nil
        return buildSwapGearbox(ioCtx, spec, alias)
      end
    end
  end
  if ctx and type(partName) == 'string' then
    local idx = tonumber(partName:match('^upa_extra_part_(%d+)$'))
    if idx and ctx.extras[idx] then
      -- donor part behind the alias of extra slot #idx (only its model for a mesh only extra)
      local ex = ctx.extras[idx]
      local part, filename
      if type(ex.frontEnd) == 'table' then
        part, filename = S.buildFrontEndPart(ioCtx, ex.part, ex.frontEnd)
      elseif ex.meshOnly then
        part, filename = S.buildMeshOnlyPart(ioCtx, ex.part, ex.meshNodes)
      else
        part, filename = origGetPart(ioCtx, ex.part)
      end
      ctx.current = idx
      ctx.names[idx] = ctx.names[idx] or {}
      if type(part) == 'table' then
        part.partName = partName
        part.slotType = extraSlotType
        S.scalePart(part, S.extraScale(ex))
        S.shiftPartTransforms(part) -- its own offsets act before the extra slot's move / rotate
        prefixPart(part, 'upa' .. idx .. '_', ctx.names[idx])
        S.noteExtraDevices(part, idx)
      end
      return part, filename
    end
  end

  local part, filename = origGetPart(ioCtx, partName)
  if ctx and type(part) == 'table' then
    if not ctx.rootDone and partName == ctx.mainPart then
      ctx.rootDone = true
      -- added swap slots (second rear axle) before the extra slots: the extras must stay last (below)
      S.addSwapSlots(part, ctx.partSwaps)
      addExtraSlots(part, ctx.extras)
    elseif ctx.current then
      -- extra slots come last on the main part, so every part loaded from here on is a sub part of one
      S.scalePart(part, S.extraScale(ctx.extras[ctx.current]))
      S.shiftPartTransforms(part)
      prefixPart(part, 'upa' .. ctx.current .. '_', ctx.names[ctx.current])
      S.noteExtraDevices(part, ctx.current)
    end
  end
  return part, filename
end

-- a part from the shared folder (/vehicles/common/etkf/...) has its meshes and materials in its model's
-- own folder (/vehicles/etkf/): for every donor part and its default sub parts, those folders
S.commonMeshDirs = function(ioCtx, names)
  local out, seen, visited = {}, {}, {}
  local function walk(name, depth)
    if depth > 6 or type(name) ~= 'string' or name == '' or visited[name] then return end
    visited[name] = true
    local okP, part, filename = pcall(origGetPart, ioCtx, name)
    if not okP or type(part) ~= 'table' then return end
    local sub = type(filename) == 'string' and filename:match('^/?vehicles/common/([^/]+)/')
    if sub and not seen[sub] then
      seen[sub] = true
      out[#out + 1] = '/vehicles/' .. sub .. '/'
    end
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      if type(s) == 'table' then walk(s.default, depth + 1) end
    end
  end
  for _, n in ipairs(names) do walk(n, 0) end
  return out
end

local function wrappedFindParts(ioCtx, vehicleConfig)
  pendingUnifySwaps, pendingUnifyEngine, pendingUnifyLogic, S.pendingUnifyExtras = nil, nil, nil, nil
  S.railHooks = {} -- per swap kind: nodes that rode a donor frame rail (S.detachSwapRails)
  S.extraDevices = {} -- powertrain device name -> index of the added part it came with (S.connectExtraDevices)
  S.extraMounts = {} -- per added part: its node names that held on to the donor (S.isolateExtras)
  local pa = type(vehicleConfig) == 'table' and type(vehicleConfig.partAttacherExp) == 'table' and vehicleConfig.partAttacherExp
  -- a modded car starts loading: collect the mod's log lines for last_load.log
  S.diag = (pa and not pa.ghost) and {string.format('=== %s  %s', os.date('%Y-%m-%d %H:%M:%S'), tostring(vehicleConfig.mainPartName or (vehicleConfig.partsTree and vehicleConfig.partsTree.chosenPartName) or '?'))} or nil
  -- a front end preview: its made-up main part, and the real parts in it for their mesh folders
  S.loadFrontEnds = {}
  local previewParts = {type(vehicleConfig) == 'table' and vehicleConfig.mainPartName or nil}
  if pa and pa.ghost and type(pa.frontEnd) == 'table' and type(vehicleConfig.mainPartName) == 'string' then
    S.loadFrontEnds[vehicleConfig.mainPartName] = pa.frontEnd
    previewParts = {}
    for _, p in ipairs(type(pa.frontEnd.parts) == 'table' and pa.frontEnd.parts or {}) do previewParts[#previewParts + 1] = p.name end
  end
  local extras = pa and type(pa.extraParts) == 'table' and pa.extraParts or {}
  -- a preview of a shared (common) part: its model's folder for meshes and materials
  if pa and pa.ghost and type(ioCtx) == 'table' and type(ioCtx.preloadedDirs) == 'table' and vehicleConfig.mainPartName then
    local have, more = {}, false
    for _, d in ipairs(ioCtx.preloadedDirs) do have[d] = true end
    for _, d in ipairs(S.commonMeshDirs(ioCtx, previewParts)) do
      if not have[d] and FS:directoryExists(d) then
        table.insert(ioCtx.preloadedDirs, d)
        have[d] = true
        more = true
      end
      pcall(loadMaterialsDir, d)
    end
    if more then jbeamIO.startLoading(ioCtx.preloadedDirs) end
  end
  -- preview of a mesh only part: its main part is the cut down part
  -- (or of a scaled part: all of its parts grow / shrink around its pivot)
  local ghostScale = pa and pa.ghost and type(pa.scale) == 'table' and pa.scale or nil
  if pa and pa.ghost and (type(pa.meshOnly) == 'table' or ghostScale) and type(ioCtx) == 'table' then
    injectCtx = {extras = {}, names = {}, ghostScale = ghostScale}
    if type(pa.meshOnly) == 'table' then injectCtx.meshOnlyMain = {name = vehicleConfig.mainPartName, nodes = pa.meshOnly.nodes} end
    local okM, a, b, c, d, e, f, g = pcall(origFindParts, ioCtx, vehicleConfig)
    injectCtx = nil
    if not okM then log('E', logTag, 'findParts failed: ' .. tostring(a)) return nil end
    return a, b, c, d, e, f, g
  end
  local swap = pa and type(pa.engineSwap) == 'table' and pa.engineSwap.part and pa.engineSwap.replaces and pa.engineSwap or nil
  local gbSwap = pa and type(pa.gearboxSwap) == 'table' and pa.gearboxSwap.part and pa.gearboxSwap.replaces and pa.gearboxSwap or nil
  local fiSwap = pa and type(pa.fiSwap) == 'table' and pa.fiSwap.enginePart and pa.fiSwap or nil
  local partSwaps
  if pa and type(pa.partSwaps) == 'table' then
    for kind, spec in pairs(pa.partSwaps) do
      if type(spec) == 'table' and spec.part and (spec.replaces or spec.added) then
        partSwaps = partSwaps or {}
        partSwaps[kind] = spec
      end
    end
  end
  if (#extras == 0 and not swap and not gbSwap and not partSwaps and not fiSwap) or type(ioCtx) ~= 'table' or type(ioCtx.preloadedDirs) ~= 'table' then
    return origFindParts(ioCtx, vehicleConfig)
  end

  -- make the donor models visible to this load; the same table is the mesh search path list
  local dirs = ioCtx.preloadedDirs
  local have, added = {}, false
  for _, d in ipairs(dirs) do have[d] = true end
  local donorModels = {}
  for _, ex in ipairs(extras) do donorModels[#donorModels + 1] = ex.model end
  if swap then donorModels[#donorModels + 1] = swap.model end
  if gbSwap then donorModels[#donorModels + 1] = gbSwap.model end
  for _, spec in pairs(partSwaps or {}) do donorModels[#donorModels + 1] = spec.model end
  for _, model in ipairs(donorModels) do
    local d = '/vehicles/' .. tostring(model) .. '/'
    if not have[d] and FS:directoryExists(d) then
      table.insert(dirs, d)
      have[d] = true
      added = true
    end
    pcall(loadMaterialsDir, d)
  end
  if added then jbeamIO.startLoading(dirs) end
  -- the model folders of shared (common) donor parts too, for their meshes and materials
  local donorParts = {}
  for _, ex in ipairs(extras) do
    if type(ex.frontEnd) == 'table' then
      for _, p in ipairs(type(ex.frontEnd.parts) == 'table' and ex.frontEnd.parts or {}) do donorParts[#donorParts + 1] = p.name end
    else
      donorParts[#donorParts + 1] = ex.part
    end
  end
  if swap then donorParts[#donorParts + 1] = swap.part end
  if gbSwap then donorParts[#donorParts + 1] = gbSwap.part end
  for _, spec in pairs(partSwaps or {}) do donorParts[#donorParts + 1] = spec.part end
  local more = false
  for _, d in ipairs(S.commonMeshDirs(ioCtx, donorParts)) do
    if not have[d] and FS:directoryExists(d) then
      table.insert(dirs, d)
      have[d] = true
      more = true
    end
    pcall(loadMaterialsDir, d)
  end
  if more then jbeamIO.startLoading(dirs) end

  -- engine swap v3 is a logic swap: the car keeps its engine part, only its mesh changes here
  local engineVersion = swap and (tonumber(swap.version) or 1) or 0
  local meshSwap = engineVersion >= 3 and swap or nil
  local partSwapEngine = engineVersion < 3 and swap or nil
  injectCtx = {mainPart = vehicleConfig.mainPartName, extras = extras, names = {}, swap = partSwapEngine, meshSwap = meshSwap, gbSwap = gbSwap, partSwaps = partSwaps, fiSwap = fiSwap}
  local ok, a, b, c, d, e, f, g = pcall(origFindParts, ioCtx, vehicleConfig)
  injectCtx = nil
  pendingUnifySwaps = partSwaps -- the loader unifies the parts right after this
  S.pendingUnifyExtras = #extras > 0 and extras or nil
  pendingUnifyEngine = engineVersion == 2 and swap or nil
  pendingUnifyLogic = engineVersion >= 4 and swap or nil
  if not ok then
    log('E', logTag, 'findParts failed: ' .. tostring(a))
    return nil
  end
  return a, b, c, d, e, f, g
end

-- prefix for the node names of a swapped part's tree
local function partSwapPrefix(kind)
  return 'ups' .. tostring(kind) .. '_'
end

local enginePrefix = 'upse_'

-- unique names for a whole part tree: its node / group / break group / rail names get prefix,
-- references to the donor's body are cut or (snapMap) pointed at the car's own nodes
local function renameTreeParts(parts, prefix, snapMap, extraNames)
  local names = {}
  for name, _ in pairs(extraNames or {}) do names[name] = true end
  for _, part in ipairs(parts) do
    collectPartNames(part, names)
    -- rail names too (slidenodes point at them), the car may have a rail of the same name
    if type(part.rails) == 'table' then
      for railName, _ in pairs(part.rails) do
        if type(railName) == 'string' then names[railName] = true end
      end
    end
  end
  for _, part in ipairs(parts) do
    renamePartRefs(part, prefix, names, true, snapMap)
    if type(part.rails) == 'table' then
      local renamed = {}
      for railName, rail in pairs(part.rails) do
        renamed[type(railName) == 'string' and (prefix .. railName) or railName] = rail
      end
      part.rails = renamed
    end
  end
end

-- slidenodes of a swapped tree that ride a rail of the donor's frame (the semi's tandem axle slides on
-- frame rails): the rail never comes along, and a slidenode fixed to a missing rail (rail id -1) blew
-- the physics up. Those rows go; their nodes hang on the virtual frame like the other mount points
-- (S.railHooks, picked up in Phase2).
S.detachSwapRails = function(subtree, kind)
  local rails = {}
  for _, part in ipairs(subtree) do
    for name, _ in pairs(type(part.rails) == 'table' and part.rails or {}) do rails[name] = true end
  end
  local held = {}
  for _, part in ipairs(subtree) do
    local section = part.slidenodes
    if type(section) == 'table' and type(section[1]) == 'table' then
      local idCol, railCol
      for i, col in ipairs(section[1]) do
        if col == 'id:' or col == 'id' then idCol = i elseif col == 'railName' then railCol = i end
      end
      for r = #section, 2, -1 do
        local row = section[r]
        if idCol and railCol and type(row) == 'table' and type(row[idCol]) == 'string' and type(row[railCol]) == 'string' and not rails[row[railCol]] then
          held[#held + 1] = row[idCol]
          table.remove(section, r)
        end
      end
    end
  end
  if #held > 0 then
    S.railHooks = S.railHooks or {}
    S.railHooks[kind] = held
    log('I', logTag, string.format('part swap %s: %d slide rail mounts on the donor frame left out, the virtual frame holds their nodes (%s)', kind, #held, table.concat(held, ', ')))
  end
end

-- a swapped tree's own drivetrain devices may be named like one of the car's outside the tree (the
-- semi axle's "transfercase" shaft next to the pickup's transfercase): one overwrote the other, the
-- car's chain broke and the universal drivetrain saw nothing to replace. Clashing donor devices get
-- the swap prefix, with their data section and the inputs that point at them.
S.renameClashingDevices = function(journal, subtree, kind)
  local inTree, carNames, rename = {}, {}, {}
  for _, part in ipairs(subtree) do inTree[part] = true end
  local function eachDevice(part, fn)
    local pt = type(part) == 'table' and part.powertrain
    if type(pt) ~= 'table' or type(pt[1]) ~= 'table' then return end
    local nameCol, inputCol
    for i, col in ipairs(pt[1]) do
      if col == 'name' then nameCol = i elseif col == 'inputName' then inputCol = i end
    end
    if not nameCol then return end
    for r = 2, #pt do
      local row = pt[r]
      if type(row) == 'table' and type(row[nameCol]) == 'string' then fn(row, nameCol, inputCol) end
    end
  end
  for _, entry in ipairs(journal) do
    if type(entry[2]) == 'table' and not inTree[entry[2]] then
      eachDevice(entry[2], function(row, nameCol) carNames[row[nameCol]] = true end)
    end
  end
  for _, part in ipairs(subtree) do
    eachDevice(part, function(row, nameCol)
      if carNames[row[nameCol]] then rename[row[nameCol]] = partSwapPrefix(kind) .. row[nameCol] end
    end)
  end
  local list = {}
  for old, _ in pairs(rename) do list[#list + 1] = old end
  if #list == 0 then return end
  table.sort(list)
  for _, part in ipairs(subtree) do
    eachDevice(part, function(row, nameCol, inputCol)
      if rename[row[nameCol]] then row[nameCol] = rename[row[nameCol]] end
      if inputCol and rename[row[inputCol]] then row[inputCol] = rename[row[inputCol]] end
    end)
    for old, new in pairs(rename) do
      if type(part[old]) == 'table' then
        part[new], part[old] = part[old], nil
      end
    end
  end
  log('I', logTag, string.format('part swap %s: %d drivetrain devices renamed, the car has devices of those names (%s)', kind, #list, table.concat(list, ', ')))
end

-- before the parts get merged: give the whole tree of a swapped part (found by its slot path, so
-- whatever sub parts were picked) unique node names and cut its references to the donor's body
local function renameSwappedTrees(journal, partSwaps)
  for kind, swapSpec in pairs(partSwaps) do
    local snapMap = type(swapSpec) == 'table' and type(swapSpec.snapMap) == 'table' and swapSpec.snapMap or nil
    local alias = partSwapAlias(kind)
    local slotPath
    for _, entry in ipairs(journal) do
      local child, partPath = entry[2], entry[5]
      if type(child) == 'table' and child.partName == alias and type(partPath) == 'string' then
        slotPath = partPath:sub(1, #partPath - #alias)
        break
      end
    end
    if slotPath then
      -- a sub part the donor car itself can't load (the rockbouncer IFS asks for the pickup's
      -- pickup_airbump_IFS) only shows up because this car also has pickup parts; its mounts were
      -- never looked up, so it would hang loose. Leave it out, as on the donor.
      local donorCtx
      if type(swapSpec) == 'table' and swapSpec.model then
        local okCtx, ctx = pcall(jbeamIO.startLoading, {'/vehicles/' .. tostring(swapSpec.model) .. '/', '/vehicles/common/'})
        donorCtx = okCtx and ctx or nil
      end
      local getRaw = origGetPart or jbeamIO.getPart
      local subtree, foreign = {}, {}
      for _, entry in ipairs(journal) do
        local part = entry[2]
        if type(part) == 'table' and type(entry[5]) == 'string' and entry[5]:sub(1, #slotPath) == slotPath then
          if donorCtx and part.partName ~= alias and type(part.partName) == 'string' and not getRaw(donorCtx, part.partName) then
            foreign[#foreign + 1] = part.partName
            for key, _ in pairs(part) do
              if key ~= 'partName' and key ~= 'slotType' and key ~= 'information' then part[key] = nil end
            end
          else
            subtree[#subtree + 1] = part
          end
        end
      end
      if #foreign > 0 then
        log('W', logTag, string.format('part swap %s: left out %d parts the donor %s does not have: %s', kind, #foreign, tostring(swapSpec.model), table.concat(foreign, ', ')))
      end
      S.detachSwapRails(subtree, kind)
      if not (type(swapSpec) == 'table' and swapSpec.added) then S.renameClashingDevices(journal, subtree, kind) end
      -- an added axle (second rear axle) sits next to the car's own one, often the same donor
      -- suspension twice: its wheels get names of their own (two "RL" wheels would clash), and its
      -- own drivetrain devices / controllers stay out (the universal drivetrain drives its wheels).
      -- Its named beams too ("axle_RR", which a wheel watches through axleBeams): else each axle's
      -- wheel would watch the other axle's beam
      local beamNames
      if type(swapSpec) == 'table' and swapSpec.added then
        local wheelSections = S.wheelSections
        local renamedWheels, strippedDevices = 0, 0
        beamNames = {}
        for _, part in ipairs(subtree) do
          for _, row in ipairs(type(part.beams) == 'table' and part.beams or {}) do
            if type(row) == 'table' then
              if type(row.name) == 'string' and row.name ~= '' then beamNames[row.name] = true end
              for _, v in ipairs(row) do
                if type(v) == 'table' and type(v.name) == 'string' and v.name ~= '' then beamNames[v.name] = true end
              end
            end
          end
          if type(part.powertrain) == 'table' then
            strippedDevices = strippedDevices + math.max(0, #part.powertrain - 1)
            part.powertrain = nil
          end
          part.controller = nil
          for sectionName, section in pairs(part) do
            if wheelSections[sectionName] and type(section) == 'table' then
              for _, row in ipairs(section) do
                if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= 'name' then
                  row[1] = partSwapPrefix(kind) .. row[1]
                  renamedWheels = renamedWheels + 1
                end
              end
            end
          end
        end
        log('I', logTag, string.format('part swap %s (added axle): %d wheels renamed, %d drivetrain devices of its own left out', kind, renamedWheels, strippedDevices))
      end
      S.droppedRefs = {}
      renameTreeParts(subtree, partSwapPrefix(kind), snapMap, beamNames)
      log('I', logTag, string.format('part swap %s: renamed %d parts below %s', kind, #subtree, slotPath))
      local missing = {}
      local expected = {}
      for _, name in ipairs(type(swapSpec) == 'table' and swapSpec.anchorNames or {}) do expected[name] = true end
      local hookRows = 0
      for name, uses in pairs(S.droppedRefs) do
        if expected[name] then hookRows = hookRows + uses else missing[#missing + 1] = name .. ' x' .. uses end
      end
      if hookRows > 0 then log('I', logTag, string.format('part swap %s: %d mount rows of hooks left behind (the virtual frame holds them)', kind, hookRows)) end
      table.sort(missing)
      if #missing > 0 then
        log('W', logTag, string.format('part swap %s: %d donor nodes not found, rows on them dropped: %s', kind, #missing, table.concat(missing, ', ')))
      end
      S.droppedRefs = nil
    end
  end
end

-- same for a swapped engine: the engine and everything in its slots, except the car's own gearbox
-- branch (it keeps its names; it gets welded to the new block instead)
local function renameSwappedEngine(journal, swap)
  local slotPath
  for _, entry in ipairs(journal) do
    local child, partPath = entry[2], entry[5]
    if type(child) == 'table' and child.partName == swapAlias and type(partPath) == 'string' then
      slotPath = partPath:sub(1, #partPath - #swapAlias)
      break
    end
  end
  if not slotPath then return end
  local keep = {}
  for _, name in ipairs(swap.keepNames or {}) do keep[name] = true end
  local subtree = {}
  for _, entry in ipairs(journal) do
    local child, partPath = entry[2], entry[5]
    if type(child) == 'table' and type(partPath) == 'string' and partPath:sub(1, #slotPath) == slotPath then
      local seg = partPath:sub(#slotPath + 1):match('^([^/]+)/')
      local isGearboxBranch = swap.keepTransmission ~= false and ((seg and isTransmissionSlot({name = seg})) or keep[child.partName])
      if not isGearboxBranch then subtree[#subtree + 1] = child end
    end
  end
  local snapMap = type(swap.snapMap) == 'table' and swap.snapMap or nil
  renameTreeParts(subtree, enginePrefix, snapMap)
  log('I', logTag, string.format('engine swap: renamed %d parts below %s', #subtree, slotPath))
end

-- physics a donor tuning part (turbo, intake, ECU...) must not bring into the car's engine
local tunePhysicsSections = {
  nodes = true, beams = true, triangles = true, quads = true, hydros = true, torsionbars = true, rails = true,
  slidenodes = true, pressureWheels = true, refNodes = true, props = true, cameraExternal = true, cameraChase = true,
}

-- logic swap v4: everything picked in the donor tuning slots comes in as data only (torque mods,
-- turbo / supercharger, sounds, variables), its meshes hung on the car's engine block nodes
local function prepareTuneParts(journal, spec)
  local enginePart, slotPath
  for _, entry in ipairs(journal) do
    local child, partPath = entry[2], entry[5]
    if type(child) == 'table' and child.partName == spec.replaces and type(partPath) == 'string' and partPath:sub(-#spec.replaces) == spec.replaces then
      enginePart, slotPath = child, partPath:sub(1, #partPath - #spec.replaces)
      break
    end
  end
  if not slotPath then return end
  local groups = partNodeGroups(enginePart)
  local count = 0
  for _, entry in ipairs(journal) do
    local child, partPath = entry[2], entry[5]
    if type(child) == 'table' and type(partPath) == 'string' and partPath:sub(1, #slotPath + #tuneSlotPrefix) == slotPath .. tuneSlotPrefix then
      for sectionName, _ in pairs(tunePhysicsSections) do child[sectionName] = nil end
      -- their nodes are gone, so any node reference in their data (e.g. "oilpanNodes:") would stay a
      -- dangling name and crash the engine code: drop those, the car's own engine keeps its own
      for sectionName, section in pairs(child) do
        if type(section) == 'table' and not noRenameKeys[sectionName] and sectionName ~= 'flexbodies' and sectionName ~= 'powertrain' and sectionName ~= 'controller' then
          for k, _ in pairs(section) do
            if isNodeKey(k) then section[k] = nil end
          end
        end
      end
      if type(child.flexbodies) == 'table' then
        if #groups > 0 then
          for i, row in ipairs(child.flexbodies) do
            if i > 1 and type(row) == 'table' and type(row[1]) == 'string' then row[2] = deepcopy(groups) end
          end
        else
          child.flexbodies = nil
        end
      end
      count = count + 1
    end
  end
  log('I', logTag, string.format('engine logic swap: %d donor tuning parts loaded as data', count))
end

-- an added part comes alone: rows of its tree that hang on the donor car's body (a pickup bullbar's
-- beams and triangles to the pickup's frame and bumper, "f1l", "fb2") would otherwise land on the
-- car's own nodes of the same name, anywhere on its body, and pull it apart. They are left out;
-- the part hangs on its virtual mount instead (S.mountExtra).
S.isolateExtras = function(journal, extras)
  for i, ex in ipairs(extras) do
    local path = '/' .. extraSlotPrefix .. i .. '/'
    local parts = {}
    for _, entry in ipairs(journal) do
      local part, partPath = entry[2], entry[5]
      if type(part) == 'table' and type(partPath) == 'string' and partPath:sub(1, #path) == path then parts[#parts + 1] = part end
    end
    if #parts > 0 and type(ex) == 'table' and not ex.meshOnly then
      local names = {}
      for _, part in ipairs(parts) do
        collectPartNames(part, names)
        for railName, _ in pairs(type(part.rails) == 'table' and part.rails or {}) do
          if type(railName) == 'string' then names[railName] = true end
        end
      end
      S.detachSwapRails(parts, 'extra' .. i) -- its nodes hang on the virtual mount's cage anyway
      S.droppedRefs, S.mountRefs = {}, {}
      for _, part in ipairs(parts) do renamePartRefs(part, '', names, true) end
      -- where the part held on to its donor (beams to the donor's body, slide rails on its frame): a
      -- hitch hangs on its virtual mount there only, so its plate / hook still moves (Phase2)
      for _, name in ipairs(type(S.railHooks) == 'table' and S.railHooks['extra' .. i] or {}) do S.mountRefs[name] = true end
      if type(S.extraMounts) == 'table' then S.extraMounts[i] = S.mountRefs end
      S.mountRefs = nil
      local list, rows = {}, 0
      for name, uses in pairs(S.droppedRefs) do
        list[#list + 1] = name .. ' x' .. uses
        rows = rows + uses
      end
      S.droppedRefs = nil
      table.sort(list)
      if rows > 0 then
        log('I', logTag, string.format('extra part %d (%s): %d rows on the donor car\'s body left out (%s) - it hangs on its own virtual mount', i, tostring(ex.part), rows, table.concat(list, ', ')))
      end
    end
  end
end

-- the powertrain devices an added part (or a sub part of it) brings, by name
S.noteExtraDevices = function(part, idx)
  if type(S.extraDevices) ~= 'table' or type(part.powertrain) ~= 'table' then return end
  for _, row in ipairs(part.powertrain) do
    if type(row) == 'table' and type(row[2]) == 'string' and row[1] ~= 'type' then S.extraDevices[row[2]] = idx end
  end
end

-- devices of added parts that hang on an engine (a truck's air compressor on its engine's 3rd
-- output): the car's engine gets the output ports they need (an engine has only 1 unless its jbeam
-- says more), a port another device already uses moves them to a free one, and an engine of
-- another name than the donor's becomes theirs. Devices that need an energy storage the car does
-- not have (the compressor's air tank) are reported.
S.connectExtraDevices = function(vehicle)
  local pt = vehicle.powertrain
  if type(pt) ~= 'table' or type(S.extraDevices) ~= 'table' or next(S.extraDevices) == nil then return end
  local byName, kids = {}, {}
  for _, d in pairs(pt) do
    if type(d) == 'table' and type(d.name) == 'string' then byName[d.name] = d end
  end
  for _, d in pairs(byName) do
    if type(d.inputName) == 'string' then
      kids[d.inputName] = kids[d.inputName] or {}
      table.insert(kids[d.inputName], d)
    end
  end
  local engine = byName.mainEngine
  if not (engine and engine.type == 'combustionEngine') then
    engine = nil
    for name, d in pairs(byName) do
      if d.type == 'combustionEngine' and not S.extraDevices[name] and (not engine or name < engine.name) then engine = d end
    end
  end
  local storages = {}
  for _, s in pairs(type(vehicle.energyStorage) == 'table' and vehicle.energyStorage or {}) do
    if type(s) == 'table' and type(s.name) == 'string' then storages[s.name] = true end
  end
  local names = {}
  for name, _ in pairs(S.extraDevices) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local d = byName[name]
    local parent = d and byName[d.inputName]
    if d and not parent and engine and type(d.inputName) == 'string' and d.inputName:lower():find('engine', 1, true) then
      log('I', logTag, string.format('added device %s: the car has no %s, it goes onto %s', name, d.inputName, engine.name))
      d.inputName = engine.name
      parent = engine
      kids[engine.name] = kids[engine.name] or {}
      table.insert(kids[engine.name], d)
    end
    local data = parent and parent.type == 'combustionEngine' and vehicle[parent.name]
    if type(data) == 'table' then
      local ports = tonumber(data.numberOfOutputPorts) or 1
      local used = {}
      for _, c in ipairs(kids[parent.name] or {}) do
        if c ~= d then used[tonumber(c.inputIndex) or 1] = true end
      end
      local idx = tonumber(d.inputIndex) or 1
      if used[idx] then
        local from = idx
        idx = math.max(ports, 1) + 1
        while used[idx] do idx = idx + 1 end
        log('I', logTag, string.format('added device %s: output %d of %s is taken, it uses output %d', name, from, parent.name, idx))
      end
      d.inputIndex = idx
      if idx > ports then
        data.numberOfOutputPorts = idx
        log('I', logTag, string.format('added device %s: %s now has %d output ports (was %d)', name, parent.name, idx, ports))
      end
    end
    local own = d and vehicle[name]
    local need = type(own) == 'table' and own.energyStorage
    for _, s in ipairs(type(need) == 'table' and need or {need}) do
      if type(s) == 'string' and not storages[s] then
        log('W', logTag, string.format('added device %s needs the energy storage %s, the car has none', name, s))
        msg(string.format('%s neturi kur kaupti: reikia "%s" (pvz. oro bako is tos pacios masinos) - pridek ir ji.', name, s), 10)
      end
    end
  end
end

local function wrappedUnifyPartJournal(ioCtx, journal)
  local swaps = pendingUnifySwaps
  local engineSwap = pendingUnifyEngine
  local logicSwap = pendingUnifyLogic
  local extras = S.pendingUnifyExtras
  pendingUnifySwaps, pendingUnifyEngine, pendingUnifyLogic, S.pendingUnifyExtras = nil, nil, nil, nil
  if extras and type(journal) == 'table' then
    local ok, err = pcall(S.isolateExtras, journal, extras)
    if not ok then log('E', logTag, 'isolating the added parts failed: ' .. tostring(err)) end
  end
  if logicSwap and type(journal) == 'table' then
    local ok, err = pcall(prepareTuneParts, journal, logicSwap)
    if not ok then log('E', logTag, 'preparing donor tuning parts failed: ' .. tostring(err)) end
  end
  if swaps and type(journal) == 'table' then
    local ok, err = pcall(renameSwappedTrees, journal, swaps)
    if not ok then log('E', logTag, 'renaming swapped parts failed: ' .. tostring(err)) end
  end
  if engineSwap and type(journal) == 'table' then
    local ok, err = pcall(renameSwappedEngine, journal, engineSwap)
    if not ok then log('E', logTag, 'renaming swapped engine failed: ' .. tostring(err)) end
  end
  return origUnifyPartJournal(ioCtx, journal)
end

local function installLoaderHooks()
  if origFindParts then return end
  origFindParts = jbeamSlotSystem.findParts
  origGetPart = jbeamIO.getPart
  origUnifyPartJournal = jbeamSlotSystem.unifyPartJournal
  jbeamSlotSystem.findParts = wrappedFindParts
  jbeamIO.getPart = wrappedGetPart
  jbeamSlotSystem.unifyPartJournal = wrappedUnifyPartJournal
end

local function removeLoaderHooks()
  if not origFindParts then return end
  jbeamSlotSystem.findParts = origFindParts
  jbeamIO.getPart = origGetPart
  jbeamSlotSystem.unifyPartJournal = origUnifyPartJournal
  origFindParts, origGetPart, origUnifyPartJournal = nil, nil, nil
end

-- nodes nothing may be welded to: the driver / passenger dummies, seats, interior, cargo. On some
-- cars (bolide) the driver dummy even has more nodes than the chassis, and a suspension welded to
-- a soft ragdoll blows the physics up
S.loosePartWords = {'occupant', 'driver', 'passenger', 'seat', 'interior', 'cargo', 'dummy'}
local function isLooseNode(n)
  local o = tostring(n.partOrigin or ''):lower()
  for _, word in ipairs(S.loosePartWords) do
    if o:find(word, 1, true) then return true end
  end
  return false
end

-- every node isPart() picks gets beamed to its k nearest body nodes (current length, so no pull);
-- for imported donor body points, which must all be held or the suspension hangs on nothing
-- isPreferred(n): body nodes to use first (the car's original suspension mounts), then the chassis part
-- visualSet[name]: mesh-only points (1 kg), linked softly so they follow along without carrying load
local function weldEachToNearest(vehicle, isPart, isBody, spec, k, maxDist, isPreferred, visualSet)
  visualSet = visualSet or {}
  local wheelHubs = {}
  for _, w in pairs(vehicle.wheels or {}) do
    if type(w) == 'table' then
      if type(w.node1) == 'number' then wheelHubs[w.node1] = true end
      if type(w.node2) == 'number' then wheelHubs[w.node2] = true end
    end
  end
  local parts, bx, by, bz, bn = {}, {}, {}, {}, {}
  local perOrigin = {}
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and type(n.cid) == 'number' and n.pos then
      if isPart(n) then
        parts[#parts + 1] = n
      elseif isBody(n) and n.wheelID == nil and not wheelHubs[n.cid] and not isLooseNode(n)
        and (tonumber(n.nodeWeight) or 5) >= 1.0 then -- not on light sheet metal nodes
        local i = #bn + 1
        bn[i], bx[i], by[i], bz[i] = n, n.pos.x, n.pos.y, n.pos.z
        local o = tostring(n.partOrigin)
        perOrigin[o] = (perOrigin[o] or 0) + 1
      end
    end
  end
  if #parts == 0 or #bn == 0 then return 0, #parts end

  -- the car's structure, not fenders or bumpers: every part named like one (chassis, frame, body,
  -- subframe, tub...; the bolide has a chassis and two subframes) and the part with the most nodes
  local chassisOrigin, most = nil, 0
  for o, c in pairs(perOrigin) do
    if c > most then chassisOrigin, most = o, c end
  end
  local structural = {}
  if chassisOrigin then structural[chassisOrigin] = true end
  for o, _ in pairs(perOrigin) do
    local lo = o:lower()
    for _, word in ipairs({'chassis', 'frame', 'body', 'subframe', 'unibody', 'tub', 'monocoque', 'cage'}) do
      if lo:find(word, 1, true) then structural[o] = true break end
    end
  end

  local strength = tonumber(spec.strength) or 40000
  if strength < 0 then strength = math.huge end
  -- bends from half its strength, as BeamNG's own mount beams do (deform 14000 / strength 28000)
  local deform = strength == math.huge and math.huge or strength * 0.5
  local maxD2 = maxDist * maxDist
  vehicle.beams = vehicle.beams or {}
  -- beams are collected first: many welds often end on the same few mount nodes, and their summed
  -- stiffness gets scaled down to what the node mass can take at the 2 kHz step
  local pendingBeams = {}
  local function addBeam(a, b, spring)
    -- mesh-only points are light: soft and almost undamped, or the 2 kHz step goes unstable
    -- (beam damping summed over a node, times the step, over its mass must stay well below 1)
    local damp = 150
    if visualSet[a.name] or visualSet[b.name] then spring, damp = 200000, 10 end
    pendingBeams[#pendingBeams + 1] = {a = a, b = b, spring = spring, damp = damp}
  end
  local function commitBeams()
    local added, addedDamp, existing = {}, {}, {}
    for _, pb in ipairs(pendingBeams) do
      for _, n in ipairs({pb.a, pb.b}) do
        added[n.cid] = (added[n.cid] or 0) + pb.spring
        addedDamp[n.cid] = (addedDamp[n.cid] or 0) + pb.damp
        existing[n.cid] = existing[n.cid] or 0
      end
    end
    for _, b in pairs(vehicle.beams) do
      if type(b) == 'table' and type(b.beamSpring) == 'number' and b.beamSpring < 1e9 then
        if existing[b.id1] then existing[b.id1] = existing[b.id1] + b.beamSpring end
        if existing[b.id2] then existing[b.id2] = existing[b.id2] + b.beamSpring end
      end
    end
    local defaultMass = tonumber(type(vehicle.options) == 'table' and vehicle.options.nodeWeight) or 5
    local omega2 = 2500 * 2500 -- omega * dt = 1.25 at 2 kHz
    local factor = {}
    for cid, sum in pairs(added) do
      local n = vehicle.nodes[cid]
      local mass = math.max(0.5, tonumber(n and n.nodeWeight) or defaultMass)
      local budget = math.max(mass * omega2 - existing[cid], 0.3 * mass * omega2)
      local dampBudget = 0.3 * mass / 0.0005
      factor[cid] = {
        spring = math.max(0.002, math.min(1, budget / sum)), -- no real floor: the budget is the limit
        damp = math.min(1, dampBudget / math.max(1e-9, addedDamp[cid])),
      }
    end
    local scaled = 0
    for _, pb in ipairs(pendingBeams) do
      local fa, fb = factor[pb.a.cid], factor[pb.b.cid]
      local fs, fd = math.min(fa.spring, fb.spring), math.min(fa.damp, fb.damp)
      if fs < 1 then scaled = scaled + 1 end
      local bcid = vehicle.maxIDs.beams or 0
      vehicle.maxIDs.beams = bcid + 1
      vehicle.beams[bcid] = {
        cid = bcid, id1 = pb.a.cid, id2 = pb.b.cid, beamType = 0,
        beamSpring = pb.spring * fs, beamDamp = pb.damp * fd, beamDeform = deform, beamStrength = strength,
        partOrigin = pb.a.partOrigin,
      }
    end
    return scaled
  end
  local preferredIdx = {}
  if isPreferred then
    for i = 1, #bn do
      if isPreferred(bn[i]) then preferredIdx[i] = true end
    end
  end
  local hasPreferred = next(preferredIdx) ~= nil
  -- filter: 'preferred', 'chassis' or nil (any body node)
  local function nearest(px, py, pz, filter)
    local best = {}
    for i = 1, #bn do
      local okNode = filter == nil
        or (filter == 'chassis' and structural[tostring(bn[i].partOrigin)])
        or (filter == 'preferred' and preferredIdx[i])
      if okNode then
        local dx, dy, dz = bx[i] - px, by[i] - py, bz[i] - pz
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 >= 0.0001 and d2 <= maxD2 then
          if #best < k then
            best[#best + 1] = {i = i, d2 = d2}
            table.sort(best, function(a, b) return a.d2 < b.d2 end)
          elseif d2 < best[k].d2 then
            best[k] = {i = i, d2 = d2}
            table.sort(best, function(a, b) return a.d2 < b.d2 end)
          end
        end
      end
    end
    return best
  end

  -- spring rates kept moderate: too stiff for the node masses makes the 2 kHz physics step unstable
  local weldSpring = 4000000
  local count, loose = 0, 0
  local attached = {} -- cids of the car's nodes that carry the part
  for _, p in ipairs(parts) do
    p.collision, p.selfCollision = false, false
    local px, py, pz = p.pos.x, p.pos.y, p.pos.z
    local best = hasPreferred and nearest(px, py, pz, 'preferred') or {}
    if spec.spread then
      -- independent bundle: besides the original mounts, the load goes into the chassis' nearest
      -- nodes too, so no single body node carries a whole axle
      local used = {}
      for _, b in ipairs(best) do used[b.i] = true end
      for _, b in ipairs(nearest(px, py, pz, 'chassis')) do
        if not used[b.i] then best[#best + 1] = b end
      end
    end
    if #best == 0 then best = nearest(px, py, pz, 'chassis') end
    if #best == 0 then best = nearest(px, py, pz, nil) end
    if #best == 0 then loose = loose + 1 end
    for _, b in ipairs(best) do
      addBeam(p, bn[b.i], weldSpring)
      attached[bn[b.i].cid] = true
      count = count + 1
    end
  end

  -- tie the imported points to their 4 nearest neighbours: a virtual subframe keeps the donor
  -- geometry (shock tops, steering box, link mounts) even where the car's body gives a little.
  -- spec.rigidFrame: every load carrying point to every other within 4 m, a rigid frame of its own
  local linked = {}
  for i = 1, #parts do
    local near = {}
    local rigid = spec.rigidFrame and not visualSet[parts[i].name]
    for j = 1, #parts do
      if j ~= i then
        local d = parts[i].pos:distance(parts[j].pos)
        local limit = (rigid and not visualSet[parts[j].name]) and (spec.hookNodes and 10.0 or 4.0) or 1.5
        if d >= 0.01 and d <= limit then near[#near + 1] = {j = j, d = d} end
      end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for m = 1, rigid and #near or math.min(4, #near) do
      local j = near[m].j
      local key = math.min(i, j) .. ':' .. math.max(i, j)
      if not linked[key] then
        linked[key] = true
        addBeam(parts[i], parts[j], weldSpring * 0.5)
        count = count + 1
      end
    end
  end

  -- spec.hookNodes: parts are the virtual frame's corners; every hook (a suspension node the donor's
  -- frame held, an imported donor body point) is held by all of them, never by the car's body.
  -- spec.visualNodes (mesh-only points) follow the 4 nearest hooks / corners softly.
  if spec.hookNodes then
    for _, h in ipairs(spec.hookNodes) do
      h.selfCollision = false
      for _, p in ipairs(parts) do
        if h.pos:distance(p.pos) >= 0.01 then
          addBeam(h, p, weldSpring * 0.5)
          count = count + 1
        end
      end
    end
    for _, v in ipairs(spec.visualNodes or {}) do
      v.collision, v.selfCollision = false, false
      local near = {}
      for _, list in ipairs({spec.hookNodes, parts}) do
        for _, n in ipairs(list) do
          local d = v.pos:distance(n.pos)
          if d >= 0.01 then near[#near + 1] = {n = n, d = d} end
        end
      end
      table.sort(near, function(a, b) return a.d < b.d end)
      for m = 1, math.min(4, #near) do
        addBeam(v, near[m].n, 200000)
        count = count + 1
      end
    end
  end
  local scaled = commitBeams()
  local structNames = {}
  for o, _ in pairs(structural) do structNames[#structNames + 1] = o end
  table.sort(structNames)
  log('I', logTag, string.format('welded to %s (structure: %s), %d weld beams softened to fit the node masses',
    hasPreferred and "the car's original suspension mounts" or 'the chassis', table.concat(structNames, ', '), scaled))
  return count, loose, attached
end

-- stability check of a swap: the physics step (2 kHz) blows up on a node whose summed beam stiffness
-- is too high for its mass (omega * dt > ~2). Only for nodes the mod made or re-weighted (imported
-- points, virtual frame, hooks, welded body nodes): every one gets just enough mass for omega * dt
-- <= 1.4. Damping is only reported - BeamNG copes with it (its own 0.1 kg shock and tyre nodes
-- carry a lot of it), and counting it once hung 40 kg on every coilover node.
local function stabilizeNodes(vehicle, nodeSet, label)
  local dt = 0.0005
  local K, C = {}, {}
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and b.beamType ~= 5 and (nodeSet[b.id1] or nodeSet[b.id2]) then
      local k = 0
      if type(b.beamSpring) == 'number' and b.beamSpring < 1e10 then k = b.beamSpring end
      if b.beamType == 2 and type(b.beamLimitSpring) == 'number' and b.beamLimitSpring < 1e10 then k = math.max(k, b.beamLimitSpring) end
      local c = 0
      for _, key in ipairs({'beamDamp', 'beamDampRebound', 'beamDampFast', 'beamDampReboundFast', 'beamLimitDamp', 'beamLimitDampRebound'}) do
        if type(b[key]) == 'number' and b[key] < 1e9 then c = math.max(c, b[key]) end
      end
      for _, cid in ipairs({b.id1, b.id2}) do
        if nodeSet[cid] then
          K[cid] = (K[cid] or 0) + k
          C[cid] = (C[cid] or 0) + c
        end
      end
    end
  end
  local defaultMass = tonumber(type(vehicle.options) == 'table' and vehicle.options.nodeWeight) or 25
  local fixed, added, worst = 0, 0, {}
  for cid, _ in pairs(nodeSet) do
    local n = vehicle.nodes[cid]
    if type(n) == 'table' and n.wheelID == nil then
      local m = tonumber(n.nodeWeight) or defaultMass
      local needK = (K[cid] or 0) * dt * dt / 1.96 -- omega * dt <= 1.4  <=>  m >= K * dt^2 / 1.4^2
      local need = needK
      if need > m then
        local newMass = math.min(40, need)
        worst[#worst + 1] = {name = tostring(n.name), m = m, need = need, wdt = math.sqrt((K[cid] or 0) / m) * dt, cdt = (C[cid] or 0) * dt / m}
        n.nodeWeight = newMass
        added = added + newMass - m
        fixed = fixed + 1
      end
    end
  end
  table.sort(worst, function(a, b) return a.need / a.m > b.need / b.m end)
  local list = {}
  for i = 1, math.min(6, #worst) do
    local w = worst[i]
    list[#list + 1] = string.format('%s %.1f->%.1f kg (w*dt %.2f, c*dt/m %.2f)', w.name, w.m, math.min(40, w.need), w.wdt, w.cdt)
  end
  log(fixed > 0 and 'W' or 'I', logTag, string.format('%s stability: %d nodes made heavier (+%.0f kg)%s', label, fixed, added,
    #list > 0 and (': ' .. table.concat(list, '; ')) or ''))
  -- the riskiest nodes as they are now, for the diagnostics file
  local risk, total = {}, 0
  for cid, _ in pairs(nodeSet) do
    local n = vehicle.nodes[cid]
    if type(n) == 'table' then
      local m = tonumber(n.nodeWeight) or defaultMass
      total = total + m
      risk[#risk + 1] = {name = tostring(n.name), m = m, wdt = math.sqrt((K[cid] or 0) / m) * dt, cdt = (C[cid] or 0) * dt / m, wheel = n.wheelID ~= nil}
    end
  end
  table.sort(risk, function(a, b) return a.wdt > b.wdt end)
  local top = {}
  for i = 1, math.min(8, #risk) do
    local r = risk[i]
    top[#top + 1] = string.format('%s%s %.1f kg w*dt %.2f c*dt/m %.2f', r.name, r.wheel and ' (tyre)' or '', r.m, r.wdt, r.cdt)
  end
  log('I', logTag, string.format('%s: %d nodes, %.0f kg; riskiest now: %s', label, #risk, total, table.concat(top, '; ')))
  return fixed
end

-- independent swapped bundle: its own beams (not the tyres) and the car's body around the nodes it
-- hangs on (two rings of beams) never break, so the load of a foreign axle can't tear the car apart.
-- They still bend as before (a crash dents them): undeformable too, they left most of a car with a
-- front and a rear swap rubbery. The settle time protects and restores them like any other beam.
local function reinforceSwap(vehicle, subtreeSet, attached)
  local wheelNode = {}
  for cid, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.wheelID ~= nil then wheelNode[cid] = true end
  end
  local ring = {}
  for cid, _ in pairs(attached) do ring[cid] = 0 end
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and not subtreeSet[b.id1] and not subtreeSet[b.id2] then
      if ring[b.id1] == 0 and not ring[b.id2] then ring[b.id2] = 1 end
      if ring[b.id2] == 0 and not ring[b.id1] then ring[b.id1] = 1 end
    end
  end
  local kept = 0
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and not wheelNode[b.id1] and not wheelNode[b.id2] then
      local inBundle = subtreeSet[b.id1] or subtreeSet[b.id2]
      local nearMount = ring[b.id1] == 0 or ring[b.id2] == 0 or (ring[b.id1] and ring[b.id2])
      if inBundle or nearMount then
        b.beamStrength = math.huge
        kept = kept + 1
      end
    end
  end
  return kept
end

-- weld beams between the nodes isPart() picks and the car body (isBody()), at their current length
local function addWelds(vehicle, isPart, isBody, ex, label)
  local wheelHubs = {}
  for _, w in pairs(vehicle.wheels or {}) do
    if type(w) == 'table' then
      if type(w.node1) == 'number' then wheelHubs[w.node1] = true end
      if type(w.node2) == 'number' then wheelHubs[w.node2] = true end
    end
  end
  local defaultWeight = vehicle.options and vehicle.options.nodeWeight or 25

  local partNodes, partSet, body = {}, {}, {}
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and type(n.cid) == 'number' and n.pos then
      if isPart(n) then
        partNodes[#partNodes + 1] = n
        partSet[n.cid] = true
      elseif isBody(n) and n.wheelID == nil and not wheelHubs[n.cid] and not isLooseNode(n) then
        body[#body + 1] = {n = n, w = type(n.nodeWeight) == 'number' and n.nodeWeight or defaultWeight}
      end
    end
  end
  if #partNodes == 0 or #body == 0 then
    log('W', logTag, tostring(label) .. ': no nodes to weld')
    return 0
  end

  for _, n in ipairs(partNodes) do
    n.selfCollision = false
    if ex.noCollision then
      n.collision = false
      n.staticCollision = true
    end
  end
  if ex.noCollision then
    for _, t in pairs(vehicle.triangles or {}) do
      if type(t) == 'table' and partSet[t.id1] and partSet[t.id2] and partSet[t.id3] then t.triangleType = 'NONCOLLIDABLE' end
    end
  end

  -- candidates: part nodes with body nodes in reach, best (heavy, close) body nodes first
  local maxGap = math.max(0.02, tonumber(ex.maxGap) or 0.3)
  local maxGap2, minD2 = maxGap * maxGap, 0.01 * 0.01
  local bx, by, bz = {}, {}, {}
  for k, b in ipairs(body) do bx[k], by[k], bz[k] = b.n.pos.x, b.n.pos.y, b.n.pos.z end
  local bodyCount = #body
  local cands = {}
  local nearestPair
  for _, pn in ipairs(partNodes) do
    local px, py, pz = pn.pos.x, pn.pos.y, pn.pos.z
    local reach = {}
    local bestD2, bestK = math.huge, nil
    for k = 1, bodyCount do
      local dx, dy, dz = bx[k] - px, by[k] - py, bz[k] - pz
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 >= minD2 then
        if d2 < bestD2 then bestD2, bestK = d2, k end
        if d2 <= maxGap2 then
          local d = math.sqrt(d2)
          reach[#reach + 1] = {n = body[k].n, d = d, score = body[k].w * (1 - 0.5 * d / maxGap)}
        end
      end
    end
    if bestK and (not nearestPair or bestD2 < nearestPair.d * nearestPair.d) then
      nearestPair = {p = pn, b = body[bestK].n, d = math.sqrt(bestD2)}
    end
    if #reach > 0 then
      table.sort(reach, function(x, y) return x.score > y.score end)
      cands[#cands + 1] = {p = pn, reach = reach, score = reach[1].score}
    end
  end

  -- spread the welds over the part (farthest point sampling)
  local wanted = math.max(1, tonumber(ex.welds) or 10)
  local chosen = {}
  while #chosen < wanted do
    local best, bestScore = nil, -math.huge
    for _, c in ipairs(cands) do
      if not c.used then
        local minD = math.huge
        for _, ch in ipairs(chosen) do minD = math.min(minD, c.p.pos:distance(ch.p.pos)) end
        if minD > 0.05 then
          local s = (#chosen == 0) and c.score or (minD * (1 + 0.05 * c.score))
          if s > bestScore then best, bestScore = c, s end
        end
      end
    end
    if not best then break end
    best.used = true
    chosen[#chosen + 1] = best
  end
  if #chosen == 0 and nearestPair then
    log('W', logTag, string.format('%s is %.2f m from the body, welding to the nearest node only', tostring(label), nearestPair.d))
    chosen[1] = {p = nearestPair.p, reach = {{n = nearestPair.b, d = nearestPair.d}}}
  end

  local strength = tonumber(ex.strength) or 40000
  if strength < 0 then strength = math.huge end
  local deform = strength == math.huge and math.huge or strength * 0.5 -- bends from half, as above
  vehicle.beams = vehicle.beams or {}
  local count = 0
  for _, c in ipairs(chosen) do
    for k = 1, math.min(3, #c.reach) do
      local bcid = vehicle.maxIDs.beams or 0
      vehicle.maxIDs.beams = bcid + 1
      vehicle.beams[bcid] = {
        cid = bcid, id1 = c.p.cid, id2 = c.reach[k].n.cid, beamType = 0,
        beamSpring = 4000000, beamDamp = 250, beamDeform = deform, beamStrength = strength,
        partOrigin = c.p.partOrigin,
      }
      count = count + 1
    end
  end
  return count
end

-- an added part with physics on a virtual mount: 8 light frame points around it hold every node of
-- the part (a rigid cage), and only those points are welded to the car's structure (chassis / frame
-- / body nodes, spread, stiffness sized to the node masses). The part keeps its weight, its own
-- beams and its collisions; no node of the car carries a node of the part directly. hooks: only
-- these nodes are held by the cage (a hitch's mount points), the rest moves on the part's own beams.
S.mountExtra = function(vehicle, i, ex, isPart, isBody, hooks)
  local defaultMass = tonumber(type(vehicle.options) == 'table' and vehicle.options.nodeWeight) or 25
  local list, mass = {}, 0
  local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and isPart(n) then
      list[#list + 1] = n
      mass = mass + (tonumber(n.nodeWeight) or defaultMass)
      lo:set(math.min(lo.x, n.pos.x), math.min(lo.y, n.pos.y), math.min(lo.z, n.pos.z))
      hi:set(math.max(hi.x, n.pos.x), math.max(hi.y, n.pos.y), math.max(hi.z, n.pos.z))
    end
  end
  if #list == 0 then return 0, 0, 0 end
  if ex.noCollision then
    local set = {}
    for _, n in ipairs(list) do
      n.collision, n.staticCollision = false, true
      set[n.cid] = true
    end
    for _, t in pairs(vehicle.triangles or {}) do
      if type(t) == 'table' and set[t.id1] and set[t.id2] and set[t.id3] then t.triangleType = 'NONCOLLIDABLE' end
    end
  end
  -- the box around the part, 5 cm out, at least 16 cm thick (a flat part would give coinciding corners)
  local c = (lo + hi) * 0.5
  local h = (hi - lo) * 0.5
  h = vec3(math.max(0.08, h.x + 0.05), math.max(0.08, h.y + 0.05), math.max(0.08, h.z + 0.05))
  local nextCid = 0
  while vehicle.nodes[nextCid] ~= nil do nextCid = nextCid + 1 end
  local frameSet, k = {}, 0
  local cornerMass = math.min(3, math.max(0.5, mass * 0.04))
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      for _, sz in ipairs({-1, 1}) do
        k = k + 1
        vehicle.nodes[nextCid] = {cid = nextCid, name = 'upa' .. i .. '_upavf' .. k, pos = c + vec3(sx * h.x, sy * h.y, sz * h.z),
          nodeWeight = cornerMass, collision = false, selfCollision = false, staticCollision = false, partOrigin = list[1].partOrigin}
        frameSet[nextCid] = true
        nextCid = nextCid + 1
      end
    end
  end
  vehicle.maxIDs.nodes = math.max(tonumber(vehicle.maxIDs.nodes) or 0, nextCid)
  local function isFrame(n) return frameSet[n.cid] == true end
  local perCorner = math.max(2, math.min(8, math.floor((tonumber(ex.welds) or 10) / 3 + 0.5)))
  local reach = math.max(1.0, (tonumber(ex.maxGap) or 0.3) * 3)
  local count, loose = weldEachToNearest(vehicle, isFrame, isBody,
    {strength = ex.strength, rigidFrame = true, hookNodes = hooks or list, spread = true}, perCorner, reach, nil, nil)
  stabilizeNodes(vehicle, frameSet, 'extra part ' .. i .. ' mount')
  return count, loose or 0, mass
end

-- a collision triangle of the part that sits in the car's body at spawn (the part placed a little
-- into the bumper) would shove those body nodes out at once: it stops colliding with the car
S.unblockOverlaps = function(vehicle, isPart)
  local function closest(p, a, b, c)
    local ab, ac, ap = b - a, c - a, p - a
    local d1, d2 = ab:dot(ap), ac:dot(ap)
    if d1 <= 0 and d2 <= 0 then return a end
    local bp = p - b
    local d3, d4 = ab:dot(bp), ac:dot(bp)
    if d3 >= 0 and d4 <= d3 then return b end
    local vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0 then return a + ab * (d1 / (d1 - d3)) end
    local cp = p - c
    local d5, d6 = ab:dot(cp), ac:dot(cp)
    if d6 >= 0 and d5 <= d6 then return c end
    local vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0 then return a + ac * (d2 / (d2 - d6)) end
    local va = d3 * d6 - d5 * d4
    if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0 then return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) end
    local denom = 1 / (va + vb + vc)
    return a + ab * (vb * denom) + ac * (vc * denom)
  end
  local carNodes = {}
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and n.selfCollision == true and not isPart(n) then carNodes[#carNodes + 1] = n.pos end
  end
  local gap, fixed = 0.04, 0
  for _, t in pairs(vehicle.triangles or {}) do
    local na, nb, nc = vehicle.nodes[t.id1], vehicle.nodes[t.id2], vehicle.nodes[t.id3]
    if type(t) == 'table' and t.triangleType ~= 'NONCOLLIDABLE' and na and nb and nc and isPart(na) and isPart(nb) and isPart(nc) then
      local a, b, c = na.pos, nb.pos, nc.pos
      local x0, x1 = math.min(a.x, b.x, c.x) - gap, math.max(a.x, b.x, c.x) + gap
      local y0, y1 = math.min(a.y, b.y, c.y) - gap, math.max(a.y, b.y, c.y) + gap
      local z0, z1 = math.min(a.z, b.z, c.z) - gap, math.max(a.z, b.z, c.z) + gap
      for _, p in ipairs(carNodes) do
        if p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and p.z >= z0 and p.z <= z1 and closest(p, a, b, c):distance(p) < gap then
          t.triangleType = 'NONCOLLIDABLE'
          fixed = fixed + 1
          break
        end
      end
    end
  end
  return fixed
end

--------------------------------------------------------------------------------
-- logic suspension: the car keeps its own suspension geometry and physics; springs, dampers, sway
-- bars and ride height get the donor's character and / or the slider values
--------------------------------------------------------------------------------

local BEAM_BOUNDED_TYPE = 2

-- s = {part = car suspension part, springMul, dampMul, swayMul, lift (m), donor = {spring, damp, sway}}
local function tuneSuspensionAxle(vehicle, s)
  if type(s) ~= 'table' or type(s.part) ~= 'string' then return 'no suspension part' end
  local slotPath
  for _, n in pairs(vehicle.nodes or {}) do
    if type(n) == 'table' and n.partOrigin == s.part and type(n.partPath) == 'string' and n.partPath:sub(-#s.part) == s.part then
      slotPath = n.partPath:sub(1, #n.partPath - #s.part)
      break
    end
  end
  if not slotPath then return 'suspension part ' .. s.part .. ' not found' end
  local inSub = {}
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and type(n.cid) == 'number' and type(n.partPath) == 'string' and n.partPath:sub(1, #slotPath) == slotPath then
      inSub[n.cid] = true
    end
  end

  -- springs: bounded beams with a spring rate; dampers: bounded beams with damping only
  local springs, dampers, bounded = {}, {}, {}
  local springSum, dampSum = 0, 0
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and b.beamType == BEAM_BOUNDED_TYPE and (inSub[b.id1] or inSub[b.id2]) then
      bounded[#bounded + 1] = b
      local k, c = tonumber(b.beamSpring) or 0, tonumber(b.beamDamp) or 0
      if k > 0 and k < 1000000 then
        springs[#springs + 1] = b
        springSum = springSum + k
      elseif k == 0 and c > 0 then
        dampers[#dampers + 1] = b
        dampSum = dampSum + c
      end
    end
  end
  local bars, barSum = {}, 0
  for _, t in pairs(vehicle.torsionbars or {}) do
    if type(t) == 'table' and type(t.spring) == 'number' and (inSub[t.id1] or inSub[t.id2] or inSub[t.id3] or inSub[t.id4]) then
      bars[#bars + 1] = t
      barSum = barSum + t.spring
    end
  end

  -- donor character: scale the car's rates to the donor's average, then the sliders on top
  local donor = type(s.donor) == 'table' and s.donor or {}
  local springScale = tonumber(s.springMul) or 1
  if tonumber(donor.spring) and #springs > 0 and springSum > 0 then springScale = springScale * donor.spring / (springSum / #springs) end
  local dampScale = tonumber(s.dampMul) or 1
  if tonumber(donor.damp) and #dampers > 0 and dampSum > 0 then dampScale = dampScale * donor.damp / (dampSum / #dampers) end
  local swayScale = tonumber(s.swayMul) or 1
  if tonumber(donor.sway) and #bars > 0 and barSum > 0 then swayScale = swayScale * donor.sway / (barSum / #bars) end
  -- a truck's rates on a car's light suspension nodes: x8 damping / x13 sway bar made the 2 kHz
  -- physics step blow up, so the scales stay within x6
  springScale = math.min(6, math.max(0.05, springScale))
  dampScale = math.min(6, math.max(0.05, dampScale))
  swayScale = math.min(6, math.max(0, swayScale))

  for _, b in ipairs(springs) do b.beamSpring = b.beamSpring * springScale end
  -- and no damper gets more than its lighter end node can take (damping * step / mass <= 0.25)
  local defaultMass = tonumber(type(vehicle.options) == 'table' and vehicle.options.nodeWeight) or 5
  local capped = 0
  for _, b in ipairs(dampers) do
    local n1, n2 = vehicle.nodes[b.id1], vehicle.nodes[b.id2]
    local m = math.min(tonumber(n1 and n1.nodeWeight) or defaultMass, tonumber(n2 and n2.nodeWeight) or defaultMass)
    local cap = 0.25 * math.max(0.5, m) / 0.0005
    for _, key in ipairs({'beamDamp', 'beamDampRebound', 'beamDampFast', 'beamDampReboundFast'}) do
      if type(b[key]) == 'number' then
        local scaled = b[key] * dampScale
        if scaled > cap and scaled > b[key] then
          scaled = math.max(b[key], cap) -- never below the car's own value
          capped = capped + 1
        end
        b[key] = scaled
      end
    end
  end
  if capped > 0 then log('I', logTag, string.format('logic suspension: %d damper values capped to fit the node masses', capped)) end
  for _, t in ipairs(bars) do
    t.spring = t.spring * swayScale
    if type(t.damp) == 'number' then t.damp = t.damp * math.min(swayScale, 1) end
  end

  -- ride height: longer / shorter springs (precompressionRange is metres added to the rest length);
  -- when lifting, the droop limits of the bounded beams get the same extra travel
  local lift = tonumber(s.lift) or 0
  if lift ~= 0 then
    for _, b in ipairs(springs) do
      local n1, n2 = vehicle.nodes[b.id1], vehicle.nodes[b.id2]
      if n1 and n2 and n1.pos and n2.pos then
        local L = n1.pos:distance(n2.pos)
        local range = type(b.precompressionRange) == 'number' and b.precompressionRange or ((tonumber(b.beamPrecompression) or 1) - 1) * L
        b.precompressionRange = range + lift
      end
    end
    -- the shocks' travel limits (absolute range or a ratio of the length) would stop the lift / drop
    for _, b in ipairs(bounded) do
      local n1, n2 = vehicle.nodes[b.id1], vehicle.nodes[b.id2]
      local L = (n1 and n2 and n1.pos and n2.pos) and math.max(0.05, n1.pos:distance(n2.pos)) or 0.5
      if lift > 0 then
        if type(b.longBoundRange) == 'number' then
          b.longBoundRange = b.longBoundRange + lift
        elseif type(b.beamLongBound) == 'number' then
          b.beamLongBound = b.beamLongBound + lift / L
        end
      else
        if type(b.shortBoundRange) == 'number' then
          b.shortBoundRange = b.shortBoundRange - lift
        elseif type(b.beamShortBound) == 'number' then
          b.beamShortBound = math.min(0.95, b.beamShortBound - lift / L)
        end
      end
    end
  end
  return string.format('%d springs x%.2f, %d dampers x%.2f, %d sway bars x%.2f, lift %+.0f mm',
    #springs, springScale, #dampers, dampScale, #bars, swayScale, lift * 1000)
end

--------------------------------------------------------------------------------
-- universal drivetrain: rebuild everything after the gearbox (driveshaft, diffs, halfshafts)
--------------------------------------------------------------------------------

local diffPresets = {
  open = {diffType = 'open'},
  lsd = {diffType = 'lsd', lsdPreload = 50, lsdLockCoef = 0.2, lsdRevLockCoef = 0.1},
  viscous = {diffType = 'viscous', viscousCoef = 3, viscousTorque = 2000, viscousExponent = 1.5},
  locked = {diffType = 'locked', lockTorque = 10000},
}

local function buildUniversalDrivetrain(vehicle, spec)
  local pt = vehicle.powertrain
  if type(pt) ~= 'table' then return 'no powertrain section' end

  local byName, keyOf, children = {}, {}, {}
  for k, d in pairs(pt) do
    if type(d) == 'table' and type(d.name) == 'string' then
      byName[d.name] = d
      keyOf[d.name] = k
    end
  end
  for _, d in pairs(byName) do
    if type(d.inputName) == 'string' then
      children[d.inputName] = children[d.inputName] or {}
      table.insert(children[d.inputName], d)
    end
  end

  -- the gearbox the engine drives (through clutch / torque converter)
  local function reachesEngine(d)
    for _ = 1, 20 do
      if not d then return false end
      if d.name == 'mainEngine' then return true end
      d = byName[d.inputName]
    end
    return false
  end
  local gearbox
  for _, d in pairs(byName) do
    if type(d.type) == 'string' and d.type:find('Gearbox$') and reachesEngine(d) then
      gearbox = d
      break
    end
  end
  if not gearbox then return 'no gearbox driven by mainEngine' end
  local attach = gearbox
  local kids = children[gearbox.name] or {}
  if #kids == 1 and kids[1].type == 'rangeBox' then attach = kids[1] end

  -- everything below the gearbox goes, and so does anything hanging on a missing device
  local removed = {}
  local function markDesc(name)
    for _, c in ipairs(children[name] or {}) do
      if not removed[c.name] then
        removed[c.name] = true
        markDesc(c.name)
      end
    end
  end
  markDesc(attach.name)
  for name, d in pairs(byName) do
    if not removed[name] and type(d.inputName) == 'string' and d.inputName ~= 'dummy' and not byName[d.inputName] then
      removed[name] = true
      markDesc(name)
    end
  end

  -- devices that turn a wheel get re-used (suspension "spindle" shafts etc.)
  local wheelDev, keptWheel = {}, {}
  for name, d in pairs(byName) do
    if type(d.connectedWheel) == 'string' then
      if removed[name] then wheelDev[d.connectedWheel] = d else keptWheel[d.connectedWheel] = true end
    end
  end

  -- wheels grouped into axles by their position (jbeam: -Y is the front, +X is the left)
  local wheels = {}
  for _, w in pairs(vehicle.wheels or {}) do
    if type(w) == 'table' and type(w.name) == 'string' and type(w.node1) == 'number' and vehicle.nodes[w.node1] then
      local p1 = vehicle.nodes[w.node1].pos
      local n2 = type(w.node2) == 'number' and vehicle.nodes[w.node2]
      local p2 = n2 and n2.pos or p1
      wheels[#wheels + 1] = {name = w.name, x = (p1.x + p2.x) * 0.5, y = (p1.y + p2.y) * 0.5}
    end
  end
  if #wheels == 0 then return 'no wheels' end
  table.sort(wheels, function(a, b) return a.y < b.y end)
  local axles = {}
  for _, w in ipairs(wheels) do
    local last = axles[#axles]
    if last and math.abs(w.y - last.y) < 0.3 then
      table.insert(last.wheels, w)
    else
      axles[#axles + 1] = {y = w.y, wheels = {w}}
    end
  end
  local frontAxles, rearAxles = {axles[1]}, {}
  for i = 2, #axles do rearAxles[#rearAxles + 1] = axles[i] end
  if #rearAxles == 0 then rearAxles = frontAxles end

  local layout = spec.layout or 'RWD'
  local finalDrive = tonumber(spec.finalDrive) or 3.7
  local axleDiff = diffPresets[spec.diffType] or diffPresets.open
  local centerDiff = diffPresets[spec.centerType] or diffPresets.viscous

  local added, usedNames = {}, {}
  for name, _ in pairs(byName) do
    if not removed[name] then usedNames[name] = true end
  end
  local function uniqueName(base)
    local name, i = base, 2
    while usedNames[name] do
      name = base .. '_' .. i
      i = i + 1
    end
    usedNames[name] = true
    return name
  end
  local function addDevice(d) added[#added + 1] = d end
  local function addDiff(base, uiName, inputName, inputIndex, preset, ratio, extra)
    local d = {type = 'differential', name = uniqueName(base), inputName = inputName, inputIndex = inputIndex,
      gearRatio = ratio, uiName = uiName, defaultVirtualInertia = 0.25, friction = 0.5}
    for k, v in pairs(preset) do d[k] = v end
    for k, v in pairs(extra or {}) do d[k] = v end
    -- a locker: the picked type plus "locked", switched while driving (the game's "toggle
    -- differential mode" key, its powertrain UI buttons, or section 4); locked = both sides turn alike
    if d.locker then
      local kind = type(d.diffType) == 'string' and d.diffType or 'open'
      d.diffType = kind == 'locked' and {'locked', 'open'} or {kind, 'locked'}
      d.lockTorque = math.max(tonumber(d.lockTorque) or 0, 10000)
      d.uiSimpleModeControl = true
      d.locker = nil
    end
    addDevice(d)
    return d.name
  end
  local function attachWheel(w, parentName, idx)
    if keptWheel[w.name] then return end -- already driven by something else (e.g. a hybrid motor)
    local dev = wheelDev[w.name]
    if dev then
      dev.inputName, dev.inputIndex = parentName, idx
      removed[dev.name] = nil
      usedNames[dev.name] = true
    else
      addDevice({type = 'shaft', name = uniqueName('wheelaxle' .. w.name), inputName = parentName, inputIndex = idx,
        connectedWheel = w.name, uiName = 'Axle ' .. w.name, friction = 1, dynamicFriction = 0.002})
    end
  end
  -- several wheels on one side (dually): locked splitter
  local function buildSide(list, parentName, idx)
    if #list == 0 then return end
    if #list == 1 then return attachWheel(list[1], parentName, idx) end
    local name = addDiff('dually', 'Dually', parentName, idx, diffPresets.locked, 1)
    local half = math.ceil(#list / 2)
    local a, b = {}, {}
    for i, w in ipairs(list) do if i <= half then a[#a + 1] = w else b[#b + 1] = w end end
    buildSide(a, name, 1)
    buildSide(b, name, 2)
  end
  local function buildAxle(axle, parentName, idx, label)
    local lockable = (label == 'F' and spec.lockerF) or (label == 'R' and spec.lockerR)
    local name = addDiff('differential_' .. label, (label == 'F' and 'Front' or 'Rear') .. ' Differential', parentName, idx, axleDiff, finalDrive,
      lockable and {locker = true} or nil)
    local left, right = {}, {}
    for _, w in ipairs(axle.wheels) do
      if w.x > 0 then left[#left + 1] = w else right[#right + 1] = w end
    end
    if #left == 0 or #right == 0 then
      left, right = {}, {}
      for i, w in ipairs(axle.wheels) do if i <= #axle.wheels / 2 then left[#left + 1] = w else right[#right + 1] = w end end
    end
    buildSide(left, name, 1)
    buildSide(right, name, 2)
  end
  local function buildAxles(list, parentName, idx, label)
    if #list == 1 then return buildAxle(list[1], parentName, idx, label) end
    local lockable = (label == 'F' and spec.lockerF) or (label == 'R' and spec.lockerR)
    local name = addDiff('tandem_' .. label, 'Inter-axle Differential', parentName, idx, diffPresets.viscous, 1, lockable and {locker = true} or nil)
    local half = math.ceil(#list / 2)
    local a, b = {}, {}
    for i, ax in ipairs(list) do if i <= half then a[#a + 1] = ax else b[#b + 1] = ax end end
    buildAxles(a, name, 1, label)
    buildAxles(b, name, 2, label)
  end

  -- low range: a range box between the gearbox and the driveshaft, high / low switched while driving
  local driveInput = attach.name
  if spec.lowRange then
    local rangeBox = uniqueName('upa_rangebox')
    addDevice({type = 'rangeBox', name = rangeBox, inputName = attach.name, inputIndex = 1, uiName = 'Range Box',
      gearRatios = {1, math.max(1.2, tonumber(spec.lowRatio) or 2.72)}, friction = 0.3, dynamicFriction = 0.0005, uiSimpleModeControl = true})
    driveInput = rangeBox
  end
  local shaftName = uniqueName('driveshaft')
  addDevice({type = 'shaft', name = shaftName, inputName = driveInput, inputIndex = 1, uiName = 'Driveshaft', friction = 0.3, dynamicFriction = 0.0005})
  if layout == 'AWD' and frontAxles[1] ~= rearAxles[1] and spec.partTime then
    -- part-time 4WD: a transfer case that is 2WD (rear) or locked 4WD (50 / 50), switched while driving
    local transferCase = uniqueName('upa_transfercase')
    addDevice({type = 'splitShaft', name = transferCase, inputName = shaftName, inputIndex = 1, uiName = '4WD',
      splitType = 'locked', canDisconnect = true, isDisconnected = true, primaryOutputID = 2, lockTorque = 10000, friction = 0.5})
    buildAxles(frontAxles, transferCase, 1, 'F')
    buildAxles(rearAxles, transferCase, 2, 'R')
  elseif layout == 'AWD' and frontAxles[1] ~= rearAxles[1] then
    local split = math.min(0.95, math.max(0.05, tonumber(spec.frontSplit) or 0.4))
    local center = addDiff('upa_center_diff', 'Center Differential', shaftName, 1, centerDiff, 1, {diffTorqueSplit = split, locker = spec.lockerC or nil})
    buildAxles(frontAxles, center, 1, 'F')
    buildAxles(rearAxles, center, 2, 'R')
  elseif layout == 'FWD' then
    buildAxles(frontAxles, shaftName, 1, 'F')
  else
    buildAxles(rearAxles, shaftName, 1, 'R')
  end

  -- apply: drop the old devices, add ours
  local maxKey = -1
  for k, _ in pairs(pt) do if type(k) == 'number' and k > maxKey then maxKey = k end end
  local removedCount = 0
  for name, _ in pairs(removed) do
    pt[keyOf[name]] = nil
    removedCount = removedCount + 1
  end
  for _, d in ipairs(added) do
    maxKey = maxKey + 1
    pt[maxKey] = d
    -- powertrain merges vehicle[deviceName] into the device: drop leftovers of the old device of that name
    if byName[d.name] and type(vehicle[d.name]) == 'table' then vehicle[d.name] = nil end
  end

  -- controllers that point at a device that no longer exists would break vehicle init
  if type(vehicle.controller) == 'table' then
    local gone = {}
    for name, _ in pairs(removed) do if not usedNames[name] then gone[name] = true end end
    local function refsGone(t, depth)
      if depth > 4 or type(t) ~= 'table' then return false end
      for _, v in pairs(t) do
        if type(v) == 'string' and gone[v] then return true end
        if type(v) == 'table' and refsGone(v, depth + 1) then return true end
      end
      return false
    end
    for k, c in pairs(vehicle.controller) do
      if type(c) == 'table' and (refsGone(c, 0) or (type(c.name) == 'string' and refsGone(vehicle[c.name], 0))) then
        log('I', logTag, 'universal drivetrain: dropping controller ' .. tostring(c.name or c.fileName))
        vehicle.controller[k] = nil
      end
    end
  end

  return string.format('%s from %s: removed %d devices, added %d, %d axles', layout, attach.name, removedCount, #added, #axles)
end

--------------------------------------------------------------------------------
-- target vehicle setup (for the ghost preview)
--------------------------------------------------------------------------------

local function setupTarget(e, target)
  e.targetId = target:getID()
  local vd = getVData(e.targetId)
  local n = target:getNodeCount()

  local a, b, c
  local ref = vd and vd.refNodes and vd.refNodes[0]
  if ref then
    a, b, c = ref.ref, ref.back, ref.up
    if not validAnchors(target, a, b, c, n) then c = ref.left end
  end
  local body = {}
  for cid = 0, n - 1 do
    if not isWheelNode(vd, cid) then body[#body + 1] = cid end
  end
  if not validAnchors(target, a, b, c, n) then
    a, b, c = pickAnchors(target, body)
  end
  if not a then return false end
  e.tA, e.tB, e.tC = a, b, c

  -- jbeam space bounds of the target body (for "put on roof")
  local tMin, tMax = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  for _, cid in ipairs(body) do
    local p = vec3(target:getInitialNodePosition(cid))
    tMin:set(math.min(tMin.x, p.x), math.min(tMin.y, p.y), math.min(tMin.z, p.z))
    tMax:set(math.max(tMax.x, p.x), math.max(tMax.y, p.y), math.max(tMax.z, p.z))
  end
  e.tMin, e.tMax = tMin, tMax
  e.targetName = target.jbeam or tostring(e.targetId)
  e.targetVData = vd -- a respawn (parts changed) renumbers nodes, setupTarget runs again then
  return true
end

--------------------------------------------------------------------------------
-- ghost setup (once the spawned ghost has physics)
--------------------------------------------------------------------------------

local function initEntry(e, ghost)
  local vd = getVData(e.id)
  if not vd or not vd.nodes then return false end
  local n = ghost:getNodeCount()
  if n == 0 then return 'empty' end

  -- connected node groups (clusters) via beams, each one is teleported on its own
  local parent = {}
  for cid = 0, n - 1 do parent[cid] = cid end
  local function find(x)
    while parent[x] ~= x do
      parent[x] = parent[parent[x]]
      x = parent[x]
    end
    return x
  end
  for _, beam in pairs(vd.beams or {}) do
    if type(beam) == 'table' and parent[beam.id1] and parent[beam.id2] then
      local r1, r2 = find(beam.id1), find(beam.id2)
      if r1 ~= r2 then parent[r1] = r2 end
    end
  end
  local groups = {}
  for cid = 0, n - 1 do
    local r = find(cid)
    groups[r] = groups[r] or {}
    table.insert(groups[r], cid)
  end

  e.clusters = {}
  local pMin, pMax = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  local centroid = vec3()
  for _, nodes in pairs(groups) do
    local cl = {nodes = nodes, rep = nodes[1]}
    cl.initRep = vec3(ghost:getInitialNodePosition(cl.rep))
    cl.a, cl.b, cl.c = pickAnchors(ghost, nodes)
    table.insert(e.clusters, cl)
    for _, cid in ipairs(nodes) do
      local p = vec3(ghost:getInitialNodePosition(cid))
      centroid = centroid + p
      pMin:set(math.min(pMin.x, p.x), math.min(pMin.y, p.y), math.min(pMin.z, p.z))
      pMax:set(math.max(pMax.x, p.x), math.max(pMax.y, p.y), math.max(pMax.z, p.z))
    end
  end
  table.sort(e.clusters, function(x, y) return #x.nodes > #y.nodes end)
  e.pivot = e.pivot or centroid / n -- an edited part keeps its stored pivot
  e.pMin, e.pMax = pMin, pMax
  e.nodeCount = n
  return true
end

--------------------------------------------------------------------------------
-- placement
--------------------------------------------------------------------------------

local function offsetRot(e)
  return eulerToQuat(e.rot[1][0], e.rot[2][0], e.rot[3][0])
end

local function offsetVec(e)
  return vec3(e.off[1][0], e.off[2][0], e.off[3][0])
end

-- teleport every cluster of the ghost to its pose relative to the target and kill its velocity.
-- part jbeam point J ends up at target jbeam point pivot + Roff*(J - pivot) + off, exactly what
-- nodeRotate1 + nodeMove do when the part is merged.
local function holdGhost(e, ghost, target)
  local Rt, wA, iA = nodeFrameRot(target, e.tA, e.tB, e.tC)
  local Roff = offsetRot(e)
  local off = offsetVec(e)
  local Rdes = Roff * Rt -- part jbeam frame -> world

  local mainCl = e.clusters[1]
  local RpMain
  if mainCl.a then
    RpMain = nodeFrameRot(ghost, mainCl.a, mainCl.b, mainCl.c)
  else
    RpMain = quat(ghost:getClusterRotationSlow(mainCl.rep))
  end

  for _, cl in ipairs(e.clusters) do
    local Rp = cl.a and nodeFrameRot(ghost, cl.a, cl.b, cl.c) or RpMain
    local diff = Rp:inversed() * Rdes
    local jT = e.pivot + Roff * (cl.initRep - e.pivot) + off
    local posDes = wA + Rt * (jT - iA)
    ghost:setClusterPosRelRot(cl.rep, posDes.x, posDes.y, posDes.z, diff.x, diff.y, diff.z, diff.w)
    ghost:applyClusterVelocityScaleAdd(cl.rep, 0, 0, 0, 0)
  end
end

local function resetOffsets(e)
  for i = 1, 3 do
    e.off[i][0] = 0
    e.rot[i][0] = 0
  end
end

-- centre the part over the target and sit it just above the highest point of the body
local function putOnRoof(e)
  if not (e.tMin and e.pMin) then return end
  local tc = (e.tMin + e.tMax) * 0.5
  local pc = (e.pMin + e.pMax) * 0.5
  resetOffsets(e)
  e.off[1][0] = tc.x - pc.x
  e.off[2][0] = tc.y - pc.y
  e.off[3][0] = e.tMax.z - e.pMin.z + 0.3
end

-- distance from the ghost to the car body and how many ghost nodes are within reach
local function measureGap(e, ghost, target)
  local tVD = getVData(target:getID())
  local tx, ty, tz = {}, {}, {}
  for cid = 0, target:getNodeCount() - 1 do
    if not isWheelNode(tVD, cid) then
      local p = target:getNodeAbsPosition(cid)
      tx[#tx + 1], ty[#ty + 1], tz[#tz + 1] = p.x, p.y, p.z
    end
  end
  local maxGap2 = S.maxGapPtr[0] * S.maxGapPtr[0]
  local nearest, inReach = math.huge, 0
  for cid = 0, ghost:getNodeCount() - 1 do
    local p = ghost:getNodeAbsPosition(cid)
    local px, py, pz = p.x, p.y, p.z
    local best = math.huge
    for k = 1, #tx do
      local dx, dy, dz = tx[k] - px, ty[k] - py, tz[k] - pz
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 < best then best = d2 end
    end
    if best <= maxGap2 then inReach = inReach + 1 end
    if best < nearest then nearest = best end
  end
  return math.sqrt(nearest), inReach
end

--------------------------------------------------------------------------------
-- merge / unmerge
--------------------------------------------------------------------------------

local function getPA(vehId)
  local d = core_vehicle_manager.getVehicleData(vehId)
  local pa = d and d.config and d.config.partAttacherExp
  return type(pa) == 'table' and pa or {}
end

local function getExtras(vehId)
  local pa = getPA(vehId)
  return type(pa.extraParts) == 'table' and pa.extraParts or {}
end

local function getSwap(vehId)
  local pa = getPA(vehId)
  return type(pa.engineSwap) == 'table' and pa.engineSwap or nil
end

-- depth first search in a partsTree node
local function findTreeNode(node, pred)
  if type(node) ~= 'table' then return nil end
  if pred(node) then return node end
  for _, child in pairs(node.children or {}) do
    local res = findTreeNode(child, pred)
    if res then return res end
  end
end

-- respawn the car (in place, like the parts menu does) after mutate(cfg) changed its config
local function respawnWithConfig(target, mutate)
  local d = core_vehicle_manager.getVehicleData(target:getID())
  if not (d and d.config) then msg('Nerasti masinos duomenys.') return false end
  local cfg = deepcopy(d.config)
  cfg.partAttacherExp = type(cfg.partAttacherExp) == 'table' and cfg.partAttacherExp or {}
  mutate(cfg)
  target:respawn(serialize(cfg))
  return true
end

-- also(cfg): more changes to the config in the same respawn (a front end empties the car's own front slots)
local function respawnWithExtras(target, extras, also)
  return respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.extraParts = extras
    -- forget old choices of our slots, the indices may have shifted
    if type(cfg.partsTree) == 'table' and type(cfg.partsTree.children) == 'table' then
      for slotId, _ in pairs(cfg.partsTree.children) do
        if type(slotId) == 'string' and slotId:sub(1, #extraSlotPrefix) == extraSlotPrefix then cfg.partsTree.children[slotId] = nil end
      end
    end
    if type(cfg.parts) == 'table' then
      for slotId, _ in pairs(cfg.parts) do
        if type(slotId) == 'string' and slotId:find(extraSlotPrefix, 1, true) then cfg.parts[slotId] = nil end
      end
    end
    if also then also(cfg) end
  end)
end

--------------------------------------------------------------------------------
-- engine swap
--------------------------------------------------------------------------------

local function modelDirs(model)
  return {'/vehicles/' .. tostring(model) .. '/', '/vehicles/common/'}
end

local function isEnginePart(part)
  if type(part) ~= 'table' or type(part.powertrain) ~= 'table' then return false end
  for _, row in ipairs(part.powertrain) do
    if type(row) == 'table' and row[2] == 'mainEngine' and type(row[1]) == 'string' and row[1] ~= 'type' then return true end
  end
  return false
end

-- rough peak power of an engine part from its base torque curve (without turbo / ECU parts)
local function engineInfo(part)
  local me = type(part) == 'table' and part.mainEngine
  if type(me) ~= 'table' then return nil end
  local best = 0
  for _, row in ipairs(type(me.torque) == 'table' and me.torque or {}) do
    if type(row) == 'table' and type(row[1]) == 'number' and type(row[2]) == 'number' then
      best = math.max(best, row[1] * row[2] * 2 * math.pi / 60 / 1000)
    end
  end
  return {kw = best, maxRPM = tonumber(me.maxRPM), fuel = me.requiredEnergyType}
end

-- the car's own combustion engine part (the original one when it was swapped already)
local function getTargetEngine(vehId)
  local swap = getSwap(vehId)
  if swap then return swap.replaces end
  local vd = getVData(vehId)
  for name, part in pairs(vd and vd.activePartsData or {}) do
    if isEnginePart(part) then return name end
  end
  -- fallback: look at every chosen part of the config
  local d = core_vehicle_manager.getVehicleData(vehId)
  local veh = getVeh(vehId)
  if not (d and d.config and veh) then return nil end
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(veh.jbeam))
  if not ok then return nil end
  local found = findTreeNode(d.config.partsTree, function(n)
    return type(n.chosenPartName) == 'string' and n.chosenPartName ~= '' and isEnginePart(jbeamIO.getPart(ioCtx, n.chosenPartName))
  end)
  return found and found.chosenPartName
end

-- centroid of a part's jbeam nodes, straight from the file
local function rawNodeCentroid(model, partName)
  local ok, part = pcall(function()
    return jbeamIO.getPart(jbeamIO.startLoading(modelDirs(model)), partName)
  end)
  if not ok or type(part) ~= 'table' then return nil end
  local sum, count = vec3(), 0
  for _, row in ipairs(part.nodes or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'number' and type(row[3]) == 'number' and type(row[4]) == 'number' then
      sum = sum + vec3(row[2], row[3], row[4])
      count = count + 1
    end
  end
  return count > 0 and sum / count or nil
end

-- default sub parts of the donor engine (they get the same move/rotate as the block)
local function collectDonorNames(model, enginePart, keepTransmission)
  local names, list = {}, {}
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not ok then return list end
  local function rec(partName, depth, isRoot)
    if depth > 20 or names[partName] then return end
    local part = jbeamIO.getPart(ioCtx, partName)
    if type(part) ~= 'table' then return end
    if not isRoot then
      names[partName] = true
      list[#list + 1] = partName
    end
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      local skip = isRoot and keepTransmission and slotHoldsGearbox(s, function(n) return jbeamIO.getPart(ioCtx, n) end)
      if type(s) == 'table' and type(s.default) == 'string' and s.default ~= '' and not skip then
        rec(s.default, depth + 1, false)
      end
    end
  end
  rec(enginePart, 0, true)
  return list
end

local function treeNodeIsEngine(replaces)
  return function(n) return n.chosenPartName == replaces or n.chosenPartName == swapAlias end
end

-- does this partsTree child (slot id + chosen part) hold the gearbox?
local function treeChildIsGearbox(slotId, child, ioCtx)
  if isTransmissionSlot({name = slotId}) then return true end
  local name = type(child) == 'table' and child.chosenPartName
  if type(name) ~= 'string' or name == '' then return false end
  if name == gearboxAlias then return true end
  local ok, part = pcall(jbeamIO.getPart, ioCtx, name)
  return ok and isGearboxPart(part)
end

local function vehicleIoCtx(vehId)
  local veh = getVeh(vehId)
  local dirs = modelDirs(veh and veh.jbeam)
  -- donor models of swaps/extras are part of the car too
  local pa = getPA(vehId)
  for _, spec in ipairs({pa.engineSwap or false, pa.gearboxSwap or false}) do
    if spec and spec.model then table.insert(dirs, '/vehicles/' .. spec.model .. '/') end
  end
  local ok, ioCtx = pcall(jbeamIO.startLoading, dirs)
  return ok and ioCtx or nil
end

-- names of the car's gearbox parts below its engine slot; they stay as they are
local function collectKeepNames(vehId, replaces)
  local d = core_vehicle_manager.getVehicleData(vehId)
  local list = {}
  local engineNode = findTreeNode(d and d.config and d.config.partsTree, treeNodeIsEngine(replaces))
  if not engineNode then return list end
  local ioCtx = vehicleIoCtx(vehId)
  local function rec(node)
    if type(node.chosenPartName) == 'string' and node.chosenPartName ~= '' then list[#list + 1] = node.chosenPartName end
    for _, c in pairs(node.children or {}) do rec(c) end
  end
  for slotId, child in pairs(engineNode.children or {}) do
    if treeChildIsGearbox(slotId, child, ioCtx) then rec(child) end
  end
  return list
end

-- respawn the car with a swap spec (or nil to restore the original engine)
local function respawnWithSwap(target, spec, replaces)
  local ioCtx = vehicleIoCtx(target:getID())
  return respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.engineSwap = spec
    local engineNode = findTreeNode(cfg.partsTree, treeNodeIsEngine(replaces))
    if engineNode then
      -- logic swap (v3) keeps the car's own engine part; v1/v2 put the donor part in its slot
      local newChosen = (spec and (tonumber(spec.version) or 1) < 3) and swapAlias or replaces
      local changed = engineNode.chosenPartName ~= newChosen
      engineNode.chosenPartName = newChosen
      -- the slot changed hands: drop the old engine's sub slot choices, keep the gearbox branch
      if changed and type(engineNode.children) == 'table' then
        for slotId, child in pairs(engineNode.children) do
          if not treeChildIsGearbox(slotId, child, ioCtx) then engineNode.children[slotId] = nil end
        end
      end
    end
  end)
end

--------------------------------------------------------------------------------
-- gearbox swap
--------------------------------------------------------------------------------

local function treeNodeIsGearbox(replaces)
  return function(n) return n.chosenPartName == replaces or n.chosenPartName == gearboxAlias end
end

-- the car's own gearbox part (the original one when it was swapped already)
local function getTargetGearbox(vehId)
  local pa = getPA(vehId)
  if type(pa.gearboxSwap) == 'table' then return pa.gearboxSwap.replaces end
  local vd = getVData(vehId)
  for name, part in pairs(vd and vd.activePartsData or {}) do
    if isGearboxPart(part) then return name end
  end
  local d = core_vehicle_manager.getVehicleData(vehId)
  local ioCtx = vehicleIoCtx(vehId)
  if not (d and d.config and ioCtx) then return nil end
  local found = findTreeNode(d.config.partsTree, function(n)
    return type(n.chosenPartName) == 'string' and n.chosenPartName ~= '' and isGearboxPart(jbeamIO.getPart(ioCtx, n.chosenPartName))
  end)
  return found and found.chosenPartName
end

local function respawnWithGearboxSwap(target, spec, replaces)
  return respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.gearboxSwap = spec
    local node = findTreeNode(cfg.partsTree, treeNodeIsGearbox(replaces))
    if node then
      node.chosenPartName = spec and gearboxAlias or replaces
      node.children = nil -- the old gearbox's sub parts don't fit the new one
    end
  end)
end

--------------------------------------------------------------------------------
-- part swaps (front / rear suspension)
--------------------------------------------------------------------------------

local swapKinds = {
  susp_F = {label = 'Priekine pakaba'},
  susp_R = {label = 'Galine pakaba'},
  susp_R2 = {label = 'Antra galine asis', added = true}, -- an added axle: replaces nothing
}

local function partNodeCentroid(part)
  local sum, count = vec3(), 0
  for _, row in ipairs(type(part) == 'table' and part.nodes or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'number' and type(row[3]) == 'number' and type(row[4]) == 'number' then
      sum = sum + vec3(row[2], row[3], row[4])
      count = count + 1
    end
  end
  return count > 0 and sum / count or nil
end

local function isSuspensionPart(part, name)
  if type(part) ~= 'table' then return false end
  local st = part.slotType
  local txt = (type(st) == 'table' and table.concat(st, ' ') or tostring(st)) .. ' ' .. tostring(name)
  return txt:lower():find('suspension', 1, true) ~= nil and partNodeCentroid(part) ~= nil
end

-- 'susp_F' or 'susp_R' from where the nodes sit (jbeam: -Y is the front)
local function suspensionKind(part, name)
  local c = partNodeCentroid(part)
  if c then return c.y < 0 and 'susp_F' or 'susp_R' end
  return tostring(name):lower():find('_r', 1, true) and 'susp_R' or 'susp_F'
end

local function getPartSwap(vehId, kind)
  local ps = getPA(vehId).partSwaps
  return type(ps) == 'table' and type(ps[kind]) == 'table' and ps[kind] or nil
end

-- the car's own front / rear suspension part: the shallowest suspension part on that side
local function getTargetSuspension(vehId, kind)
  local swap = getPartSwap(vehId, kind)
  if swap then return swap.replaces end
  local d = core_vehicle_manager.getVehicleData(vehId)
  local ioCtx = vehicleIoCtx(vehId)
  if not (d and d.config and ioCtx) then return nil end
  local best, bestDepth
  local function rec(node, depth)
    if type(node) ~= 'table' or depth > 12 then return end
    local name = node.chosenPartName
    if type(name) == 'string' and name ~= '' and (not bestDepth or depth < bestDepth) then
      local ok, part = pcall(jbeamIO.getPart, ioCtx, name)
      if ok and isSuspensionPart(part, name) and suspensionKind(part, name) == kind then
        best, bestDepth = name, depth
      end
    end
    for _, c in pairs(node.children or {}) do rec(c, depth + 1) end
  end
  rec(d.config.partsTree, 0)
  return best
end

-- the donor's body / frame points the part tree hangs on (shock tops, spring hangers, steering box,
-- diff mounts...): every name the tree references that is a node of the donor's default car but not
-- of the tree itself. Returned as {name, x, y, z} in donor jbeam coordinates.
local function collectImportNodes(model, partName, excludeGearbox)
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not ok or not ioCtx then return {} end

  -- fn(row, nodeWeight, group): weight / group from the property rows above the node or its own options
  local function nodeRows(part, fn)
    local weight, group
    for _, row in ipairs(type(part) == 'table' and type(part.nodes) == 'table' and part.nodes or {}) do
      if type(row) == 'table' then
        if row[1] == nil then
          if type(row.nodeWeight) == 'number' then weight = row.nodeWeight end
          if row.group ~= nil then group = row.group end
        end
        if type(row[1]) == 'string' and type(row[2]) == 'number' and type(row[3]) == 'number' and type(row[4]) == 'number' then
          local w, g = weight, group
          if type(row[5]) == 'table' then
            if type(row[5].nodeWeight) == 'number' then w = row[5].nodeWeight end
            if row[5].group ~= nil then g = row[5].group end
          end
          fn(row, w, g)
        end
      end
    end
  end

  -- the swapped tree and its own nodes
  local own, treeParts = {}, {}
  local treeNames = {partName}
  for _, n in ipairs(collectDonorNames(model, partName, excludeGearbox == true)) do treeNames[#treeNames + 1] = n end
  local inTree = {}
  local ownPos = {}
  for _, name in ipairs(treeNames) do
    inTree[name] = true
    local part = jbeamIO.getPart(ioCtx, name)
    if type(part) == 'table' then
      treeParts[#treeParts + 1] = part
      nodeRows(part, function(row)
        own[row[1]] = vec3(row[2], row[3], row[4])
        ownPos[#ownPos + 1] = own[row[1]]
      end)
    end
  end

  -- every node of the donor's default car outside the tree
  local carNodes = {}
  local visited = {}
  local defaultOrder, extraOrder = {}, {} -- part names: the default car's, then all the others
  -- slots the tree fills itself: the donor's other parts for them (its default leaf spring axle
  -- when a 4-link is swapped...) share node names with the tree and must stay out
  local treeSlotTypes, defaultSlotTypes = {}, {}
  for _, part in ipairs(treeParts) do
    if type(part.slotType) == 'string' then treeSlotTypes[part.slotType] = true end
  end
  -- the same goes for a part that redefines many of the tree's own nodes, whatever its slot is
  -- called (the desert 4-link sits in "pickup_desert_suspension_R", the default leaf spring axle it
  -- replaces in "pickup_suspension_R": same ax1l / rx1l... nodes, a different axle)
  local function isAlternative(part)
    local total, shared = 0, 0
    nodeRows(part, function(row)
      total = total + 1
      if own[row[1]] then shared = shared + 1 end
    end)
    return shared >= 4 and shared >= 0.25 * total
  end
  local function rec(name, depth)
    if depth > 30 or visited[name] or inTree[name] then return end
    visited[name] = true
    local part = jbeamIO.getPart(ioCtx, name)
    if type(part) ~= 'table' then return end
    if (type(part.slotType) == 'string' and treeSlotTypes[part.slotType]) or isAlternative(part) then return end
    if type(part.slotType) == 'string' then defaultSlotTypes[part.slotType] = true end
    defaultOrder[#defaultOrder + 1] = name
    nodeRows(part, function(row, w, g)
      if not carNodes[row[1]] then carNodes[row[1]] = {row[2], row[3], row[4], w, deepcopy(g)} end
    end)
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      if type(s) == 'table' and type(s.default) == 'string' and s.default ~= '' then rec(s.default, depth + 1) end
    end
  end
  local mainPart = jbeamIO.getMainPartName(ioCtx)
  if mainPart then rec(mainPart, 0) end
  -- then every other part of the donor: special suspensions (desert, off-road...) hang on frame /
  -- bed nodes that only the matching non-default frame or body variant has
  local okAll, allParts = pcall(jbeamIO.getAvailableParts, ioCtx)
  if okAll and type(allParts) == 'table' then
    local partNames = {}
    for name, _ in pairs(allParts) do
      if not inTree[name] and not visited[name] then partNames[#partNames + 1] = name end
    end
    table.sort(partNames)
    for _, name in ipairs(partNames) do
      local part = jbeamIO.getPart(ioCtx, name)
      -- only variants of the default car's own slots (desert frame for the frame slot, other beds...)
      local slotType = type(part) == 'table' and part.slotType
      if type(slotType) == 'string' and defaultSlotTypes[slotType] and not treeSlotTypes[slotType] and not isAlternative(part) then
        extraOrder[#extraOrder + 1] = name
        nodeRows(part, function(row, w, g)
          if not carNodes[row[1]] then carNodes[row[1]] = {row[2], row[3], row[4], w, deepcopy(g)} end
        end)
      end
    end
  end

  -- beam rows of a part with their effective properties; plain = a NORMAL beam (no spring / damper /
  -- limiter of its own: a piece of structure)
  local function eachBeam(part, fn)
    local props = {}
    for _, row in ipairs(type(part) == 'table' and type(part.beams) == 'table' and part.beams or {}) do
      if type(row) == 'table' then
        if row[1] == nil then
          for k, v in pairs(row) do props[k] = v end
        elseif type(row[1]) == 'string' and type(row[2]) == 'string' and not row[1]:find(':', 1, true) then
          local bt = props.beamType
          if type(row[3]) == 'table' and row[3].beamType ~= nil then bt = row[3].beamType end
          fn(row[1], row[2], props, row, bt == nil or bt == '|NORMAL' or bt == 'NORMAL' or bt == '')
        end
      end
    end
  end

  -- mount beams: plain beams between a tree node and a donor body node, from the tree itself and
  -- from the donor's frame / body (link mounts, shock tops... are often nodes of the suspension that
  -- only the FRAME part ties down). A tree node held that way by 3+ different body nodes is bolted
  -- to the body: it becomes a hook the virtual frame holds, and those mount beams and their body
  -- nodes stay behind. A node held by fewer (track bar, a link: ONE beam to the frame) moves, so
  -- its beams come along with their body ends imported, exactly as in the donor.
  local anchors = {} -- tree node -> {body node = true}
  local function addAnchor(a, b)
    local o, x = own[a] and a or b, own[a] and b or a
    anchors[o] = anchors[o] or {}
    anchors[o][x] = true
  end
  for _, part in ipairs(treeParts) do
    eachBeam(part, function(a, b, _, _, plain)
      if plain and (own[a] ~= nil) ~= (own[b] ~= nil) and carNodes[own[a] and b or a] then addAnchor(a, b) end
    end)
  end
  -- the donor's frame / body beams on tree nodes: the default car's parts first; a variant part
  -- (desert frame...) only for tree nodes the default car doesn't hold
  local frameRows, covered, seenBeam = {}, {}, {}
  local function takeFrame(name, onlyNew)
    local touched = {}
    eachBeam(jbeamIO.getPart(ioCtx, name), function(a, b, props, row, plain)
      local ownA, ownB = own[a] ~= nil, own[b] ~= nil
      local knownA, knownB = ownA or carNodes[a] ~= nil, ownB or carNodes[b] ~= nil
      local fresh = not onlyNew or ((not ownA or not covered[a]) and (not ownB or not covered[b]))
      local key = a < b and (a .. '|' .. b) or (b .. '|' .. a)
      if (ownA or ownB) and knownA and knownB and fresh and not seenBeam[key] then
        seenBeam[key] = true
        local o = {}
        for k, v in pairs(props) do o[k] = v end
        if type(row[3]) == 'table' then for k, v in pairs(row[3]) do o[k] = v end end
        for k, v in pairs(o) do
          -- the frame part's $variables are not defined in the car
          if type(v) == 'string' and v:sub(1, 1) == '$' then o[k] = nil end
        end
        o.breakGroup, o.deformGroup = nil, nil -- groups of the donor's frame, not of the swap
        frameRows[#frameRows + 1] = {a, b, o, mount = plain and ownA ~= ownB}
        if plain and ownA ~= ownB then addAnchor(a, b) end
        if ownA then touched[a] = true end
        if ownB then touched[b] = true end
      end
    end)
    for n, _ in pairs(touched) do covered[n] = true end
  end
  for _, name in ipairs(defaultOrder) do takeFrame(name, false) end
  for _, name in ipairs(extraOrder) do takeFrame(name, true) end

  local hooks, hookEnds, anchorNames = {}, {}, {}
  for o, set in pairs(anchors) do
    if tableSize(set) >= 3 then
      hooks[o] = true
      for x, _ in pairs(set) do hookEnds[x] = true end
    end
  end
  local function isHookMount(a, b, plain)
    return plain and ((hooks[a] and not own[b]) or (hooks[b] and not own[a]))
  end

  -- imported donor body points: every body node the tree (or a frame beam that comes along)
  -- uses, except the ones that only bolt a hook down
  local found, list = {}, {}
  local function import(v)
    if not own[v] and not found[v] and carNodes[v] then
      found[v] = true
      local p = carNodes[v]
      list[#list + 1] = {v, p[1], p[2], p[3], p[4], p[5]}
    end
  end
  local function scan(t, depth)
    if depth > 6 then return end
    for _, v in pairs(t) do
      if type(v) == 'string' then
        import(v)
      elseif type(v) == 'table' then
        scan(v, depth + 1)
      end
    end
  end
  for _, part in ipairs(treeParts) do
    for sectionName, section in pairs(part) do
      if type(section) == 'table' and not noRenameKeys[sectionName] and sectionName ~= 'nodes' then
        if sectionName == 'beams' then
          eachBeam(part, function(a, b, _, row, plain)
            if not isHookMount(a, b, plain) then scan(row, 0) end
          end)
          -- property rows may name nodes too (optional link options)
          for _, row in ipairs(section) do
            if type(row) == 'table' and row[1] == nil then scan(row, 0) end
          end
        else
          scan(section, 0)
        end
      end
    end
  end
  local reverse = {}
  for _, fr in ipairs(frameRows) do
    if not isHookMount(fr[1], fr[2], fr.mount) then
      reverse[#reverse + 1] = {fr[1], fr[2], deepcopy(fr[3])}
      import(fr[1])
      import(fr[2])
      scan(fr[3], 0) -- nodes in its options too (the third node of an LBEAM...)
    end
  end
  -- body nodes only hook mounts used: their rows in the tree get dropped on purpose
  for x, _ in pairs(hookEnds) do
    if not found[x] then anchorNames[#anchorNames + 1] = x end
  end
  table.sort(anchorNames)
  local hookList = {}
  for n, _ in pairs(hooks) do
    local p = own[n]
    hookList[#hookList + 1] = {n, p.x, p.y, p.z}
  end
  table.sort(hookList, function(x, y) return x[1] < y[1] end)

  -- the full bundle: the tree's meshes (shock tops, sway bar, subframe...) bind to node groups such
  -- as "pickup_frame" that live on the donor's body. Bring the donor body nodes of those groups that
  -- sit near the tree too, so the meshes have the same nodes to hang on as in the donor.
  -- They are marked visual (index 7): light and softly linked, they carry no load.
  local meshGroups = {}
  for _, part in ipairs(treeParts) do
    for _, row in ipairs(type(part.flexbodies) == 'table' and part.flexbodies or {}) do
      if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= 'mesh' and type(row[2]) == 'table' then
        for _, g in ipairs(row[2]) do
          if type(g) == 'string' then meshGroups[g] = true end
        end
      end
    end
  end
  local function inMeshGroup(g)
    if type(g) == 'string' then return meshGroups[g] == true end
    if type(g) == 'table' then
      for _, s in ipairs(g) do if meshGroups[s] then return true end end
    end
    return false
  end
  local visual = {}
  for name, p in pairs(carNodes) do
    if not own[name] and not found[name] and inMeshGroup(p[5]) then
      local pos = vec3(p[1], p[2], p[3])
      local nearest = math.huge
      for _, op in ipairs(ownPos) do
        local d = op:squaredDistance(pos)
        if d < nearest then nearest = d end
      end
      nearest = math.sqrt(nearest)
      -- a body node that only bolted a hook down comes as a renamed mesh-only copy: the link /
      -- mount meshes still find a node of their group there, while its stiff mount beams (which
      -- name the original) stay behind instead of landing on a light mesh point
      local copyName = hookEnds[name] and ('upav_' .. name) or name
      if nearest <= 0.6 then visual[#visual + 1] = {name = copyName, p = p, d = nearest} end
    end
  end
  table.sort(visual, function(a, b) return a.d < b.d end)
  for i = 1, math.min(40, #visual) do
    local v = visual[i]
    list[#list + 1] = {v.name, v.p[1], v.p[2], v.p[3], v.p[4], v.p[5], true}
  end
  local hookEndList = {}
  for n, _ in pairs(hookEnds) do hookEndList[#hookEndList + 1] = n end
  table.sort(hookEndList)
  return list, ownPos, reverse, hookList, hookEndList, anchorNames
end

-- body nodes the car's ORIGINAL part was bolted to (strut towers, subframe mounts...): the places
-- built to carry suspension loads, so the new suspension's points get tied to these
local function collectTargetMounts(target, replaces)
  local names = {}
  local imports, _, _, _, hookEnds = collectImportNodes(target.jbeam, replaces)
  for _, n in ipairs(imports) do
    if not n[7] then names[#names + 1] = n[1] end -- load carrying points only, not mesh-only ones
  end
  -- and the body nodes whose own beams held the old part down
  for _, name in ipairs(hookEnds or {}) do names[#names + 1] = name end
  return names
end

-- node names of a part and its default sub parts (the car's part that is about to be replaced:
-- its nodes vanish, so nothing may get hooked onto them)
local function treeNodeNames(model, partName, excludeGearbox)
  local set = {}
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not ok or not ioCtx then return set end
  local names = {partName}
  for _, n in ipairs(collectDonorNames(model, partName, excludeGearbox == true)) do names[#names + 1] = n end
  for _, name in ipairs(names) do
    local part = jbeamIO.getPart(ioCtx, name)
    for _, row in ipairs(type(part) == 'table' and type(part.nodes) == 'table' and part.nodes or {}) do
      if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'number' then set[row[1]] = true end
    end
  end
  return set
end

-- donor body points that land on (or right next to) a real node of the car get hooked straight onto
-- it, like the factory part: the car's original suspension mounts within 25 cm, any body node within
-- 3 cm (the same suspension on the same car maps 1:1). Only the rest become imported + welded points.
-- Sets spec.snapMap {donorName = carName}, spec.importNodes (the rest) and spec.mountNames.
local function snapImports(target, spec, allImports, excludeNames, noSnap)
  spec.snapMap = {}
  local rest = {}
  local vd = getVData(target:getID())
  local mounts = {}
  for _, name in ipairs(spec.targetMounts or {}) do mounts[name] = true end
  local cands = {}
  for _, n in pairs(vd and vd.nodes or {}) do
    if type(n) == 'table' and type(n.name) == 'string' and n.pos and n.wheelID == nil
      and not n.name:find('^ups') and not n.name:find('^upa') and not (excludeNames and excludeNames[n.name]) then
      cands[#cands + 1] = {name = n.name, pos = vec3(n.pos), mount = mounts[n.name] == true}
    end
  end
  local Roff = eulerToQuat(spec.rot[1], spec.rot[2], spec.rot[3])
  local pivot = vec3(spec.pivot[1], spec.pivot[2], spec.pivot[3])
  local move = vec3(spec.move[1], spec.move[2], spec.move[3])
  for _, imp in ipairs(allImports) do
    local hit
    if not imp[7] and not noSnap then -- mesh-only points always come along with the bundle
      local p = vec3(imp[2], imp[3], imp[4])
      local pt = pivot + Roff * (p - pivot) + move -- where the point lands in the car's jbeam frame
      local bestMount, bestMountD, bestAny, bestAnyD = nil, 0.05, nil, 0.03
      for _, c in ipairs(cands) do
        local d = c.pos:distance(pt)
        if c.mount and d <= bestMountD then bestMount, bestMountD = c.name, d end
        if d <= bestAnyD then bestAny, bestAnyD = c.name, d end
      end
      hit = bestMount or bestAny
    end
    if hit then spec.snapMap[imp[1]] = hit else rest[#rest + 1] = imp end
  end
  spec.importNodes = rest
  spec.mountNames, spec.visualNames = {}, {}
  for _, n in ipairs(rest) do
    spec.mountNames[#spec.mountNames + 1] = n[1]
    if n[7] then spec.visualNames[#spec.visualNames + 1] = n[1] end
  end
  return tableSize(spec.snapMap), #rest
end

-- virtual frame of a suspension swap: 8 heavy own nodes, a box around the points the suspension
-- hangs on (hooks: its own nodes the donor's frame bolted down, and the imported donor body points),
-- or around the upper half of the suspension when it has few of them. In the car the 8 corners are
-- one rigid box, every hook is held by all 8, and only the box is welded to the chassis: the
-- suspension hangs on its own frame, never straight on the body.
local function addVirtualFrame(spec, ownPos, hooks)
  local pts = {}
  for _, n in ipairs(spec.importNodes or {}) do
    if not n[7] then pts[#pts + 1] = vec3(n[2], n[3], n[4]) end
  end
  for _, h in ipairs(hooks or {}) do pts[#pts + 1] = vec3(h[2], h[3], h[4]) end
  if #pts < 4 then
    local zs = {}
    for _, p in ipairs(ownPos or {}) do zs[#zs + 1] = p.z end
    table.sort(zs)
    local mid = zs[math.max(1, math.ceil(#zs / 2))]
    for _, p in ipairs(ownPos or {}) do
      if mid and p.z >= mid then pts[#pts + 1] = p end
    end
  end
  if #pts == 0 then return 0 end
  local lo, hi = vec3(pts[1]), vec3(pts[1])
  for _, p in ipairs(pts) do
    lo.x, lo.y, lo.z = math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z)
    hi.x, hi.y, hi.z = math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z)
  end
  local c = (lo + hi) * 0.5
  -- 10 cm outside the points, so no hook sits on a face of the box
  local hx = math.max(0.3, (hi.x - lo.x) * 0.5 + 0.1)
  local hy = math.max(0.3, (hi.y - lo.y) * 0.5 + 0.1)
  local hz = math.max(0.2, (hi.z - lo.z) * 0.5 + 0.1)
  spec.importNodes = spec.importNodes or {}
  spec.mountNames = spec.mountNames or {}
  spec.frameNames = {}
  local i = 0
  for _, sx in ipairs({-1, 1}) do
    for _, sy in ipairs({-1, 1}) do
      for _, sz in ipairs({-1, 1}) do
        i = i + 1
        local name = 'upvf' .. i
        spec.importNodes[#spec.importNodes + 1] = {name, c.x + sx * hx, c.y + sy * hy, c.z + sz * hz, 12, ''}
        spec.mountNames[#spec.mountNames + 1] = name
        spec.frameNames[#spec.frameNames + 1] = name
      end
    end
  end
  return i
end

-- everything a suspension swap needs from the donor: its body points (all imported, none snapped
-- onto the car's nodes) and the virtual frame they hang on
local function prepareSuspensionBundle(target, spec)
  -- an added axle has no part of its own to replace: it is welded around the car's rear suspension mounts
  local mountRef = spec.replaces or spec.mountRef
  spec.targetMounts = mountRef and collectTargetMounts(target, mountRef) or {}
  local imports, ownPos, frameBeams, hooks, _, anchorNames = collectImportNodes(spec.model, spec.part)
  spec.frameBeams = frameBeams
  spec.anchorNames = anchorNames -- mount rows on these get dropped on purpose
  spec.hookNames = {}
  for _, h in ipairs(hooks or {}) do spec.hookNames[#spec.hookNames + 1] = h[1] end
  local _, imported = snapImports(target, spec, imports, spec.replaces and treeNodeNames(target.jbeam, spec.replaces) or {}, true)
  local frame = addVirtualFrame(spec, ownPos, hooks)
  log('I', logTag, string.format('suspension swap: %d hooks, %d donor body points imported, virtual frame of %d nodes, %d working frame beams brought along',
    #spec.hookNames, imported, frame, #(frameBeams or {})))
  return imported + #spec.hookNames, frame
end

-- would the donor's wheel shafts find the devices they hang on in this car?
local function donorWheelsDrivable(vehId, model, partName, replaces)
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not ok then return true end
  local names = {partName}
  for _, n in ipairs(collectDonorNames(model, partName, false)) do names[#names + 1] = n end
  local defined, needs = {}, {}
  for _, name in ipairs(names) do
    local part = jbeamIO.getPart(ioCtx, name)
    for _, row in ipairs(type(part) == 'table' and type(part.powertrain) == 'table' and part.powertrain or {}) do
      if type(row) == 'table' and type(row[2]) == 'string' and row[1] ~= 'type' then
        defined[row[2]] = true
        if type(row[3]) == 'string' then needs[#needs + 1] = row[3] end
      end
    end
  end
  -- the car's devices, without the ones that go away with the replaced part (a live axle's own
  -- differential and half shafts, the old suspension's drive shafts...)
  local removed = {}
  local d = core_vehicle_manager.getVehicleData(vehId)
  local oldNode = replaces and findTreeNode(d and d.config and d.config.partsTree, function(n) return n.chosenPartName == replaces end)
  local carCtx = oldNode and vehicleIoCtx(vehId)
  local function rec(node)
    local part = carCtx and type(node.chosenPartName) == 'string' and node.chosenPartName ~= '' and jbeamIO.getPart(carCtx, node.chosenPartName)
    for _, row in ipairs(type(part) == 'table' and type(part.powertrain) == 'table' and part.powertrain or {}) do
      if type(row) == 'table' and type(row[2]) == 'string' and row[1] ~= 'type' then removed[row[2]] = true end
    end
    for _, c in pairs(node.children or {}) do rec(c) end
  end
  if oldNode then rec(oldNode) end
  local carDevices = {}
  local vd = getVData(vehId)
  for _, dev in pairs(vd and vd.powertrain or {}) do
    if type(dev) == 'table' and type(dev.name) == 'string' and not removed[dev.name] then carDevices[dev.name] = true end
  end
  for _, input in ipairs(needs) do
    if not defined[input] and input ~= 'dummy' and not carDevices[input] then return false, input end
  end
  return true
end

local function respawnWithPartSwap(target, kind, spec, replaces, drivetrain)
  return respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.partSwaps = type(cfg.partAttacherExp.partSwaps) == 'table' and cfg.partAttacherExp.partSwaps or {}
    cfg.partAttacherExp.partSwaps[kind] = spec
    if next(cfg.partAttacherExp.partSwaps) == nil then cfg.partAttacherExp.partSwaps = nil end
    local alias = partSwapAlias(kind)
    -- (an added axle replaces nothing: only its own slot is looked for, emptied when it goes)
    local node = findTreeNode(cfg.partsTree, function(n) return (replaces ~= nil and n.chosenPartName == replaces) or n.chosenPartName == alias end)
    if node then
      node.chosenPartName = spec and alias or (replaces or '')
      node.children = nil -- struts, wheels... of the old part don't fit the new one
    end
    if drivetrain then cfg.partAttacherExp.drivetrain = drivetrain end
  end)
end

local deleteEntry -- forward

local drivetrainSpecFromUI -- forward

-- engine swap version 2: the engine tree gets unique names (no more donor nodes overwriting the
-- car's body nodes), and the donor body points its mounts hang on come along (snapped onto the car
-- where they coincide, otherwise imported and welded to the car's original engine mounts)
local function prepareEngineBundle(target, spec)
  spec.version = 2
  local excludeGearbox = spec.keepTransmission ~= false
  spec.targetMounts = collectTargetMounts(target, spec.replaces)
  -- nothing may get hooked onto nodes that vanish or get renamed: the car's old engine tree, and the
  -- donor engine tree (an older swap of it may be in the car right now under its plain names)
  local exclude = treeNodeNames(target.jbeam, spec.replaces, excludeGearbox)
  for name, _ in pairs(treeNodeNames(spec.model, spec.part, excludeGearbox)) do exclude[name] = true end
  local snapped, imported = snapImports(target, spec, collectImportNodes(spec.model, spec.part, excludeGearbox), exclude)
  log('I', logTag, string.format('engine swap bundle: %d mount points snapped onto the car, %d imported', snapped, imported))
end

-- average spring rate (N/m), damping and sway bar stiffness of a donor suspension, straight from its
-- jbeam (default sub parts, $variables at their default values)
local function donorSuspensionRates(model, partName)
  local ok, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not ok or not ioCtx then return nil end
  local names = {partName}
  for _, n in ipairs(collectDonorNames(model, partName, false)) do names[#names + 1] = n end
  local parts, defaults = {}, {}
  for _, name in ipairs(names) do
    local part = jbeamIO.getPart(ioCtx, name)
    if type(part) == 'table' then
      parts[#parts + 1] = part
      for i, row in ipairs(type(part.variables) == 'table' and part.variables or {}) do
        if i > 1 and type(row) == 'table' and type(row[1]) == 'string' and type(row[5]) == 'number' then defaults[row[1]] = row[5] end
      end
    end
  end
  local function num(v)
    if type(v) == 'number' then return v end
    if type(v) == 'string' and v:sub(1, 1) == '$' and v:sub(2, 2) ~= '=' then return defaults[v] end
    return nil
  end
  local springSum, springN, dampSum, dampN, barSum, barN = 0, 0, 0, 0, 0, 0
  for _, part in ipairs(parts) do
    local props = {}
    for _, row in ipairs(type(part.beams) == 'table' and part.beams or {}) do
      if type(row) == 'table' then
        if row[1] == nil then
          for k, v in pairs(row) do props[k] = v end
        elseif type(row[1]) == 'string' and type(row[2]) == 'string' and not row[1]:find(':', 1, true) then
          local o = {}
          for k, v in pairs(props) do o[k] = v end
          for _, x in ipairs(row) do
            if type(x) == 'table' then for k, v in pairs(x) do o[k] = v end end
          end
          if type(o.beamType) == 'string' and o.beamType:find('BOUNDED', 1, true) then
            local k, c = num(o.beamSpring), num(o.beamDamp)
            if k and k > 0 and k < 1000000 then
              springSum, springN = springSum + k, springN + 1
            elseif k == 0 and c and c > 0 then
              dampSum, dampN = dampSum + c, dampN + 1
            end
          end
        end
      end
    end
    local barProps = {}
    for _, row in ipairs(type(part.torsionbars) == 'table' and part.torsionbars or {}) do
      if type(row) == 'table' then
        if row[1] == nil then
          for k, v in pairs(row) do barProps[k] = v end
        elseif type(row[1]) == 'string' and not row[1]:find(':', 1, true) then
          local spring = num(barProps.spring)
          for _, x in ipairs(row) do
            if type(x) == 'table' and x.spring ~= nil then spring = num(x.spring) end
          end
          if spring and spring > 0 then barSum, barN = barSum + spring, barN + 1 end
        end
      end
    end
  end
  return {
    spring = springN > 0 and springSum / springN or nil,
    damp = dampN > 0 and dampSum / dampN or nil,
    sway = barN > 0 and barSum / barN or nil,
    model = model, part = partName,
  }
end

local function swapPart(e, target)
  local kind = e.kind
  local added = e.added or (swapKinds[kind] and swapKinds[kind].added)
  local replaces = not added and (e.replaces or getTargetSuspension(target:getID(), kind)) or nil
  if not replaces and not added then msg('Nerasta masinos detale, kuria butu galima pakeisti.', 6) return end
  local off = offsetVec(e)
  local spec = {
    model = e.model,
    part = e.partName,
    replaces = replaces,
    version = 15,
    move = {off.x, off.y, off.z},
    rot = {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
    pivot = {e.pivot.x, e.pivot.y, e.pivot.z},
    maxGap = S.maxGapPtr[0],
    strength = S.unbreakablePtr[0] and -1 or math.max(1000, S.strengthPtr[0]),
    added = added or nil,
    mountRef = added and (e.mountRef or getTargetSuspension(target:getID(), 'susp_R')) or nil,
  }
  local imported, frame = prepareSuspensionBundle(target, spec)
  local drivetrain
  local current = getPA(target:getID()).drivetrain
  if added then
    -- its own drivetrain devices stay out: the universal drivetrain drives it (both rear axles,
    -- an inter-axle differential between them)
    if not (type(current) == 'table' and current.enabled) then
      drivetrain = drivetrainSpecFromUI()
      if drivetrain.layout == 'FWD' then drivetrain.layout = 'AWD' end
      msg(string.format('Antra galine asis varoma universaliomis pavaromis (%s).', drivetrain.layout), 8)
    end
  else
    local drivable, missing = donorWheelsDrivable(target:getID(), e.model, e.partName, replaces)
    if not drivable and S.autoDrivetrainPtr[0] and not (type(current) == 'table' and current.enabled) then
      drivetrain = drivetrainSpecFromUI()
      msg(string.format('Naujos pakabos velenai iesko "%s" - ijungiamos universalios pavaros (%s).', tostring(missing), drivetrain.layout), 8)
    end
  end
  deleteEntry(e)
  if respawnWithPartSwap(target, kind, spec, replaces, drivetrain) then
    msg(string.format('%s: %s -> %s (virtualus remas: %d tasku + %d donoro remo tasku)', swapKinds[kind].label, tostring(replaces or '+'), tostring(e.partName), frame, imported), 6)
  end
end

-- engine swap v4 (logic swap): the car keeps its own engine block physics; the donor's engine base
-- data, sounds and block mesh go into the car's engine part, and its tuning slots (ECU, internals,
-- intake / turbo...) replace the car's, so the donor engine can be tuned in the normal parts menu.
-- Nothing physical changes, so nothing can break or fly off.
local function swapEngine(e, target)
  local replaces = e.replaces or getTargetEngine(target:getID())
  if not replaces then msg('Si masina neturi vidaus degimo variklio, kuri butu galima pakeisti.', 6) return end
  local data = captureEngineData(getVData(e.id)) -- only for the power shown in the message
  local off = offsetVec(e)
  local spec = {
    model = e.model,
    part = e.partName,
    replaces = replaces,
    version = 4,
    mode = 'logic',
    meshSwap = S.engineMeshPtr[0],
    move = {off.x, off.y, off.z},
    rot = {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
    pivot = {e.pivot.x, e.pivot.y, e.pivot.z},
  }
  local info = data and engineInfo(data) or {}
  deleteEntry(e)
  if respawnWithSwap(target, spec, replaces) then
    msg(string.format('Engine swap: %s -> %s (~%d kW bazine kreive)', tostring(replaces), tostring(e.partName), math.floor((info.kw or 0) + 0.5)), 6)
  end
end

drivetrainSpecFromUI = function()
  return {
    enabled = true,
    layout = layouts[S.dtLayoutPtr[0] + 1],
    diffType = diffTypes[S.dtDiffPtr[0] + 1],
    centerType = diffTypes[S.dtCenterPtr[0] + 1],
    frontSplit = S.dtSplitPtr[0],
    finalDrive = S.dtFinalPtr[0],
    lockerF = S.dtLockFPtr[0] or nil,
    lockerR = S.dtLockRPtr[0] or nil,
    lockerC = S.dtLockCPtr[0] or nil,
    partTime = S.dtPartTimePtr[0] or nil,
    lowRange = S.dtLowRangePtr[0] or nil,
    lowRatio = S.dtLowRatioPtr[0],
  }
end

local function swapGearbox(e, target)
  local replaces = e.replaces or getTargetGearbox(target:getID())
  if not replaces then msg('Nerasta masinos pavaru deze, kuria butu galima pakeisti.', 6) return end
  local off = offsetVec(e)
  local spec = {
    model = e.model,
    part = e.partName,
    replaces = replaces,
    move = {off.x, off.y, off.z},
    rot = {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
    pivot = {e.pivot.x, e.pivot.y, e.pivot.z},
    welds = math.max(1, S.maxWeldsPtr[0]),
    maxGap = S.maxGapPtr[0],
    strength = S.unbreakablePtr[0] and -1 or math.max(1000, S.strengthPtr[0]),
  }
  local useDrivetrain = S.autoDrivetrainPtr[0]
  deleteEntry(e)
  local ok = respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.gearboxSwap = spec
    local node = findTreeNode(cfg.partsTree, treeNodeIsGearbox(replaces))
    if node then
      node.chosenPartName = gearboxAlias
      node.children = nil
    end
    if useDrivetrain then cfg.partAttacherExp.drivetrain = drivetrainSpecFromUI() end
  end)
  if ok then msg(string.format('Gearbox swap: %s -> %s', tostring(replaces), tostring(e.partName)), 6) end
end

local function mergeIntoTarget(e)
  local ghost, target = getVeh(e.id), getVeh(e.targetId)
  if not ghost or not target then msg('Nerasta detale arba masina.') return end
  if e.mode == 'engine' then return swapEngine(e, target) end
  if e.mode == 'gearbox' then return swapGearbox(e, target) end
  if e.mode == 'partswap' then return swapPart(e, target) end
  local meshOnly = e.mode == 'meshonly'

  local nearest, inReach = measureGap(e, ghost, target)
  if inReach == 0 and not meshOnly then -- a mesh only part just follows the body, from any distance
    msg(string.format('Per toli nuo masinos: artimiausias tarpas %.2f m (leidziama %.2f m). Priartink detale arba padidink "Maks. tarpas".', nearest, S.maxGapPtr[0]), 8)
    return
  end

  local off = offsetVec(e)
  local extras = deepcopy(getExtras(e.targetId))
  -- a front end: the car's own front parts come off (kept in the extra, back when it is removed)
  local frontEnd = e.frontEnd and deepcopy(e.frontEnd) or nil
  local replaced
  if frontEnd then
    frontEnd.replaced = nil
    if frontEnd.removeOwn then
      replaced = S.targetFrontParts(target)
      frontEnd.replaced = #replaced > 0 and replaced or nil
    end
  end
  table.insert(extras, {
    model = e.model,
    part = e.partName,
    move = {off.x, off.y, off.z},
    rot = {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
    pivot = {e.pivot.x, e.pivot.y, e.pivot.z},
    scale = e.builtScale ~= 1 and e.builtScale or nil,
    welds = math.max(1, S.maxWeldsPtr[0]),
    maxGap = S.maxGapPtr[0],
    strength = S.unbreakablePtr[0] and -1 or math.max(1000, S.strengthPtr[0]),
    noCollision = S.noCollisionPtr[0] or nil,
    meshOnly = meshOnly or nil,
    meshNodes = meshOnly and e.meshNodes or nil,
    frontEnd = frontEnd,
  })

  deleteEntry(e)
  local also = replaced and #replaced > 0 and function(cfg) S.setTreeParts(cfg, replaced, '') end or nil
  if respawnWithExtras(target, extras, also) then
    if frontEnd then
      msg(string.format('Priekis is %s idiegtas (%d detales, %d savu nuimta).', tostring(e.model), #frontEnd.parts, replaced and #replaced or 0), 6)
    else
      msg(string.format('Detale %s idiegta i masina (%d tasku arti kebulo).', e.partName, inReach), 5)
    end
  end
end

local function removeExtra(target, index)
  local extras = deepcopy(getExtras(target:getID()))
  local ex = extras[index]
  if not ex then return end
  table.remove(extras, index)
  -- a front end gives the car its own front parts back
  local back = type(ex.frontEnd) == 'table' and type(ex.frontEnd.replaced) == 'table' and ex.frontEnd.replaced or nil
  respawnWithExtras(target, extras, back and function(cfg) S.setTreeParts(cfg, back, nil) end or nil)
end

--------------------------------------------------------------------------------
-- spawning the ghost
--------------------------------------------------------------------------------

-- preset: {move, rot, pivot?, mode?, replaces?} (an engine swap ghost or a part taken off the car)
local function registerEntry(id, partName, model, target, preset)
  if entries[id] then return entries[id] end
  pendingSpawn = nil
  local e = {
    id = id,
    partName = partName,
    model = model,
    state = 'loading',
    stateTimer = 0,
    hold = true,
    placeOnRoof = preset == nil or (preset.mode == 'meshonly' and preset.move == nil),
    mode = preset and preset.mode or 'part',
    meshNodes = preset and preset.meshNodes,
    replaces = preset and preset.replaces,
    kind = preset and preset.kind,
    added = preset and preset.added,
    mountRef = preset and preset.mountRef,
    presetMove = preset and preset.move,
    autoMove = preset and preset.auto and preset.move,
    off = {im.FloatPtr(0), im.FloatPtr(0), im.FloatPtr(0)},
    rot = {im.FloatPtr(0), im.FloatPtr(0), im.FloatPtr(0)},
    -- size: the slider, and the factor the preview was built with (only that one gets attached)
    frontEnd = preset and type(preset.frontEnd) == 'table' and preset.frontEnd or nil,
    builtScale = preset and S.extraScale(preset) and tonumber(preset.scale) or 1,
  }
  e.scale = im.FloatPtr(e.builtScale)
  if preset then
    for i = 1, 3 do
      e.off[i][0] = preset.move and preset.move[i] or 0
      e.rot[i][0] = preset.rot and preset.rot[i] or 0
    end
    if preset.pivot then e.pivot = vec3(preset.pivot[1], preset.pivot[2], preset.pivot[3]) end
  end
  if not (target and setupTarget(e, target)) then
    msg('Nepavyko nuskaityti masinos mazgu (nodes).')
  end
  entries[id] = e
  selectedEntryId = id
  S.tabRequest = 'part' -- the window shows the tab with the new preview's position (e.g. after Move in Installed)
  return e
end

local function spawnGhost(model, partName, target, preset)
  -- a suspension alone has nothing to hang on (its frame is not there): the preview gets glued rigid
  -- (a front end too: its pieces - bumper, fenders, hood - would fall apart)
  local frontEnd = type(preset) == 'table' and type(preset.frontEnd) == 'table' and preset.frontEnd or nil
  local config = {mainPartName = partName, partAttacherExp = {ghost = true, model = model, rigid = (type(preset) == 'table' and preset.mode == 'partswap') or frontEnd ~= nil, frontEnd = frontEnd}}
  if type(preset) == 'table' and preset.mode == 'meshonly' then config.partAttacherExp.meshOnly = {nodes = preset.meshNodes} end
  -- a scaled part: the preview is built at that size (around the pivot the part keeps)
  config.partAttacherExp.scale = type(preset) == 'table' and S.extraScale(preset) or nil
  -- only the engine preview keeps its powertrain (its data feeds the swap message)
  if type(preset) == 'table' and preset.mode == 'engine' then config.partAttacherExp.keepPowertrain = true end
  if S.copyPaintPtr[0] then
    local td = core_vehicle_manager.getVehicleData(target:getID())
    if td and td.config and td.config.paints then config.paints = deepcopy(td.config.paints) end
  end

  -- onVehicleSpawned picks the ghost up too, in case spawnNewVehicle doesn't return it
  pendingSpawn = {partName = partName, model = model, targetId = target:getID(), time = os.clock(), preset = preset}

  -- safeSpawn off: the safe spawn search drops the part on the ground and returns nil
  local spawnPos = vec3(target:getPosition()) + vec3(0, 0, 4)
  local veh = core_vehicles.spawnNewVehicle(model, {config = config, pos = spawnPos, autoEnterVehicle = false, safeSpawn = false})
  if veh and type(veh) ~= 'boolean' and veh.getID then
    registerEntry(veh:getID(), partName, model, target, preset)
  end
end

-- ghost of a donor engine, placed where the car's engine sits (block centroids matched)
local function spawnEngineGhost(model, enginePart, target)
  local replaces = getTargetEngine(target:getID())
  if not replaces then msg('Si masina neturi vidaus degimo variklio, kuri butu galima pakeisti.', 6) return end
  local tc = rawNodeCentroid(target.jbeam, replaces)
  local dc = rawNodeCentroid(model, enginePart)
  local move = (tc and dc) and (tc - dc) or vec3()
  spawnGhost(model, enginePart, target, {mode = 'engine', replaces = replaces, move = {move.x, move.y, move.z}, rot = {0, 0, 0}})
end

-- ghost of a donor gearbox, placed where the car's gearbox sits
local function spawnGearboxGhost(model, gearboxPart, target)
  local replaces = getTargetGearbox(target:getID())
  if not replaces then msg('Nerasta masinos pavaru deze, kuria butu galima pakeisti.', 6) return end
  local pa = getPA(target:getID())
  -- the car's current gearbox may itself come from a donor model (engine swap without keeping it)
  local tc = rawNodeCentroid(target.jbeam, replaces)
  if not tc and type(pa.engineSwap) == 'table' then tc = rawNodeCentroid(pa.engineSwap.model, replaces) end
  local dc = rawNodeCentroid(model, gearboxPart)
  local move = (tc and dc) and (tc - dc) or vec3()
  spawnGhost(model, gearboxPart, target, {mode = 'gearbox', replaces = replaces, move = {move.x, move.y, move.z}, rot = {0, 0, 0}})
end

-- ghost of a donor suspension, placed where the car's suspension on that side sits
local function spawnPartSwapGhost(model, partName, target, kind)
  if swapKinds[kind] and swapKinds[kind].added then
    -- a second rear axle: its preview goes 1.3 m behind the car's rear suspension
    local ref = getTargetSuspension(target:getID(), 'susp_R')
    local ioCtx = vehicleIoCtx(target:getID())
    local tc = ref and ioCtx and partNodeCentroid(jbeamIO.getPart(ioCtx, ref))
    local dc = rawNodeCentroid(model, partName)
    local move = (tc and dc) and (tc + vec3(0, 1.3, 0) - dc) or vec3()
    return spawnGhost(model, partName, target, {mode = 'partswap', kind = kind, added = true, mountRef = ref, move = {move.x, move.y, move.z}, rot = {0, 0, 0}})
  end
  local replaces = getTargetSuspension(target:getID(), kind)
  if not replaces then msg('Nerasta masinos ' .. swapKinds[kind].label:lower() .. ', kuria butu galima pakeisti.', 6) return end
  local ioCtx = vehicleIoCtx(target:getID())
  local tc = ioCtx and partNodeCentroid(jbeamIO.getPart(ioCtx, replaces))
  local dc = rawNodeCentroid(model, partName)
  local move = (tc and dc) and (tc - dc) or vec3()
  spawnGhost(model, partName, target, {mode = 'partswap', kind = kind, replaces = replaces, move = {move.x, move.y, move.z}, rot = {0, 0, 0}})
end

local function removePartSwap(target, kind)
  local spec = getPartSwap(target:getID(), kind)
  if spec then respawnWithPartSwap(target, kind, nil, spec.replaces) end
end

-- swaps made before version 2 welded the moving mount nodes; redo them with imported body points
local function upgradePartSwap(target, kind)
  local spec = getPartSwap(target:getID(), kind)
  if not spec then return end
  spec = deepcopy(spec)
  local imported, frame = prepareSuspensionBundle(target, spec)
  spec.version = 15
  local drivetrain
  local current = getPA(target:getID()).drivetrain
  if not spec.added and S.autoDrivetrainPtr[0] and not (type(current) == 'table' and current.enabled) then
    -- the car's tree holds the swapped part now: check against the original part's devices
    local drivable, missing = donorWheelsDrivable(target:getID(), spec.model, spec.part, partSwapAlias(kind))
    if not drivable then
      drivetrain = drivetrainSpecFromUI()
      msg(string.format('Naujos pakabos velenai iesko "%s" - ijungiamos universalios pavaros (%s).', tostring(missing), drivetrain.layout), 8)
    end
  end
  if respawnWithPartSwap(target, kind, spec, spec.replaces, drivetrain) then
    msg(string.format('%s pataisyta: virtualus remas %d tasku + %d donoro remo tasku.', swapKinds[kind].label, frame, imported), 6)
  end
end

local function editPartSwap(target, kind)
  local spec = getPartSwap(target:getID(), kind)
  if not spec then return end
  local preset = deepcopy(spec)
  preset.mode, preset.kind = 'partswap', kind
  removePartSwap(target, kind)
  spawnGhost(spec.model, spec.part, target, preset)
end

--------------------------------------------------------------------------------
-- radiator (logic): the car keeps its own radiator and mesh, its engine gets the donor radiator's
-- cooling data (a radiator part is mostly data: two nodes and a mesh hung on its own car's body)
--------------------------------------------------------------------------------

-- cooling keys of a part's mainEngine, $variables at the part's defaults; nil when it has none
S.radiatorData = function(part)
  local me = type(part) == 'table' and type(part.mainEngine) == 'table' and part.mainEngine
  if not me then return nil end
  local defaults = {}
  for i, row in ipairs(type(part.variables) == 'table' and part.variables or {}) do
    if i > 1 and type(row) == 'table' and type(row[1]) == 'string' then defaults[row[1]] = row[5] end
  end
  local data, n = {}, 0
  for k, v in pairs(me) do
    if type(k) == 'string' and (k:find('^radiator') or k == 'coolantVolume' or k == 'thermostatTemperature') then
      if type(v) == 'string' and v:sub(1, 1) == '$' then v = defaults[v] end
      if type(v) == 'number' or type(v) == 'string' or type(v) == 'boolean' then
        data[k] = v
        n = n + 1
      end
    end
  end
  if not (data.radiatorArea or data.radiatorEffectiveness) then return nil end
  return data, n
end

S.applyRadiator = function(target, model, partName)
  if not target then msg('Isek i masina.', 5) return end
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  local part = okCtx and jbeamIO.getPart(ioCtx, partName)
  local data = S.radiatorData(part)
  if not data then msg('Si detale neturi ausinimo duomenu.', 5) return end
  local vd = getVData(target:getID())
  local me = vd and type(vd.mainEngine) == 'table' and vd.mainEngine
  if not me then msg('Si masina neturi vidaus degimo variklio, kuri butu galima ausinti.', 6) return end
  if respawnWithConfig(target, function(cfg)
    cfg.partAttacherExp.radiatorSwap = {model = model, part = partName, data = data}
  end) then
    msg(string.format('Radiatorius %s: plotas %s -> %s, efektyvumas %s -> %s%s', partName,
      tostring(me.radiatorArea or '-'), tostring(data.radiatorArea or '-'),
      tostring(me.radiatorEffectiveness or '-'), tostring(data.radiatorEffectiveness or '-'),
      me.thermalsEnabled == false and ' (sio variklio temperatura neskaiciuojama - poveikio nebus)' or ''), 8)
  end
end

S.removeRadiator = function(target)
  if target then respawnWithConfig(target, function(cfg) cfg.partAttacherExp.radiatorSwap = nil end) end
end

--------------------------------------------------------------------------------
-- snorkel (any added part with air intake points, engineGroup "engine_intake"): the engine floods
-- only while ALL of its intake points are under water, so with the snorkel's points among them it
-- keeps running until the snorkel's top goes under too. The car's engine may call its group
-- differently: the points are added to the engine's resolved list directly.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- glowing materials: a part's mesh may be switched (materialOverride) to a material name that only
-- the donor's glowMap defines - e.g. the Scintilla's brake discs go "scintilla_brakedisc_front" ->
-- "scintilla_brakedisc_front_R", which the glowMap of its MAIN part turns into the plain or the
-- glowing disc. The donor's main part never comes along, so without its entries the disc has no
-- material at all (no texture).
--------------------------------------------------------------------------------

-- every glowMap entry of a model: its main part and its default parts below
S.donorGlowMap = function(model)
  S.glowCache = S.glowCache or {}
  if S.glowCache[model] then return S.glowCache[model] end
  local out = {}
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if okCtx and ioCtx then
    local visited = {}
    local function walk(name, depth)
      if depth > 8 or type(name) ~= 'string' or name == '' or visited[name] then return end
      visited[name] = true
      local okP, part = pcall(origGetPart or jbeamIO.getPart, ioCtx, name)
      if not okP or type(part) ~= 'table' then return end
      if type(part.glowMap) == 'table' then
        for k, v in pairs(part.glowMap) do
          if out[k] == nil then out[k] = v end
        end
      end
      for _, s in ipairs(part.slots2 or part.slots or {}) do
        if type(s) == 'table' then walk(s.default, depth + 1) end
      end
    end
    walk(jbeamIO.getMainPartName(ioCtx), 0)
  end
  S.glowCache[model] = out
  return out
end

-- the entries the vehicle's meshes need from its donors: every materialOverride target, and the
-- donor's own names ("scintilla_headlight" on an added light); the car's own entries stay
S.addDonorGlowMaps = function(vehicle, marker)
  local models, seen = {}, {}
  local function add(m)
    if type(m) == 'string' and m ~= '' and not seen[m] then
      seen[m] = true
      models[#models + 1] = m
    end
  end
  add(marker.model)
  for _, ex in ipairs(type(marker.extraParts) == 'table' and marker.extraParts or {}) do add(type(ex) == 'table' and ex.model) end
  for _, spec in pairs(type(marker.partSwaps) == 'table' and marker.partSwaps or {}) do add(type(spec) == 'table' and spec.model) end
  for _, key in ipairs({'engineSwap', 'gearboxSwap'}) do add(type(marker[key]) == 'table' and marker[key].model) end
  if #models == 0 then return end
  local targets = {}
  for _, section in ipairs({vehicle.flexbodies or {}, vehicle.props or {}}) do
    for _, fb in pairs(section) do
      if type(fb) == 'table' and type(fb.materialOverride) == 'table' then
        for _, mo in ipairs(fb.materialOverride) do
          if type(mo) == 'table' and type(mo[2]) == 'string' then targets[mo[2]] = true end
        end
      end
    end
  end
  vehicle.glowMap = type(vehicle.glowMap) == 'table' and vehicle.glowMap or {}
  local added = 0
  for _, model in ipairs(models) do
    for key, entry in pairs(S.donorGlowMap(model)) do
      if type(key) == 'string' and vehicle.glowMap[key] == nil and (targets[key] or key:sub(1, #model + 1) == model .. '_') then
        vehicle.glowMap[key] = deepcopy(entry)
        added = added + 1
      end
    end
  end
  if added > 0 and not marker.ghost then
    log('I', logTag, string.format('%d glowing / switched materials of the donor (brake discs, lights) added', added))
  end
end

--------------------------------------------------------------------------------
-- safety / driving electronics on any car (spec: {abs, tc, esc, twoStep = rpm, lineLock}): ABS on
-- every wheel (the wheels' own ABS), traction / stability control (the game's classic "esc"
-- controller, its modes switched while driving), 2-step launch control and a line lock (front
-- brakes held for a burnout). Whatever the car already has of these stays as it is.
--------------------------------------------------------------------------------

-- the 4 corner wheels {FL, FR, RL, RR}: by name, else by position (jbeam -Y is forward, +X left)
S.cornerWheels = function(vehicle)
  local list, byName = {}, {}
  for _, w in pairs(type(vehicle.wheels) == 'table' and vehicle.wheels or {}) do
    local n1 = type(w) == 'table' and vehicle.nodes[w.node1]
    local n2 = type(w) == 'table' and vehicle.nodes[w.node2]
    if type(w) == 'table' and type(w.name) == 'string' and n1 and n2 and n1.pos and n2.pos then
      list[#list + 1] = {name = w.name, pos = (n1.pos + n2.pos) * 0.5}
      byName[w.name] = true
    end
  end
  if #list < 4 then return nil end
  if byName.FL and byName.FR and byName.RL and byName.RR then return {'FL', 'FR', 'RL', 'RR'} end
  table.sort(list, function(a, b) return a.pos.y < b.pos.y end)
  local front, rear = {list[1], list[2]}, {list[#list - 1], list[#list]}
  local function leftFirst(a, b) return a.pos.x > b.pos.x end
  table.sort(front, leftFirst)
  table.sort(rear, leftFirst)
  return {front[1].name, front[2].name, rear[1].name, rear[2].name}
end

S.hasController = function(vehicle, fileNames)
  for _, c in pairs(type(vehicle.controller) == 'table' and vehicle.controller or {}) do
    if type(c) == 'table' and type(c.fileName) == 'string' and fileNames[c.fileName] then return true end
  end
  return false
end

S.addController = function(vehicle, row)
  local key = 0
  for k, _ in pairs(vehicle.controller) do
    if type(k) == 'number' and k >= key then key = k + 1 end
  end
  vehicle.controller[key] = row
end

-- classic esc controller modes: traction control and / or stability control, and "Off"
S.escConfig = function(wheelNames, tc, esc)
  local tcs = {slipThreshold = 0.03, minThrottleFactor = 0.05, maxBrakingFactor = 0.85, throttleProportionalFactor = 3.5,
    throttleIntegralFactor = 5, brakingProportionalFactor = 2, brakingIntegralFactor = 1, brakeThrottleSwitchThreshold = 20}
  local yaw = {maxSideAcceleration = 10, brakeForceMultiplier = 1, escThreshold = 0.2, characteristicSpeed = -1,
    proportionalFactor = 0.95, integralFactor = 2.0, maxIntegralPart = 2.0, skewStiffnessFront = 122500,
    skewStiffnessRear = 134100, desiredYawRateSmoothing = 570}
  local function mode(order, color, withTc, withEsc)
    local m = {escEnabled = true, escConfigurationEnabled = true, order = order, activeColor = color}
    for k, v in pairs(yaw) do m[k] = v end
    for k, v in pairs(tcs) do m[k] = v end
    if not withEsc then m.escThreshold = 999 end -- never brakes a wheel for the yaw
    if not withTc then m.slipThreshold = 99 end -- never cuts the throttle for wheelspin
    return m
  end
  local configurations = {['ESC Off'] = {escEnabled = false, escConfigurationEnabled = true, order = 40, activeColor = 'AA3939',
    overrideESCPulse = 1, overrideTCSPulse = 1}}
  if esc and tc then configurations['ESC + TC'] = mode(10, '98FB00', true, true) end
  if esc and not tc then configurations['ESC'] = mode(10, '98FB00', false, true) end
  if tc then configurations['TC'] = mode(20, 'FFD700', true, false) end
  return {fileName = 'esc', name = 'esc', actionedWheels = wheelNames, isDebugMode = 0, defaultConfig = 1, configurations = configurations}
end

S.applySafety = function(vehicle, spec)
  if type(vehicle.controller) ~= 'table' then return 'the car has no controllers (not a driven vehicle) - nothing added' end
  local done, own = {}, {}
  if spec.abs then
    local count = 0
    for _, w in pairs(type(vehicle.wheels) == 'table' and vehicle.wheels or {}) do
      if type(w) == 'table' then
        if not (w.enableABS or w.enableABSactuator) then count = count + 1 end
        w.enableABS = true
      end
    end
    done[#done + 1] = string.format('ABS on %d more wheels', count)
  end
  local corners = S.cornerWheels(vehicle)
  if spec.tc or spec.esc then
    if S.hasController(vehicle, {esc = true, ['drivingDynamics/supervisors/tractionControl'] = true, ['drivingDynamics/supervisors/yawControl'] = true}) then
      own[#own + 1] = 'traction / stability control'
    elseif not corners then
      own[#own + 1] = 'traction / stability control (needs 4 wheels)'
    else
      S.addController(vehicle, S.escConfig(corners, spec.tc, spec.esc))
      done[#done + 1] = string.format('%s on %s', spec.tc and spec.esc and 'ESC + TC' or spec.tc and 'TC' or 'ESC', table.concat(corners, ' '))
    end
  end
  local rpm = tonumber(spec.twoStep)
  if rpm then
    if S.hasController(vehicle, {twoStepLaunch = true}) then
      own[#own + 1] = '2-step'
    else
      S.addController(vehicle, {fileName = 'twoStepLaunch', rpmLimit = rpm})
      done[#done + 1] = string.format('2-step at %d rpm', rpm)
    end
  end
  if spec.lineLock then
    if S.hasController(vehicle, {lineLock = true}) then
      own[#own + 1] = 'line lock'
    elseif not corners then
      own[#own + 1] = 'line lock (needs 4 wheels)'
    else
      S.addController(vehicle, {fileName = 'lineLock', name = 'lineLock', lockedLines = {corners[1], corners[2]}})
      done[#done + 1] = string.format('line lock on %s %s', corners[1], corners[2])
    end
  end
  return table.concat(done, ', ') .. (#own > 0 and ('; kept the car\'s own / skipped: ' .. table.concat(own, ', ')) or '')
end

S.isIntakeGroup = function(g)
  for _, s in ipairs(type(g) == 'table' and g or {g}) do
    if type(s) == 'string' and s:lower():find('intake', 1, true) then return true end
  end
  return false
end

S.connectIntakes = function(vehicle, extras)
  local wd = type(vehicle.mainEngine) == 'table' and vehicle.mainEngine.waterDamage
  local list = type(wd) == 'table' and type(wd._engineGroup_nodes) == 'table' and wd._engineGroup_nodes or nil
  for i, ex in ipairs(extras) do
    local prefix = 'upa' .. i .. '_'
    local cids = {}
    for _, n in pairs(vehicle.nodes) do
      if type(n) == 'table' and type(n.name) == 'string' and n.name:sub(1, #prefix) == prefix and S.isIntakeGroup(n.engineGroup) then
        cids[#cids + 1] = n.cid
      end
    end
    if #cids > 0 then
      if list and #list > 0 then
        local have = {}
        for _, cid in ipairs(list) do have[cid] = true end
        for _, cid in ipairs(cids) do
          if not have[cid] then list[#list + 1] = cid end
        end
        log('I', logTag, string.format('extra part %d (%s): the engine takes its air through it too (%d of its %d intake points) - it floods only when all of them are under water', i, tostring(ex.part), #cids, #list))
      else
        -- an engine that can't flood stays so (a snorkel must not add a way to break it)
        log('I', logTag, string.format('extra part %d (%s): %d air intake points, but the car\'s engine never floods - nothing to do', i, tostring(ex.part), #cids))
      end
    end
  end
end

--------------------------------------------------------------------------------
-- turbo / supercharger (logic): the engine finds its forced induction through mainEngine.turbocharger /
-- .supercharger = "<section name>". The donor part's section (from it or its default sub parts: a
-- twin turbo is switched on in its exhaust manifold) goes into the car's engine part as upa_turbocharger
-- / upa_supercharger, with the donor's tuning variables (wastegate...: they show in the Tuning menu);
-- after loading the engine is pointed at them, over whatever the car's own intake had.
--------------------------------------------------------------------------------

S.forcedInductionOf = function(model, partName)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not okCtx or not ioCtx then return nil end
  local out, seenVar, visited = {variables = {}}, {}, {}
  local function take(name, depth)
    if depth > 4 or type(name) ~= 'string' or visited[name] then return end
    visited[name] = true
    local p = jbeamIO.getPart(ioCtx, name)
    if type(p) ~= 'table' then return end
    local me = type(p.mainEngine) == 'table' and p.mainEngine or {}
    for _, kind in ipairs({'turbocharger', 'supercharger'}) do
      local section = type(me[kind]) == 'string' and me[kind] or kind
      -- one turbo's data is often split over several parts (engine side in the intake, the boost
      -- curve in a sub part): merged like the game does, later parts adding to / overriding
      if type(p[section]) == 'table' then
        out[kind] = out[kind] or {}
        for k, v in pairs(p[section]) do out[kind][k] = deepcopy(v) end
      end
    end
    if me.torqueModIntake ~= nil and out.torqueModIntake == nil then out.torqueModIntake = deepcopy(me.torqueModIntake) end
    for i, row in ipairs(type(p.variables) == 'table' and p.variables or {}) do
      if i > 1 and type(row) == 'table' and type(row[1]) == 'string' and not seenVar[row[1]] then
        seenVar[row[1]] = true
        out.variables[#out.variables + 1] = deepcopy(row)
      end
    end
    for _, s in ipairs(p.slots2 or p.slots or {}) do
      if type(s) == 'table' then take(s.default, depth + 1) end
    end
  end
  take(partName, 0)
  -- only complete ones: the engine code needs a turbo's boost curve and a supercharger's type
  if out.turbocharger and not S.fiComplete('turbocharger', out.turbocharger) then out.turbocharger = nil end
  if out.supercharger and not S.fiComplete('supercharger', out.supercharger) then out.supercharger = nil end
  if not (out.turbocharger or out.supercharger) then return nil end
  return out
end

-- what turbocharger.lua / supercharger.lua need to start; anything less disables the whole vehicle
S.fiComplete = function(kind, section)
  if type(section) ~= 'table' then return false end
  if kind == 'turbocharger' then return type(section.pressurePSI) == 'table' and type(section.engineDef) == 'table' end
  return type(section.type) == 'string'
end

S.forcedInductionKind = function(fi)
  return (fi.turbocharger and fi.supercharger) and 'Turbo + kompresorius' or fi.turbocharger and 'Turbo' or 'Kompresorius'
end

S.applyForcedInduction = function(target, model, partName)
  if not target then msg('Isek i masina.', 5) return end
  local fi = S.forcedInductionOf(model, partName)
  if not fi then msg('Si detale neturi turbo / kompresoriaus duomenu.', 6) return end
  local enginePart = getTargetEngine(target:getID())
  if not enginePart then msg('Si masina neturi vidaus degimo variklio, kuri butu galima pakeisti.', 6) return end
  fi.model, fi.part, fi.enginePart = model, partName, enginePart
  if respawnWithConfig(target, function(cfg) cfg.partAttacherExp.fiSwap = fi end) then
    msg(string.format('%s (logic): %s ant variklio %s. Nustatymai (pvz. wastegate) - Tuning meniu.', L(S.forcedInductionKind(fi)), partName, enginePart), 8)
  end
end

S.removeForcedInduction = function(target)
  if target then respawnWithConfig(target, function(cfg) cfg.partAttacherExp.fiSwap = nil end) end
end

-- at load time, into the car's engine part: the donor section(s) and tuning variables
S.injectForcedInduction = function(part, fi)
  if type(part) ~= 'table' or type(fi) ~= 'table' then return end
  if type(fi.turbocharger) == 'table' then part.upa_turbocharger = deepcopy(fi.turbocharger) end
  if type(fi.supercharger) == 'table' then part.upa_supercharger = deepcopy(fi.supercharger) end
  if type(fi.variables) == 'table' and #fi.variables > 0 then
    if type(part.variables) ~= 'table' then
      part.variables = {{'name', 'type', 'unit', 'category', 'default', 'min', 'max', 'title', 'description'}}
    end
    local have = {}
    for _, row in ipairs(part.variables) do
      if type(row) == 'table' and type(row[1]) == 'string' then have[row[1]] = true end
    end
    for _, row in ipairs(fi.variables) do
      if type(row) == 'table' and type(row[1]) == 'string' and not have[row[1]] then table.insert(part.variables, deepcopy(row)) end
    end
  end
end

--------------------------------------------------------------------------------
-- mirror: a copy of a part on the other side of the car. Cars are symmetric about x = 0 in their
-- jbeam frame, so the mirror M flips x: the copy gets move' = M move, pivot' = M pivot and the
-- rotation M R M (x rotation the same, y and z negated). The part itself becomes its left / right
-- counterpart (door_FL -> door_FR, mirror_L -> mirror_R...); a part without one is placed mirrored
-- as it is (good for parts that are symmetric themselves).
--------------------------------------------------------------------------------

-- the donor's other-side part: one name token (between "_") swapped L <-> R, FL <-> FR...
S.counterpartName = function(model, partName)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not okCtx or not ioCtx or type(partName) ~= 'string' then return nil end
  local pairsLR = {FL = 'FR', FR = 'FL', RL = 'RR', RR = 'RL', L = 'R', R = 'L', fl = 'fr', fr = 'fl', rl = 'rr', rr = 'rl',
    l = 'r', r = 'l', Left = 'Right', Right = 'Left', left = 'right', right = 'left', LEFT = 'RIGHT', RIGHT = 'LEFT'}
  local tokens = {}
  for t in (partName .. '_'):gmatch('([^_]*)_') do tokens[#tokens + 1] = t end
  for i = #tokens, 1, -1 do
    local other = pairsLR[tokens[i]]
    if other then
      local cand = {}
      for j, t in ipairs(tokens) do cand[j] = j == i and other or t end
      local name = table.concat(cand, '_')
      if jbeamIO.getPart(ioCtx, name) then return name end
    end
  end
  return nil
end

-- preview of the mirrored copy of a part placed with move / rot / pivot (tables of 3), same scale
S.spawnMirror = function(target, model, partName, move, rot, pivot, meshOnly, scale)
  if not target then msg('Isek i masina.', 5) return end
  move, rot = move or {0, 0, 0}, rot or {0, 0, 0}
  local counterpart = S.counterpartName(model, partName)
  local part = counterpart or partName
  local preset = {rot = {rot[1], -rot[2], -rot[3]}, scale = pivot and tonumber(scale) or nil}
  local meshNodes = meshOnly and S.meshNodesFor(model, part) or nil
  if counterpart then
    preset.move = {-move[1], move[2], move[3]}
    if pivot then preset.pivot = {-pivot[1], pivot[2], pivot[3]} end
  else
    -- the same part: its middle goes to the mirrored spot of where its middle is now
    local c0
    if meshNodes and #meshNodes > 0 then
      c0 = vec3()
      for _, n in ipairs(meshNodes) do c0 = c0 + vec3(n[2], n[3], n[4]) end
      c0 = c0 / #meshNodes
    else
      c0 = rawNodeCentroid(model, part) or vec3()
    end
    local pv = pivot and vec3(pivot[1], pivot[2], pivot[3]) or c0
    c0 = pv + (c0 - pv) * (preset.scale or 1) -- the middle of the scaled part
    local mv = vec3(move[1], move[2], move[3])
    local center = eulerToQuat(rot[1], rot[2], rot[3]) * (c0 - pv) + pv + mv
    local target2 = vec3(-center.x, center.y, center.z)
    local newMove = target2 - (eulerToQuat(preset.rot[1], preset.rot[2], preset.rot[3]) * (c0 - pv) + pv)
    preset.move = {newMove.x, newMove.y, newMove.z}
    preset.pivot = {pv.x, pv.y, pv.z}
  end
  if meshOnly then
    if not meshNodes or #meshNodes == 0 then msg('Si detale neturi modelio (tik duomenys) - nera ka parodyti.', 6) return end
    preset.mode, preset.meshNodes = 'meshonly', meshNodes
  end
  spawnGhost(model, part, target, preset)
  msg(counterpart and string.format('Veidrodine kopija: %s -> %s. Pastumdyk, jei reikia, ir PRITVIRTINK.', partName, counterpart)
    or string.format('Veidrodine kopija: %s (kitos puses detales nera - ta pati, pastatyta veidrodiskai). PRITVIRTINK.', partName), 8)
end

--------------------------------------------------------------------------------
-- auto position: a new part goes where the car's own part of the same kind sits (a bumper on the
-- car's bumper, a hood on its hood): the slots are matched by type without the model prefix
-- (pickup_bumper_F ~ etk800_bumper_F), the part centres are lined up
--------------------------------------------------------------------------------

S.autoFitMove = function(target, model, partName, meshNodes)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  local donorPart = okCtx and jbeamIO.getPart(ioCtx, partName)
  if type(donorPart) ~= 'table' or type(donorPart.slotType) ~= 'string' or donorPart.slotType == 'main' then return nil end
  local function keys(s)
    s = tostring(s):lower()
    return s, (s:gsub('^[^_]+_', ''))
  end
  local d1, d2 = keys(donorPart.slotType)
  local d = core_vehicle_manager.getVehicleData(target:getID())
  local carCtx = vehicleIoCtx(target:getID())
  if not (d and d.config and carCtx) then return nil end
  local found
  local function walk(node)
    if found or type(node) ~= 'table' then return end
    for slotName, child in pairs(node.children or {}) do
      if found then return end
      local chosen = type(child) == 'table' and child.chosenPartName
      if type(chosen) == 'string' and chosen ~= '' then
        local carPart = jbeamIO.getPart(carCtx, chosen)
        local c1, c2 = keys(type(carPart) == 'table' and carPart.slotType or slotName)
        local s1, s2 = keys(slotName)
        if (c1 == d1 or c2 == d2 or s1 == d1 or s2 == d2) and partNodeCentroid(carPart) then
          found = {name = chosen, center = partNodeCentroid(carPart)}
        end
      end
      walk(child)
    end
  end
  walk(d.config.partsTree)
  if not found then return nil end
  local dc
  if meshNodes and #meshNodes > 0 then
    dc = vec3()
    for _, n in ipairs(meshNodes) do dc = dc + vec3(n[2], n[3], n[4]) end
    dc = dc / #meshNodes
  else
    dc = rawNodeCentroid(model, partName)
  end
  if not dc then return nil end
  local mv = found.center - dc
  return {mv.x, mv.y, mv.z}, found.name
end

-- why a part can only come as its model: 'radiator' (mostly data), 'nomesh' (its mesh hangs on its
-- own car's body, it has no points of its own for it); nil when it can have physics
S.meshOnlyReason = function(model, partName)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  local part = okCtx and jbeamIO.getPart(ioCtx, partName)
  if type(part) ~= 'table' then return nil end
  if S.radiatorData(part) then return 'radiator' end
  local ownGroups, nodes = {}, 0
  local group
  for _, row in ipairs(type(part.nodes) == 'table' and part.nodes or {}) do
    if type(row) == 'table' then
      if row[1] == nil and row.group ~= nil then group = row.group end
      if type(row[1]) == 'string' and type(row[2]) == 'number' then
        nodes = nodes + 1
        local g = type(row[5]) == 'table' and row[5].group or group
        for _, s in ipairs(type(g) == 'table' and g or {g}) do if type(s) == 'string' then ownGroups[s] = true end end
      end
    end
  end
  local meshOwn, meshes = false, 0
  for _, row in ipairs(type(part.flexbodies) == 'table' and part.flexbodies or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and row[1] ~= 'mesh' and type(row[2]) == 'table' then
      meshes = meshes + 1
      for _, g in ipairs(row[2]) do if ownGroups[g] then meshOwn = true end end
    end
  end
  if meshes > 0 and (nodes == 0 or not meshOwn) then return 'nomesh' end
  -- the loaded part's slots come as a list of slot tables (no header row)
  local slots = 0
  for _, s in ipairs(part.slots2 or part.slots or {}) do
    if type(s) == 'table' then slots = slots + 1 end
  end
  if nodes == 0 and meshes == 0 and slots == 0 then
    -- nothing to see or hold (a truck's air compressor: a powertrain device and its data only):
    -- 'data' goes straight onto the car, 'empty' has nothing that would do anything there
    local data = type(part.powertrain) == 'table' or type(part.energyStorage) == 'table' or type(part.controller) == 'table'
    return data and 'data' or 'empty'
  end
  return nil
end

-- the coupler tags of a part and of its default sub parts: a fifth wheel's "fifthwheel_v2", a
-- pintle hitch's "pintle", a tow hitch's "tow_hitch"
S.partCouplerTags = function(model, partName)
  local list, seen, visited = {}, {}, {}
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not okCtx then return list end
  local function walk(name, depth)
    if depth > 6 or type(name) ~= 'string' or name == '' or visited[name] then return end
    visited[name] = true
    local okP, part = pcall(origGetPart, ioCtx, name)
    if not okP or type(part) ~= 'table' then return end
    for _, row in ipairs(type(part.nodes) == 'table' and part.nodes or {}) do
      -- a node's own options, or a modifier row for the nodes below it
      local opt = type(row) == 'table' and (row[1] == nil and row or type(row[5]) == 'table' and row[5]) or nil
      local tag = type(opt) == 'table' and opt.couplerTag
      if type(tag) == 'string' and tag ~= '' and not seen[tag] then
        seen[tag] = true
        list[#list + 1] = tag
      end
    end
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      if type(s) == 'table' then walk(s.default, depth + 1) end
    end
  end
  walk(partName, 0)
  return list
end

-- a part with nothing physical of its own (S.meshOnlyReason 'data') has no preview to place: it goes
-- straight onto the car as an added part, its devices on the car's engine (S.connectExtraDevices)
S.installDataPart = function(target, model, partName)
  local extras = deepcopy(getExtras(target:getID()))
  for _, ex in ipairs(extras) do
    if ex.dataOnly and ex.model == model and ex.part == partName then
      msg(string.format('%s jau idiegta.', tostring(partName)), 5)
      return
    end
  end
  extras[#extras + 1] = {model = model, part = partName, dataOnly = true}
  if respawnWithExtras(target, extras) then
    msg(string.format('%s: idiegta iskart (tik duomenys, be modelio - nera ka stumdyti).', tostring(partName)), 6)
  end
end

S.meshOnlyMessage = function(reason, partName)
  if reason == 'radiator' then
    return 'Radiatorius: rodomas tik jo modelis (be fizikos). Kad ausintu, rinkis ji aplanke ">> RADIATORIUS (ausinimas, logic)".'
  end
  if reason == 'data' or reason == 'empty' then return 'Si detale neturi modelio (tik duomenys) - nera ka parodyti.' end
  return string.format('Detale %s neturi savo modelio tasku (modelis kabo ant savo masinos kebulo) - atsiras tik jos modelis, be fizikos.', partName)
end

-- an installed part switched between "model only" and physics (on its virtual mount), in place
S.setExtraPhysics = function(target, index, physics)
  local extras = deepcopy(getExtras(target:getID()))
  local ex = extras[index]
  if not ex then return end
  if physics then
    local reason = S.meshOnlyReason(ex.model, ex.part)
    if reason then msg(S.meshOnlyMessage(reason, ex.part), 8) return end
    ex.meshOnly, ex.meshNodes = nil, nil
  else
    local nodes = S.meshNodesFor(ex.model, ex.part)
    if #nodes == 0 then msg('Si detale neturi modelio (tik duomenys) - nera ka parodyti.', 6) return end
    ex.meshOnly, ex.meshNodes = true, nodes
  end
  if respawnWithExtras(target, extras) then
    msg(physics and string.format('%s: dabar su fizika (virtualus tvirtinimas).', tostring(ex.part))
      or string.format('%s: dabar tik modelis (be fizikos).', tostring(ex.part)), 5)
  end
end

--------------------------------------------------------------------------------
-- front end swap (section 8): another car's whole front - bumper, fenders, hood, lights, grille -
-- as one preview, placed and sized like any part, installed as one part on one virtual mount
--------------------------------------------------------------------------------

-- a front end part by its slot / name (bumper_F is the front bumper, bumper_R the rear one; fender_R
-- is the right fender). Doors, mirrors, suspension and engine parts are never front end parts.
S.frontWords = {'bumper_f', 'bumperbar_f', 'bumper_front', 'front_bumper', 'fender', 'hood', 'bonnet',
  'headlight', 'grille', 'grill', 'foglight', 'fog_light', 'splitter', 'front_lip', 'lip_f', 'nose',
  'radsupport', 'radiator_support', 'license_plate_f', 'licenseplate_f', 'fascia_f', 'front_fascia'}
S.notFrontWords = {'rear', 'bumper_r', 'bumperbar_r', 'fender_rl', 'fender_rr', 'engine', 'suspension', 'steer',
  'brake', 'hub', 'wheel', 'tire', 'axle', 'coilover', 'shock', 'strut', 'sway', 'door', 'seat', 'interior',
  'dash', 'mirror', 'trunk', 'tailgate', 'radiator_', 'turbo', 'intercooler', 'intake', 'exhaust'}

S.isFrontPart = function(slotName, partName)
  local s = (tostring(slotName) .. ' ' .. tostring(partName)):lower()
  for _, w in ipairs(S.notFrontWords) do
    if s:find(w, 1, true) then return false end
  end
  for _, w in ipairs(S.frontWords) do
    if s:find(w, 1, true) then return true end
  end
  return false
end

S.slotOffset = function(s)
  local function num(v) return tonumber(v) or 0 end
  local o = type(s.nodeOffset) == 'table' and s.nodeOffset or {}
  local m = type(s.nodeMove) == 'table' and s.nodeMove or {}
  return num(o.x) + num(m.x), num(o.y) + num(m.y), num(o.z) + num(m.z)
end

-- the donor's front end parts in its default part tree: {name, slot, desc, offset (the move its
-- slots there add up to)}; below a front end part nothing more is picked (its sub parts come with it)
S.findFrontParts = function(model)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not okCtx then return {} end
  local okMain, main = pcall(jbeamIO.getMainPartName, ioCtx)
  if not okMain or type(main) ~= 'string' then return {} end
  local found, visited = {}, {}
  local function walk(name, depth, ox, oy, oz)
    if depth > 8 or visited[name] then return end
    visited[name] = true
    local okP, part = pcall(origGetPart, ioCtx, name)
    if not okP or type(part) ~= 'table' then return end
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      local child = type(s) == 'table' and s.default
      if type(child) == 'string' and child ~= '' then
        local dx, dy, dz = S.slotOffset(s)
        if S.isFrontPart(s.name, child) then
          local desc = type(s.description) == 'string' and s.description ~= '' and s.description or tostring(s.name)
          found[#found + 1] = {name = child, slot = s.name, desc = desc, offset = {ox + dx, oy + dy, oz + dz}}
        else
          walk(child, depth + 1, ox + dx, oy + dy, oz + dz)
        end
      end
    end
  end
  walk(main, 0, 0, 0, 0)
  return found
end

-- the box around those parts and their default sub parts, as they sit on the donor
S.donorFrontBounds = function(model, parts)
  local okCtx, ioCtx = pcall(jbeamIO.startLoading, modelDirs(model))
  if not okCtx then return nil end
  local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  local count, visited = 0, {}
  local function walk(name, depth, ox, oy, oz)
    if depth > 6 or visited[name] then return end
    visited[name] = true
    local okP, part = pcall(origGetPart, ioCtx, name)
    if not okP or type(part) ~= 'table' then return end
    for _, row in ipairs(type(part.nodes) == 'table' and part.nodes or {}) do
      if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'number' then
        local x, y, z = row[2] + ox, (tonumber(row[3]) or 0) + oy, (tonumber(row[4]) or 0) + oz
        lo:set(math.min(lo.x, x), math.min(lo.y, y), math.min(lo.z, z))
        hi:set(math.max(hi.x, x), math.max(hi.y, y), math.max(hi.z, z))
        count = count + 1
      end
    end
    for _, s in ipairs(part.slots2 or part.slots or {}) do
      if type(s) == 'table' and type(s.default) == 'string' and s.default ~= '' then
        local dx, dy, dz = S.slotOffset(s)
        walk(s.default, depth + 1, ox + dx, oy + dy, oz + dz)
      end
    end
  end
  for _, p in ipairs(parts) do
    local o = p.offset or {}
    walk(p.name, 0, o[1] or 0, o[2] or 0, o[3] or 0)
  end
  if count == 0 then return nil end
  return lo, hi
end

-- the car's own front end parts in its parts tree: {path = slot names from the root, part}
S.targetFrontParts = function(target)
  local d = core_vehicle_manager.getVehicleData(target:getID())
  local tree = d and d.config and d.config.partsTree
  local list = {}
  local function walk(node, path, depth)
    if depth > 10 or type(node) ~= 'table' or type(node.children) ~= 'table' then return end
    for slot, child in pairs(node.children) do
      if type(slot) == 'string' and type(child) == 'table' and slot:sub(1, #extraSlotPrefix) ~= extraSlotPrefix then
        local part = child.chosenPartName
        local p = {}
        for i, v in ipairs(path) do p[i] = v end
        p[#p + 1] = slot
        if type(part) == 'string' and part ~= '' then
          if S.isFrontPart(slot, part) then list[#list + 1] = {path = p, part = part} else walk(child, p, depth + 1) end
        end
      end
    end
  end
  walk(tree, {}, 0)
  return list
end

-- the box around the car's front end (its own front parts' nodes; without those, its front 60 cm)
S.targetFrontBounds = function(target)
  local vd = getVData(target:getID())
  if not (vd and vd.nodes) then return nil end
  local names = {}
  for _, f in ipairs(S.targetFrontParts(target)) do names[f.part] = true end
  local n = target:getNodeCount()
  local function box(pick)
    local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
    local count = 0
    for cid = 0, n - 1 do
      local nd = vd.nodes[cid]
      if type(nd) == 'table' and not isWheelNode(vd, cid) and pick(nd, cid) then
        local p = vec3(target:getInitialNodePosition(cid))
        lo:set(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z))
        hi:set(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z))
        count = count + 1
      end
    end
    if count == 0 then return nil end
    return lo, hi
  end
  local lo, hi = box(function(nd) return names[nd.partOrigin] == true end)
  if lo then return lo, hi end
  local own = function(nd) return not (type(nd.name) == 'string' and (nd.name:find('^upa%d+_') or nd.name:find('^ups%w+_'))) end
  local allLo = box(own)
  if not allLo then return nil end
  return box(function(nd, cid) return own(nd) and target:getInitialNodePosition(cid).y < allLo.y + 0.6 end)
end

-- the made-up front end part's name for a donor
S.frontEndName = function(model) return 'upa_frontend_' .. tostring(model) end

-- the preview: centred on the car, its front at the car's front, its bottom at the car's front
-- bottom, and (autoScale) as wide as the car's own front end
S.spawnFrontEnd = function(target, model, parts, removeOwn, autoScale)
  if #parts == 0 then msg('Pasirink bent viena priekio detale.', 5) return end
  local spec = {parts = {}, removeOwn = removeOwn or nil}
  for _, p in ipairs(parts) do spec.parts[#spec.parts + 1] = {name = p.name, offset = p.offset} end
  local preset = {mode = 'part', frontEnd = spec, rot = {0, 0, 0}, move = {0, 0, 0}}
  local dLo, dHi = S.donorFrontBounds(model, parts)
  local tLo, tHi = S.targetFrontBounds(target)
  if dLo then
    local c = (dLo + dHi) * 0.5
    preset.pivot = {c.x, c.y, c.z}
    if tLo then
      local s = 1
      local dw, tw = dHi.x - dLo.x, tHi.x - tLo.x
      if autoScale and dw > 0.2 and tw > 0.2 then s = math.max(0.6, math.min(1.6, tw / dw)) end
      preset.scale = s
      preset.move = {(tLo.x + tHi.x) * 0.5 - c.x, tLo.y - (c.y + (dLo.y - c.y) * s), tLo.z - (c.z + (dLo.z - c.z) * s)}
    end
  end
  spawnGhost(model, S.frontEndName(model), target, preset)
  msg(string.format('Priekis is %s: %d detales. Detale korteleje pastumdyk, pakeisk dydi ir spausk PRITVIRTINTI.', tostring(model), #parts), 8)
end

-- set the chosen parts at those tree paths (nil: back to each one's own part, '' empties the slot)
S.setTreeParts = function(cfg, list, value)
  for _, f in ipairs(list or {}) do
    local node = cfg.partsTree
    for _, slot in ipairs(f.path or {}) do
      node = type(node) == 'table' and type(node.children) == 'table' and node.children[slot] or nil
    end
    if type(node) == 'table' then
      node.chosenPartName = value or f.part
      node.children = nil
    end
    local last = f.path and f.path[#f.path]
    if last and type(cfg.parts) == 'table' and cfg.parts[last] ~= nil then cfg.parts[last] = value or f.part end
  end
end

local function spawnSelectedPart()
  local target = getPlayerVehicle(0)
  if not target then msg('Pirma isek i masina, ant kurios desi detale.') return end
  if not S.selectedModel or not S.selectedPartName then msg('Pasirink detale sarase.') return end
  if S.selectedIsEngine == 'radiator' then return S.applyRadiator(target, S.selectedModel, S.selectedPartName) end
  if S.selectedIsEngine == 'fi' then return S.applyForcedInduction(target, S.selectedModel, S.selectedPartName) end
  if not S.selectedIsEngine then
    -- a part that is mostly data (radiator...) or whose mesh hangs on its own car's body would be
    -- invisible on its own: it comes as its model only, as with the "Tik modelis" checkbox
    local meshOnly = S.meshOnlyPtr[0]
    local reason = S.meshOnlyReason(S.selectedModel, S.selectedPartName)
    if reason == 'data' then return S.installDataPart(target, S.selectedModel, S.selectedPartName) end
    if reason == 'empty' then msg(S.meshOnlyMessage(reason, S.selectedPartName), 6) return end
    if reason and not meshOnly then
      meshOnly = true
      msg(S.meshOnlyMessage(reason, S.selectedPartName), 8)
    elseif meshOnly and not reason then
      -- a hitch without physics has no coupler point: tell before it's placed
      local okT, tags = pcall(S.partCouplerTags, S.selectedModel, S.selectedPartName)
      if okT and #tags > 0 then
        msg(string.format('%s yra kablys (%s): jis veikia tik su fizika - 2 dalyje spausk "Su fizika".', tostring(S.selectedPartName), table.concat(tags, ', ')), 10)
      end
    end
    local preset
    if meshOnly then
      local meshNodes = S.meshNodesFor(S.selectedModel, S.selectedPartName)
      if #meshNodes == 0 then msg('Si detale neturi modelio (tik duomenys) - nera ka parodyti.', 6) return end
      preset = {mode = 'meshonly', meshNodes = meshNodes}
    end
    -- auto position: where the car's own part of the same kind is
    if S.autoFitPtr[0] then
      local okFit, move, carPart = pcall(S.autoFitMove, target, S.selectedModel, S.selectedPartName, preset and preset.meshNodes)
      if okFit and move then
        preset = preset or {}
        preset.move, preset.rot, preset.auto = move, {0, 0, 0}, true
        msg(string.format('Pastatyta ten, kur tavo masinos %s.', tostring(carPart)), 5)
      end
    end
    return spawnGhost(S.selectedModel, S.selectedPartName, target, preset)
  end
  if swapKinds[S.selectedIsEngine] then
    spawnPartSwapGhost(S.selectedModel, S.selectedPartName, target, S.selectedIsEngine)
  elseif S.selectedIsEngine == 'gearbox' then
    spawnGearboxGhost(S.selectedModel, S.selectedPartName, target)
  elseif S.selectedIsEngine then
    spawnEngineGhost(S.selectedModel, S.selectedPartName, target)
  else
    spawnGhost(S.selectedModel, S.selectedPartName, target, nil)
  end
end

-- the preview built again where it is now: at the size of its slider (scale), and model only or
-- with physics (meshOnly true / false; nil keeps its mode)
S.respawnGhost = function(e, meshOnly)
  local target = getVeh(e.targetId)
  if not target or not e.pivot then return end
  local preset = {
    move = {e.off[1][0], e.off[2][0], e.off[3][0]},
    rot = {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
    pivot = {e.pivot.x, e.pivot.y, e.pivot.z},
    scale = math.max(0.05, e.scale[0]),
  }
  if meshOnly == nil then meshOnly = e.mode == 'meshonly' end
  if e.frontEnd then
    -- a front end is never a model only part
    preset.frontEnd = e.frontEnd
    meshOnly = false
  end
  if meshOnly then
    local nodes = e.mode == 'meshonly' and e.meshNodes or S.meshNodesFor(e.model, e.partName)
    if not nodes or #nodes == 0 then msg('Si detale neturi modelio (tik duomenys) - nera ka parodyti.', 6) return end
    preset.mode, preset.meshNodes = 'meshonly', nodes
  elseif not e.frontEnd then
    local reason = S.meshOnlyReason(e.model, e.partName)
    if reason then msg(S.meshOnlyMessage(reason, e.partName), 8) return end
  end
  deleteEntry(e)
  spawnGhost(e.model, e.partName, target, preset)
end
S.rescaleGhost = function(e) S.respawnGhost(e, nil) end

-- take an installed part off the car again and turn it back into a movable ghost
local function editExtra(target, index)
  local ex = getExtras(target:getID())[index]
  if not ex then return end
  local preset = deepcopy(ex)
  if ex.meshOnly then preset.mode = 'meshonly' end
  removeExtra(target, index)
  spawnGhost(ex.model, ex.part, target, preset)
end

local function removeSwap(target)
  local swap = getSwap(target:getID())
  if swap then respawnWithSwap(target, nil, swap.replaces) end
end

local function removeGearboxSwap(target)
  local spec = getPA(target:getID()).gearboxSwap
  if type(spec) == 'table' then respawnWithGearboxSwap(target, nil, spec.replaces) end
end

local function editGearboxSwap(target)
  local spec = getPA(target:getID()).gearboxSwap
  if type(spec) ~= 'table' then return end
  local preset = deepcopy(spec)
  preset.mode = 'gearbox'
  removeGearboxSwap(target)
  spawnGhost(spec.model, spec.part, target, preset)
end

local function setDrivetrain(target, spec)
  respawnWithConfig(target, function(cfg) cfg.partAttacherExp.drivetrain = spec end)
end

-- logic suspension: respawn the car with the sliders (and donor characters) of both axles
local function applySuspTune(target)
  local id = target:getID()
  local spec = {}
  for axle, kind in pairs({F = 'susp_F', R = 'susp_R'}) do
    local ui = suspUI[axle]
    local part = getTargetSuspension(id, kind)
    local changed = ui.donor or ui.lift[0] ~= 0 or ui.spring[0] ~= 1 or ui.damp[0] ~= 1 or ui.sway[0] ~= 1
    if part and changed then
      spec[axle] = {
        part = part,
        lift = ui.lift[0] / 100, -- the slider is in cm
        springMul = ui.spring[0], dampMul = ui.damp[0], swayMul = ui.sway[0],
        donor = ui.donor and deepcopy(ui.donor) or nil,
      }
    end
  end
  if next(spec) == nil then spec = nil end
  if respawnWithConfig(target, function(cfg) cfg.partAttacherExp.suspTune = spec end) then
    msg(spec and 'Pakabos nustatymai pritaikyti (logic).' or 'Pakaba grazinta i originalia.', 4)
  end
end

-- take the character (spring / damper / sway bar rates) of the suspension picked in the list
local function takeDonorCharacter(target, kind, model, partName)
  local rates = donorSuspensionRates(model, partName)
  if not rates or not (rates.spring or rates.damp or rates.sway) then
    msg('Nepavyko nuskaityti sios pakabos spyruokliu / amortizatoriu.', 6)
    return
  end
  local axle = kind == 'susp_F' and 'F' or 'R'
  suspUI[axle].donor = rates
  msg(string.format('%s charakteris: spyruokles %s N/m, slopinimas %s, stabilizatorius %s',
    partName, rates.spring and string.format('%.0f', rates.spring) or '-', rates.damp and string.format('%.0f', rates.damp) or '-',
    rates.sway and string.format('%.0f', rates.sway) or '-'), 8)
  applySuspTune(target)
end

-- final drive the car has now: product of gear ratios from the gearbox output down to a wheel
local function readFinalDrive(vehId)
  local vd = getVData(vehId)
  local pt = vd and vd.powertrain
  if type(pt) ~= 'table' then return nil end
  local byName, children = {}, {}
  for _, d in pairs(pt) do
    if type(d) == 'table' and type(d.name) == 'string' then byName[d.name] = d end
  end
  for _, d in pairs(byName) do
    if type(d.inputName) == 'string' then
      children[d.inputName] = children[d.inputName] or {}
      table.insert(children[d.inputName], d)
    end
  end
  local gearbox
  for _, d in pairs(byName) do
    if type(d.type) == 'string' and d.type:find('Gearbox$') then gearbox = d break end
  end
  if not gearbox then return nil end
  local function rec(d, ratio, depth)
    if depth > 20 then return nil end
    if d.connectedWheel then return ratio end
    for _, c in ipairs(children[d.name] or {}) do
      local r = rec(c, ratio * (tonumber(c.gearRatio) or 1), depth + 1)
      if r then return r end
    end
  end
  return rec(gearbox, 1, 0)
end

-- redo an engine swap made before version 2 with unique names, mount points and no self collision
local function upgradeEngineSwap(target)
  local swap = getSwap(target:getID())
  if not swap then return end
  local spec = deepcopy(swap)
  prepareEngineBundle(target, spec)
  if respawnWithSwap(target, spec, spec.replaces) then
    msg(string.format('Variklio swap pataisytas: %d tasku prisegta, %d atsinesta.', tableSize(spec.snapMap or {}), #(spec.importNodes or {})), 6)
  end
end

-- put the original engine back and turn the swapped one into a ghost again
local function editSwap(target)
  local swap = getSwap(target:getID())
  if not swap then return end
  local preset = deepcopy(swap)
  preset.mode = 'engine'
  removeSwap(target)
  spawnGhost(swap.model, swap.part, target, preset)
end

deleteEntry = function(e)
  entries[e.id] = nil
  if selectedEntryId == e.id then selectedEntryId = nil end
  local ghost = getVeh(e.id)
  if ghost then ghost:delete() end
end

--------------------------------------------------------------------------------
-- part / model lists
--------------------------------------------------------------------------------

-- what a model is, by the Type of its info.json: driven vehicles (Car, Truck, Heavy Machinery and any
-- type a mod brings: bus, motorcycle...) go straight in the list, trailers and static objects (props,
-- traffic dummies, test rigs, the walking unicycle) into folders of their own
S.modelGroups = {{id = 'trailer', label = 'Priekabos'}, {id = 'static', label = 'Statiniai objektai (props)'}}
S.staticModelTypes = {prop = true, traffic = true, debug = true, proptraffic = true, propparked = true}
S.modelGroupOf = function(m)
  local t = tostring(m.Type or ''):lower()
  if t == 'trailer' then return 'trailer' end
  if S.staticModelTypes[t] or m.key == 'unicycle' then return 'static' end
  return 'drive'
end

local function loadModelList()
  S.modelList = {}
  local ok, res = pcall(core_vehicles.getModelList, true)
  if ok and res and res.models then
    for _, m in ipairs(res.models) do
      if m.key then
        local label = ((m.Brand and m.Brand ~= '') and (m.Brand .. ' ') or '') .. (m.Name or m.key)
        table.insert(S.modelList, {key = m.key, label = label .. '  [' .. m.key .. ']', group = S.modelGroupOf(m)})
      end
    end
  end
  table.sort(S.modelList, function(a, b) return a.label:lower() < b.label:lower() end)
end

local function sortByLabel(list)
  table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
end

-- builds S.partList (flat, for search) and S.partCategories / S.otherCategories (folders by slot)
local function loadPartList(model)
  S.partIoCtx, S.partMain, S.partEntries, S.slotCache, S.treeChoice = nil, nil, {}, {}, {}
  S.partList, S.partCategories, S.otherCategories, S.engineList, S.gearboxList = {}, {}, {}, {}, {}
  S.suspLists = {susp_F = {}, susp_R = {}}
  S.partListModel = model
  S.selectedPartName = nil
  S.selectedIsEngine = nil
  local dirs = modelDirs(model)
  local ok, res = pcall(function()
    local ioCtx = jbeamIO.startLoading(dirs)
    return {jbeamIO.getAvailableParts(ioCtx), jbeamIO.getAvailableSlotNameMap(ioCtx), ioCtx}
  end)
  if not ok or type(res) ~= 'table' or type(res[1]) ~= 'table' then
    log('E', logTag, 'unable to list parts of ' .. tostring(model) .. ': ' .. tostring(res))
    return
  end
  local parts, slotMap, ioCtx = res[1], res[2] or {}, res[3]
  -- for the slot tree (like the game's Parts menu): the model's parts by slot, from its main part down
  S.partIoCtx, S.partSlotMap, S.slotCache, S.treeChoice = ioCtx, slotMap, {}, {}
  local okMain, mainName = pcall(jbeamIO.getMainPartName, ioCtx)
  S.partMain = okMain and mainName or nil

  -- slot type -> readable name ("Front Bumper"), from the slots the parts offer
  local slotDesc = {}
  for _, desc in pairs(parts) do
    if type(desc) == 'table' and type(desc.slotInfoUi) == 'table' then
      for slotName, s in pairs(desc.slotInfoUi) do
        if type(s) == 'table' then
          local d = type(s.description) == 'string' and s.description ~= '' and s.description or nil
          local types = type(s.allowTypes) == 'table' and s.allowTypes or {s.type or slotName}
          for _, t in ipairs(types) do
            if type(t) == 'string' and (not slotDesc[t] or slotDesc[t] == t) then slotDesc[t] = d or t end
          end
        end
      end
    end
  end

  local partEntries = {}
  for name, desc in pairs(parts) do
    local d = type(desc) == 'table' and type(desc.description) == 'string' and desc.description or ''
    local label = (d ~= '' and d ~= name) and (d .. '  (' .. name .. ')') or name
    local p = {name = name, label = label, lower = label:lower()}
    partEntries[name] = p
    table.insert(S.partList, p)
  end
  sortByLabel(S.partList)
  S.partEntries = partEntries

  -- folders: slots this model offers on top (merged by readable name), the rest under "Kita"
  local byLabel, byOther = {}, {}
  for slotType, names in pairs(slotMap) do
    local folder
    if slotType == 'main' then
      folder = byLabel['Kebulas (main)'] or {label = 'Kebulas (main)', parts = {}}
      byLabel[folder.label] = folder
    elseif slotDesc[slotType] then
      local label = slotDesc[slotType]
      folder = byLabel[label] or {label = label, parts = {}}
      byLabel[label] = folder
    else
      folder = byOther[slotType] or {label = slotType, parts = {}}
      byOther[slotType] = folder
    end
    for _, name in ipairs(names) do
      if partEntries[name] then table.insert(folder.parts, partEntries[name]) end
    end
  end
  for _, f in pairs(byLabel) do
    if #f.parts > 0 then sortByLabel(f.parts) table.insert(S.partCategories, f) end
  end
  for _, f in pairs(byOther) do
    if #f.parts > 0 then sortByLabel(f.parts) table.insert(S.otherCategories, f) end
  end
  sortByLabel(S.partCategories)
  sortByLabel(S.otherCategories)

  -- engine swap folder: real combustion engines that fit this model's engine slot
  for slotType, names in pairs(slotMap) do
    if slotDesc[slotType] and type(slotType) == 'string' and slotType:lower():find('engine', 1, true) then
      for _, name in ipairs(names) do
        local okPart, part = pcall(jbeamIO.getPart, ioCtx, name)
        if okPart and isEnginePart(part) then
          local info = engineInfo(part) or {}
          local base = partEntries[name] and partEntries[name].label or name
          local extra = (info.kw and info.kw > 0) and string.format('   ~%d kW', math.floor(info.kw + 0.5)) or ''
          if info.maxRPM then extra = extra .. string.format(', %d rpm', math.floor(info.maxRPM)) end
          if type(info.fuel) == 'string' then extra = extra .. ', ' .. info.fuel end
          table.insert(S.engineList, {name = name, label = base .. extra})
        end
      end
    end
  end
  sortByLabel(S.engineList)

  -- gearbox swap folder: parts with a gearbox device in the slots this model offers
  for slotType, names in pairs(slotMap) do
    if slotDesc[slotType] and type(slotType) == 'string' and isTransmissionSlot({name = slotType}) then
      for _, name in ipairs(names) do
        local okPart, part = pcall(jbeamIO.getPart, ioCtx, name)
        if okPart and isGearboxPart(part) then
          local kind = ''
          for _, row in ipairs(part.powertrain) do
            if type(row) == 'table' and type(row[1]) == 'string' and row[1]:find('Gearbox$') then kind = row[1]:gsub('Gearbox$', '') end
          end
          local base = partEntries[name] and partEntries[name].label or name
          table.insert(S.gearboxList, {name = name, label = base .. '   [' .. kind .. ']'})
        end
      end
    end
  end
  sortByLabel(S.gearboxList)

  -- suspension swap folders: front / rear by where the part's nodes sit
  for slotType, names in pairs(slotMap) do
    if slotDesc[slotType] and type(slotType) == 'string' and slotType:lower():find('suspension', 1, true) then
      for _, name in ipairs(names) do
        local okPart, part = pcall(jbeamIO.getPart, ioCtx, name)
        if okPart and isSuspensionPart(part, name) then
          local kind = suspensionKind(part, name)
          local base = partEntries[name] and partEntries[name].label or name
          table.insert(S.suspLists[kind], {name = name, label = base})
        end
      end
    end
  end
  sortByLabel(S.suspLists.susp_F)
  sortByLabel(S.suspLists.susp_R)

  -- turbo / supercharger folder: parts with a forced induction section of their own
  S.fiList = {}
  -- radiator folder: parts with cooling data (radiator area / effectiveness)
  S.radiatorList = {}
  for name, p in pairs(partEntries) do
    local okPart, part = pcall(jbeamIO.getPart, ioCtx, name)
    if okPart and type(part) == 'table' and (type(part.turbocharger) == 'table' or type(part.supercharger) == 'table') then
      local kind = (type(part.turbocharger) == 'table' and type(part.supercharger) == 'table') and 'turbo + supercharger'
        or type(part.turbocharger) == 'table' and 'turbo' or 'supercharger'
      table.insert(S.fiList, {name = name, label = p.label .. '   [' .. kind .. ']'})
    end
    local data = okPart and S.radiatorData(part)
    if data then
      local info = string.format('   [plotas %s, efekt. %s%s]', tostring(data.radiatorArea or '-'), tostring(data.radiatorEffectiveness or '-'),
        data.radiatorFanType and (', ' .. tostring(data.radiatorFanType)) or '')
      table.insert(S.radiatorList, {name = name, label = p.label .. info})
    end
  end
  sortByLabel(S.radiatorList)
  sortByLabel(S.fiList)
end

local function drawPartSelectable(p)
  if im.Selectable1(p.label .. '##' .. p.name, p.name == S.selectedPartName and not S.selectedIsEngine) then
    S.selectedPartName = p.name
    S.selectedIsEngine = false
  end
end

local function drawEngineFolder()
  if S.engineList and #S.engineList > 0 and im.TreeNode1(string.format('>> VARIKLIO SWAP (engine swap)  (%d)##engineswap', #S.engineList)) then
    imText('kW - bazine kreive, turbo / ECU / internals prideda daugiau')
    for _, p in ipairs(S.engineList) do
      if im.Selectable1(p.label .. '##eng' .. p.name, p.name == S.selectedPartName and S.selectedIsEngine == true) then
        S.selectedPartName = p.name
        S.selectedIsEngine = true
      end
    end
    im.TreePop()
  end
  for _, kind in ipairs({'susp_F', 'susp_R'}) do
    local list = S.suspLists and S.suspLists[kind] or {}
    local title = kind == 'susp_F' and '>> PRIEKINE PAKABA (front suspension swap)' or '>> GALINE PAKABA (rear suspension swap)'
    if #list > 0 and im.TreeNode1(string.format('%s  (%d)##%s', title, #list, kind)) then
      for _, p in ipairs(list) do
        if im.Selectable1(p.label .. '##' .. kind .. p.name, p.name == S.selectedPartName and S.selectedIsEngine == kind) then
          S.selectedPartName = p.name
          S.selectedIsEngine = kind
        end
      end
      im.TreePop()
    end
  end
  if S.gearboxList and #S.gearboxList > 0 and im.TreeNode1(string.format('>> PAVARU DEZES SWAP (gearbox swap)  (%d)##gearboxswap', #S.gearboxList)) then
    for _, p in ipairs(S.gearboxList) do
      if im.Selectable1(p.label .. '##gb' .. p.name, p.name == S.selectedPartName and S.selectedIsEngine == 'gearbox') then
        S.selectedPartName = p.name
        S.selectedIsEngine = 'gearbox'
      end
    end
    im.TreePop()
  end
  if S.fiList and #S.fiList > 0 and im.TreeNode1(string.format('>> TURBO / KOMPRESORIUS (logic)  (%d)##forcedinduction', #S.fiList)) then
    imText('Tavo variklis gauna sito turbo / kompresoriaus duomenis ir garsa, nustatymai - Tuning meniu.')
    for _, p in ipairs(S.fiList) do
      if im.Selectable1(p.label .. '##fi' .. p.name, p.name == S.selectedPartName and S.selectedIsEngine == 'fi') then
        S.selectedPartName = p.name
        S.selectedIsEngine = 'fi'
      end
    end
    im.TreePop()
  end
  if S.radiatorList and #S.radiatorList > 0 and im.TreeNode1(string.format('>> RADIATORIUS (ausinimas, logic)  (%d)##radiators', #S.radiatorList)) then
    imText('Tavo radiatorius lieka, varikliui perkeliami sito ausinimo duomenys.')
    for _, p in ipairs(S.radiatorList) do
      if im.Selectable1(p.label .. '##rad' .. p.name, p.name == S.selectedPartName and S.selectedIsEngine == 'radiator') then
        S.selectedPartName = p.name
        S.selectedIsEngine = 'radiator'
      end
    end
    im.TreePop()
  end
end

local function drawFolder(f, idPrefix)
  if im.TreeNode1(string.format('%s  (%d)##%s%s', f.label, #f.parts, idPrefix, f.label)) then
    for _, p in ipairs(f.parts) do drawPartSelectable(p) end
    im.TreePop()
  end
end

-- the slots of a part, as the game's Parts menu lists them: {name, desc, default, options}
S.slotsOf = function(partName)
  if not (S.partIoCtx and type(partName) == 'string') then return {} end
  local cached = S.slotCache[partName]
  if cached then return cached end
  local okPart, part = pcall(jbeamIO.getPart, S.partIoCtx, partName)
  local list = {}
  for _, s in ipairs(okPart and type(part) == 'table' and (part.slots2 or part.slots) or {}) do
    if type(s) == 'table' and type(s.name) == 'string' then
      local deny = {}
      for _, t in ipairs(type(s.denyTypes) == 'table' and s.denyTypes or {}) do deny[t] = true end
      local options, seen = {}, {}
      for _, t in ipairs(type(s.allowTypes) == 'table' and s.allowTypes or {s.type or s.name}) do
        if not deny[t] then
          for _, n in ipairs(S.partSlotMap[t] or {}) do
            if not seen[n] then
              seen[n] = true
              options[#options + 1] = n
            end
          end
        end
      end
      local function label(n) return (S.partEntries[n] and S.partEntries[n].label or n):lower() end
      table.sort(options, function(a, b) return label(a) < label(b) end)
      local desc = type(s.description) == 'string' and s.description ~= '' and s.description or s.name
      list[#list + 1] = {name = s.name, desc = desc, default = s.default, options = options}
    end
  end
  S.slotCache[partName] = list
  return list
end

-- the slot tree from a part down: each slot opens to its options (the default marked *), and below
-- them the slots of the option picked there (or of the default), like the game's Parts menu
S.drawSlotTree = function(partName, path, depth)
  if depth > 12 then return end
  for _, s in ipairs(S.slotsOf(partName)) do
    local p = path .. '/' .. s.name
    local chosen = S.treeChoice[p] or s.default
    local subSlots = type(chosen) == 'string' and chosen ~= '' and S.slotsOf(chosen) or {}
    if #s.options > 0 or #subSlots > 0 then
      if im.TreeNode1(string.format('%s  (%d)##tree%s', s.desc, #s.options, p)) then
        for _, name in ipairs(s.options) do
          local e = S.partEntries[name]
          local text = (e and e.label or name) .. (name == s.default and '  *' or '')
          if im.Selectable1(text .. '##tp' .. p .. '/' .. name, name == S.selectedPartName and not S.selectedIsEngine) then
            S.selectedPartName, S.selectedIsEngine = name, false
            S.treeChoice[p] = name
          end
        end
        if #subSlots > 0 then
          imText(string.format('-- %s detales:', S.partEntries[chosen] and S.partEntries[chosen].label or chosen))
          S.drawSlotTree(chosen, p, depth + 1)
        end
        im.TreePop()
      end
    end
  end
end

local function selectModel(model)
  if model and model ~= S.selectedModel then
    S.selectedModel = model
    loadPartList(model)
  end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function drawSpawnSection(player)
  if player and im.SmallButton('Mano masinos modelis') then selectModel(player.jbeam) end

  -- model picker
  if not S.modelList then loadModelList() end
  local preview = S.selectedModel or 'pasirink modeli...'
  if im.BeginCombo('Modelis', preview) then
    im.InputText('Paieska##models', S.modelSearchPtr, 64)
    local ms = ffi.string(S.modelSearchPtr):lower()
    local function modelRow(m)
      if im.Selectable1(m.label .. '##' .. m.key, m.key == S.selectedModel) then selectModel(m.key) end
    end
    if ms ~= '' then
      -- a search finds every model, wherever it is filed
      for _, m in ipairs(S.modelList) do
        if m.label:lower():find(ms, 1, true) then modelRow(m) end
      end
    else
      -- driven vehicles, then the folders for trailers and static objects
      for _, m in ipairs(S.modelList) do
        if m.group == 'drive' then modelRow(m) end
      end
      for _, g in ipairs(S.modelGroups) do
        local count = 0
        for _, m in ipairs(S.modelList) do
          if m.group == g.id then count = count + 1 end
        end
        if count > 0 and im.TreeNode1(string.format('%s  (%d)##modelgroup_%s', g.label, count, g.id)) then
          for _, m in ipairs(S.modelList) do
            if m.group == g.id then modelRow(m) end
          end
          im.TreePop()
        end
      end
    end
    im.EndCombo()
  end

  if not S.selectedModel then
    if player then selectModel(player.jbeam) end
    if not S.selectedModel then return end
  end

  im.InputText('Ieskoti detales', S.partSearchPtr, 128)
  local s = ffi.string(S.partSearchPtr):lower()
  if im.BeginChild1('##partlist', im.ImVec2(0, 340), true) then
    if s ~= '' then
      -- search: flat list
      local shown, total = 0, 0
      for _, p in ipairs(S.partList or {}) do
        if p.lower:find(s, 1, true) then
          total = total + 1
          if shown < maxListedParts then
            shown = shown + 1
            drawPartSelectable(p)
          end
        end
      end
      if total == 0 then imText('Nieko nerasta.') end
      if total > shown then imText(string.format('... ir dar %d', total - shown)) end
    else
      -- the swap folders, then the model's slot tree like the game's Parts menu, and at the bottom
      -- every part by type (common parts and other vehicles' too)
      drawEngineFolder()
      if S.partMain then
        im.Separator()
        S.drawSlotTree(S.partMain, '', 0)
      end
      im.Separator()
      if im.TreeNode1(string.format('Visos detales pagal tipa  (%d)##bytype', #(S.partCategories or {}))) then
        for _, f in ipairs(S.partCategories or {}) do drawFolder(f, 'c') end
        if S.otherCategories and #S.otherCategories > 0 then
          if im.TreeNode1(string.format('Kita (bendros / kitu masinu detales)  (%d)##other', #S.otherCategories)) then
            for _, f in ipairs(S.otherCategories) do drawFolder(f, 'o') end
            im.TreePop()
          end
        end
        im.TreePop()
      end
    end
  end
  im.EndChild()
  imText(string.format('%s: %d kategorijos, %d detales', tostring(S.partListModel), S.partCategories and #S.partCategories or 0, S.partList and #S.partList or 0))

  im.Checkbox('Masinos spalva', S.copyPaintPtr)
  im.SameLine()
  im.Checkbox('Tik modelis (be fizikos)', S.meshOnlyPtr)
  if im.IsItemHovered() then im.SetTooltip('Detale atsiras tik kaip modelis: nesveria, nesimusa, nelusta, tik juda kartu su masina. Detales be savo modelio tasku (radiatorius...) taip rodomos visada.') end
  im.Checkbox('Auto vieta', S.autoFitPtr)
  if im.IsItemHovered() then im.SetTooltip('Nauja detale atsiras ten, kur stovi tavo masinos tokia pati detale (buferis ant buferio, kapotas ant kapoto).') end
  local label = swapKinds[S.selectedIsEngine] and (swapKinds[S.selectedIsEngine].label:upper() .. ' SWAP - perziura: ' .. tostring(S.selectedPartName))
    or S.selectedIsEngine == 'gearbox' and ('GEARBOX SWAP - perziura: ' .. tostring(S.selectedPartName))
    or S.selectedIsEngine == 'radiator' and ('PRITAIKYTI RADIATORIU (logic): ' .. tostring(S.selectedPartName))
    or S.selectedIsEngine == 'fi' and ('PRITAIKYTI TURBO / KOMPRESORIU (logic): ' .. tostring(S.selectedPartName))
    or S.selectedIsEngine and ('ENGINE SWAP - perziura: ' .. tostring(S.selectedPartName))
    or ('Sukurti detale: ' .. (S.selectedPartName or '-'))
  if swapKinds[S.selectedIsEngine] then
    -- the safe way: only the character goes onto the car's own suspension (see section 5)
    if S.primaryButton('LOGIC (rekomenduojama): perkelti tik charakteri - ' .. tostring(S.selectedPartName), im.ImVec2(-1, 0)) then
      if player then takeDonorCharacter(player, S.selectedIsEngine, S.selectedModel, S.selectedPartName) end
    end
    if im.IsItemHovered() then im.SetTooltip('Tavo pakabos geometrija lieka, perkeliami donoro spyruokliu, amortizatoriu ir stabilizatoriaus standumai. Niekas nelus. Koreguok 5 dalyje.') end
    imText('Zemiau - tikras geometrijos swap (eksperimentinis, gali glitchinti):')
  end
  -- the main button of the tab; for a suspension the LOGIC one above is the recommended one
  local spawnButton = swapKinds[S.selectedIsEngine] and im.Button or S.primaryButton
  if spawnButton(label, im.ImVec2(-1, 0)) then spawnSelectedPart() end
  if S.selectedIsEngine == 'susp_R' then
    if im.Button('PRIDETI KAIP ANTRA GALINE ASI (6 ratai): ' .. tostring(S.selectedPartName), im.ImVec2(-1, 0)) and player then
      spawnPartSwapGhost(S.selectedModel, S.selectedPartName, player, 'susp_R2')
    end
    if im.IsItemHovered() then im.SetTooltip('Tavo galine pakaba lieka, si atsiranda uz jos kaip antra asis (pvz. 6x4 sunkvezimis). Abi asys varomos universaliomis pavaromis.') end
  end
end

-- [-][+] [=====slider=====] label ; Ctrl+click on the slider lets you type a value
local function sliderRow(label, ptr, step, minV, maxV, fmt)
  im.PushID1(label)
  if im.SmallButton('-') then ptr[0] = ptr[0] - step end
  im.SameLine()
  if im.SmallButton('+') then ptr[0] = ptr[0] + step end
  im.SameLine()
  im.PushItemWidth(-130)
  im.SliderFloat('##v', ptr, minV, maxV, fmt)
  im.PopItemWidth()
  im.SameLine()
  im.PopID()
  imText(label)
end

local function drawGhostSection()
  local ids = {}
  for id, _ in pairs(entries) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then
    imText('Sukurk detale 1 dalyje - ji atsiras virs masinos.')
    return
  end

  if #ids > 1 and im.BeginChild1('##entries', im.ImVec2(0, 70), true) then
    for _, id in ipairs(ids) do
      local e = entries[id]
      if im.Selectable1(string.format('#%d %s##e%d', id, e.partName, id), id == selectedEntryId) then selectedEntryId = id end
    end
  end
  if #ids > 1 then im.EndChild() end

  local e = selectedEntryId and entries[selectedEntryId]
  if not e then
    selectedEntryId = ids[1]
    return
  end

  imText(string.format('Detale: %s (%s) -> masina %s', e.partName, e.model, tostring(e.targetName)))
  if e.state == 'loading' then imText('kraunama...') return end
  -- what it becomes on ATTACH, switchable here (the "Tik modelis" checkbox of section 1 stays on)
  if e.mode == 'meshonly' then
    im.TextColored(im.ImVec4(1.0, 0.72, 0.25, 1.0), 'Rezimas: TIK MODELIS - be fizikos, lenda kiaurai kliutis')
    im.SameLine()
    if im.SmallButton('Su fizika##ghostmode') then S.respawnGhost(e, false) return end
  elseif e.mode == 'part' then
    im.TextColored(im.ImVec4(0.55, 0.9, 0.55, 1.0), 'Rezimas: su fizika (virtualus tvirtinimas)')
    im.SameLine()
    if im.SmallButton('Tik modelis##ghostmode') then S.respawnGhost(e, true) return end
  end

  local holdPtr = im.BoolPtr(e.hold)
  if im.Checkbox('Laikyti ore', holdPtr) then e.hold = holdPtr[0] end
  im.SameLine()
  if im.SmallButton('Taikinys = dabartine masina') then
    local player = getPlayerVehicle(0)
    if player and player:getID() ~= e.id and setupTarget(e, player) then msg('Taikinys pakeistas.') end
  end

  imText('Pozicija masinos atzvilgiu (-Y = pirmyn). Ctrl+click ant slankiklio = ivesti skaiciu')
  im.PushItemWidth(120)
  im.InputFloat('+/- zingsnis (m)', S.stepPtr, 0.01, 0.1, '%.3f')
  im.PopItemWidth()
  local st = math.max(0.001, S.stepPtr[0])
  sliderRow('X (sonas)', e.off[1], st, -4, 4, '%.3f m')
  sliderRow('Y (pirmyn/atgal)', e.off[2], st, -8, 8, '%.3f m')
  sliderRow('Z (aukstis)', e.off[3], st, -3, 6, '%.3f m')
  sliderRow('Pasvirimas (X)', e.rot[1], 5, -180, 180, '%.1f deg')
  sliderRow('Pokrypis (Y)', e.rot[2], 5, -180, 180, '%.1f deg')
  sliderRow('Pasukimas (Z)', e.rot[3], 5, -180, 180, '%.1f deg')
  if e.mode == 'part' or e.mode == 'meshonly' then
    -- size: the preview is built again at the new size once the slider is let go
    local apply = false
    im.PushID1('scale')
    if im.SmallButton('-') then e.scale[0] = e.scale[0] - 0.1 apply = true end
    im.SameLine()
    if im.SmallButton('+') then e.scale[0] = e.scale[0] + 0.1 apply = true end
    im.SameLine()
    im.PushItemWidth(-130)
    im.SliderFloat('##v', e.scale, 0.1, 5, 'x%.2f')
    if im.IsItemDeactivatedAfterEdit() then apply = true end
    im.PopItemWidth()
    im.SameLine()
    im.PopID()
    imText('Dydis (scale)')
    if im.IsItemHovered() then im.SetTooltip('Detale padideja / sumazeja apie savo centra (modelis ir fizika). Atleidus slankikli perziura persikrauna.') end
    if e.builtScale ~= 1 then
      im.SameLine()
      if im.SmallButton('Tikras dydis') then e.scale[0] = 1 apply = true end
    end
    e.scale[0] = math.min(10, math.max(0.05, e.scale[0]))
    if apply and math.abs(e.scale[0] - e.builtScale) > 1e-3 then
      S.rescaleGhost(e)
      return
    end
  end
  local isEngine = e.mode == 'engine'
  local isPartSwap = e.mode == 'partswap'
  local isGearbox = e.mode == 'gearbox' or isPartSwap -- same handling as a gearbox swap from here on
  if isEngine or isGearbox then
    if im.Button(isEngine and 'Senojo variklio vieta' or isPartSwap and 'Senosios pakabos vieta' or 'Senosios dezes vieta') then
      resetOffsets(e)
      for i = 1, 3 do e.off[i][0] = e.presetMove and e.presetMove[i] or 0 end
    end
    if im.IsItemHovered() then im.SetTooltip('Naujo variklio centras ten, kur buvo senojo') end
  else
    if im.Button('Donoro vieta') then resetOffsets(e) end
    if im.IsItemHovered() then im.SetTooltip('Detale ten, kur ji butu ant savo originalios masinos') end
    im.SameLine()
    if im.Button('Ant stogo') then putOnRoof(e) end
    if e.autoMove then
      im.SameLine()
      if im.Button('Kaip mano masinos detale') then
        resetOffsets(e)
        for i = 1, 3 do e.off[i][0] = e.autoMove[i] end
      end
    end
    im.SameLine()
    if im.Button('Veidrodine kopija') then
      local target = getVeh(e.targetId)
      S.spawnMirror(target, e.model, e.partName, {e.off[1][0], e.off[2][0], e.off[3][0]}, {e.rot[1][0], e.rot[2][0], e.rot[3][0]},
        e.pivot and {e.pivot.x, e.pivot.y, e.pivot.z}, e.mode == 'meshonly', e.builtScale)
    end
    if im.IsItemHovered() then im.SetTooltip('Atsiras tokia pati detale kitoje masinos puseje (kaire <-> desine), veidrodiskai.') end
  end

  im.Separator()
  if isEngine then
    imText('ENGINE SWAP: senas variklis (' .. tostring(e.replaces) .. ') bus pakeistas siuo.')
    imText('LOGIC SWAP: tavo variklio fizika lieka (niekas nesulus), keiciasi galia, sukimo momentas,')
    imText('apsukos, inercija, garsas. Tiuningas (ECU, internals, turbo...) - Parts meniu po varikliu.')
    im.Checkbox('Pakeisti ir variklio modeli (matosi donoro variklis)', S.engineMeshPtr)
    if im.IsItemHovered() then im.SetTooltip('Stumdyk perziura, kad modelis tilptu i variklio skyriu. Isjungus - lieka tavo variklio modelis, keiciasi tik galia ir garsas.') end
  elseif isPartSwap then
    local label = swapKinds[e.kind] and swapKinds[e.kind].label or tostring(e.kind)
    if e.added then
      imText('ANTRA GALINE ASIS: bus prideta uz esamos galines pakabos (pastumk Y, kad stovetu kur reikia).')
    else
      imText(label:upper() .. ' SWAP: ' .. tostring(e.replaces) .. ' bus pakeista sita.')
    end
    imText('Kartu keliauja ratai, stebules, amortizatoriai, stabdziai, vairavimas.')
    imText('Virinama tik per donoro tvirtinimo taskus - svirtys lieka judancios.')
    im.Checkbox('Jei ratai nebus varomi - ijungti universalias pavaras', S.autoDrivetrainPtr)
    if im.IsItemHovered() then im.SetTooltip('Patikrinama, ar naujos pakabos velenai randa masinos pavaras. Jei ne - ijungiamos universalios pavaros pagal 4 dalies nustatymus.') end
  elseif isGearbox then
    imText('GEARBOX SWAP: dabartine deze (' .. tostring(e.replaces) .. ') bus pakeista sita.')
    im.Checkbox('Kartu ijungti universalias pavaras (4 dalis)', S.autoDrivetrainPtr)
    if im.IsItemHovered() then im.SetTooltip('Rekomenduojama: kardanas, diferencialai ir pusasiai sugeneruojami is naujo, kad galia tikrai pasiektu ratus.') end
  end
  if not isEngine then -- a logic engine swap welds nothing
    imText(isGearbox and 'Tvirtinimas prie kebulo:' or 'Tvirtinimas (detale taps masinos dalimi):')
    if e.mode == 'part' then
      imText('Virtualus tvirtinimas: detale laiko 8 remo taskai aplink ja, prie masinos strukturos')
      imText('privirinami tik jie. Detale turi savo svori, fizika ir susidurimus.')
    end
    im.PushItemWidth(140)
    if im.InputInt('Suvirinimo tasku', S.maxWeldsPtr) then S.maxWeldsPtr[0] = math.min(40, math.max(1, S.maxWeldsPtr[0])) end
    im.InputFloat('Maks. tarpas (m)', S.maxGapPtr, 0.05, 0.25, '%.2f')
    if not S.unbreakablePtr[0] then
      im.InputFloat('Stiprumas (N)', S.strengthPtr, 5000, 20000, '%.0f')
      if im.IsItemHovered() then im.SetTooltip('Vienos suvirinimo sijos jega, nuo kurios ji nutruksta; lankstytis pradeda nuo puses. Numatyta 40000 (BeamNG buferio tvirtinimas - 28000).') end
    end
    im.PopItemWidth()
    im.Checkbox('Nesulauzoma', S.unbreakablePtr)
    if not isGearbox then
      im.SameLine()
      im.Checkbox('Be susidurimu', S.noCollisionPtr)
      if im.IsItemHovered() then im.SetTooltip('Detale nesimus su kitomis masinomis (tik dekoracija)') end
    end
  end
  im.Checkbox(string.format('Apsauga nuo sudauzymo pirmas %.1f s', S.settleSeconds), S.settlePtr)
  if im.IsItemHovered() then im.SetTooltip('Po spawn\'o / R visos masinos sijos kelias sekundes nesilanksto ir nelusta, kol naujos detales nusistovi. Po to - iprasta zalos fizika.') end

  if S.primaryButton(isEngine and 'ATLIKTI ENGINE SWAP' or isPartSwap and 'ATLIKTI PAKABOS SWAP' or isGearbox and 'ATLIKTI GEARBOX SWAP' or 'PRITVIRTINTI (idiegti i masina)', im.ImVec2(260, 0)) then
    mergeIntoTarget(e)
  end
  im.SameLine()
  if im.Button('Istrinti') then deleteEntry(e) end
end

local function drawInstalledSection(player)
  if not player then imText('Isek i masina.') return end
  local swap = getSwap(player:getID())
  if swap then
    imText(string.format('Variklis: %s (is %s), vietoj %s', tostring(swap.part), tostring(swap.model), tostring(swap.replaces)))
    im.SameLine()
    if im.SmallButton('Perkelti##swap') then editSwap(player) end
    if im.IsItemHovered() then im.SetTooltip('Grazina sena varikli ir vel leidzia nauja stumdyti') end
    im.SameLine()
    if im.SmallButton('Grazinti originalu##swap') then removeSwap(player) end
    if (tonumber(swap.version) or 1) < 4 then
      im.SameLine()
      if im.SmallButton('PATAISYTI##fixengine') then editSwap(player) end
      if im.IsItemHovered() then im.SetTooltip('Senos versijos swap (fiziskai istatytas svetimas variklis). Grazina originalu ir atidaro perziura - spausk ATLIKTI ENGINE SWAP, bus padaryta nauju logic budu.') end
    end
  end
  local gbSwap = getPA(player:getID()).gearboxSwap
  if type(gbSwap) == 'table' then
    imText(string.format('Pavaru deze: %s (is %s), vietoj %s', tostring(gbSwap.part), tostring(gbSwap.model), tostring(gbSwap.replaces)))
    im.SameLine()
    if im.SmallButton('Perkelti##gbswap') then editGearboxSwap(player) end
    im.SameLine()
    if im.SmallButton('Grazinti originalia##gbswap') then removeGearboxSwap(player) end
  end
  local fiSwap = getPA(player:getID()).fiSwap
  if type(fiSwap) == 'table' then
    imText(string.format('%s (logic): %s (is %s)', S.forcedInductionKind(fiSwap), tostring(fiSwap.part), tostring(fiSwap.model)))
    im.SameLine()
    if im.SmallButton('Grazinti originalu##fiswap') then S.removeForcedInduction(player) end
  end
  local radSwap = getPA(player:getID()).radiatorSwap
  if type(radSwap) == 'table' then
    imText(string.format('Radiatorius (logic): %s (is %s)', tostring(radSwap.part), tostring(radSwap.model)))
    im.SameLine()
    if im.SmallButton('Grazinti originalu##radswap') then S.removeRadiator(player) end
  end
  local anySwap = swap or type(gbSwap) == 'table' or type(radSwap) == 'table' or type(fiSwap) == 'table'
  for _, kind in ipairs({'susp_F', 'susp_R', 'susp_R2'}) do
    local ps = getPartSwap(player:getID(), kind)
    if ps then
      anySwap = true
      if ps.added then
        imText(string.format('%s: %s (is %s), prideta', swapKinds[kind].label, tostring(ps.part), tostring(ps.model)))
      else
        imText(string.format('%s: %s (is %s), vietoj %s', swapKinds[kind].label, tostring(ps.part), tostring(ps.model), tostring(ps.replaces)))
      end
      im.SameLine()
      if im.SmallButton('Perkelti##' .. kind) then editPartSwap(player, kind) end
      im.SameLine()
      if im.SmallButton('Grazinti originalia##' .. kind) then removePartSwap(player, kind) end
      if (tonumber(ps.version) or 1) < 15 then
        im.SameLine()
        if im.SmallButton('PATAISYTI##fix' .. kind) then upgradePartSwap(player, kind) end
        if im.IsItemHovered() then im.SetTooltip('Senos versijos swap: perdaro tvirtinima per donoro remo taskus (taiso vaira ir glitchus)') end
      end
    end
  end
  local extras = getExtras(player:getID())
  if #extras == 0 then
    if not anySwap then imText('Si masina dar neturi pridetu detaliu.') end
    return
  end
  for i, ex in ipairs(extras) do
    im.PushID1('extra' .. i)
    local isFront = type(ex.frontEnd) == 'table'
    if isFront then
      imText(string.format('%d. PRIEKIS is %s (%d detales)', i, tostring(ex.model), #(ex.frontEnd.parts or {})))
    else
      imText(string.format('%d. %s  (is %s)%s', i, tostring(ex.part), tostring(ex.model), ex.meshOnly and '  [tik modelis]' or ex.dataOnly and '  [tik duomenys]' or ''))
    end
    if ex.dataOnly then
      -- nothing to move, mirror or give physics: it can only come off
      im.SameLine()
      if im.SmallButton('Nuimti') then removeExtra(player, i) end
    else
      if S.extraScale(ex) then
        im.SameLine()
        imText(string.format('x%.2f', ex.scale))
      end
      im.SameLine()
      if im.SmallButton('Perkelti') then editExtra(player, i) end
      if im.IsItemHovered() then im.SetTooltip('Nuima detale ir vel leidzia ja stumdyti') end
      im.SameLine()
      if im.SmallButton('Nuimti') then removeExtra(player, i) end
      if isFront and im.IsItemHovered() then im.SetTooltip('Priekis nuimamas, tavo masinos savos priekio detales grizta.') end
    end
    if not ex.dataOnly and not isFront then
      im.SameLine()
      if im.SmallButton('Veidrodis') then S.spawnMirror(player, ex.model, ex.part, ex.move, ex.rot, ex.pivot, ex.meshOnly, ex.scale) end
      if im.IsItemHovered() then im.SetTooltip('Tokia pati detale kitoje puseje: atsiras perziura, pastumdyk ir PRITVIRTINK.') end
      im.SameLine()
      if ex.meshOnly then
        if im.SmallButton('Su fizika') then S.setExtraPhysics(player, i, true) end
        if im.IsItemHovered() then im.SetTooltip('Detale gauna savo fizika, svori ir susidurimus (virtualus tvirtinimas), toje pacioje vietoje.') end
      else
        if im.SmallButton('Tik modelis') then S.setExtraPhysics(player, i, false) end
        if im.IsItemHovered() then im.SetTooltip('Lieka tik detales modelis, be fizikos (nesveria, nesimusa).') end
      end
    end
    im.PopID()
  end
end

-- section 5: logic suspension (the car's own geometry, donor character and / or sliders)
local function drawSuspSection(player)
  if not player then imText('Isek i masina.') return end
  local id = player:getID()
  local current = getPA(id).suspTune

  -- show the car's saved settings when switching cars
  if suspLoadedFor ~= id then
    suspLoadedFor = id
    for _, axle in ipairs({'F', 'R'}) do
      local ui, s = suspUI[axle], type(current) == 'table' and current[axle] or nil
      ui.lift[0] = s and (tonumber(s.lift) or 0) * 100 or 0
      ui.spring[0] = s and tonumber(s.springMul) or 1
      ui.damp[0] = s and tonumber(s.dampMul) or 1
      ui.sway[0] = s and tonumber(s.swayMul) or 1
      ui.donor = s and s.donor or nil
    end
  end

  imText('Tavo pakabos geometrija ir fizika lieka - keiciasi tik jos charakteris. Niekas nelus.')
  imText('Donoro charakteri pasirink 1 dalyje: pakabu aplankas -> "LOGIC: perkelti tik charakteri".')
  for _, axle in ipairs({'F', 'R'}) do
    local ui = suspUI[axle]
    im.PushID1('susp' .. axle)
    im.Separator()
    imText(axle == 'F' and 'PRIEKIS' or 'GALAS')
    if ui.donor then
      imText(string.format('  donoro charakteris: %s (%s)', tostring(ui.donor.part), tostring(ui.donor.model)))
      im.SameLine()
      if im.SmallButton('pamirsti') then ui.donor = nil end
    end
    im.PushItemWidth(-170)
    im.SliderFloat('Prosvaisa (cm)', ui.lift, -20, 60, '%+.1f cm')
    im.SliderFloat('Spyruokles x', ui.spring, 0.1, 6, '%.2f')
    im.SliderFloat('Amortizatoriai x', ui.damp, 0.1, 6, '%.2f')
    im.SliderFloat('Stabilizatorius x', ui.sway, 0, 6, '%.2f')
    im.PopItemWidth()
    im.PopID()
  end
  im.Separator()
  if S.primaryButton('PRITAIKYTI PAKABA', im.ImVec2(220, 0)) then applySuspTune(player) end
  im.SameLine()
  if im.Button('Atstatyti originalia') then
    for _, axle in ipairs({'F', 'R'}) do suspUI[axle] = newSuspUI() end
    applySuspTune(player)
  end
  if type(current) == 'table' then imText('Busena: pritaikyta (logic).') end
end

local function drawDrivetrainSection(player)
  if not player then imText('Isek i masina.') return end
  local id = player:getID()
  local current = getPA(id).drivetrain
  local active = type(current) == 'table' and current.enabled

  -- show the car's saved settings when switching cars
  if dtLoadedFor ~= id then
    dtLoadedFor = id
    if active then
      for i, v in ipairs(layouts) do if v == current.layout then S.dtLayoutPtr[0] = i - 1 end end
      for i, v in ipairs(diffTypes) do if v == current.diffType then S.dtDiffPtr[0] = i - 1 end end
      for i, v in ipairs(diffTypes) do if v == current.centerType then S.dtCenterPtr[0] = i - 1 end end
      S.dtSplitPtr[0] = tonumber(current.frontSplit) or 0.4
      S.dtFinalPtr[0] = tonumber(current.finalDrive) or 3.7
      S.dtLockFPtr[0], S.dtLockRPtr[0], S.dtLockCPtr[0] = current.lockerF == true, current.lockerR == true, current.lockerC == true
      S.dtPartTimePtr[0], S.dtLowRangePtr[0] = current.partTime == true, current.lowRange == true
      S.dtLowRatioPtr[0] = tonumber(current.lowRatio) or 2.72
    else
      local fd = readFinalDrive(id)
      if fd and fd > 1 then S.dtFinalPtr[0] = fd end
    end
  end

  imText('Sugeneruoja kardana, diferencialus ir pusasius nuo BET KOKIOS pavaru dezes iki ratu.')
  imText('Busena: ' .. (active and string.format('IJUNGTA (%s, %s, %.2f)', tostring(current.layout), tostring(current.diffType), tonumber(current.finalDrive) or 0) or 'isjungta (originalios pavaros)'))

  imText('Varomi ratai:')
  for i, name in ipairs(layouts) do
    im.SameLine()
    im.RadioButton2(name .. '##layout', S.dtLayoutPtr, i - 1)
  end
  imText('Tilto diferencialas:')
  for i, name in ipairs(diffTypes) do
    im.SameLine()
    im.RadioButton2(name .. '##axdiff', S.dtDiffPtr, i - 1)
  end
  imText('Uzrakinami (locker):')
  im.SameLine()
  im.Checkbox('Priekinis##lockF', S.dtLockFPtr)
  im.SameLine()
  im.Checkbox('Galinis##lockR', S.dtLockRPtr)
  local awd = S.dtLayoutPtr[0] == 2
  local partTime = awd and S.dtPartTimePtr[0]
  if awd and not partTime then
    im.SameLine()
    im.Checkbox('Centrinis (abu tiltai kartu)##lockC', S.dtLockCPtr)
  end
  if im.IsItemHovered() then im.SetTooltip('Uzrakinamas diferencialas turi 2 rezimus: pasirinktas tipas ir "locked" (abi puses sukasi vienodai). Perjungiama vaziuojant - mygtukais zemiau arba zaidimo klavisu "Toggle differential mode".') end
  if awd then
    im.Checkbox('Perjungiamas 2WD / 4WD (part-time)', S.dtPartTimePtr)
    if im.IsItemHovered() then im.SetTooltip('Vietoj centrinio diferencialo - skirstymo deze kaip visureigiuose: 2WD (galas) arba 4WD (priekis ir galas sujungti 50 / 50). Perjungiama vaziuojant. Ant sauso asfalto 4WD posukiuose "stringa" - kaip tikroje masinoje.') end
    if S.dtPartTimePtr[0] then imText('   4WD rezime abu tiltai sujungti ir sukasi kartu (centrinio uzrakto nereikia).') end
  end
  if awd and not partTime then
    imText('Centrinis diferencialas:')
    for i, name in ipairs(diffTypes) do
      im.SameLine()
      im.RadioButton2(name .. '##cdiff', S.dtCenterPtr, i - 1)
    end
    im.PushItemWidth(-160)
    im.SliderFloat('Priekio dalis (AWD)', S.dtSplitPtr, 0.05, 0.95, '%.2f')
    im.PopItemWidth()
  end
  im.Checkbox('Zemoji pavara (low range)', S.dtLowRangePtr)
  if im.IsItemHovered() then im.SetTooltip('Papildoma deze po pavaru deze: High (1:1) arba Low - letai, bet labai stipriai (bekelei, kopimui). Perjungiama vaziuojant.') end
  if S.dtLowRangePtr[0] then
    im.PushItemWidth(-160)
    im.SliderFloat('Zemosios santykis', S.dtLowRatioPtr, 1.5, 4.5, '%.2f')
    im.PopItemWidth()
  end
  im.PushItemWidth(-160)
  im.SliderFloat('Galutine pavara', S.dtFinalPtr, 1.5, 8, '%.2f')
  im.PopItemWidth()
  if im.IsItemHovered() then im.SetTooltip('Didesnis skaicius = greitesnis isibegejimas, mazesnis max greitis. Ctrl+click - ivesti') end
  if im.SmallButton('Nuskaityti dabartine galutine pavara') then
    local fd = readFinalDrive(id)
    if fd then
      S.dtFinalPtr[0] = fd
      msg(string.format('Dabartine galutine pavara: %.2f', fd), 4)
    else
      msg('Nepavyko nuskaityti.', 4)
    end
  end

  if S.primaryButton(active and 'Atnaujinti pavaras' or 'IJUNGTI universalias pavaras', im.ImVec2(240, 0)) then
    setDrivetrain(player, drivetrainSpecFromUI())
  end
  if active then
    im.SameLine()
    if im.Button('Isjungti (originalios)') then setDrivetrain(player, nil) end
  end

  -- what the drivetrain on the car can switch while driving: lockers, 2WD / 4WD, high / low
  local partTimeOn = current and current.partTime and current.layout == 'AWD'
  if active and (current.lockerF or current.lockerR or (current.lockerC and not partTimeOn) or partTimeOn or current.lowRange) then
    im.Separator()
    imText('Perjungti vaziuojant:')
    -- every device with more than one mode whose name starts with one of the prefixes
    local function toggle(prefixes)
      local conds = {}
      for _, p in ipairs(prefixes) do conds[#conds + 1] = string.format('d.name:find(%q, 1, true) == 1', p) end
      player:queueLuaCommand(string.format("for _, d in pairs(powertrain.getDevices()) do if type(d.availableModes) == 'table' and #d.availableModes > 1 and (%s) then powertrain.toggleDeviceMode(d.name) end end",
        table.concat(conds, ' or ')))
    end
    local buttons = {}
    if partTimeOn then buttons[#buttons + 1] = {'2WD / 4WD##tglTC', {'upa_transfercase'}} end
    if current.lowRange then buttons[#buttons + 1] = {'High / Low##tglRB', {'upa_rangebox'}} end
    if current.lockerF then buttons[#buttons + 1] = {'Priekinis##tglF', {'differential_F', 'tandem_F'}} end
    if current.lockerR then buttons[#buttons + 1] = {'Galinis##tglR', {'differential_R', 'tandem_R'}} end
    if current.lockerC and not partTimeOn then buttons[#buttons + 1] = {'Centrinis##tglC', {'upa_center_diff'}} end
    for _, b in ipairs(buttons) do
      im.SameLine()
      if im.SmallButton(b[1]) then toggle(b[2]) end
    end
    if current.lockerF or current.lockerR or current.lockerC then
      im.SameLine()
      if im.SmallButton('Visi diferencialai##tglAll') then player:queueLuaCommand('powertrain.toggleDefaultDiffs()') end
    end
    -- everything at once: every lockable diff locked and the transfer case in 4WD (both axles and
    -- both sides of each axle turn together), or all of it back
    local lockAll = "for _, d in pairs(powertrain.getDevices()) do local m = d.availableModes if type(m) == 'table' and #m > 1 then local want "
      .. "if d.type == 'differential' then for _, x in ipairs(m) do if x == 'locked' then want = 'locked' end end "
      .. "elseif d.type == 'splitShaft' then want = 'connected' end "
      .. "if want and d.mode ~= want then powertrain.setDeviceMode(d.name, want) end end end"
    local unlockAll = "for _, d in pairs(powertrain.getDevices()) do local m = d.availableModes if type(m) == 'table' and #m > 1 then local want "
      .. "if d.type == 'differential' then want = d.defaultMode if want == 'locked' then for _, x in ipairs(m) do if x ~= 'locked' then want = x break end end end "
      .. "elseif d.type == 'splitShaft' then want = 'disconnected' end "
      .. "if want and d.mode ~= want then powertrain.setDeviceMode(d.name, want) end end end"
    if im.Button('UZRAKINTI VISKA##lockAll') then player:queueLuaCommand(lockAll) end
    if im.IsItemHovered() then im.SetTooltip('Visi uzrakinami diferencialai - locked, skirstymo deze - 4WD: abu tiltai ir abi kiekvieno tilto puses sukasi kartu.') end
    im.SameLine()
    if im.Button('ATRAKINTI VISKA##unlockAll') then player:queueLuaCommand(unlockAll) end
  end
end

local placeWindow = true -- put the window back on screen when it gets opened

-- section 6: safety electronics (ABS, TC, ESC, 2-step, line lock) for the current car
S.drawSafetySection = function(player)
  if not player then imText('Isek i masina.') return end
  local id = player:getID()
  local current = getPA(id).safety
  if not S.sf then
    S.sf = {abs = im.BoolPtr(true), tc = im.BoolPtr(true), esc = im.BoolPtr(false), twoStep = im.BoolPtr(false),
      rpm = im.FloatPtr(4000), lineLock = im.BoolPtr(false)}
  end
  -- the car's installed choice when switching cars
  if S.sfLoadedFor ~= id then
    S.sfLoadedFor = id
    if type(current) == 'table' then
      S.sf.abs[0], S.sf.tc[0], S.sf.esc[0] = current.abs == true, current.tc == true, current.esc == true
      S.sf.twoStep[0] = tonumber(current.twoStep) ~= nil
      S.sf.rpm[0] = tonumber(current.twoStep) or 4000
      S.sf.lineLock[0] = current.lineLock == true
    end
  end
  imText('Prideda elektronika bet kuriai masinai (ko masina jau turi pati - nekeiciama).')
  if type(current) == 'table' then
    local on = {}
    if current.abs then on[#on + 1] = 'ABS' end
    if current.tc then on[#on + 1] = 'TC' end
    if current.esc then on[#on + 1] = 'ESC' end
    if current.twoStep then on[#on + 1] = string.format('2-step %d', tonumber(current.twoStep) or 0) end
    if current.lineLock then on[#on + 1] = 'line lock' end
    imText(string.format('Busena: idiegta - %s', table.concat(on, ', ')))
  else
    imText('Busena: neidiegta')
  end
  im.Checkbox('ABS (stabdziai neuzsiblokuoja)', S.sf.abs)
  im.Checkbox('Traction control (TC) - ratai nebuksuoja', S.sf.tc)
  im.Checkbox('Stabilumo kontrole (ESC) - neslysta / nesisuka', S.sf.esc)
  if im.IsItemHovered() then im.SetTooltip('Bendri nustatymai, ne pagal sia masina: ant labai neiprastu masinu gali veikti netiksliai.') end
  im.Checkbox('2-step (launch control)', S.sf.twoStep)
  if S.sf.twoStep[0] then
    im.SameLine()
    im.PushItemWidth(160)
    im.SliderFloat('##twostep', S.sf.rpm, 1500, 9000, '%.0f rpm')
    im.PopItemWidth()
  end
  im.Checkbox('Line lock (laiko priekinius stabdzius - burnout)', S.sf.lineLock)
  if S.primaryButton('IDIEGTI / ATNAUJINTI##safety', im.ImVec2(220, 0)) then
    local spec = {abs = S.sf.abs[0] or nil, tc = S.sf.tc[0] or nil, esc = S.sf.esc[0] or nil,
      twoStep = S.sf.twoStep[0] and math.floor(S.sf.rpm[0] / 100 + 0.5) * 100 or nil, lineLock = S.sf.lineLock[0] or nil}
    if next(spec) == nil then
      msg('Nieko nepasirinkta.')
    elseif respawnWithConfig(player, function(cfg) cfg.partAttacherExp.safety = spec end) then
      msg('Saugos elektronika idiegta. Rezimai - radialiniame meniu (Vehicle features) arba Options > Controls.', 8)
    end
  end
  if type(current) == 'table' then
    im.SameLine()
    if im.Button('Pasalinti##safety') then respawnWithConfig(player, function(cfg) cfg.partAttacherExp.safety = nil end) end
  end
  imText('Vaziuojant: TC / ESC rezimai (ESC + TC / TC / Off) - klavisas "Toggle ESC mode" arba radialinis meniu.')
  imText('2-step: stovint laikyk stabdi + pilna gaza, atleisk stabdi - startas. Ijungiama meniu / "Toggle Two-Step".')
  imText('Line lock: laikyk stabdi, ijunk "Toggle Line Lock" - priekiniai laikomi, galiniai buksuoja.')
end

--------------------------------------------------------------------------------
-- look: the game's own (Vue) menus - near black translucent panels, the BeamNG orange as the one
-- accent, rounded corners, roomy spacing; the sections as tabs
--------------------------------------------------------------------------------

S.accent = {1.0, 0.4, 0.0} -- BeamNG orange, #FF6600

-- colours / style values pushed around the window (built once: they never change)
S.themeStyle = function()
  if S.themeCache then return S.themeCache end
  local a = S.accent
  local function c(r, g, b, alpha) return im.ImVec4(r, g, b, alpha) end
  local function acc(alpha) return im.ImVec4(a[1], a[2], a[3], alpha) end
  S.themeCache = {
    colors = {
      {im.Col_WindowBg, c(0.08, 0.08, 0.09, 0.96)}, {im.Col_ChildBg, c(1, 1, 1, 0.03)},
      {im.Col_PopupBg, c(0.10, 0.10, 0.11, 0.98)}, {im.Col_Border, c(1, 1, 1, 0.08)},
      {im.Col_TitleBg, c(0.06, 0.06, 0.07, 1)}, {im.Col_TitleBgActive, c(0.11, 0.11, 0.12, 1)},
      {im.Col_TitleBgCollapsed, c(0.06, 0.06, 0.07, 0.9)},
      {im.Col_Text, c(0.95, 0.95, 0.95, 1)}, {im.Col_TextDisabled, c(0.55, 0.55, 0.58, 1)},
      {im.Col_FrameBg, c(1, 1, 1, 0.06)}, {im.Col_FrameBgHovered, c(1, 1, 1, 0.11)}, {im.Col_FrameBgActive, acc(0.25)},
      {im.Col_Button, c(1, 1, 1, 0.08)}, {im.Col_ButtonHovered, acc(0.45)}, {im.Col_ButtonActive, acc(0.7)},
      {im.Col_Header, acc(0.22)}, {im.Col_HeaderHovered, acc(0.38)}, {im.Col_HeaderActive, acc(0.55)},
      {im.Col_CheckMark, acc(1)}, {im.Col_SliderGrab, acc(0.9)}, {im.Col_SliderGrabActive, c(1, 0.55, 0.2, 1)},
      {im.Col_Separator, c(1, 1, 1, 0.12)}, {im.Col_TextSelectedBg, acc(0.35)},
      {im.Col_Tab, c(1, 1, 1, 0.05)}, {im.Col_TabHovered, acc(0.5)}, {im.Col_TabActive, acc(0.85)},
      {im.Col_TabUnfocused, c(1, 1, 1, 0.04)}, {im.Col_TabUnfocusedActive, acc(0.55)},
      {im.Col_ScrollbarBg, c(0, 0, 0, 0.15)}, {im.Col_ScrollbarGrab, c(1, 1, 1, 0.18)},
      {im.Col_ScrollbarGrabHovered, c(1, 1, 1, 0.28)}, {im.Col_ScrollbarGrabActive, acc(0.8)},
      {im.Col_ResizeGrip, acc(0.25)}, {im.Col_ResizeGripHovered, acc(0.6)}, {im.Col_ResizeGripActive, acc(0.9)},
    },
    vars = {
      {im.StyleVar_WindowRounding, 8}, {im.StyleVar_ChildRounding, 6}, {im.StyleVar_FrameRounding, 4},
      {im.StyleVar_PopupRounding, 6}, {im.StyleVar_GrabRounding, 4}, {im.StyleVar_TabRounding, 4},
      {im.StyleVar_ScrollbarRounding, 6}, {im.StyleVar_WindowBorderSize, 1}, {im.StyleVar_FrameBorderSize, 0},
      {im.StyleVar_WindowPadding, im.ImVec2(12, 10)}, {im.StyleVar_FramePadding, im.ImVec2(8, 4)},
      {im.StyleVar_ItemSpacing, im.ImVec2(8, 6)}, {im.StyleVar_ItemInnerSpacing, im.ImVec2(6, 4)},
    },
  }
  return S.themeCache
end

S.pushTheme = function()
  local t = S.themeStyle()
  for _, e in ipairs(t.colors) do im.PushStyleColor2(e[1], e[2]) end
  for _, e in ipairs(t.vars) do
    if type(e[2]) == 'number' then im.PushStyleVar1(e[1], e[2]) else im.PushStyleVar2(e[1], e[2]) end
  end
  return #t.colors, #t.vars
end

-- the main action of a section, filled with the accent colour as in the game's own menus
S.primaryButton = function(label, size)
  local a = S.accent
  im.PushStyleColor2(im.Col_Button, im.ImVec4(a[1], a[2], a[3], 0.88))
  im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(1, 0.52, 0.16, 1))
  im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.85, 0.33, 0, 1))
  im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 1, 1))
  local pressed = im.Button(label, size)
  im.PopStyleColor(4)
  return pressed
end

-- section 7, car cutter (experimental): the car's own body in its jbeam space (all of it, also what
-- a cut made into mesh holders) and three kept nodes that place the cut plane in the world.
-- Built again for every spawn of the car (its vehicle data is a new table then).
S.cutInfo = function(veh)
  local id = veh:getID()
  local vd = getVData(id)
  if not (vd and vd.nodes) then return nil end
  local c = S.cutCache
  if c and c.id == id and c.vd == vd then return c end
  local n = veh:getNodeCount()
  local lo, hi = vec3(math.huge, math.huge, math.huge), vec3(-math.huge, -math.huge, -math.huge)
  local solid, count = {}, 0
  for cid = 0, n - 1 do
    local nd = vd.nodes[cid]
    local name = type(nd) == 'table' and nd.name
    local added = type(name) == 'string' and (name:find('^upa%d+_') or name:find('^ups%w+_'))
    if nd and not added and not isWheelNode(vd, cid) then
      count = count + 1
      local p = vec3(veh:getInitialNodePosition(cid))
      lo:set(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z))
      hi:set(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z))
      if not nd.upaCut then solid[#solid + 1] = cid end
    end
  end
  if count < 3 then return nil end
  local a, b, cc
  local ref = vd.refNodes and vd.refNodes[0]
  if ref then
    a, b, cc = ref.ref, ref.back, ref.up
    if not validAnchors(veh, a, b, cc, n) then cc = ref.left end
  end
  if not validAnchors(veh, a, b, cc, n) then a, b, cc = pickAnchors(veh, solid) end
  if not a then return nil end
  S.cutCache = {id = id, vd = vd, lo = lo, hi = hi, a = a, b = b, c = cc}
  return S.cutCache
end

-- the cut plane across the car (jbeam y), and an arrow towards the side that comes off
S.drawCutPlane = function(veh, info, y, keepFront)
  local okR, Rt, wA, iA = pcall(nodeFrameRot, veh, info.a, info.b, info.c)
  if not okR or not Rt then return end
  local function world(x, z) return wA + Rt * (vec3(x, y, z) - iA) end
  local x0, x1 = info.lo.x - 0.15, info.hi.x + 0.15
  local z0, z1 = info.lo.z - 0.05, info.hi.z + 0.15
  local p1, p2, p3, p4 = world(x0, z0), world(x1, z0), world(x1, z1), world(x0, z1)
  local fill = color(255, 102, 0, 70)
  debugDrawer:drawTriSolid(p1, p2, p3, fill)
  debugDrawer:drawTriSolid(p1, p3, p4, fill)
  debugDrawer:drawTriSolid(p3, p2, p1, fill)
  debugDrawer:drawTriSolid(p4, p3, p1, fill)
  local edge = ColorF(1, 0.4, 0, 1)
  debugDrawer:drawLine(p1, p2, edge)
  debugDrawer:drawLine(p2, p3, edge)
  debugDrawer:drawLine(p3, p4, edge)
  debugDrawer:drawLine(p4, p1, edge)
  local mid = (p1 + p3) * 0.5
  local dir = Rt * vec3(0, keepFront and 1 or -1, 0)
  debugDrawer:drawLine(mid, mid + dir * 1.0, ColorF(1, 0.15, 0.1, 1))
  debugDrawer:drawTextAdvanced(mid + dir * 1.1, String(L('nupjaunama')), ColorF(1, 1, 1, 1), true, false, ColorI(160, 20, 10, 200))
end

S.drawCutSection = function(player)
  if not player then imText('Isek i masina.') return end
  local info = S.cutInfo(player)
  if not info then imText('Nepavyko nuskaityti masinos.') return end
  local id = player:getID()
  local current = getPA(id).cut
  local length = math.max(0.5, info.hi.y - info.lo.y)
  S.cutPosPtr = S.cutPosPtr or im.FloatPtr(0)
  S.cutShowPtr = S.cutShowPtr or im.BoolPtr(true)
  -- the car's own cut when switching cars, else the middle
  if S.cutLoadedFor ~= id then
    S.cutLoadedFor = id
    if type(current) == 'table' and tonumber(current.y) then
      S.cutPosPtr[0] = tonumber(current.y) - info.lo.y
      S.cutKeepFront = current.keep ~= 'rear'
    else
      S.cutPosPtr[0] = length * 0.5
      S.cutKeepFront = true
    end
  end

  im.TextColored(im.ImVec4(1, 0.75, 0.2, 1), L('EKSPERIMENTINE funkcija: gali glitchinti, issisaugok masina pries pjaudamas.'))
  imText('Nupjauk dali savo masinos: kas uz plokstumos, nuimama (ratai, sijos, detales).')
  imText('Per pjuvi einantys modeliai perpjaunami tikrai (pirmas pjuvis uztrunka sekunde). Pridetos detales ir pakeistos pakabos lieka.')
  sliderRow('Pjovimo vieta nuo priekio (m)', S.cutPosPtr, 0.05, 0, length, '%.2f')
  S.cutPosPtr[0] = math.max(0, math.min(length, S.cutPosPtr[0]))
  imText(string.format('Masinos ilgis: %.2f m', length))
  local frontButton = S.cutKeepFront and S.primaryButton or im.Button
  if frontButton('Palikti PRIEKI##cutfront', im.ImVec2(0, 0)) then S.cutKeepFront = true end
  im.SameLine()
  local rearButton = S.cutKeepFront and im.Button or S.primaryButton
  if rearButton('Palikti GALA##cutrear', im.ImVec2(0, 0)) then S.cutKeepFront = false end
  im.Checkbox('Rodyti pjovimo plokstuma', S.cutShowPtr)
  if S.cutShowPtr[0] then S.drawCutPlane(player, info, info.lo.y + S.cutPosPtr[0], S.cutKeepFront) end

  if S.primaryButton('PJAUTI##cutapply', im.ImVec2(-1, 0)) then
    local y, keep, at = info.lo.y + S.cutPosPtr[0], S.cutKeepFront and 'front' or 'rear', S.cutPosPtr[0]
    -- the models across the plane, cut for real (reads the car's model file: a second or two)
    local okB, meshes, summary, meshDir = pcall(S.buildCutMeshes, player, y, keep ~= 'rear')
    if not okB then
      log('E', logTag, 'car cutter: cutting the models failed: ' .. tostring(meshes))
      meshes, summary = {}, 'failed'
    end
    log('I', logTag, 'car cutter: ' .. tostring(summary))
    local spec = {y = y, keep = keep, meshes = meshes, meshDir = okB and meshDir or nil}
    -- the respawn comes in place: stand the car up first (a cut half tipped onto its cut end would
    -- spawn into the ground)
    local fwd = vec3(player:getDirectionVector())
    fwd.z = 0
    if fwd:length() > 1e-3 then
      local pos = player:getPosition()
      local rot = quatFromDir(fwd:normalized(), vec3(0, 0, 1))
      player:setPositionRotation(pos.x, pos.y, pos.z + 0.2, rot.x, rot.y, rot.z, rot.w)
    end
    if respawnWithConfig(player, function(cfg) cfg.partAttacherExp.cut = spec end) then
      msg(string.format('Masina nupjauta %.2f m nuo priekio, lieka %s.', at, keep == 'rear' and 'galas' or 'priekis'), 6)
    end
  end
  if type(current) == 'table' and tonumber(current.y) then
    imText(string.format('Dabar nupjauta %.2f m nuo priekio, liko %s.', tonumber(current.y) - info.lo.y, current.keep == 'rear' and 'galas' or 'priekis'))
    if im.Button('Atkurti visa masina##cutundo', im.ImVec2(-1, 0)) then
      if respawnWithConfig(player, function(cfg) cfg.partAttacherExp.cut = nil end) then msg('Masina vel visa.', 5) end
    end
  end
  imText('Prie pjuvio gali prideti kitos masinos pakaba (Detale, pakabos aplankas) ar detales.')
  imText('Kitos masinos puse prie pjuvio - kitame zingsnyje.')
end

-- section 8, front end swap: pick the donor car, tick its front parts, spawn them as one preview
S.feSearchPtr = im.ArrayChar(64)
S.feRemovePtr = im.BoolPtr(true)
S.feAutoScalePtr = im.BoolPtr(true)
S.drawFrontSection = function(player)
  if not player then imText('Isek i masina.') return end
  if not S.modelList then loadModelList() end
  if im.BeginCombo('Masina (donoras)##femodel', S.feModel or 'pasirink modeli...') then
    im.InputText('Paieska##femodels', S.feSearchPtr, 64)
    local ms = ffi.string(S.feSearchPtr):lower()
    for _, m in ipairs(S.modelList) do
      if (ms ~= '' and m.label:lower():find(ms, 1, true)) or (ms == '' and m.group == 'drive') then
        if im.Selectable1(m.label .. '##fe' .. m.key, m.key == S.feModel) then S.feModel = m.key end
      end
    end
    im.EndCombo()
  end
  if not S.feModel then
    imText('Pasirink masina, kurios prieki nori.')
    return
  end
  -- its front end parts, found once per model (all ticked)
  if not (S.feParts and S.feParts.model == S.feModel) then
    local okF, list = pcall(S.findFrontParts, S.feModel)
    if not okF then log('E', logTag, 'front end parts of ' .. tostring(S.feModel) .. ': ' .. tostring(list)) end
    S.feParts = {model = S.feModel, list = okF and list or {}, on = {}}
    for i = 1, #S.feParts.list do S.feParts.on[i] = im.BoolPtr(true) end
  end
  local list = S.feParts.list
  if #list == 0 then
    imText('Sios masinos priekio detaliu nerasta.')
    return
  end
  imText(string.format('Priekio detales (%d) - nuimk varneles, ko nereikia:', #list))
  if im.BeginChild1('##feparts', im.ImVec2(0, 200), true) then
    for i, p in ipairs(list) do
      ui_imgui.Checkbox(string.format('%s  (%s)##fepart%d', tostring(p.desc), tostring(p.name), i), S.feParts.on[i])
    end
  end
  im.EndChild()
  im.Checkbox('Nuimti savo masinos priekio detales', S.feRemovePtr)
  if im.IsItemHovered() then im.SetTooltip('Tavo buferis, sparnai, kapotas, zibintai, groteles nuimami (Parts meniu), kai prieki pritvirtini; nuemus prieki - grizta.') end
  im.Checkbox('Auto dydis (pagal tavo masinos ploti)', S.feAutoScalePtr)
  if S.primaryButton('SPAWN FRONT END##fespawn', im.ImVec2(-1, 0)) then
    local picked = {}
    for i, p in ipairs(list) do
      if S.feParts.on[i][0] then picked[#picked + 1] = p end
    end
    S.spawnFrontEnd(player, S.feModel, picked, S.feRemovePtr[0], S.feAutoScalePtr[0])
  end
  imText('Atsiras visas priekis kaip viena perziura - Detale korteleje pastumdyk (X/Y/Z),')
  imText('pakeisk dydi ir spausk PRITVIRTINTI. Idiegta korteleje ji galima perkelti ar nuimti.')
end

-- the window's tabs: id, tab label, the old section title shown on top of it. The part tab holds
-- sections 1 and 2 (picking and placing a part), so a new preview needs no other tab
S.tabs = {
  {id = 'part', label = 'Detale'},
  {id = 'inst', label = 'Idiegta', title = '3. Idiegtos detales'},
  {id = 'dt', label = 'Pavaros', title = '4. Universalios pavaros (kardanas / diferencialai / pusasiai)'},
  {id = 'susp', label = 'Pakaba', title = '5. Pakaba (logic): prosvaisa, spyruokles, amortizatoriai'},
  {id = 'safe', label = 'Elektronika', title = '6. Saugos elektronika (ABS, TC, ESC, 2-step, line lock)'},
  {id = 'cut', label = 'Pjovimas', title = '7. Masinos pjovimas (experimental)'},
  {id = 'front', label = 'Priekis', title = '8. Priekio swap: visas kitos masinos priekis'},
}

local function drawWindow()
  if not showWindow[0] then return end
  if placeWindow then
    -- the saved position can be off screen (e.g. after the game window was tiny), so every time the
    -- window opens it goes to the top left of the screen, expanded, with a size that fits
    placeWindow = false
    local vp = im.GetMainViewport()
    local x, y, w, h = 40, 60, 1280, 720
    if vp then
      x, y = vp.WorkPos.x + 40, vp.WorkPos.y + 60
      w, h = vp.WorkSize.x, vp.WorkSize.y
    end
    im.SetNextWindowPos(im.ImVec2(x, y), im.Cond_Always)
    im.SetNextWindowCollapsed(false, im.Cond_Always)
    im.SetNextWindowSize(im.ImVec2(math.min(560, w - 80), math.min(780, h - 100)), im.Cond_Always)
  end
  local pushedColors, pushedVars = S.pushTheme()
  local function content()
    -- header: name and version, the author credit, an accent line under it
    im.SetWindowFontScale(1.45)
    ui_imgui.Text('Part Attacher Experimental')
    im.SetWindowFontScale(1.0)
    im.SameLine()
    im.TextColored(im.ImVec4(0.6, 0.6, 0.63, 1), S.version)
    im.SetWindowFontScale(1.15)
    im.TextColored(im.ImVec4(1.0, 0.78, 0.22, 1.0), 'Mod author: Kavencki - Giedrius P.')
    im.SetWindowFontScale(1.0)
    im.PushStyleColor2(im.Col_Separator, im.ImVec4(S.accent[1], S.accent[2], S.accent[3], 0.9))
    im.Separator()
    im.PopStyleColor(1)
    local player = getPlayerVehicle(0)
    im.TextColored(im.ImVec4(0.7, 0.7, 0.73, 1), 'Masina: ' .. (player and (player.jbeam or '?') .. ' #' .. player:getID() or 'nera'))

    -- what the tabs hold, with counts where it helps (previews open, parts / swaps on the car)
    local previews = 0
    for _, _ in pairs(entries) do previews = previews + 1 end
    local installed = 0
    if player then
      local pa = getPA(player:getID())
      installed = #(type(pa.extraParts) == 'table' and pa.extraParts or {})
      for _, key in ipairs({'engineSwap', 'gearboxSwap', 'fiSwap', 'radiatorSwap'}) do
        if type(pa[key]) == 'table' then installed = installed + 1 end
      end
      for _, _ in pairs(type(pa.partSwaps) == 'table' and pa.partSwaps or {}) do installed = installed + 1 end
    end
    local counts = {part = previews, inst = installed}
    local request = S.tabRequest -- a tab asked for this frame (a new preview, Move...)
    S.tabRequest = nil
    local draws = {
      part = function()
        -- a preview being placed comes first: its position and mounting right where it was spawned
        if previews > 0 then
          -- just spawned: scroll up so its controls are in view, not the part list below
          if request == 'part' then im.SetScrollY(0) end
          ui_imgui.SeparatorText(L('2. Pozicija ir tvirtinimas'))
          drawGhostSection()
        end
        ui_imgui.SeparatorText(L('1. Pasirinkti detale'))
        drawSpawnSection(player)
      end,
      inst = function() drawInstalledSection(player) end,
      dt = function() drawDrivetrainSection(player) end,
      susp = function() drawSuspSection(player) end,
      safe = function() S.drawSafetySection(player) end,
      cut = function() S.drawCutSection(player) end,
      front = function() S.drawFrontSection(player) end,
    }
    if im.BeginTabBar('##partAttacherExpTabs', im.TabBarFlags_FittingPolicyResizeDown) then
      for _, t in ipairs(S.tabs) do
        local label = L(t.label) .. ((counts[t.id] or 0) > 0 and string.format(' (%d)', counts[t.id]) or '') .. '###patab_' .. t.id
        if ui_imgui.BeginTabItem(label, nil, request == t.id and im.TabItemFlags_SetSelected or 0) then
          if t.title then ui_imgui.SeparatorText(L(t.title)) end
          draws[t.id]()
          ui_imgui.EndTabItem()
        end
      end
      ui_imgui.EndTabBar()
    end

    -- the copyright and the language, at the very bottom (labels in both languages)
    ui_imgui.Separator()
    im.TextColored(im.ImVec4(0.5, 0.5, 0.53, 1), string.format('Part Attacher Experimental %s (c) 2026 Kavencki. Visos teises saugomos.', S.version))
    ui_imgui.Text('Language / Kalba:')
    for _, lang in ipairs({{'en', 'English'}, {'lt', 'Lietuviu'}}) do
      ui_imgui.SameLine()
      local active = S.lang == lang[1]
      if active then
        im.PushStyleColor2(im.Col_Button, im.ImVec4(S.accent[1], S.accent[2], S.accent[3], 0.88))
        im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 1, 1, 1))
      end
      if ui_imgui.SmallButton(lang[2] .. '##lang_' .. lang[1]) then S.setLanguage(lang[1]) end
      if active then im.PopStyleColor(2) end
    end
  end
  -- "###" keeps the window id the same whatever the title says. A Lua error in the content must not
  -- leave the window open or the theme pushed (ImGui's stacks would be out of balance)
  if im.Begin('Part Attacher Experimental by Kavencki - Giedrius P.###partAttacherExpWindow', showWindow) then
    local ok, err = pcall(content)
    if not ok and err ~= S.lastWindowError then
      S.lastWindowError = err
      log('E', logTag, 'window: ' .. tostring(err))
    end
  end
  im.End()
  im.PopStyleVar(pushedVars)
  im.PopStyleColor(pushedColors)
end

--------------------------------------------------------------------------------
-- update loop
--------------------------------------------------------------------------------

local function updateEntry(e, dt)
  local ghost = getVeh(e.id)
  if not ghost then entries[e.id] = nil return end
  local target = getVeh(e.targetId)
  e.stateTimer = (e.stateTimer or 0) + dt

  if e.state == 'loading' then
    local res = initEntry(e, ghost)
    if res == 'empty' and e.stateTimer < 3 then
      return -- physics may not be up yet
    elseif res == 'empty' then
      msg('Si detale neturi savo mazgu (nodes) - ji tik vizuali ir negali buti atskira. Pasirink kita.', 8)
      deleteEntry(e)
    elseif res then
      if e.placeOnRoof then
        putOnRoof(e)
        e.placeOnRoof = nil
      end
      e.state = 'ready'
    elseif e.stateTimer > 15 then
      msg('Detale nepasikrove.', 6)
      deleteEntry(e)
    end
    return
  end

  if target and getVData(e.targetId) ~= e.targetVData then
    if target:getNodeCount() == 0 or not getVData(e.targetId) then return end -- still respawning
    if not setupTarget(e, target) then return end
  end
  if e.hold and target and e.tA then holdGhost(e, ghost, target) end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  for _, e in pairs(entries) do
    local ok, err = pcall(updateEntry, e, dtReal)
    if not ok then
      log('E', logTag, 'update failed for ghost #' .. tostring(e.id) .. ': ' .. tostring(err))
      e.hold = false
    end
  end
  drawWindow()
end

--------------------------------------------------------------------------------
-- hooks
--------------------------------------------------------------------------------

-- car cutter (experimental). The models: a mesh across the cut plane is cut for real - the car's
-- Collada file is read, the mesh's triangles beyond the plane go, the ones across it are clipped,
-- and the cut mesh is written as a small Collada file next to the car's own (its spawn finds it
-- there). A mesh lives in the car's jbeam space (meshes bind to the nodes by position), moved by
-- its flexbody pos / scale and its node's matrix. Returns the text of that file, or nil and why.
S.cutMeshPrefix = 'partattacherexp_cut_' -- the first version wrote its cut meshes into the car's folder under this name
S.cutMeshRoot = '/settings/partAttacherExp/cutmeshes/'

S.cutDaeMesh = function(text, mesh, newName, y0, keepFront, posY, scaleY)
  local esc = mesh:gsub('%p', '%%%0')
  local gs = text:find('<geometry id="[^"]*" name="' .. esc .. '">')
  if not gs then return nil, 'no geometry' end
  local ge = text:find('</geometry>', gs, true)
  if not ge then return nil, 'broken geometry' end
  local geom = text:sub(gs, ge + 10)
  -- the node that places the mesh: its matrix and its materials
  local matrix, bind = '1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1', nil
  local ns = text:find('<node id="[^"]*" name="' .. esc .. '"')
  if ns then
    local ne = text:find('</node>', ns, true)
    local node = ne and text:sub(ns, ne) or ''
    matrix = node:match('<matrix[^>]*>([^<]*)</matrix>') or matrix
    bind = node:match('<bind_material>.-</bind_material>')
  end
  local m = {}
  for v in matrix:gmatch('%S+') do m[#m + 1] = tonumber(v) or 0 end
  if #m < 12 then m = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0} end

  local sources = {}
  for src in geom:gmatch('<source .-</source>') do
    local id = src:match('<source id="([^"]*)"')
    local arr = src:match('<float_array id="[^"]*" count="%d+">([^<]*)</float_array>')
    if id and arr then
      local values = {}
      for v in arr:gmatch('%S+') do values[#values + 1] = tonumber(v) or 0 end
      sources[id] = {id = id, text = src, values = values, stride = tonumber(src:match('stride="(%d+)"')) or 1}
    end
  end
  local vertsId, vertsBody = geom:match('<vertices id="([^"]*)">(.-)</vertices>')
  local vertSources, posSource = {}, nil
  for sem, srcId in (vertsBody or ''):gmatch('<input semantic="(%w+)" source="#([^"]*)"') do
    if sources[srcId] then vertSources[#vertSources + 1] = {sem = sem, src = sources[srcId]} end
    if sem == 'POSITION' then posSource = sources[srcId] end
  end
  if not (vertsId and posSource) then return nil, 'no positions' end

  local function countOf(s) return math.floor(#s.values / s.stride) end
  -- a new corner between two old ones: every source read at that offset gets the blended value
  local function lerpIndex(group, i, j, t)
    local idx = 0
    for _, g in ipairs(group) do idx = math.max(idx, countOf(g.src)) end
    for _, g in ipairs(group) do
      local s, st = g.src, g.src.stride
      while countOf(s) < idx do
        for _ = 1, st do s.values[#s.values + 1] = 0 end
      end
      local base = #s.values
      for c = 1, st do
        local a, b = s.values[i * st + c] or 0, s.values[j * st + c] or 0
        s.values[base + c] = a + (b - a) * t
      end
      if g.sem == 'NORMAL' and st == 3 then
        local x, y, z = s.values[base + 1], s.values[base + 2], s.values[base + 3]
        local l = math.sqrt(x * x + y * y + z * z)
        if l > 1e-9 then s.values[base + 1], s.values[base + 2], s.values[base + 3] = x / l, y / l, z / l end
      end
    end
    return idx
  end
  -- how far a position lies beyond the plane (> 0: it goes)
  local pv = posSource.values
  local function side(i)
    local x, y, z = pv[i * 3 + 1] or 0, pv[i * 3 + 2] or 0, pv[i * 3 + 3] or 0
    local vy = (m[5] * x + m[6] * y + m[7] * z + m[8]) * scaleY + posY
    if keepFront then return vy - y0 end
    return y0 - vy
  end

  local prims, materials, total = {}, {}, 0
  for _, kind in ipairs({'triangles', 'polylist'}) do
    for attrs, body in geom:gmatch('<' .. kind .. '([^>]*)>(.-)</' .. kind .. '>') do
      local material = attrs:match('material="([^"]*)"') or ''
      local inputs, tags, maxOff, vOff = {}, {}, 0, nil
      for tag in body:gmatch('<input [^>]*/>') do
        local inp = {sem = tag:match('semantic="(%w+)"'), srcId = tag:match('source="#([^"]*)"'), off = tonumber(tag:match('offset="(%d+)"')) or 0}
        inputs[#inputs + 1] = inp
        tags[#tags + 1] = tag
        maxOff = math.max(maxOff, inp.off)
        if inp.sem == 'VERTEX' then vOff = inp.off end
      end
      if vOff then
        local stride = maxOff + 1
        local groups = {}
        for _, inp in ipairs(inputs) do
          groups[inp.off] = groups[inp.off] or {}
          if inp.sem == 'VERTEX' then
            for _, vs in ipairs(vertSources) do table.insert(groups[inp.off], vs) end
          elseif sources[inp.srcId] then
            table.insert(groups[inp.off], {sem = inp.sem, src = sources[inp.srcId]})
          end
        end
        local vcount
        local vc = body:match('<vcount>([^<]*)</vcount>')
        if vc then
          vcount = {}
          for v in vc:gmatch('%d+') do vcount[#vcount + 1] = tonumber(v) end
        end
        local p = {}
        for v in (body:match('<p>([^<]*)</p>') or ''):gmatch('%d+') do p[#p + 1] = tonumber(v) end
        local out, tris, at = {}, 0, 1
        local polys = vcount and #vcount or math.floor(#p / (3 * stride))
        for poly = 1, polys do
          local n = vcount and vcount[poly] or 3
          local corners, inside, outside = {}, 0, 0
          for c = 1, n do
            local idx = {}
            for o = 0, stride - 1 do idx[o] = p[at + o] or 0 end
            at = at + stride
            local d = side(idx[vOff])
            corners[c] = {idx = idx, d = d}
            if d <= 0 then inside = inside + 1 else outside = outside + 1 end
          end
          local keep = corners
          if outside == n then
            keep = {}
          elseif outside > 0 then
            -- Sutherland-Hodgman against the plane
            keep = {}
            for c = 1, n do
              local a, b = corners[c], corners[c % n + 1]
              local ain, bin = a.d <= 0, b.d <= 0
              if ain then keep[#keep + 1] = a end
              if ain ~= bin then
                local t = a.d / (a.d - b.d)
                local idx = {}
                for o = 0, stride - 1 do
                  if a.idx[o] == b.idx[o] or not groups[o] then idx[o] = a.idx[o]
                  else idx[o] = lerpIndex(groups[o], a.idx[o], b.idx[o], t) end
                end
                keep[#keep + 1] = {idx = idx, d = 0}
              end
            end
          end
          for k = 2, #keep - 1 do
            for _, c in ipairs({keep[1], keep[k], keep[k + 1]}) do
              for o = 0, stride - 1 do out[#out + 1] = c.idx[o] end
            end
            tris = tris + 1
          end
        end
        if tris > 0 then
          prims[#prims + 1] = string.format('<triangles material="%s" count="%d">%s<p>%s</p></triangles>', material, tris, table.concat(tags), table.concat(out, ' '))
          materials[material] = true
          total = total + tris
        end
      end
    end
  end
  if total == 0 then return nil, 'empty' end

  local parts = {}
  for _, s in pairs(sources) do
    local nums = {}
    for i, v in ipairs(s.values) do nums[i] = string.format('%.6g', v) end
    local count = #s.values
    local txt = s.text:gsub('(<float_array id="[^"]*" count=")%d+(">)[^<]*(</float_array>)', function(a, b, c) return a .. count .. b .. table.concat(nums, ' ') .. c end)
    txt = txt:gsub('(<accessor [^>]*count=")%d+(")', function(a, b) return a .. math.floor(count / s.stride) .. b end)
    parts[#parts + 1] = txt
  end
  if not bind then
    local list = {}
    for mat, _ in pairs(materials) do list[#list + 1] = string.format('<instance_material symbol="%s" target="#%s"/>', mat, mat) end
    bind = '<bind_material><technique_common>' .. table.concat(list) .. '</technique_common></bind_material>'
  end
  local function block(tag)
    return text:match('<' .. tag .. '>.-</' .. tag .. '>') or ''
  end
  return table.concat({
    '<?xml version="1.0" encoding="utf-8"?>\n',
    '<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">\n',
    block('asset'), '\n', block('library_effects'), '\n', block('library_images'), '\n', block('library_materials'), '\n',
    '<library_geometries><geometry id="', newName, '-mesh" name="', newName, '"><mesh>\n',
    table.concat(parts, '\n'), '\n<vertices id="', vertsId, '">', vertsBody, '</vertices>\n', table.concat(prims, '\n'),
    '\n</mesh></geometry></library_geometries>\n',
    '<library_visual_scenes><visual_scene id="Scene" name="Scene"><node id="', newName, '" name="', newName, '" type="NODE">',
    '<matrix sid="transform">', matrix, '</matrix><instance_geometry url="#', newName, '-mesh" name="', newName, '">', bind,
    '</instance_geometry></node></visual_scene></library_visual_scenes>\n',
    '<scene><instance_visual_scene url="#Scene"/></scene>\n</COLLADA>\n',
  })
end

-- the meshes of the car (the spawned one) across a cut at jbeam y0, cut and written once (a file
-- per mesh and cut position, reused after that). Returns {original mesh = cut mesh name, or false
-- when nothing of it stays} and a summary.
S.buildCutMeshes = function(veh, y0, keepFront)
  local vd = getVData(veh:getID())
  if not (vd and type(vd.flexbodies) == 'table' and type(vd.nodes) == 'table') then return {}, 'no vehicle data' end
  local function own(cid)
    local nd = vd.nodes[cid]
    local name = type(nd) == 'table' and nd.name
    return nd ~= nil and not (type(name) == 'string' and (name:find('^upa%d+_') or name:find('^ups%w+_')))
  end
  local wanted, order = {}, {}
  for _, fb in pairs(vd.flexbodies) do
    -- the jbeam name: the game may rename a loaded mesh (originalMesh), a cut keeps it in upaOrigMesh
    local mesh = type(fb) == 'table' and (fb.upaOrigMesh or fb.originalMesh or fb.mesh)
    local nodes = type(fb) == 'table' and (fb.upaGroupNodes or fb._group_nodes)
    if type(mesh) == 'string' and type(nodes) == 'table' and not wanted[mesh] then
      local ownCount, beyondCount = 0, 0
      for _, cid in ipairs(nodes) do
        if own(cid) then
          ownCount = ownCount + 1
          local p = veh:getInitialNodePosition(cid)
          if (keepFront and p.y > y0) or (not keepFront and p.y < y0) then beyondCount = beyondCount + 1 end
        end
      end
      local r = type(fb.rot) == 'table' and fb.rot or {}
      local rotated = math.abs(tonumber(r.x) or 0) + math.abs(tonumber(r.y) or 0) + math.abs(tonumber(r.z) or 0) > 0.01
      if beyondCount > 0 and beyondCount < ownCount and not rotated then
        local pos, scale = type(fb.pos) == 'table' and fb.pos or {}, type(fb.scale) == 'table' and fb.scale or {}
        local sy = tonumber(scale.y) or 1
        wanted[mesh] = {posY = tonumber(pos.y) or 0, scaleY = math.abs(sy) > 1e-6 and sy or 1}
        order[#order + 1] = mesh
      end
    end
  end
  if #order == 0 then return {}, 'no mesh crosses the cut' end

  local dir = type(vd.vehicleDirectory) == 'string' and vd.vehicleDirectory or ('/vehicles/' .. tostring(veh.jbeam) .. '/')
  if dir:sub(-1) ~= '/' then dir = dir .. '/' end
  local files = FS:findFiles(dir, '*.dae', -1, true, false) or {}
  -- the car's own files before its sub folders (a 3-wheel or trailer variant may name a mesh alike)
  local function depth(p) return select(2, p:gsub('/', '')) end
  table.sort(files, function(a, b)
    if depth(a) ~= depth(b) then return depth(a) < depth(b) end
    return a < b
  end)
  -- the cut meshes go to a folder of their own per car and cut, outside the car's folder: a new
  -- mesh file in a vehicle's own folder makes the game reload that vehicle a second later (in
  -- whatever pose it is then - a cut half tipped onto its cut end spawned into the ground and blew
  -- up). The car finds them through that folder added to its search path (S.applyCut).
  local model = dir:match('/vehicles/([^/]+)/') or tostring(veh.jbeam)
  local cutTag = string.format('%s%d', keepFront and 'f' or 'r', math.floor(y0 * 1000 + 0.5)):gsub('%-', 'm')
  local outDir = S.cutMeshRoot .. model .. '/' .. cutTag .. '/'
  local result, made, reused, empty, left = {}, 0, 0, 0, #order
  for _, path in ipairs(files) do
    if left == 0 then break end
    if not path:find(S.cutMeshPrefix, 1, true) then
      local text = readFile(path)
      for _, mesh in ipairs(order) do
        local w = wanted[mesh]
        if type(text) == 'string' and not w.done and text:find('<geometry id="[^"]*" name="' .. mesh:gsub('%p', '%%%0') .. '">') then
          w.done, left = true, left - 1
          local plane = (y0 - w.posY) / w.scaleY
          local tag = string.format('%s%d', keepFront and 'f' or 'r', math.floor(plane * 1000 + 0.5)):gsub('%-', 'm')
          local newName = mesh .. '_upacut_' .. tag
          local outPath = outDir .. newName .. '.dae'
          if FS:fileExists(outPath) then
            result[mesh] = newName
            reused = reused + 1
          else
            local okC, dae, why = pcall(S.cutDaeMesh, text, mesh, newName, y0, keepFront, w.posY, w.scaleY)
            if okC and dae then
              if not FS:directoryExists(outDir) then FS:directoryCreate(outDir, true) end
              writeFile(outPath, dae)
              if FS:fileExists(outPath) then
                result[mesh] = newName
                made = made + 1
              else
                log('W', logTag, 'car cutter: could not write ' .. outPath)
              end
            elseif okC and why == 'empty' then
              result[mesh] = false
              empty = empty + 1
            else
              log('W', logTag, string.format('car cutter: mesh %s not cut (%s)', mesh, tostring(okC and why or dae)))
            end
          end
        end
      end
      text = nil
    end
  end
  return result, string.format('%d meshes across the cut: %d cut now, %d reused, %d fully beyond, %d not found in %s (cut meshes in %s)', #order, made, reused, empty, left, dir, outDir), outDir
end

-- The structure: the car's own nodes beyond the plane leave it. The node and wheel lists must stay
-- gap-free, so those nodes stay as light holders (no collision, 0.1 kg: too light to be welded to)
-- that ride along on soft beams; their own beams stop pulling, their triangles stop colliding, their
-- wheels go. A mesh across the cut is swapped for its cut version (S.buildCutMeshes) bound to the
-- kept nodes only; one not cut stays whole, carried by the holders, unless it is mostly beyond.
-- Added parts and swapped suspensions are not the car's own: they stay wherever they are.

S.applyCut = function(vehicle, cut, marker)
  local y0 = tonumber(cut.y)
  if not y0 or type(vehicle.nodes) ~= 'table' then return 'no cut position' end
  -- the folder holding this cut's meshes, on the search path the meshes are looked up in
  if type(cut.meshDir) == 'string' and type(vehicle.directoriesLoaded) == 'table' then
    local have = false
    for _, d in ipairs(vehicle.directoriesLoaded) do
      if d == cut.meshDir then have = true end
    end
    if not have then table.insert(vehicle.directoriesLoaded, cut.meshDir) end
  end
  local keepFront = cut.keep ~= 'rear'
  -- jbeam: -Y is the front
  local function beyond(p) if keepFront then return p.y > y0 else return p.y < y0 end end
  local swapPrefixes = {}
  for kind, _ in pairs(type(marker.partSwaps) == 'table' and marker.partSwaps or {}) do swapPrefixes[#swapPrefixes + 1] = partSwapPrefix(kind) end
  local function ownNode(n)
    if type(n.name) ~= 'string' then return true end
    if n.name:find('^upa%d+_') then return false end
    if type(n.partOrigin) == 'string' and n.partOrigin:sub(1, 9) == 'upa_swap_' then return false end
    for _, p in ipairs(swapPrefixes) do
      if n.name:sub(1, #p) == p then return false end
    end
    return true
  end
  local defaultMass = tonumber(type(vehicle.options) == 'table' and vehicle.options.nodeWeight) or 25

  -- a wheel goes (or stays) whole, by its hub's side: a cut through a tyre keeps the tyre round
  local wheels = type(vehicle.wheels) == 'table' and vehicle.wheels or {}
  local wheelCount = tableSizeC(wheels)
  local wheelGone, wheelsGone = {}, 0
  for k = 0, wheelCount - 1 do
    local w = wheels[k]
    local n1 = type(w) == 'table' and vehicle.nodes[w.node1]
    local n2 = type(w) == 'table' and vehicle.nodes[w.node2]
    if n1 and n2 and ownNode(n1) and ownNode(n2) and beyond((n1.pos + n2.pos) * 0.5) then
      wheelGone[k] = true
      wheelsGone = wheelsGone + 1
    end
  end
  local removed, removedCount, keptCount = {}, 0, 0
  for cid, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and ownNode(n) then
      local gone
      if n.wheelID ~= nil and wheels[n.wheelID] then gone = wheelGone[n.wheelID] == true else gone = beyond(n.pos) end
      if gone then
        removed[cid] = n
        removedCount = removedCount + 1
      else
        keptCount = keptCount + 1
      end
    end
  end
  if removedCount == 0 then return 'nothing of the car is beyond the cut' end
  if keptCount == 0 then return 'nothing of the car would stay' end
  -- a kept node whose beams all went beyond the cut would hang free (fall, fly off): a holder too
  local tied = {}
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and b.id1 ~= b.id2 and not removed[b.id1] and not removed[b.id2] then
      tied[b.id1], tied[b.id2] = true, true
    end
  end
  local orphans = 0
  for cid, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and not removed[cid] and not tied[cid] and ownNode(n) and n.wheelID == nil then
      removed[cid] = n
      removedCount, keptCount, orphans = removedCount + 1, keptCount - 1, orphans + 1
    end
  end

  -- the kept nodes at the cut the holders hang on: within 50 cm of the plane, at least 24 (the
  -- holders' load spreads over them)
  local kept = {}
  for cid, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and not removed[cid] and ownNode(n) and n.wheelID == nil
      and (tonumber(n.nodeWeight) or defaultMass) >= 1 then
      kept[#kept + 1] = n
    end
  end
  table.sort(kept, function(a, b) return math.abs(a.pos.y - y0) < math.abs(b.pos.y - y0) end)
  local anchors = {}
  for _, n in ipairs(kept) do
    if math.abs(n.pos.y - y0) > 0.5 and #anchors >= 24 then break end
    anchors[#anchors + 1] = n
  end
  if #anchors < 3 then return 'too few nodes stay at the cut' end

  -- beams, triangles, torsion bars, rails and props on the removed side. A beam can't be deleted
  -- (beam ids must stay gap-free) and the physics never sees a beam type "broken" (setBeam takes
  -- the spring and damping whatever the type): a plain beam with no spring and no damping pulls on
  -- nothing. Bounded / pressured / anisotropic beams act through their own limits, so they become plain.
  local NONCOLLIDABLE = 2
  local beamsCut = 0
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and (removed[b.id1] or removed[b.id2]) then
      b.beamType = 0
      b.beamSpring, b.beamDamp = 0, 0
      b.beamStrength, b.beamDeform = math.huge, math.huge
      b.beamPrecompression, b.beamPrecompressionTime, b.precompressionRange = 1, nil, nil
      b.breakGroup, b.deformGroup, b.wheelID, b.deformationTriggerRatio = nil, nil, nil, nil
      b.beamLimitSpring, b.beamLimitDamp, b.springExpansion, b.dampExpansion = nil, nil, nil, nil
      beamsCut = beamsCut + 1
    end
  end
  for _, t in pairs(vehicle.triangles or {}) do
    if type(t) == 'table' and (removed[t.id1] or removed[t.id2] or removed[t.id3]) then
      t.triangleType = NONCOLLIDABLE
      t.pressureGroup, t.breakGroup = nil, nil
      t.dragCoef, t.liftCoef = 0, 0
    end
  end
  for _, sec in ipairs({'torsionbars', 'torsionHydros'}) do
    for _, tb in pairs(type(vehicle[sec]) == 'table' and vehicle[sec] or {}) do
      if type(tb) == 'table' and (removed[tb.id1] or removed[tb.id2] or removed[tb.id3] or removed[tb.id4]) then
        tb.spring, tb.spring2, tb.damp, tb.damp2 = 0, 0, 0, 0
        tb.precompressionTime, tb.precompressionAngle = nil, 0
      end
    end
  end
  for name, rail in pairs(type(vehicle.rails) == 'table' and vehicle.rails or {}) do
    local links = type(rail) == 'table' and rail['links:']
    if type(links) == 'table' then
      local keep = {}
      for _, cid in ipairs(links) do
        if not removed[cid] then keep[#keep + 1] = cid end
      end
      if #keep < 2 then vehicle.rails[name] = nil elseif #keep < #links then rail['links:'] = keep end
    end
  end
  for k, sn in pairs(type(vehicle.slidenodes) == 'table' and vehicle.slidenodes or {}) do
    if type(sn) == 'table' and (removed[sn.id] or (type(sn.railName) == 'string' and not (type(vehicle.rails) == 'table' and vehicle.rails[sn.railName]))) then
      vehicle.slidenodes[k] = nil
    end
  end
  local propsGone = 0
  for k, p in pairs(type(vehicle.props) == 'table' and vehicle.props or {}) do
    if type(p) == 'table' and (removed[tonumber(p.idRef)] or removed[tonumber(p.idX)] or removed[tonumber(p.idY)]) then
      vehicle.props[k] = nil
      propsGone = propsGone + 1
    end
  end
  -- meshes: one fully beyond the cut goes; one across it becomes its cut version (S.buildCutMeshes),
  -- bound to the kept nodes only; one that could not be cut stays whole on the holders, unless most
  -- of it is beyond (then it goes too). The original name and nodes stay on the flexbody, so the
  -- next cut starts from the whole mesh again.
  local cutMeshes = type(cut.meshes) == 'table' and cut.meshes or {}
  local dropShare = math.max(0.3, math.min(1, tonumber(cut.dropShare) or 0.6))
  local meshesGone, meshesCut = 0, 0
  for _, fb in pairs(type(vehicle.flexbodies) == 'table' and vehicle.flexbodies or {}) do
    local nodes = type(fb) == 'table' and fb._group_nodes
    if type(nodes) == 'table' and #nodes > 0 then
      local keptNodes = {}
      for _, cid in ipairs(nodes) do
        if not removed[cid] then keptNodes[#keptNodes + 1] = cid end
      end
      local cutNodes = #nodes - #keptNodes
      local swap = cutMeshes[fb.mesh]
      if cutNodes > 0 then
        fb.upaGroupNodes = nodes
        -- with fewer than 4 nodes left a mesh can't bind ("VY node not found"): it goes
        if #keptNodes < 4 or swap == false or (type(swap) ~= 'string' and cutNodes >= dropShare * #nodes) then
          fb._group_nodes = {}
          meshesGone = meshesGone + 1
        elseif type(swap) == 'string' then
          fb.upaOrigMesh, fb.mesh = fb.mesh, swap
          fb._group_nodes = keptNodes
          meshesCut = meshesCut + 1
        end
      end
    end
  end

  -- the wheel list without the gone wheels (the physics wants it gap-free), renumbered
  if wheelsGone > 0 then
    local remap, newWheels, nextId = {}, {}, 0
    for k = 0, wheelCount - 1 do
      local w = wheels[k]
      if w and not wheelGone[k] then
        remap[k] = nextId
        w.cid = nextId
        newWheels[nextId] = w
        nextId = nextId + 1
      end
    end
    vehicle.wheels = newWheels
    if type(vehicle.maxIDs) == 'table' then vehicle.maxIDs.wheels = nextId end
    for _, n in pairs(vehicle.nodes) do
      if type(n) == 'table' and n.wheelID ~= nil then
        n.wheelID = remap[n.wheelID]
        if n.wheelID == nil then n.pairedNode, n.pairedNode2 = nil, nil end
      end
    end
    for _, b in pairs(vehicle.beams or {}) do
      if type(b) == 'table' and b.wheelID ~= nil then b.wheelID = remap[b.wheelID] end
    end
    S.cutWheelsGone = true
  end

  -- an engine (or motor) whose torque reaction nodes were cut off pushes on kept nodes at the cut
  local trn = {anchors[1].cid, anchors[math.max(2, math.floor(#anchors / 2))].cid, anchors[#anchors].cid}
  for _, section in pairs(vehicle) do
    if type(section) == 'table' and type(section.torqueReactionNodes_nodes) == 'table' then
      for _, cid in pairs(section.torqueReactionNodes_nodes) do
        if removed[cid] then
          section.torqueReactionNodes_nodes = {trn[1], trn[2], trn[3]}
          break
        end
      end
    end
  end

  -- the vehicle's reference nodes (its orientation, the cameras) must be kept nodes
  local refs = type(vehicle.refNodes) == 'table' and vehicle.refNodes[0]
  if type(refs) == 'table' then
    local function nearestKept(pos, notCid)
      local best, bestD
      for _, n in ipairs(kept) do
        local d = n.pos:distance(pos)
        if n.cid ~= notCid and (not bestD or d < bestD) then best, bestD = n, d end
      end
      return best
    end
    -- ref -> back / left / up give the car its axes (direction, camera): a node standing in for a
    -- cut one must lie the same way from the new ref, or the axes fold and turn NaN. When any of
    -- them is cut off (or the ref is close to the cut), the set moves 0.6 m into the kept part.
    local refNode = vehicle.nodes[refs.ref]
    local inward = keepFront and -1 or 1
    if refNode and (removed[refs.ref] or removed[refs.back] or removed[refs.left] or removed[refs.up]
      or math.abs(refNode.pos.y - y0) < 0.5) then
      local origin = refNode.pos
      local spot = vec3(origin.x, y0 + inward * 0.6, origin.z)
      if math.abs(origin.y - y0) >= 0.6 and not beyond(origin) then spot = vec3(origin) end
      local newRef = nearestKept(spot)
      if newRef then
        local picked = {[newRef.cid] = true}
        for _, key in ipairs({'back', 'left', 'up'}) do
          local n = vehicle.nodes[refs[key]]
          if refs[key] == refs.ref then
            refs[key] = newRef.cid
          elseif n then
            local dir = (n.pos - origin)
            local want = math.max(0.3, math.min(1.0, dir:length()))
            dir = dir:normalized()
            -- the kept node best along that direction, 15 cm to 1.5 m away
            local best, bestScore
            for _, k in ipairs(kept) do
              if not picked[k.cid] then
                local off = k.pos - newRef.pos
                local len = off:length()
                if len >= 0.15 and len <= 1.5 then
                  local score = off:dot(dir) / len - 0.2 * math.abs(len - want)
                  if not bestScore or score > bestScore then best, bestScore = k, score end
                end
              end
            end
            if best and bestScore > 0.5 then
              refs[key] = best.cid
              picked[best.cid] = true
            end
          end
        end
        refs.ref = newRef.cid
        local function nodeName(cid) return tostring(vehicle.nodes[cid] and vehicle.nodes[cid].name or cid) end
        log('I', logTag, string.format('car cutter: reference nodes now ref %s, back %s, left %s, up %s',
          nodeName(refs.ref), nodeName(refs.back), nodeName(refs.left), nodeName(refs.up)))
      end
    end
    for key, cid in pairs(refs) do
      if type(cid) == 'number' and removed[cid] then
        local pick = nearestKept(removed[cid].pos)
        if pick then refs[key] = pick.cid end
      end
    end
  end

  -- the holders: light, no collision, riding along where they are on 3 soft beams each to nodes at
  -- the cut (no mesh is bent: a cut mesh doesn't use them, an uncut one stays whole on them)
  local holderMass = 0.1
  local links, perAnchor = {}, {}
  for cid, n in pairs(removed) do
    n.collision, n.selfCollision, n.staticCollision = false, false, false
    n.nodeWeight = holderMass
    n.couplerTag, n.tag, n.fixed = nil, nil, nil
    n.chemEnergy, n.flashPoint, n.isExhaust = nil, nil, nil
    n.upaCut = true
    -- of the 8 nearest nodes at the cut, the 3 least loaded so far: the load spreads out
    local near = {}
    for _, a in ipairs(anchors) do
      local d = a.pos:distance(n.pos)
      if d >= 0.05 then near[#near + 1] = {n = a, d = d} end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for m = #near, 9, -1 do near[m] = nil end
    table.sort(near, function(a, b)
      local la, lb = perAnchor[a.n.cid] or 0, perAnchor[b.n.cid] or 0
      if la ~= lb then return la < lb end
      return a.d < b.d
    end)
    for m = 1, math.min(3, #near) do
      local a = near[m].n
      links[#links + 1] = {cid = cid, holder = n, anchor = a}
      perAnchor[a.cid] = (perAnchor[a.cid] or 0) + 1
    end
  end
  -- soft, damped holder beams (a stiff light node rings): 3000 N/m, up to 15 Ns/m (0.1 kg on 3 of
  -- them: damping * dt / mass ~ 0.2). Many holders share a node at the cut, so what they add must
  -- also suit that node's mass at the 2 kHz step (omega * dt ~ 1.25, damping * dt / mass ~ 0.3 at most)
  local existing = {}
  for cid, _ in pairs(perAnchor) do existing[cid] = 0 end
  for _, b in pairs(vehicle.beams or {}) do
    local s = type(b) == 'table' and tonumber(b.beamSpring)
    if s and s > 0 and s < 1e9 then
      if existing[b.id1] then existing[b.id1] = existing[b.id1] + s end
      if existing[b.id2] then existing[b.id2] = existing[b.id2] + s end
    end
  end
  local omega2 = 2500 * 2500
  local anchorSpring, anchorDamp = {}, {}
  for cid, count in pairs(perAnchor) do
    local mass = math.max(0.5, tonumber(vehicle.nodes[cid].nodeWeight) or defaultMass)
    local budget = math.max(mass * omega2 - existing[cid], 0.2 * mass * omega2)
    anchorSpring[cid] = math.min(3000, budget / count)
    anchorDamp[cid] = math.min(15, 0.3 * mass / 0.0005 / count)
  end
  local holderBeams = 0
  for _, l in ipairs(links) do
    local bcid = vehicle.maxIDs.beams or 0
    vehicle.maxIDs.beams = bcid + 1
    vehicle.beams[bcid] = {
      cid = bcid, id1 = l.cid, id2 = l.anchor.cid, beamType = 0,
      beamSpring = anchorSpring[l.anchor.cid], beamDamp = anchorDamp[l.anchor.cid],
      beamDeform = math.huge, beamStrength = math.huge,
      partOrigin = l.holder.partOrigin,
    }
    holderBeams = holderBeams + 1
  end

  return string.format('%d nodes of the car beyond y %.2f (keeps the %s; %d left without beams) are holders now, %d beams let go, %d wheels and %d props taken off, %d meshes cut, %d meshes gone, %d holder beams (%d kept nodes at the cut)',
    removedCount, y0, keepFront and 'front' or 'rear', orphans, beamsCut, wheelsGone, propsGone, meshesCut, meshesGone, holderBeams, #anchors)
end

-- runs inside the jbeam loader for every vehicle
local function onJbeamLoadingPhase2(loadingProgress, objID, vehicle, unifyJournal, vehicleConfig, vars)
  if type(vehicle) ~= 'table' or type(vehicleConfig) ~= 'table' then return end
  local marker = vehicleConfig.partAttacherExp
  if type(marker) ~= 'table' then return end

  -- the donors' glowMap entries their parts' meshes need (else e.g. a brake disc has no texture)
  local okG, errG = pcall(S.addDonorGlowMaps, vehicle, marker)
  if not okG then log('E', logTag, 'adding the donor glow maps failed: ' .. tostring(errG)) end

  -- a slidenode on a rail the vehicle doesn't have would get rail id -1 and blow the physics up (a
  -- donor part's rail lives on the donor's frame; a preview has no frame at all)
  local lostRails = 0
  for k, sn in pairs(type(vehicle.slidenodes) == 'table' and vehicle.slidenodes or {}) do
    if type(sn) == 'table' and type(sn.railName) == 'string' and not (type(vehicle.rails) == 'table' and vehicle.rails[sn.railName]) then
      vehicle.slidenodes[k] = nil
      lostRails = lostRails + 1
    end
  end
  if lostRails > 0 and not marker.ghost then log('W', logTag, string.format('%d slidenodes on rails the vehicle does not have left out', lostRails)) end

  -- car cutter first: the parts and swaps welded below must not hang on what the cut takes off
  S.cutWheelsGone = nil
  if type(marker.cut) == 'table' and not marker.ghost then
    local okC, resC = pcall(S.applyCut, vehicle, marker.cut, marker)
    log(okC and 'I' or 'E', logTag, 'car cutter: ' .. tostring(resC))
  end

  -- ghost preview: collides with nothing but the ground
  if marker.ghost then
    -- a preview is only a picture: a gearbox alone has a torque converter / clutch without an engine
    -- in front of it, its powertrain fails and the vehicle Lua dies (the preview never shows)
    if not marker.keepPowertrain then
      vehicle.powertrain = nil
      vehicle.controller = nil
    end
    for _, n in pairs(vehicle.nodes or {}) do
      if type(n) == 'table' then
        n.collision = false
        n.staticCollision = true
        n.selfCollision = false
      end
    end
    for _, t in pairs(vehicle.triangles or {}) do
      if type(t) == 'table' then t.triangleType = 'NONCOLLIDABLE' end
    end
    -- suspension preview: every node glued to its 6 nearest, so arms and wheels hold still
    if marker.rigid and type(vehicle.nodes) == 'table' and type(vehicle.maxIDs) == 'table' then
      vehicle.beams = vehicle.beams or {}
      local list = {}
      for cid, n in pairs(vehicle.nodes) do
        if type(n) == 'table' and n.pos then list[#list + 1] = {cid = cid, pos = n.pos} end
      end
      local seen, glued = {}, 0
      for i, a in ipairs(list) do
        local near = {}
        for j, b in ipairs(list) do
          if j ~= i then
            local d = a.pos:distance(b.pos)
            if d > 0.01 then near[#near + 1] = {j = j, d = d} end
          end
        end
        table.sort(near, function(x, y) return x.d < y.d end)
        for m = 1, math.min(6, #near) do
          local j = near[m].j
          local key = math.min(i, j) .. ':' .. math.max(i, j)
          if not seen[key] then
            seen[key] = true
            -- soft enough for the lighter end (tyre nodes weigh a few hundred grams)
            local na, nb = vehicle.nodes[a.cid], vehicle.nodes[list[j].cid]
            local mass = math.max(0.1, math.min(tonumber(na.nodeWeight) or 5, tonumber(nb.nodeWeight) or 5))
            local bcid = vehicle.maxIDs.beams or 0
            vehicle.maxIDs.beams = bcid + 1
            vehicle.beams[bcid] = {cid = bcid, id1 = a.cid, id2 = list[j].cid, beamType = 0,
              beamSpring = math.min(300000, 100000 * mass), beamDamp = math.min(20, 15 * mass),
              beamDeform = math.huge, beamStrength = math.huge}
            glued = glued + 1
          end
        end
      end
      -- controllers (bypass shocks...) look for beams that hang on the missing frame
      vehicle.controller = nil
      log('I', logTag, string.format('suspension preview: %d glue beams keep it rigid', glued))
    end
  end

  -- merged parts: weld them to the body
  if type(vehicle.nodes) ~= 'table' or type(vehicle.maxIDs) ~= 'table' then return end
  local function isExtraName(n) return type(n.name) == 'string' and n.name:find('^upa%d+_') ~= nil end
  -- nodes of a swapped suspension (its tree, imported points, virtual frame) are never "body" for
  -- something else: the rear frame was getting welded to the swapped front suspension
  local swapPrefixes = {}
  for kind, _ in pairs(type(marker.partSwaps) == 'table' and marker.partSwaps or {}) do
    swapPrefixes[#swapPrefixes + 1] = partSwapPrefix(kind)
  end
  local function inAnySwap(n)
    if type(n.partOrigin) == 'string' and n.partOrigin:sub(1, 9) == 'upa_swap_' then return true end
    if type(n.name) ~= 'string' then return false end
    for _, p in ipairs(swapPrefixes) do
      if n.name:sub(1, #p) == p then return true end
    end
    return false
  end
  -- ...but a swapped suspension's own frame is rigid on the body (its virtual frame corners, the
  -- donor frame points it brought, its hooks and rail mounts): an added part may hang on it where
  -- the car's body is out of reach - a fifth wheel on the semi frame of a swapped semi axle. Never
  -- on its moving parts (axles, arms, wheels) or its mesh-only points.
  local swapStructure, structureCount = {}, 0
  for kind, spec in pairs(type(marker.partSwaps) == 'table' and marker.partSwaps or {}) do
    if type(spec) == 'table' and type(spec.frameNames) == 'table' and #spec.frameNames > 0 then
      local p = partSwapPrefix(kind)
      local visual = {}
      for _, name in ipairs(spec.visualNames or {}) do visual[name] = true end
      for _, list in ipairs({spec.frameNames, spec.mountNames or {}, spec.hookNames or {}, type(S.railHooks) == 'table' and S.railHooks[kind] or {}}) do
        for _, name in ipairs(list) do
          if type(name) == 'string' and not visual[name] and not swapStructure[p .. name] then
            swapStructure[p .. name] = true
            structureCount = structureCount + 1
          end
        end
      end
    end
  end

  if type(marker.extraParts) == 'table' then
    if structureCount > 0 then
      log('I', logTag, string.format('added parts can hang on %d frame points of the swapped suspension too, where the car\'s body is out of reach', structureCount))
    end
    for i, ex in ipairs(marker.extraParts) do
      local prefix = 'upa' .. i .. '_'
      local function isPart(n) return type(n.name) == 'string' and n.name:sub(1, #prefix) == prefix end
      -- the car's body first (weldEachToNearest takes its chassis when in reach), then a swapped
      -- suspension's frame and the parts added with physics (a part on top of another added part)
      local function isBody(n)
        if not isExtraName(n) and not inAnySwap(n) then return true end
        if type(n.name) ~= 'string' then return false end
        if swapStructure[n.name] then return true end
        local j = tonumber(n.name:match('^upa(%d+)_'))
        local other = j and j ~= i and marker.extraParts[j]
        return type(other) == 'table' and not other.meshOnly and not other.dataOnly
      end
      local ok, res
      if ex.dataOnly then
        -- no model, no nodes (an air compressor): only its devices and data, nothing to weld
        ok = true
        log('I', logTag, string.format('extra part %d (%s): data only (no model, no nodes)', i, tostring(ex.part)))
      elseif ex.meshOnly then
        -- only a model: every point follows its 3 nearest body nodes softly, carries nothing
        local visualSet = {}
        for _, n in pairs(vehicle.nodes) do
          if type(n) == 'table' and isPart(n) then visualSet[n.name] = true end
        end
        ok, res = pcall(weldEachToNearest, vehicle, isPart, isBody, {strength = -1}, 3, 3.0, nil, visualSet)
      else
        -- with physics: on its own virtual mount, never on the car's nodes directly
        local okO, overlaps = pcall(S.unblockOverlaps, vehicle, isPart)
        if okO and overlaps > 0 then
          log('I', logTag, string.format('extra part %d (%s): %d collision triangles sit in the car\'s body - they don\'t push it', i, tostring(ex.part), overlaps))
        end
        -- a hitch (fifth wheel, pintle, tow hitch: nodes with a coupler tag) hangs on its mount
        -- points only, so its plate tilts / slides and its hook moves as on the donor. So does a
        -- front end (its parts where they were bolted to the donor's body): held whole, a crash
        -- could not bend its bumper, fenders or hood
        local isFront = type(ex.frontEnd) == 'table'
        local tags, seenTag, hooks = {}, {}, nil
        for _, n in pairs(vehicle.nodes) do
          if type(n) == 'table' and isPart(n) and type(n.couplerTag) == 'string' and n.couplerTag ~= '' and not seenTag[n.couplerTag] then
            seenTag[n.couplerTag] = true
            tags[#tags + 1] = n.couplerTag
          end
        end
        local mounts = type(S.extraMounts) == 'table' and S.extraMounts[i]
        if (#tags > 0 or isFront) and type(mounts) == 'table' then
          hooks = {}
          for _, n in pairs(vehicle.nodes) do
            if type(n) == 'table' and isPart(n) and mounts[n.name] then hooks[#hooks + 1] = n end
          end
          if #hooks < 3 then hooks = nil end
        end
        if #tags > 0 then
          log('I', logTag, string.format('extra part %d (%s): hitch %s, %s', i, tostring(ex.part), table.concat(tags, ', '),
            hooks and string.format('held at its %d mount points, its moving parts move', #hooks) or 'held rigidly (no mount points of its own found)'))
        end
        if isFront then
          log('I', logTag, string.format('extra part %d (front end of %s): %s', i, tostring(ex.model),
            hooks and string.format('held at its %d mount points, the rest of it bends and breaks as on the donor', #hooks) or 'held rigidly (no mount points of its own found)'))
        end
        local loose, mass
        ok, res, loose, mass = pcall(S.mountExtra, vehicle, i, ex, isPart, isBody, hooks)
        if ok then
          log(loose > 0 and 'W' or 'I', logTag, string.format('extra part %d (%s): %.0f kg on a virtual mount of 8 points%s', i, tostring(ex.part), mass,
            loose > 0 and string.format(', %d of them found no car node within reach', loose) or ''))
          if mass > 0 and loose >= 8 then
            msg(string.format('%s niekur neprisitvirtino (per toli nuo masinos remo ir kebulo) - ji nukris. Perkelk ja arciau arba padidink "Maks. tarpas".', tostring(ex.part)), 10)
          end
        end
      end
      if not ok then
        log('E', logTag, 'welding extra part failed: ' .. tostring(res))
      elseif res then
        log('I', logTag, string.format('extra part %d (%s): %d weld beams', i, tostring(ex.part), res))
      end
    end
    local okI, errI = pcall(S.connectIntakes, vehicle, marker.extraParts)
    if not okI then log('E', logTag, 'connecting air intakes failed: ' .. tostring(errI)) end
    local okD, errD = pcall(S.connectExtraDevices, vehicle)
    if not okD then log('E', logTag, 'connecting the devices of added parts failed: ' .. tostring(errD)) end
  end

  -- logic engine swap (v3): only the data changes, the car's engine physics stay as they are
  local swap = marker.engineSwap
  if type(swap) == 'table' and (tonumber(swap.version) or 1) >= 3 then
    -- v3 overrides the data captured from the ghost; v4 builds it like a normal engine (nothing to do here)
    local ok, res = true, 'built from the donor tuning parts'
    if (tonumber(swap.version) or 1) == 3 then ok, res = pcall(applyEngineData, vehicle, swap.engineData) end
    log(ok and 'I' or 'E', logTag, string.format('engine logic swap %s: data %s', tostring(swap.part), ok and (res == true and 'applied' or tostring(res)) or tostring(res)))

    -- donor data may use a $variable that only the donor car defines: left unresolved it stays a
    -- "$..." string where the engine code expects a number and the whole vehicle fails to load
    local sections = {'mainEngine'}
    if type(vehicle.mainEngine) == 'table' then
      for _, key in ipairs(engineRefKeys) do
        if type(vehicle.mainEngine[key]) == 'string' then sections[#sections + 1] = vehicle.mainEngine[key] end
      end
    end
    for _, sectionName in ipairs(sections) do
      local section = vehicle[sectionName]
      if type(section) == 'table' then
        for k, v in pairs(section) do
          if type(v) == 'string' and v:sub(1, 1) == '$' then
            log('W', logTag, string.format('engine logic swap: dropping unresolved %s.%s = %s', sectionName, tostring(k), v))
            section[k] = nil
          end
        end
      end
    end
    swap = nil
  end

  -- swapped engine (v1/v2): tie the new block to the bay (mount beams of the donor rarely match the car)
  if type(swap) == 'table' then
    local donorNames = {}
    for _, name in ipairs(swap.donorNames or {}) do donorNames[name] = true end
    local keep = {}
    for _, name in ipairs(swap.keepNames or {}) do keep[name] = true end

    -- engine slot path (everything below it is the engine's subtree, whatever parts were picked)
    local engineSlotPath
    for _, n in pairs(vehicle.nodes) do
      if type(n) == 'table' and n.partOrigin == swapAlias and type(n.partPath) == 'string' and n.partPath:sub(-#swapAlias) == swapAlias then
        engineSlotPath = n.partPath:sub(1, #n.partPath - #swapAlias)
        break
      end
    end
    local function inGearbox(n)
      if keep[n.partOrigin] then return true end
      if engineSlotPath and type(n.partPath) == 'string' and n.partPath:sub(1, #engineSlotPath) == engineSlotPath then
        local seg = n.partPath:sub(#engineSlotPath + 1):match('^([^/]+)/')
        return seg ~= nil and isTransmissionSlot({name = seg})
      end
      return false
    end
    local function inEngine(n)
      if n.partOrigin == swapAlias or donorNames[n.partOrigin] then return true end
      return engineSlotPath ~= nil and type(n.partPath) == 'string' and n.partPath:sub(1, #engineSlotPath) == engineSlotPath and not inGearbox(n)
    end

    local engineMounts = {}
    for _, name in ipairs(swap.mountNames or {}) do engineMounts[enginePrefix .. name] = true end

    if (tonumber(swap.version) or 1) >= 2 then
      -- the new engine must not fight the car's body / chassis it overlaps (that is what bent them)
      local engineSet = {}
      for _, n in pairs(vehicle.nodes) do
        if type(n) == 'table' and type(n.cid) == 'number' and inEngine(n) then
          engineSet[n.cid] = true
          n.selfCollision = false
        end
      end
      for _, t in pairs(vehicle.triangles or {}) do
        if type(t) == 'table' and engineSet[t.id1] and engineSet[t.id2] and engineSet[t.id3] then t.triangleType = 'NONCOLLIDABLE' end
      end

      -- the donor's body points its engine mounts hang on: held by the car's original engine mounts
      if next(engineMounts) then
        local targetMounts = {}
        for _, name in ipairs(swap.targetMounts or {}) do targetMounts[name] = true end
        local function isMount(n) return engineMounts[n.name] == true end
        local function isBodyNode(n) return not isExtraName(n) and not inEngine(n) end
        local function isPreferred(n) return targetMounts[n.name] == true end
        local visualSet = {}
        for _, name in ipairs(swap.visualNames or {}) do visualSet[enginePrefix .. name] = true end
        local okM, resM, looseM = pcall(weldEachToNearest, vehicle, isMount, isBodyNode, {strength = -1}, 4, 3.0, next(targetMounts) and isPreferred or nil, visualSet)
        log(okM and 'I' or 'E', logTag, string.format('engine swap: %s weld beams on %d donor mount points, %s too far', tostring(resM), tableSize(engineMounts), tostring(looseM)))
      end
    end

    local function isPart(n) return n.partOrigin == swapAlias and not engineMounts[n.name] end
    local function isBody(n) return not isExtraName(n) and not inEngine(n) end
    local ok, res = pcall(addWelds, vehicle, isPart, isBody, swap, 'engine ' .. tostring(swap.part))
    if ok then
      log('I', logTag, string.format('engine swap %s: %d weld beams', tostring(swap.part), res))
    else
      log('E', logTag, 'welding swapped engine failed: ' .. tostring(res))
    end

    -- the kept gearbox usually hangs on engine node names the new block may not have: tie it to the block
    if swap.keepTransmission ~= false then
      local function isGearbox(n) return inGearbox(n) end
      local function isBlock(n) return inEngine(n) end
      local gearboxSpec = {welds = 6, maxGap = math.max(0.3, tonumber(swap.maxGap) or 0.3), strength = swap.strength}
      local ok2, res2 = pcall(addWelds, vehicle, isGearbox, isBlock, gearboxSpec, 'gearbox to swapped engine')
      if ok2 then
        log('I', logTag, string.format('gearbox to swapped engine: %d weld beams', res2))
      else
        log('E', logTag, 'welding gearbox failed: ' .. tostring(res2))
      end
    end
  end

  -- swapped gearbox: tie it to the engine and the body
  local gbSwap = marker.gearboxSwap
  if type(gbSwap) == 'table' then
    local function isPart(n) return n.partOrigin == gearboxAlias end
    local function isBody(n) return not isExtraName(n) and n.partOrigin ~= gearboxAlias end
    local ok, res = pcall(addWelds, vehicle, isPart, isBody, gbSwap, 'gearbox ' .. tostring(gbSwap.part))
    if ok then
      log('I', logTag, string.format('gearbox swap %s: %d weld beams', tostring(gbSwap.part), res))
    else
      log('E', logTag, 'welding swapped gearbox failed: ' .. tostring(res))
    end
  end

  -- swapped parts (suspension...): weld only the donor's chassis mount points, never the moving arms
  if type(marker.partSwaps) == 'table' then
    for kind, spec in pairs(marker.partSwaps) do
      if type(spec) == 'table' then
        local alias = partSwapAlias(kind)
        local slotPath
        for _, n in pairs(vehicle.nodes) do
          if type(n) == 'table' and n.partOrigin == alias and type(n.partPath) == 'string' and n.partPath:sub(-#alias) == alias then
            slotPath = n.partPath:sub(1, #n.partPath - #alias)
            break
          end
        end
        local prefix = partSwapPrefix(kind)
        local function inSubtree(n)
          if n.partOrigin == alias then return true end
          if type(n.name) == 'string' and n.name:sub(1, #prefix) == prefix then return true end
          return slotPath ~= nil and type(n.partPath) == 'string' and n.partPath:sub(1, #slotPath) == slotPath
        end
        local mounts = {}
        for _, name in ipairs(spec.mountNames or {}) do mounts[prefix .. name] = true end
        local hasMounts = next(mounts) ~= nil

        -- the new suspension must not fight the car's own body (overlaps would blow it apart).
        -- Tyres too: a bigger donor wheel (live axles from trucks) sits inside the car's arch
        -- panels at spawn; the ground still touches the tyre nodes, only car-to-car tyre hits go
        local subtreeSet = {}
        for _, n in pairs(vehicle.nodes) do
          if type(n) == 'table' and type(n.cid) == 'number' and inSubtree(n) then
            subtreeSet[n.cid] = true
            n.selfCollision = false
          end
        end
        for _, t in pairs(vehicle.triangles or {}) do
          if type(t) == 'table' and (subtreeSet[t.id1] or subtreeSet[t.id2] or subtreeSet[t.id3]) then
            t.triangleType = 'NONCOLLIDABLE'
          end
        end
        -- donor springs pre-load slowly instead of kicking at spawn
        local ramped = 0
        for _, b in pairs(vehicle.beams or {}) do
          local n1, n2 = vehicle.nodes[b.id1], vehicle.nodes[b.id2]
          local onWheel = (n1 and n1.wheelID ~= nil) or (n2 and n2.wheelID ~= nil) or b.wheelID ~= nil
          if type(b) == 'table' and not onWheel and (subtreeSet[b.id1] or subtreeSet[b.id2])
            and (type(b.precompressionRange) == 'number' or (type(b.beamPrecompression) == 'number' and b.beamPrecompression ~= 1))
            and not (type(b.beamPrecompressionTime) == 'number' and b.beamPrecompressionTime > 0) then
            b.beamPrecompressionTime = 0.5
            ramped = ramped + 1
          end
        end
        if ramped > 0 then log('I', logTag, string.format('part swap %s: %d pre-loaded springs ramp in over 0.5 s', kind, ramped)) end
        local function isPart(n)
          if not inSubtree(n) then return false end
          if hasMounts then return mounts[n.name] == true end
          return n.partOrigin == alias
        end
        local function isBody(n) return not isExtraName(n) and not inSubtree(n) and not inAnySwap(n) end
        local version = tonumber(spec.version) or 1
        if version >= 5 and not hasMounts then
          -- every donor body point was hooked straight onto the car's own nodes: nothing to weld
          log('I', logTag, string.format('part swap %s (%s): fully hooked onto the car, no welds needed', kind, tostring(spec.part)))
        elseif version >= 2 and hasMounts then
          -- imported donor body points: each one held by the 4 nearest of the car's original
          -- suspension mounts (built for the load), unbreakable; long beams are fine
          local targetMounts = {}
          for _, name in ipairs(spec.targetMounts or {}) do targetMounts[name] = true end
          local function isPreferred(n) return targetMounts[n.name] == true end
          local independent = version >= 8
          local weldSpec = {strength = -1, spread = independent, rigidFrame = independent}
          local visualSet = {}
          for _, name in ipairs(spec.visualNames or {}) do visualSet[prefix .. name] = true end
          local partPick = isPart
          if version >= 11 and type(spec.frameNames) == 'table' and #spec.frameNames > 0 then
            -- hook frame: only the 8 corners touch the car; hooks and imported points hang on them
            local frameSet, hookSet = {}, {}
            for _, name in ipairs(spec.frameNames) do frameSet[prefix .. name] = true end
            for _, name in ipairs(spec.hookNames or {}) do hookSet[prefix .. name] = true end
            for _, name in ipairs(spec.mountNames or {}) do
              local full = prefix .. name
              if not frameSet[full] and not visualSet[full] then hookSet[full] = true end
            end
            -- nodes that rode a donor frame rail (S.detachSwapRails) are held like the other hooks
            for _, name in ipairs(type(S.railHooks) == 'table' and S.railHooks[kind] or {}) do hookSet[prefix .. name] = true end
            local hookNodes, visualNodes = {}, {}
            for _, n in pairs(vehicle.nodes) do
              if type(n) == 'table' and type(n.cid) == 'number' and n.pos and type(n.name) == 'string' then
                if hookSet[n.name] then hookNodes[#hookNodes + 1] = n
                elseif visualSet[n.name] then visualNodes[#visualNodes + 1] = n end
              end
            end
            weldSpec.hookNodes, weldSpec.visualNodes = hookNodes, visualNodes
            partPick = function(n) return frameSet[n.name] == true end
            log('I', logTag, string.format('part swap %s: %d hooks + %d mesh points hang on the %d frame corners', kind, #hookNodes, #visualNodes, #spec.frameNames))
          end
          local ok, res, loose, attached = pcall(weldEachToNearest, vehicle, partPick, isBody, weldSpec, 4, 3.0, next(targetMounts) and isPreferred or nil, visualSet)
          log(ok and 'I' or 'E', logTag, string.format('part swap %s (%s): %s weld beams on %d body points, %s too far from the body',
            kind, tostring(spec.part), tostring(res), #(spec.mountNames or {}), tostring(loose)))
          if ok and independent and type(attached) == 'table' then
            local kept = reinforceSwap(vehicle, subtreeSet, attached)
            log('I', logTag, string.format('part swap %s: independent bundle on a virtual frame of %d nodes, %d beams of it and of its mount area never break (they still bend)', kind, #(spec.frameNames or {}), kept))
          end
          if ok then
            -- the nodes the mod made or re-weighted (imported points, frame corners, hooks) and the
            -- body nodes they are welded to must suit the physics step; the donor's own nodes stay as
            -- the donor has them
            local modNames = {}
            for _, name in ipairs(spec.mountNames or {}) do modNames[prefix .. name] = true end
            for _, name in ipairs(spec.hookNames or {}) do modNames[prefix .. name] = true end
            local checkSet = {}
            for cid, _ in pairs(subtreeSet) do
              local n = vehicle.nodes[cid]
              if n and modNames[n.name] then checkSet[cid] = true end
            end
            for cid, _ in pairs(type(attached) == 'table' and attached or {}) do checkSet[cid] = true end
            local okS, resS = pcall(stabilizeNodes, vehicle, checkSet, 'part swap ' .. kind)
            if not okS then log('E', logTag, 'stability check failed: ' .. tostring(resS)) end
          end
        else
          -- old swaps (made before version 2): weld the tree's own mount nodes
          local weldSpec = {welds = 40, maxGap = math.max(0.6, tonumber(spec.maxGap) or 0.3), strength = spec.strength}
          local ok, res = pcall(addWelds, vehicle, isPart, isBody, weldSpec, kind .. ' ' .. tostring(spec.part))
          log(ok and 'I' or 'E', logTag, string.format('part swap %s (%s): %s weld beams', kind, tostring(spec.part), tostring(res)))
        end
      end
    end
  end

  -- logic suspension: donor character / sliders on the car's own suspension
  if type(marker.suspTune) == 'table' then
    for _, axle in ipairs({'F', 'R'}) do
      if type(marker.suspTune[axle]) == 'table' then
        local ok, res = pcall(tuneSuspensionAxle, vehicle, marker.suspTune[axle])
        log(ok and 'I' or 'E', logTag, string.format('logic suspension %s: %s', axle, tostring(res)))
      end
    end
  end

  -- turbo / supercharger (logic): the engine points at the donor section(s) loaded into its part
  local fi = marker.fiSwap
  if type(fi) == 'table' then
    if type(vehicle.mainEngine) == 'table' then
      local on = {}
      for _, kind in ipairs({'turbocharger', 'supercharger'}) do
        local section = vehicle['upa_' .. kind]
        if type(section) == 'table' then
          -- a $variable nothing defines would reach the engine code as a string
          for k, v in pairs(section) do
            if type(v) == 'string' and v:sub(1, 1) == '$' then section[k] = nil end
          end
          -- incomplete data (a turbo without its boost curve, a supercharger without its type)
          -- would disable the whole vehicle: left off, the engine runs without it
          if not S.fiComplete(kind, section) then
            log('W', logTag, string.format('forced induction %s: the %s data is incomplete - left off so the engine still starts', tostring(fi.part), kind))
            msg(string.format('%s: %s duomenys nepilni - neijungta, kad variklis veiktu.', tostring(fi.part), kind), 8)
            section = nil
          end
        end
        if type(section) == 'table' then
          vehicle.mainEngine[kind] = 'upa_' .. kind
          on[#on + 1] = kind
        end
      end
      if fi.torqueModIntake ~= nil then vehicle.mainEngine.torqueModIntake = deepcopy(fi.torqueModIntake) end
      log('I', logTag, string.format('forced induction %s: %s on the engine', tostring(fi.part), #on > 0 and table.concat(on, ' + ') or 'nothing (section missing)'))
    else
      log('W', logTag, 'forced induction ' .. tostring(fi.part) .. ': the car has no mainEngine')
    end
  end

  -- radiator (logic): the donor radiator's cooling data on the car's engine, over whatever the
  -- car's own radiator part set
  local rad = marker.radiatorSwap
  if type(rad) == 'table' and type(rad.data) == 'table' then
    if type(vehicle.mainEngine) == 'table' then
      local n = 0
      for k, v in pairs(rad.data) do
        vehicle.mainEngine[k] = v
        n = n + 1
      end
      log('I', logTag, string.format('radiator %s: %d cooling values on the engine (area %s, effectiveness %s)', tostring(rad.part), n,
        tostring(rad.data.radiatorArea), tostring(rad.data.radiatorEffectiveness)))
    else
      log('W', logTag, 'radiator ' .. tostring(rad.part) .. ': the car has no mainEngine')
    end
  end

  -- universal drivetrain last, after every part that adds powertrain devices is in
  local dt = marker.drivetrain
  if not (type(dt) == 'table' and dt.enabled) and S.cutWheelsGone then
    -- the cut took driven wheels off: the wheels that stay get driven
    dt = {enabled = true, layout = 'RWD'}
    log('I', logTag, 'car cutter: wheels were cut off, the universal drivetrain drives the rest')
  end
  if type(dt) == 'table' and dt.enabled then
    local ok, res = pcall(buildUniversalDrivetrain, vehicle, dt)
    log(ok and 'I' or 'E', logTag, 'universal drivetrain: ' .. tostring(res))
  end

  -- safety electronics (ABS, TC, ESC, 2-step, line lock) after the drivetrain, which drops controllers
  if type(marker.safety) == 'table' then
    local ok, res = pcall(S.applySafety, vehicle, marker.safety)
    log(ok and 'I' or 'E', logTag, 'safety electronics: ' .. tostring(res))
  end

  -- an LBEAM needs a third node; one whose third node stayed on the donor's body would make the
  -- vehicle side throw a fatal error (setBeamLbeam got nil) and disable the whole car
  local fixedL = 0
  for _, b in pairs(vehicle.beams or {}) do
    if type(b) == 'table' and b.beamType == 4 and type(b.id3) ~= 'number' then
      b.beamType, b.id3 = 0, nil
      fixedL = fixedL + 1
    end
  end
  if fixedL > 0 then log('W', logTag, string.format('%d LBEAMs without their third node made plain beams', fixedL)) end

  -- settle time: for the first seconds after a spawn / reset nothing bends or breaks while the new
  -- parts find their place; the vehicle side (partAttacherExpSettle) puts the originals back
  local changed = marker.extraParts or marker.engineSwap or marker.gearboxSwap or marker.partSwaps or marker.suspTune
  if not marker.ghost and changed and S.settlePtr[0] then
    local count = 0
    for _, b in pairs(vehicle.beams or {}) do
      if type(b) == 'table' then
        b.upaStrength = b.beamStrength == nil and false or b.beamStrength
        b.upaDeform = b.beamDeform == nil and false or b.beamDeform
        b.beamStrength, b.beamDeform = math.huge, math.huge
        count = count + 1
      end
    end
    vehicle.partAttacherExpSettle = S.settleSeconds
    log('I', logTag, string.format('settle time: %d beams unbreakable for %.1f s', count, S.settleSeconds))
  end

  -- the mod's lines of this load go to their own file, safe from the game log's size limit
  if S.diag then
    local lines = S.diag
    S.diag = nil
    lines[#lines + 1] = string.format('vehicle: %d nodes, %d beams', tableSize(vehicle.nodes), tableSize(vehicle.beams or {}))
    pcall(function()
      local dir = '/settings/partAttacherExp/'
      if not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
      writeFile(dir .. 'last_load.log', table.concat(lines, '\n') .. '\n')
    end)
  end
end

local function onVehicleSpawned(vid)
  local p = pendingSpawn
  if not p or entries[vid] then return end
  if os.clock() - p.time > 30 then pendingSpawn = nil return end
  local veh = getVeh(vid)
  if not veh then return end
  local d = core_vehicle_manager.getVehicleData(vid)
  local mainPart = d and d.config and d.config.mainPartName
  local isOurs = mainPart == p.partName or (not mainPart and tostring(veh.partConfig or ''):find(p.partName, 1, true))
  if isOurs and veh.jbeam == p.model then
    registerEntry(vid, p.partName, p.model, getVeh(p.targetId), p.preset)
  end
end

local function onVehicleDestroyed(vid)
  if entries[vid] then
    entries[vid] = nil
    if selectedEntryId == vid then selectedEntryId = nil end
  end
  for _, e in pairs(entries) do
    if e.targetId == vid then
      e.targetId = nil
      e.hold = false
    end
  end
end

local function toggleWindow()
  showWindow[0] = not showWindow[0]
  if showWindow[0] then placeWindow = true end
  log('I', logTag, 'window ' .. (showWindow[0] and 'opened' or 'closed'))
end

--------------------------------------------------------------------------------
-- multiplayer (BeamMP): a preview is a vehicle of its own, so BeamMP sends it to every other
-- player, whose game spawns it with the game's safe spawn. That places a car by the box of its
-- colliding nodes, and a preview has none (it collides with nothing): spawn.spawnVehicle returns
-- nil and BeamMP's spawn queue errors out on it (MPVehicleGE.lua:1538). A preview is spawned
-- where it is sent instead, as its owner spawns it.
--------------------------------------------------------------------------------

S.isPreviewConfig = function(cfg)
  if type(cfg) == 'string' then
    return cfg:find('partAttacherExp', 1, true) ~= nil and cfg:find('["ghost"]=true', 1, true) ~= nil
  end
  return type(cfg) == 'table' and type(cfg.partAttacherExp) == 'table' and cfg.partAttacherExp.ghost == true
end

S.installSpawnHook = function()
  local sp = rawget(_G, 'spawn')
  if type(sp) ~= 'table' or type(sp.spawnVehicle) ~= 'function' or S.origSpawnVehicle then return end
  S.origSpawnVehicle, S.origSetVehicleObject = sp.spawnVehicle, sp.setVehicleObject
  sp.spawnVehicle = function(model, partConfig, pos, rot, options)
    if S.isPreviewConfig(partConfig) then
      options = options or {}
      options.safeSpawn = false
    end
    return S.origSpawnVehicle(model, partConfig, pos, rot, options)
  end
  if type(S.origSetVehicleObject) == 'function' then
    sp.setVehicleObject = function(veh, options)
      if type(options) == 'table' and S.isPreviewConfig(options.config) then options.safeSpawn = false end
      return S.origSetVehicleObject(veh, options)
    end
  end
end

S.removeSpawnHook = function()
  local sp = rawget(_G, 'spawn')
  if type(sp) == 'table' and S.origSpawnVehicle then
    sp.spawnVehicle = S.origSpawnVehicle
    if S.origSetVehicleObject then sp.setVehicleObject = S.origSetVehicleObject end
  end
  S.origSpawnVehicle, S.origSetVehicleObject = nil, nil
end

local function onExtensionLoaded()
  installLoaderHooks()
  S.installSpawnHook()
  log('I', logTag, 'Part Attacher Experimental ' .. S.version .. ' by Kavencki - Giedrius P. loaded. Ctrl+Shift+U or partAttacherExp.toggleWindow()')
end

local function onExtensionUnloaded()
  removeLoaderHooks()
  S.removeSpawnHook()
  for _, e in pairs(entries) do
    local ghost = getVeh(e.id)
    if ghost then ghost:delete() end
  end
  entries = {}
end

M.toggleWindow = toggleWindow
M.showWindow = function() showWindow[0] = true placeWindow = true end
-- the pause menu's Mods tab (ui/ui-vue/mods/partAttacherExp): open the window and go back to driving
-- (ui_router.navigate is the game's way since 0.39.4, ChangeState the old one)
M.openFromMenu = function()
  M.showWindow()
  local router = rawget(_G, 'ui_router')
  if not (router and router.navigate and pcall(router.navigate, 'play')) then
    guihooks.trigger('ChangeState', {state = 'play'})
  end
end
M.getLang = function() return S.lang end
M.getVersion = function() return S.version end
M.onUpdate = onUpdate
M.onJbeamLoadingPhase2 = onJbeamLoadingPhase2
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
-- a map change unloads materials: the donor folders loaded on the last map have to load again
M.onClientStartMission = function() loadedMaterialDirs = {} S.glowCache = nil end
M.onClientEndMission = function() loadedMaterialDirs = {} S.glowCache = nil end

return M
