extends Node
## Scripted playtest of the real game (scenes/main.tscn: GameMode + Ship + Player + SolarSystem).
##
##   godot --headless --fixed-fps 60 -s tools/dev/playtest.gd -- [session|soak|extras|all|quick] [soak_sec=180] [seed=1] [from=selene] [pace=1]
## (this file is the runner Node; tools/dev/playtest.gd is a tiny SceneTree bootstrap that loads
## it after the autoloads exist)
##
## session: start (landed on Terra Nova) -> take off -> climb to orbit (SPACE, above the
##   atmosphere) -> target Selene (T cycle) -> autopilot -> descend & land on Selene -> exit (F) ->
##   walk 50 m -> walk back, re-enter (F) -> take off -> target Aurelion -> autopilot: warp, drop
##   out -> target Terra Nova -> autopilot back -> descend & land on Terra Nova.
## extras: ocean landing (floats, exit blocked), gas-giant pressure floor, star autopilot stop.
## soak: N s of free flight with random inputs: NaN / teleport / falling-through-terrain checks.
## The ship is driven through its pilot inputs (`scripted` = a virtual pilot writes in_move /
## steer_dir / throttle / modes, like the keyboard does); GameMode does the enter/exit flow.
## Every step logs telemetry and PASS/FAIL; exit code 1 on any failure.

const DT := 1.0 / 60.0

var main: Node3D
var ship: Ship
var game: GameMode
var system: SolarSystem
var results: Array[String] = []
var failed := false
var frame := 0
var mode := "all"
## Start the session at a later step (fast iteration): "" | "selene" (5 km above Selene) | "aurelion"
var from_step := ""
## Real-time pacing near surfaces (terrain / collision streaming runs on worker threads in wall
## time: an unpaced headless sim at ~300 fps outruns it). 1 = real time, 0 = off. Applied while
## the gameplay body is below `pace_altitude` over a solid body.
var pace := 1.0
var pace_altitude := 15000.0
var _pacing := false
var _pace_t0 := 0
var _pace_f0 := 0
var soak_sec := 180.0
var rng := RandomNumberGenerator.new()
var warp_engaged := 0
var warp_dropped := 0
var _log_t := 0.0
var _messages: Array[String] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a in ["session", "soak", "extras", "all", "quick"]:
			mode = a
		elif a.begins_with("soak_sec="):
			soak_sec = float(a.substr(9))
		elif a.begins_with("pace="):
			pace = float(a.substr(5))
		elif a.begins_with("from="):
			from_step = a.substr(5)
		elif a.begins_with("seed="):
			rng.seed = int(a.substr(5))
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node3D
	get_tree().root.add_child(main)
	ship = main.get_node("World/Ship") as Ship
	game = main.get_node("GameMode") as GameMode
	system = main.get_node("World/SolarSystem") as SolarSystem
	if not main.get("started"):
		await main.session_started
	_result("load", true, "session ready in %d ms (main: %d ms)" % [Time.get_ticks_msec() - t0, main.get("load_ms")])
	ship.warp_engaged.connect(func() -> void: warp_engaged += 1)
	ship.warp_dropped.connect(func() -> void: warp_dropped += 1)
	ship.hud_message.connect(func(m: String) -> void: _messages.append(m))
	await _frames(30)
	_check_start()
	await _check_freecam()
	if mode == "session" or mode == "all":
		await _session()
	if mode == "extras" or mode == "all":
		await _extras()
	if mode == "soak" or mode == "all":
		await _soak()
	print("\n========== PLAYTEST SUMMARY ==========")
	for r in results:
		print(r)
	print("RESULT: %s (%d sim s, %d s wall)" % ["FAIL" if failed else "PASS", int(frame * DT),
		(Time.get_ticks_msec() - t0) / 1000])
	main.queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if failed else 0)


# ------------------------------------------------------------------ helpers

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
		frame += 1
		_pace_frame()


func _pace_frame() -> void:
	var want := pace > 0.0 and _near_surface()
	if want != _pacing:
		_pacing = want
		_pace_t0 = Time.get_ticks_usec()
		_pace_f0 = frame
	if not _pacing:
		return
	var target := float(frame - _pace_f0) * DT * 1.0e6 / pace
	var now := float(Time.get_ticks_usec() - _pace_t0)
	if now < target:
		OS.delay_usec(int(minf(target - now, 100000.0)))


