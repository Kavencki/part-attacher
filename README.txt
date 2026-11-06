PART ATTACHER - any part from any vehicle, on any vehicle (BeamNG.drive 0.40)
==============================================================================
Mod author: Kavencki - Giedrius P.        Version: 1.4 beta
(c) 2026 Kavencki. All rights reserved. Do not re-upload, redistribute or
publish this mod as your own without the author's permission.


WHAT IT DOES
------------
- Put any part (bumpers, fenders, bars, lights...) from any vehicle - official or
  modded - onto your vehicle. The part becomes a real part of your car's jbeam
  (not a separate "vehicle"), welded to the body, and it stays after a reset.
- ENGINE SWAP, GEARBOX SWAP and FRONT / REAR SUSPENSION SWAP from any vehicle.
- TURBO / SUPERCHARGER and RADIATOR from any vehicle onto your engine.
- UNIVERSAL DRIVETRAIN: RWD / FWD / AWD with any gearbox, lockable differentials,
  switchable 2WD / 4WD and low range - all switched while driving.
- Model-only parts (static mesh, no physics), mirror copies, auto positioning,
  part size (scale).
- SAFETY ELECTRONICS on any vehicle: ABS, traction control, stability control,
  2-step launch control, line lock.
- FRONT END and WHOLE BODY SWAP: another vehicle's front or whole body on yours.
- SAVED VEHICLES: save a finished vehicle by name and spawn it again later.
- REAR WHEEL STEERING (4WS) like the Pessima AWS, and a DIFFERENT WHEEL ON EVERY
  CORNER, picked in the game's own Parts menu.
- Part pictures: rest the mouse on a part in the list to see its model; parts
  that would do nothing on a vehicle are left out of the list.
- Everything is saved with the game's own vehicle save and loads on any map.
- UI in English, Lithuanian, German, Spanish, Italian, Russian, Chinese and Japanese,
  with a UI size slider.


INSTALL
-------
Download file from https://github.com/Kavencki/part-attacher/releases ,  Put the zip into  Documents/BeamNG.drive/mods  (or %LOCALAPPDATA%/BeamNG/
BeamNG.drive/current/mods) and enable it in the in-game Mod Manager.


QUICK START
-----------
The window's sections are tabs at its top: Part (sections 1 and 2), Installed
(3), Drivetrain (4), Suspension (5), Electronics (6), Body (7), Saved (8).
When a preview appears, its position (section 2) shows on top of the same Part tab - no other tab needed.

1. Get into the vehicle you want to modify.
2. Press  Ctrl + Shift + Y  to open the window (rebind it in Options > Controls >
   Gameplay > "Part Attacher: open / close window"), or press ESC and pick
   Mods > Part Attacher > "OPEN PART ATTACHER".
3. Section 1: pick the "Model" you want a part FROM. Its parts are shown like
   the game's own Parts menu (slot tree; the default part is marked *), with the
   swap folders on top. Or type in "Search parts".
4. Press the button at the bottom of section 1: a PREVIEW of the part appears.
5. Section 2: move / rotate it (X / Y / Z, pitch / roll / yaw; type an exact
   value in the field next to a slider), then press ATTACH. Your vehicle reloads with the
   part built in.
6. Section 3 lists everything you added: Move, Remove, Mirror, Restore original,
   and "With physics" / "Model only" to switch an installed part in place.
   Section 2 shows the preview's mode (MODEL ONLY or with physics) with a
   button to switch it - the "Model only" checkbox of section 1 stays ticked
   until you untick it.


SECTION 1 - PICK A PART
-----------------------
- "Auto position" (on by default): a new part appears where your vehicle's part
  of the same kind is (bumper on bumper, hood on hood).
- "Model only (no physics)": the part comes as its model only - no weight, no
  collisions, never breaks, it just moves with the vehicle. Parts whose model
  hangs on their own car's body (radiators...) always come like this.
