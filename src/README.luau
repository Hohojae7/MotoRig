--[[
	MotoRig - notes for map makers

	One motorcycle you can drop anywhere in a map and ride. Every script it
	needs is inside this model: nothing goes into StarterPlayer,
	ServerScriptService or anywhere else.


	SETUP

	1. Put the model in Workspace (or any folder in it). Copies work too,
	   and it can be renamed.
	2. Place it with the wheels on the ground; a little above is fine, it
	   settles at the start. Do not scale it: the physics uses its real
	   dimensions.
	3. Press Play, stand next to the bike and hold E (gamepad X) to ride.
	   A ride starts in neutral (N) with the engine running: RightShift
	   puts it in 1st, W rides off.


	CONTROLS

	Keyboard  W throttle, S brake (front and rear linked), A/D lean
	          LeftShift gear up, RightShift gear down (1-N-2-3-4-5-6), N neutral
	          B rear brake, F engine, Space get off
	          Stopped in N, hold S for 1 s: reverse (R); in R, W stops the
	          bike, then 1st goes in
	Camera    right mouse drag to look around, wheel or I/O to zoom (all the
	          way in: helmet view), V chase/helmet view, C look back (held)
	Gamepad   R2 throttle, L2 brake (reverse), left stick lean, R1 up / L1
	          down (R1+L1 = N), Select engine, A get off, Y view, right stick
	          look around
	Touch     drag left/right on the left of the screen to lean, SHIFT UP /
	          DOWN above it, THROTTLE and BRAKE (reverse) at the bottom right,
	          ENGINE, NEUTRAL, VIEW, BACK (look back) and GET OFF on top; drag
	          anywhere else to look around


	SETTINGS (BikeConfig)

	Common ones:
	- Sound.Profile            engine sound ("YamahaR1", "HondaCBR600", "KawasakiZ1R")
	- Sound.Enabled            false: no sound
	- Camera.Enabled           false: Roblox's default camera
	- Dashboard.Enabled        false: no meter (rpm, gear, speed; bottom right)
	                           and no control tiles
	- Dashboard.SpeedUnit      "km/h", "mph" or "studs/s"
	- Dashboard.Hints          false: no control tiles (bottom left)
	- Dashboard.RedZoneRPM     where the meter's red zone starts (default
	                           11000); the gear turns red there too
	- Dashboard.TouchControls  false: no touch buttons on phones and tablets
	                           (for maps with their own, which drive the bike
	                           through the BikeTouch* attributes)
	- Diagnostics.Enabled      true: development lines in the Output (drive
	                           state changes and more); default false
	- Mount.ActionText / ObjectText   the ride prompt's text
	- Engine.AutoStartOnMount / StopOnDismount   start the engine on getting
	                           on, stop it on getting off

	The physics values (mass, suspension, tires, engine, gears) work
	together. Change one at a time and ride after each change.


	EXTERIOR

	This version has no body shell: it rides on its plain frame parts. A
	shell is a Model named Exterior inside the bike; the names of the groups
	inside it set how each part moves:
	  Body        fixed to the frame
	  Steering    turns with the handlebar
	  Fork        turns, and moves with the front suspension
	  FrontWheel  spins with the front wheel
	  RearWheel   spins with the rear wheel
	  Swingarm    pivots about its "Pivot" attachment
	Each wheel group's "Axle" attachment marks the wheel center, and the
	shell is fitted to the wheels at those points. The shell does not
	change the physics: the bike rides the same with or without it.


	IN A MAP

	- Several bikes: each one runs on its own scripts; they do not
	  interfere.
	- StreamingEnabled works: a far bike appears when you come close, and
	  its wheels and sound start again then.
	- The map's Gravity, AirDensity, wind (GlobalWind) and terrain and
	  material friction are used as they are. With other gravity the
	  suspension height and the braking follow it.
	- It does not fall over (by design). A step higher than the wheel axle
	  stops it like a wall.
	- A bike nobody rides holds its parking brake, so it stays put on
	  slopes.
	- Shift Lock is off while riding (it shares the gear keys) and comes
	  back on getting off.
	- A body shell, if one is added, does not collide: pressed against a
	  wall, it may sink in slightly.


	TROUBLESHOOTING

	Warnings in the Output from [BikeServer], [BikeControllerClient],
	[BikeCameraClient] and [BikeSoundClient] say what failed; when all is
	well they print nothing. During Play, select the bike model in the
	Explorer: its attributes BikeServerStatus, BikeControllerStatus,
	BikeCamera and BikeSound show each script's state.
]]

return {}