func _near_surface() -> bool:
	var n: Node3D = game.get_gameplay_body() if game else null
	if n == null:
		return false
	var b: Node3D = Universe.get_nearest_body(n.global_position)
	return b is Planet and (b as Planet).get_altitude_global(n.global_position) < pace_altitude


func _result(step: String, ok: bool, info: String) -> void:
	var line := "[%s] %-28s %s" % ["PASS" if ok else "FAIL", step, info]
	results.append(line)
	print(line)
	if not ok:
		failed = true


func _body(n: String) -> Node3D:
	return system.get_body_node(n)


func _telemetry(tag: String, every := 2.0) -> void:
	_log_t += DT
	if _log_t < every:
		return
	_log_t = 0.0
	var h := ship.get_hud_data()
	print("  [%s t=%.0f] %s alt=%.0f v=%.0f vs=%.0f ρ=%.3f heat=%.2f thr=%.2f AP=%s body=%s tgt=%s %.0f km gear=%s landed=%s %s" % [
		tag, frame * DT, h["mode_name"], h["altitude"], h["speed"], h["vertical_speed"], h["atmosphere_density"],
		h["heat"], h["throttle"], h["autopilot"], h["body_name"], h["target_name"],
		float(h["target_distance"]) / 1000.0, h["gear_down"], h["landed"], h["message"]])


func _true_pos(n: Node3D) -> Vector3:
	var p := n.global_position
	return Vector3(p.x + Universe.origin_x, p.y + Universe.origin_y, p.z + Universe.origin_z)


func _clear_inputs() -> void:
	ship.in_move = Vector3.ZERO
	ship.in_stick = Vector2.ZERO
	ship.in_roll = 0.0
	ship.in_boost = false
	ship.steer_dir = Vector3.ZERO
	ship.steer_up = Vector3.ZERO


func _check_start() -> void:
	var h := ship.get_hud_data()
	var cam := get_viewport().get_camera_3d()
	var ok: bool = game.state == GameMode.State.SHIP and ship.landed and ship.gear_down \
		and h["body_name"] == "Terra Nova" and cam == ship.get_camera() and Universe.focus == ship \
		and system.focus != null and system.focus.name == "Terra Nova"
	var sun_el := rad_to_deg(asin(ship.up_dir.dot(system.sun_dir)))
	_result("start_state", ok, "state=%s landed=%s gear=%s body=%s cam=%s focus=%s sun=%.1f° alt=%.2f m" % [
		game.get_state_name(), ship.landed, ship.gear_down, h["body_name"], cam.name if cam else "-",
		Universe.focus.name if Universe.focus else "-", sun_el, ship.altitude])


## V: free camera takes over (camera, focus), flies 600 m away; the terrain under the landed ship
## keeps its fine LOD (second focus); V again returns to the ship camera.
func _check_freecam() -> void:
	game.toggle_freecam()
	await _frames(5)
	var fc := game.free_camera as Camera3D
	var ok1: bool = game.state == GameMode.State.FREECAM and fc != null and get_viewport().get_camera_3d() == fc \
		and Universe.focus == fc and system.active_camera() == fc and not ship.input_enabled
	fc.global_position += ship.up_dir * 400.0 + fc.global_basis.z * 450.0
	await _frames(60)
	var terra := (system.get_body("Terra Nova").planet as Planet).terrain
	var focus2 := terra.has_focus2
	game.toggle_freecam()
	await _frames(5)
	var ok2: bool = game.state == GameMode.State.SHIP and get_viewport().get_camera_3d() == ship.get_camera() \
		and Universe.focus == ship and ship.input_enabled
	await _frames(30)
	_result("freecam_toggle", ok1 and ok2 and focus2, "V: state FREECAM, camera/focus = free camera, ship input off: %s; terrain 2nd focus under the ship while away: %s; V again -> SHIP camera/focus/input: %s" % [
		ok1, focus2, ok2])


# ------------------------------------------------------------------ session