- "Vehicle paint": paint the part in your vehicle's colours.
- Part picture: rest the mouse on a part in the list and a small window shows its
  model ("Part picture on mouse hover"). The first time the part loads for a
  moment (the game may stop for a second); the picture is saved and shows at once
  next time. "Delete pictures" deletes the saved ones. In multiplayer only the
  pictures saved before show.
  Picking a vehicle makes its part pictures by itself: a few of its factory
  configs load one by one (each one a short stutter) and all their parts get a
  picture. The progress shows under the list, "Stop" stops it.
- Parts that would do nothing on a vehicle (bulbs, ECU tunes - no points, model
  or devices of their own) are not listed. Parts with devices but no model (e.g.
  a truck's air compressor) are marked "[data only]"; hovering one says what it adds.
- "All parts by type" at the bottom: every part, including common ones and
  other vehicles' parts.
- Data-only parts (no model and no points of their own, e.g. a truck's "Air
  Compressor") have no preview: the button puts them straight onto your vehicle.
  Their devices are connected to your engine (it gets the outputs they need).
  Section 3 marks them "[data only]"; they can only be removed. A compressor
  needs an air tank too - add the same vehicle's "Air Tanks", otherwise a
  message says what is missing.


SECTION 2 - POSITION AND MOUNTING
---------------------------------
- Donor position / On the roof / Like my vehicle's part: quick positions.
- "Size (scale)": make the part smaller or bigger (x0.1 - x5 on the slider, up
  to x10 typed in its field). It grows / shrinks around its centre - model and
  physics both. "Size per axis X / Y / Z" gives width, length and height a
  factor each (a wider bumper that is not taller). The preview reloads when you
  let go of a slider or a field; "Real size" goes back to x1. Section 3 shows
  the size (e.g. x1.50, or x1.20 / 0.90 / 1.00) and Move / Mirror / Copy keep
  it. The light changes with it: a bigger lamp shines stronger (by
  its area), further and with a bigger flare. Other props (e.g. a beacon's turning
  model) keep their own size.
- "Copy" (section 2 and section 3): one more of the same part as a new preview,
  at the very same place, turn and size - move it and ATTACH. In section 3 the
  installed part stays on the car.
- Exhaust: an attached exhaust really works - smoke, afterfire pops and the
  exhaust sound come out of its tips like out of your car's own, for any number
  of them (two or three different exhausts at once too). The load log says
  "exhaust on mainEngine".
- Livery: your car's livery only goes on its own parts - another car's parts and
  a front end swap have their own meshes, so they can take one of the donor's
  own liveries instead: "Livery (donor)" in section 2 (preview) and section 7
  (front end), and a "Livery" button by an installed part in section 3 (the car
  reloads). Shown only when the donor has liveries. The load log says
  "livery ... on N meshes".
- Snorkel: an attached snorkel (or any part with air intake points) really
  works - your engine takes its air through it too and floods only when the
  snorkel's top goes under water as well (also as "Model only"). The load log
  says "the engine takes its air through it too".
- "Mirror copy": the same part on the other side. If the donor has the
  other-side part (door_FL -> door_FR, mirror_L -> mirror_R) that one is used.
- Virtual mount (parts with physics): the part is never welded to your car's
  nodes directly. 8 light frame points around it hold every node of the part,
  and only those points are welded to the car's structure (chassis / frame /
  body, spread out, sized to the node masses). The part keeps its own weight,
  beams and collisions - a bull bar works as a bull bar. Its links to the
  donor car's body (frame, bumper) are left out, so they can't grab your car.
- A part far from the car's own body (a fifth wheel on the frame of a swapped
  semi axle) also hangs on the swapped suspension's frame (its virtual frame,
  the donor frame it brought) and on parts you added before with physics - the
  car's body always comes first when it is in reach. Never on the moving parts
  of a suspension (axles, arms, wheels). If a part reaches nothing at all, a
  message says it will fall.