func _session() -> void:
	var terra := _body("Terra Nova")
	var selene := _body("Selene")
	var aurelion := _body("Aurelion")
	ship.scripted = true
	if from_step == "":
		await _takeoff_and_climb(terra, terra.get_atmosphere_height() + 8000.0, "takeoff_terra")
		# target Selene with the T key logic (cycle through bodies by distance)
		var found := false
		for i in 12:
			ship.cycle_target()
			if ship.target == selene:
				found = true
				break
		_result("target_selene", found, "target=%s" % (ship.target.get_body_name() if ship.target else "-"))
		await _autopilot_to(selene, 240.0, "autopilot_selene")
	elif from_step == "selene":
		var sr := system.get_body("Selene")
		var dd := system.sun_dir_from("Selene").rotated(Vector3.UP, 0.6)
		main.call("_ship_at", sr, dd * (sr.radius + 5000.0), main.call("_nose_basis", dd.cross(Vector3.UP), dd), Vector3.ZERO, Ship.Mode.SPACE)
		ship.target = selene
	if from_step in ["", "selene"]:
		await _descend_and_land(selene, "land_selene", 300.0)
		await _exit_walk_enter("selene")
		await _takeoff_and_climb(selene, 6000.0, "takeoff_selene")
	ship.target = aurelion
	warp_engaged = 0
	warp_dropped = 0
	await _autopilot_to(aurelion, 300.0, "warp_aurelion")
	_result("warp_engage_drop", warp_engaged > 0 and warp_dropped > 0, "engaged=%d dropped=%d" % [warp_engaged, warp_dropped])
	ship.target = terra
	warp_engaged = 0
	await _autopilot_to(terra, 300.0, "autopilot_terra")
	await _descend_and_land(terra, "land_terra", 900.0)


## Lift off (HOVER, Space), gear up, climb nose-up through ATMOSPHERE to SPACE until `alt`.
func _takeoff_and_climb(b: Node3D, alt: float, step: String) -> void:
	_clear_inputs()
	var t := 0.0
	var ok := false
	var max_heat := 0.0
	while t < 400.0:
		_clear_inputs()
		var up := ship.up_dir
		var fwd := -ship.global_basis.z
		fwd = (fwd - up * fwd.dot(up)).normalized()
		if ship.altitude < 60.0 and t < 20.0:
			ship.set_mode(Ship.Mode.HOVER, true)
			ship.in_move.y = 1.0          # Space: lift off (releases the landing clamps)
		elif ship.altitude < 1500.0 and ship.in_atmosphere:
			if ship.mode != Ship.Mode.ATMOSPHERE:
				ship.set_mode(Ship.Mode.ATMOSPHERE)
				ship.throttle = 1.0
			ship.steer_dir = (fwd + up * 1.2).normalized()
			ship.steer_up = up
		else:
			if ship.mode < Ship.Mode.SPACE:
				ship.set_mode(Ship.Mode.SPACE)
			ship.throttle = 1.0
			ship.steer_dir = (fwd * 0.25 + up).normalized()
			ship.steer_up = Vector3.ZERO
		max_heat = maxf(max_heat, ship.heat)
		_telemetry(step)
		if ship.body == b and ship.altitude > alt and not ship.in_atmosphere:
			ok = true
			break
		await _frames(1)
		t += DT
	ship.full_stop()
	await _frames(240)
	_clear_inputs()
	_result(step, ok and ship.mode == Ship.Mode.SPACE, "%.0f s: alt %.0f m, mode %s, in_atm=%s, max heat %.2f, speed after stop %.0f m/s" % [
		t, ship.altitude, Ship.MODE_NAMES[ship.mode], ship.in_atmosphere, max_heat, ship.vel.length()])


func _autopilot_to(b: Node3D, timeout: float, step: String) -> void:
	_clear_inputs()
	ship.target = b
	if not ship.autopilot:
		ship.toggle_autopilot()
	var t := 0.0
	var max_v := 0.0
	var min_surf := INF
	var max_mode := 0
	while t < timeout and ship.autopilot:
		max_v = maxf(max_v, ship.vel.length())
		max_mode = maxi(max_mode, ship.mode)
		min_surf = minf(min_surf, ship.surface_dist)
		_telemetry(step, 3.0)
		await _frames(1)
		t += DT
	await _frames(480)   # braking to a stop
	var d: float = b.global_position.distance_to(ship.global_position) - b.get_body_radius()
	var safe: float = ship.safe_orbit_altitude(b)
	var ok: bool = not ship.autopilot and d > safe * 0.8 and d < safe * 1.6 and ship.vel.length() < 300.0
	_result(step, ok, "%.0f s: dist to %s surface %.0f km (safe %.0f km), max speed %.0f km/s, top mode %s, speed now %.0f m/s" % [
		t, b.get_body_name(), d / 1000.0, safe / 1000.0, max_v / 1000.0, Ship.MODE_NAMES[max_mode], ship.vel.length()])


## Pilot descent: nose down in SPACE/ATMOSPHERE at a speed that follows the altitude, then HOVER
## level and settle on the gear (FA ground limiter makes the touchdown soft).
func _descend_and_land(b: Node3D, step: String, timeout: float) -> void:
	_clear_inputs()
	var t := 0.0
	var touch_v := 0.0
	var max_heat := 0.0
	var phase := 0
	while t < timeout and not ship.landed:
		_clear_inputs()
		var up := ship.up_dir
		var fwd := -ship.global_basis.z
		var hz := (fwd - up * fwd.dot(up))
		if hz.length() < 0.1:
			hz = ship.global_basis.y - up * ship.global_basis.y.dot(up)
		hz = hz.normalized()
		var alt := ship.altitude
		if alt > 400.0 and phase == 0:
			var m := Ship.Mode.ATMOSPHERE if ship.density > 0.05 else Ship.Mode.SPACE
			if ship.mode != m:
				ship.set_mode(m, true)
			# descend steeply; speed ~ altitude / 12 s, slower in thick air (heating)
			var want := clampf(alt / 12.0, 40.0, 1500.0 if ship.density < 0.01 else 450.0)
			ship.steer_dir = (hz * 0.35 - up).normalized()
			ship.steer_up = Vector3.ZERO
			ship.throttle = clampf(want / maxf(ship.speed_cap, 1.0), 0.02, 1.0)
		else:
			phase = 1
			if ship.mode != Ship.Mode.HOVER:
				ship.set_mode(Ship.Mode.HOVER, true)
			if alt > 3.0:
				ship.steer_dir = hz
				ship.steer_up = up
			if not ship.gear_down:
				ship.set_gear(true)
			ship.in_move.y = -1.0 if alt > 6.0 else (-0.25 if alt > 0.8 else 0.0)
		if ship.gear_contacts > 0 and touch_v == 0.0:
			touch_v = ship.vel.length()
		max_heat = maxf(max_heat, ship.heat)
		_telemetry(step)
		await _frames(1)
		t += DT
	_clear_inputs()
	await _frames(60)
	var water := ship.is_over_water()
	_result(step, ship.landed and ship.body == b, "%.0f s: landed=%s on %s, touchdown %.1f m/s, max heat %.2f, alt %.2f m, water=%s" % [
		t, ship.landed, ship.body.get_body_name() if ship.body else "-", touch_v, max_heat, ship.altitude, water])


func _exit_walk_enter(tag: String) -> void:
	await game.exit_ship()
	if game.state != GameMode.State.ON_FOOT:
		_result("exit_" + tag, false, "exit refused: can_exit=%s landed=%s contacts=%d water=%s" % [ship.can_exit(),
			ship.landed, ship.gear_contacts, ship.is_over_water()])
		return
	await _frames(60)
	var pl := game.player
	var ok: bool = game.state == GameMode.State.ON_FOOT and pl.is_grounded() and Universe.focus == pl \
		and get_viewport().get_camera_3d() == pl.get_camera()
	_result("exit_" + tag, ok, "state=%s grounded=%s feet alt=%.2f m focus=%s" % [game.get_state_name(),
		pl.is_grounded(), pl.altitude, Universe.focus.name if Universe.focus else "-"])
	# walk 50 m straight ahead (away from the hatch)
	pl.use_sim_input = true
	var start := _true_pos(pl)
	var t := 0.0
	var air := 0
	var n := 0
	var rescues0 := pl.rescue_count
	var min_alt := INF
	var max_alt := -INF
	pl.sim_move = Vector2(0, -1)
	while t < 40.0 and _true_pos(pl).distance_to(start) < 50.0:
		await _frames(1)
		t += DT
		n += 1
		if not pl.is_grounded():
			air += 1
		min_alt = minf(min_alt, pl.altitude)
		max_alt = maxf(max_alt, pl.altitude)
	var dist := _true_pos(pl).distance_to(start)
	_collision_debug(pl)
	pl.sim_move = Vector2.ZERO
	await _frames(20)
	_result("walk50_" + tag, dist >= 50.0 and pl.rescue_count == rescues0 and float(air) / maxf(n, 1) < 0.1,
		"%.1f m in %.1f s, airborne %.1f%%, feet alt %.2f..%.2f m, rescues %d, collision under feet: %s" % [
		dist, t, 100.0 * air / maxf(n, 1), min_alt, max_alt, pl.rescue_count - rescues0, pl.is_on_floor()])
	# walk back to the hatch and board
	t = 0.0
	while t < 60.0 and game.distance_to_hatch() > 2.5:
		pl.look_at_point(game._entry_point())
		pl.set_pitch_deg(0.0)
		pl.sim_move = Vector2(0, -1)
		await _frames(1)
		t += DT
	pl.sim_move = Vector2.ZERO
	pl.use_sim_input = false
	await _frames(10)
	var near := game.distance_to_hatch()
	await game.enter_ship()
	await _frames(30)
	ok = near < game.interact_distance and game.state == GameMode.State.SHIP and ship.is_piloted and Universe.focus == ship \
		and get_viewport().get_camera_3d() == ship.get_camera()
	_result("reenter_" + tag, ok, "hatch distance %.1f m after %.1f s, state=%s piloted=%s" % [near, t,
		game.get_state_name(), ship.is_piloted])
	ship.scripted = true