- Weld points (welds per frame point = weld points / 3), Max gap (the frame
  reaches 3x as far, at least 1 m), Strength / Unbreakable, No collisions.
  Strength is per weld beam: it breaks at that force and starts to bend at
  half of it. Default 40000 N (BeamNG mounts its own bumpers with 28000 N).
- "Crash protection for the first 2.5 s": after a spawn / reset nothing bends
  or breaks for 2.5 s while new parts settle, then normal damage returns.


HITCHES (fifth wheel, pintle, tow hitch)
----------------------------------------
- An attached hitch works like on its own vehicle: the semi's "Fifth Wheel"
  (us_semi) takes a semi trailer when you back under it, a "Pintle Hitch" and
  other hitches couple with the game's coupler key (L). Unhitch with the fifth
  wheel's handle or the radial menu.
- A hitch hangs on its virtual mount at its own mount points only (its rails,
  its frame points), so the fifth wheel plate tilts and slides like on the donor.
  last_load.log says "hitch fifthwheel_v2, held at its N mount points".
- A hitch only works with physics: a "Model only" part has no coupler point.
- A heavy trailer pulls through the hitch's welds: if it tears off, raise
  "Strength" in section 2 or tick "Unbreakable".

ENGINE SWAP  (folder ">> ENGINE SWAP")
-----------
A LOGIC swap: your engine's physics (block, mounts) stay, so nothing breaks or
flies off. The donor's power and torque curves, revs, inertia, sound and (if you
want) its model come over. The donor's tuning slots (ECU, internals, intake /
turbo, N2O) appear in the normal Parts menu under the engine. Your gearbox and
fuel stay yours; extra engine outputs (air compressor, PTO on trucks) keep working.


GEARBOX SWAP  (folder ">> GEARBOX SWAP")
------------
Any gearbox (manual / automatic / DCT / CVT / sequential). Tick "Also enable the
universal drivetrain" so the power reaches the wheels with any gearbox.


TURBO / SUPERCHARGER  (folder ">> TURBO / SUPERCHARGER (logic)")
--------------------
Pick any vehicle's turbo or supercharger: its data (boost curve, wastegate,
inertia) and sounds (spool, BOV, whine) go onto your engine - also a swapped one.
Its settings (e.g. Wastegate Pressure) appear in the normal Tuning menu.


RADIATOR  (folder ">> RADIATOR (cooling, logic)")
--------
Your radiator stays; your engine gets the donor's cooling data (area,
effectiveness, coolant volume, fan, thermostat). Only for engines with
temperature simulation.


SUSPENSION
----------
- SUSPENSION SWAP (the orange button): the real donor suspension with its wheels,
  hubs, dampers, brakes and steering. It hangs on its own invisible virtual
  frame that is welded to your body, so a foreign axle can't tear the body
  apart. Live axles, links and coilovers are supported. Older swaps get a FIX
  button in section 3. If the new suspension's shafts can't find your drivetrain,
  the universal drivetrain switches on by itself.
- LOGIC (safer, never breaks): the button below it, "LOGIC: take over only the
  character" - the donor's spring, damper and sway bar rates go onto your own
  suspension. Section 5 adjusts front / rear separately: ride height
  (-20..+60 cm), springs x, dampers x, sway bar x.
- SECOND REAR AXLE (6 wheels): in the rear suspension folder press "ADD AS A
  SECOND REAR AXLE". Your rear suspension stays; the new axle comes behind it on
  its own virtual frame (move Y in section 2), with its own wheel names. Both rear
  axles are driven by the universal drivetrain (an inter-axle differential
  between them; lock it with the Rear locker).


SECTION 4 - UNIVERSAL DRIVETRAIN
--------------------------------
Everything after the gearbox (driveshaft, transfer case, differentials, half
shafts) is rebuilt from the real wheel positions:
- Driven wheels: RWD / FWD / AWD (center differential + front share).
- Differential type: open / lsd / viscous / locked; final drive.
- Lockable (locker): Front / Rear / Center (both axles together). A lockable
  diff has two modes: the chosen type and "locked" (both sides turn alike).