## Prints what collision exists under the player (terrain chunk bodies, a ray down).
func _collision_debug(pl: Player) -> void:
	var b: Node3D = Universe.get_dominant_body(pl.global_position)
	if b == null or not (b is Planet):
		return
	var terr := (b as Planet).terrain
	var bodies := 0
	var enabled := 0
	var nearest := INF
	for c in terr.get_children():
		if c is StaticBody3D:
			bodies += 1
			var cs := c.get_child(0) as CollisionShape3D
			if not cs.disabled:
				enabled += 1
				nearest = minf(nearest, (c as Node3D).global_position.distance_to(pl.global_position))
	var up: Vector3 = pl.current_up
	var q := PhysicsRayQueryParameters3D.create(pl.global_position + up * 2.0, pl.global_position - up * 5.0)
	q.exclude = [pl.get_rid()]
	var hit := pl.get_world_3d().direct_space_state.intersect_ray(q)
	print("  [collision] terrain focus %s (player local %s), focus2=%s, bodies %d (enabled %d, nearest %.0f m), ray hit: %s, stats %s" % [
		str(terr.focus), str(b.to_local(pl.global_position)), terr.has_focus2, bodies, enabled, nearest,
		str(hit.get("collider")) if hit else "none", str(terr.get_stats())])


# ------------------------------------------------------------------ extras

func _extras() -> void:
	ship.scripted = true
	if game.state != GameMode.State.SHIP:
		game.force_ship()
	var terra := system.get_body("Terra Nova")
	# --- ocean: hover down onto the sea, float, exit blocked
	var sea := Vector3.ZERO
	var base := terra.planet.config.get_base_level()
	var d0: Vector3 = main.get("start_site")
	for i in 1200:
		var spread := 0.04 + 0.6 * float(i) / 1200.0   # widening search around the start site
		var d := (d0 + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * spread).normalized()
		if terra.planet.get_height(d) < base - 60.0:
			sea = d
			break
	if sea == Vector3.ZERO:
		_result("ocean_landing", false, "no sea found near the start")
	else:
		var off := sea * (terra.planet.config.get_ocean_radius() + 30.0)
		main.call("_ship_at", terra, off, main.call("_nose_basis", sea.cross(Vector3.UP), sea), Vector3.ZERO, Ship.Mode.HOVER)
		system.build_terrain_now(system.active_camera())
		await _descend_and_land(terra.node, "ocean_landing", 120.0)
		var sea_alt := ship.global_position.distance_to(terra.node.global_position) - terra.planet.config.get_ocean_radius() - Ship.GROUND_OFFSET
		var before := game.state
		await game.exit_ship()
		await _frames(30)
		_result("ocean_exit_blocked", ship.is_over_water() and before == GameMode.State.SHIP and game.state == GameMode.State.SHIP,
			"over water=%s, state=%s, pads %.2f m above sea" % [ship.is_over_water(), game.get_state_name(), sea_alt])
	# --- gas giant: dive into Aurelion at full SPACE thrust, must be held at the pressure floor
	var a := system.get_body("Aurelion")
	var dn := system.sun_dir_from("Aurelion")
	var off2 := dn * (a.radius + 60000.0)
	main.call("_ship_at", a, off2, main.call("_nose_basis", -dn, Vector3.UP), -dn * 800.0, Ship.Mode.SPACE)
	_clear_inputs()
	var t := 0.0
	var min_alt := INF
	var msgs0 := _messages.size()
	while t < 60.0:
		ship.steer_dir = -ship.up_dir
		ship.throttle = 1.0
		min_alt = minf(min_alt, ship.altitude)
		_telemetry("gas_giant", 4.0)
		await _frames(1)
		t += DT
	var warned := false
	for i in range(msgs0, _messages.size()):
		warned = warned or _messages[i].contains("PRESSURE")
	_result("gas_giant_floor", min_alt >= Ship.GAS_GIANT_FLOOR.y - 50.0 and warned and not ship.landed,
		"min altitude above clouds %.0f m (floor %.0f), warned=%s, landed=%s" % [min_alt, Ship.GAS_GIANT_FLOOR.y, warned, ship.landed])
	ship.full_stop()
	await _frames(120)
	# --- star: autopilot must stop at a safe distance (from 1.5e7 m out)
	var st := system.get_body("Helios")
	var dir := system.sun_dir_from("Terra Nova") * -1.0
	main.call("_ship_at", st, dir * 3.0e6, main.call("_nose_basis", dir, Vector3.UP), Vector3.ZERO, Ship.Mode.SPACE)
	await _autopilot_to(st.node, 200.0, "autopilot_star")