- Switchable 2WD / 4WD (part-time, AWD): a transfer case - 2WD (rear) or 4WD
  (front and rear locked 50 / 50). Starts in 2WD.
- Low range: High (1:1) or Low (ratio 1.5 - 4.5, default 2.72).
- "Switch while driving": 2WD / 4WD, High / Low, Front / Rear / Center,
  LOCK EVERYTHING / UNLOCK EVERYTHING. The game's "Toggle differential mode"
  key and its powertrain UI buttons work too.
- Works with 3-axle trucks (tandem) and dually wheels. Physics only - no
  driveshaft model is drawn.


SECTION 7 - FRONT END / BODY SWAP (tab "Body")
----------------------------------------------
"Front end only" puts the whole front of another vehicle on yours:
- Pick the donor in "Vehicle (donor)". Its front end parts are listed from its
  default parts (front bumper, bumper support, fenders, hood, headlights, grille,
  fog lights, front fascia, radiator support...) - untick what you don't want.
- "SPAWN FRONT END": all of them appear as ONE preview, each where it sits on
  its own car, with its own lights and sub parts. It starts centred on your car,
  its front at your car's front and, with "Auto size", as wide as your car's
  front. Move it and set its size in the Part tab, then ATTACH.
- It is installed as one part on one virtual mount. "Take my vehicle's own front
  parts off" (on by default) empties your bumper, fender, hood, headlight and
  grille slots, like the Parts menu; removing the front end in the Installed tab
  puts them back. "Move" turns it back into a preview.
- It takes damage like on its own car: the mount holds only the points where
  its parts were bolted to the donor's body, so the bumper, fenders and hood
  bend and break in a crash. "Strength" in section 2 sets how hard it holds on.

"Whole body (body swap)" puts another vehicle's whole body on your running gear:
- Its body parts are listed (shell, doors, hood, trunk, bumpers, fenders, lights,
  glass, interior...) - without its wheels, suspension, engine, gearbox, frame
  and fuel tank, which stay out of it.
- Under each body part its own parts are listed (doors, hood, trunk, bumpers,
  lights, glass, interior...): untick any you don't want, it is left out.
- "SPAWN BODY": one preview, centred on your car's body and, with "Auto size",
  as long and as wide as it (width and length sized separately). Move it and
  set its size in the Part tab, then ATTACH.
- "Hide my vehicle's own body" (on by default): your body and its panels stay
  only as the frame under the new one - invisible and not colliding; your
  wheels, suspension, engine and steering wheel still show and work.
- The new body hangs on your car at the points where the donor's suspension,
  engine and frame held it, so it bends and breaks like on its own car. Its
  lights work with your car's lights. Removing it in the Installed tab shows
  your own body again.

SECTION 8 - SAVED VEHICLES (tab "Saved")
----------------------------------------
Type a name and press "SAVE THIS VEHICLE": the whole vehicle with everything
you added (parts, swaps, drivetrain, electronics, paint) is saved in
settings/partAttacher/cars/<name>.json. The list below it: "Spawn" replaces
the vehicle you are in with that saved one (on any map), "Delete" (press twice)
removes it.

SAVING YOUR VEHICLE
-------------------
The game's own save works too (Vehicle Config > Save): everything the mod did -
parts, swaps, drivetrain, tuning, safety electronics, paint - is saved with the
vehicle, and it loads on any map. Part Attacher must be enabled when you load
such a vehicle.


REAR WHEEL STEERING (4WS, section 5, at the bottom)
--------------------------------------------------
Like the Ibishu Pessima 2.0 ZX AWS: the rear wheels steer with the front ones. Every
rear wheel with its disc gets a kingpin of its own and a hydraulic tie rod, the
suspension or axle stays in place; the game's own rear wheel steering controller
drives the tie rod. Modes: by speed (slow the opposite way - a smaller turning
circle, fast the same way - more stable), like the Pessima (by the steering angle),
always the opposite way, or always the same way (crab walk). "Largest angle" is how
far the rear wheels turn at most (up to 45 deg; the by-speed mode holds it to a
few degrees at speed). Works on a solid axle and with a swapped rear
suspension too.

A DIFFERENT WHEEL ON EVERY CORNER (section 5, at the bottom)
------------------------------------------------------------
Press "TURN ON" - the vehicle reloads, and the game's Parts menu (ESC > Vehicle
Config) gets "- left" and "- right" next to "Front Wheels" and "Rear Wheels". Pick a
rim and tyre for every wheel (wheels of different sizes tilt the vehicle). "Turn off"
brings the usual slots back.


SECTION 6 - SAFETY ELECTRONICS
------------------------------
Tick what you want and press "INSTALL / UPDATE" (the vehicle reloads):
- ABS - the wheels never lock up when braking (all wheels).
- Traction control (TC) - cuts the throttle / brakes a spinning wheel.
- Stability control (ESC) - brakes wheels to stop sliding and spinning out.
  Generic settings, not tuned for the vehicle.
- 2-step (launch control) - holds the chosen rpm for a launch: standing still,
  hold the brake + full throttle, then let go of the brake.
- Line lock - holds the front brakes while the rear wheels spin (burnout).
While driving: TC / ESC modes (ESC + TC / TC / Off), 2-step and line lock are
switched in the radial menu (Vehicle features) or with the Options > Controls
keys "Toggle ESC mode", "Toggle Two-Step", "Toggle Line Lock". What the vehicle
already has of its own (its ESC / TC, 2-step) stays as it is.


MULTIPLAYER (BeamMP)
--------------------
- Put the mod zip in the server's Resources/Client folder: every player gets it
  from there.
- In ServerConfig.toml set MaxCars = 2 or more: a part preview is a vehicle of
  its own while you place it.
- Other players see your previews and your finished car (parts, swaps,
  drivetrain) like any edited vehicle.
- Before joining, disable your own local copy of Part Attacher in the Mod
  Manager if you have one (the server's copy has the same files).

LANGUAGE
--------
At the bottom of the window: "Language / Kalba" - English (default), Lithuanian,
German, Spanish, Italian, Russian, Chinese or Japanese. The choice is saved
(settings/partAttacher/settings.json). Chinese and Japanese use the game's own
Chinese / Japanese font. Translations: lua/ge/extensions/partAttacher/lang*.lua
"UI size" next to it makes the window's text and buttons bigger or smaller (x0.80 -
x2.00, applied when you let go of the slider; "x1" goes back). The window always
opens at the normal size.
A bigger size first asks in a small window in the middle of the screen: press
"APPROVE THIS SIZE" within 15 s, or the size before comes back.


TROUBLESHOOTING
---------------
- Auto undo: if the vehicle goes unstable (its physics blow up) within 20 s after
  a change made by the mod, the change is undone at once and the vehicle is put
  back as it was, upright where it stood.
- Every load of a modded vehicle writes  settings/partAttacher/last_load.log
  (what was built, what was left out, which nodes needed more mass). If a
  vehicle explodes or a part hangs loose, that file tells why - please attach it
  to bug reports.
- After changing mod files: Ctrl+L reloads Lua, Ctrl+R reloads the vehicle.
- "Instability detected": try the suspension LOGIC button instead of a geometry
  swap, or a donor closer in size to your vehicle.

KNOWN LIMITATIONS (beta)
------------------------
- Suspension geometry swaps between very different vehicles can still be unstable.
- Leaf-spring suspensions: ride height / spring rate in the LOGIC mode may not change.
- Parts with no nodes and no model of their own (decals...) can't be added.
- Game updates may break parts of the mod; check for a new version.