# ------------------------------------------------------------------ soak

func _soak() -> void:
	ship.scripted = true
	if game.state != GameMode.State.SHIP:
		game.force_ship()
	main.call("_place_start")
	_clear_inputs()
	ship.in_move.y = 1.0
	await _frames(120)
	var t := 0.0
	var next := 0.0
	var nan := 0
	var jumps := 0
	var under := 0
	var far := 0
	var worst_jump := 0.0
	var prev := _true_pos(ship)
	var prev_v := ship.vel
	var modes_seen := {}
	var max_alt := 0.0
	var min_hull := INF
	while t < soak_sec:
		if t >= next:
			next = t + rng.randf_range(1.0, 3.5)
			_clear_inputs()
			ship.in_move = Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
			ship.in_stick = Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * rng.randf_range(0.0, 0.8)
			ship.in_roll = rng.randf_range(-1, 1) * 0.5
			ship.in_boost = rng.randf() < 0.3
			var r := rng.randf()
			if r < 0.12:
				ship.set_mode(rng.randi_range(0, 3))
			elif r < 0.16:
				ship.set_mode(Ship.Mode.WARP)
			elif r < 0.2:
				ship.full_stop()
			elif r < 0.24:
				ship.toggle_flight_assist()
			elif r < 0.27:
				ship.set_gear(not ship.gear_down)
			ship.throttle = rng.randf_range(-0.1, 1.0)
			# keep the soak near the ground (contacts, collision streaming): dive back down often
			if ship.altitude > 150.0 and rng.randf() < 0.45:
				ship.in_move.y = -1.0
				ship.in_move.z = rng.randf_range(-0.2, 1.0)
				if rng.randf() < 0.5:
					ship.steer_dir = (-ship.up_dir + (-ship.global_basis.z) * rng.randf_range(0.0, 1.5)).normalized()
				if rng.randf() < 0.3:
					ship.flight_assist = rng.randf() < 0.5   # FA off: unassisted crash into the ground
		await _frames(1)
		t += DT
		modes_seen[ship.mode] = true
		var p := _true_pos(ship)
		var v := ship.vel
		if is_nan(p.x + p.y + p.z + v.x + v.y + v.z):
			nan += 1
			continue
		var expect := (v + prev_v) * 0.5 * DT
		var err := (p - prev - expect).length()
		var tol := maxf(5.0, (v.length() + prev_v.length()) * DT * 0.6)
		if err > tol:
			jumps += 1
			worst_jump = maxf(worst_jump, err)
		if ship.global_position.length() > 3000.0:
			far += 1
		if ship.body and ship.body is Planet:
			# hull below the ground: the centre or any hull probe deeper than the clamp allows
			# (`altitude` is pad-based and goes negative when the ship lies on its side/back)
			var worst := ship._ground_alt(ship.body, ship.global_position)
			for hp in Ship.HULL_PROBES:
				worst = minf(worst, ship._ground_alt(ship.body, ship.global_transform * hp))
			min_hull = minf(min_hull, worst)
			if worst < -1.0:
				under += 1
		max_alt = maxf(max_alt, ship.altitude)
		prev = p
		prev_v = v
		_telemetry("soak", 10.0)
	_clear_inputs()
	ship.full_stop()
	_result("soak_%ds" % int(soak_sec), nan == 0 and jumps == 0 and under == 0 and far == 0,
		"NaN %d, teleports %d (worst %.1f m), hull below terrain %d frames (deepest probe %.2f m), off-origin %d frames, modes seen %s, max alt %.0f m" % [
		nan, jumps, worst_jump, under, min_hull, far, str(modes_seen.keys()), max_alt])
