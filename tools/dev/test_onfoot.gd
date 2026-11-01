extends SceneTree
## Headless on-foot test: walks the Player around FULL great circles and checks that it stays on
## the ground and upright everywhere (incl. the underside of the planet).
##
##   godot --headless --fixed-fps 60 -s tools/dev/test_onfoot.gd -- [sphere|terrain|all] [stations=36]
##
## 1. "sphere": analytic sphere (StaticBody3D + SphereShape3D, R = 160 m, g = 9.81) registered as a
##    celestial body. Continuous sprint along a great circle tilted 75° (passes the "bottom").
## 2. "terrain": real Selene terrain (R = 10 km, quadtree collision streaming). A continuous walk
##    of 62.8 km would take hours, so the circle is sampled by N stations (every 360/N degrees):
##    at each station the player is dropped 1 m above ground, LOD/collision are built, then it
##    sprints forward for 6 s (real physics, collision streaming every frame, 60 Hz pacing).
##    Plus one continuous 60 s sprint segment with paced frames (collision streaming realism).
## 3. "flow": scenes/test/onfoot_test.tscn — presses F (InputEventAction) near the hatch, checks
##    SHIP state / focus / camera, presses F again, checks the player is back on foot at the
##    ExitPoint, upright and grounded; V without free_camera.gd must not change the state.
## Criteria per frame (after landing): grounded by real collision (not the analytic safety net),
## |body up − local up| < 3°, feet within [−0.25, +0.35] m of the analytic surface.

var PLAYER: PackedScene
var Universe: Node   # autoload, resolved at runtime (-s scripts compile before autoloads)
const UP_TOL_DEG := 3.0
## Analytic height has small cliffs at crater-cell borders (TerrainGenerator); standing at such an
## edge the capsule rests on the half-res collision a bit above the analytic value.
const TERRAIN_ALT_TOL := 0.6
const CLIFF_ALT_TOL := 1.6


class SphereBody extends Node3D:
	var radius := 160.0
	var g := 9.81
	func get_body_name() -> String: return "TestSphere"
	func get_body_radius() -> float: return radius
	func get_soi_radius() -> float: return radius * 50.0
	func get_surface_gravity() -> float: return g
	func get_atmosphere_height() -> float: return 0.0
	func get_altitude_global(p: Vector3) -> float: return global_position.distance_to(p) - radius


var mode := "all"
var stations := 36
var gravity := 9.81   # Selene surface gravity for the terrain test (Planet default is 9.81)
var results: Array[String] = []
var failed := false


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		mode = a[0]
	if a.size() > 1:
		stations = int(a[1])
	if a.size() > 2:
		gravity = float(a[2])
	Universe = root.get_node("Universe")
	PLAYER = load("res://scenes/player/player.tscn")
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _make_world() -> Node3D:
	var w := Node3D.new()
	w.name = "World"
	root.add_child(w)
	Universe.set_world_root(w)
	Universe.origin_x = 0.0
	Universe.origin_y = 0.0
	Universe.origin_z = 0.0
	return w


func _run() -> void:
	if mode == "sphere" or mode == "all":
		await _test_sphere()
	if mode == "terrain" or mode == "all":
		await _test_terrain()
	if mode == "flow" or mode == "all":
		await _test_flow()
	print("\n==== test_onfoot results ====")
	for r in results:
		print(r)
	print("RESULT: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)


# ---------------------------------------------------------------------------- per-frame checks
class Stats:
	var frames := 0
	var air := 0          # not grounded (controller view: floor, coyote, ledge-edge rest)
	var nofloor := 0      # no physics floor contact (is_on_floor() false)
	var air_high := 0   # airborne and > 0.35 m above the analytic ground (real flight, e.g. off a cliff)
	var up_err_max := 0.0
	var alt_min := INF
	var alt_max := -INF
	var rescues := 0
	var steps := 0
	var detours := 0
	var dist := 0.0
	func line() -> String:
		return "frames=%d airborne=%d (flight >0.35 m: %d, no floor contact: %d) max_up_err=%.2f° alt=[%.3f, %.3f] m rescues=%d step-ups=%d detours=%d dist=%.0f m" % [
			frames, air, air_high, nofloor, up_err_max, alt_min, alt_max, rescues, steps, detours, dist]


func _check(p: CharacterBody3D, body: Node3D, st: Stats) -> void:
	st.frames += 1
	var up: Vector3 = Universe.get_up(p.global_position)
	st.up_err_max = maxf(st.up_err_max, rad_to_deg(p.global_basis.y.angle_to(up)))
	var alt: float = body.get_altitude_global(p.global_position)
	st.alt_min = minf(st.alt_min, alt)
	st.alt_max = maxf(st.alt_max, alt)
	if not p.is_on_floor():
		st.nofloor += 1
	if not p.is_grounded():
		st.air += 1
		if alt > 0.35:
			st.air_high += 1


func _ok(st: Stats, max_air_ratio: float, alt_tol := 0.35) -> bool:
	return st.up_err_max < UP_TOL_DEG and st.alt_min > -0.25 and st.alt_max < alt_tol \
		and st.rescues == 0 and float(st.air) / maxf(st.frames, 1) <= max_air_ratio


# ---------------------------------------------------------------------------- 1. analytic sphere
func _test_sphere() -> void:
	var w := _make_world()
	var body := SphereBody.new()
	w.add_child(body)
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = body.radius
	cs.shape = sh
	sb.add_child(cs)
	body.add_child(sb)
	Universe.register_body(body)
	var p: CharacterBody3D = PLAYER.instantiate()
	w.add_child(p)
	p.use_sim_input = true
	Universe.set_focus(p)
	# start on the equator facing a great circle tilted by 75 deg (goes through the lower hemisphere)
	var start_dir := Vector3(1, 0, 0)
	var fwd := Vector3(0, sin(deg_to_rad(75.0)), cos(deg_to_rad(75.0)))
	p.place_at(Transform3D(Basis.looking_at(fwd, start_dir), start_dir * (body.radius + 0.5)))
	await _frames(60)
	var st := Stats.new()
	var plane_n := start_dir.cross(fwd).normalized()
	var travelled := 0.0
	var prev_dir: Vector3 = (p.global_position - body.global_position).normalized()
	var off_plane_max := 0.0
	var min_y := INF
	p.sim_move = Vector2(0, -1)
	p.sim_sprint = true
	var max_frames := int(TAU * body.radius / p.sprint_speed * 60.0 * 1.3)
	while travelled < TAU and st.frames < max_frames:
		await physics_frame
		var d: Vector3 = (p.global_position - body.global_position).normalized()
		travelled += prev_dir.angle_to(d)
		prev_dir = d
		off_plane_max = maxf(off_plane_max, absf(d.dot(plane_n)))
		min_y = minf(min_y, d.y)
		if st.frames > 30:
			_check(p, body, st)
		else:
			st.frames += 1
	st.rescues = p.rescue_count
	st.dist = travelled * body.radius
	# jump test at the end
	p.sim_move = Vector2.ZERO
	await _frames(30)
	p.sim_jump = true
	var max_alt := 0.0
	var landed_ok := false
	for i in 240:
		await physics_frame
		max_alt = maxf(max_alt, body.get_altitude_global(p.global_position))
		if i > 20 and p.is_on_floor():
			landed_ok = true
			break
	var ok := travelled >= TAU and _ok(st, 0.01) and landed_ok and max_alt > 0.6
	var drift_deg := rad_to_deg(asin(clampf(off_plane_max, 0.0, 1.0)))
	results.append("[sphere R=%.0f m] %s: circle %.1f°, lowest point y=%.2f (−1 = bottom), drift from great circle %.2f°, %s, jump apex %.2f m, landed=%s" % [
		body.radius, "PASS" if ok else "FAIL", rad_to_deg(travelled), min_y, drift_deg, st.line(), max_alt, landed_ok])
	failed = failed or not ok
	w.queue_free()
	await _frames(2)


# ---------------------------------------------------------------------------- 2. Selene terrain
func _test_terrain() -> void:
	var w := _make_world()
	var planet: Planet = (load("res://scenes/planets/planet.tscn") as PackedScene).instantiate()
	planet.config = load("res://src/planets/presets/selene.tres")
	planet.auto_focus_camera = false
	planet.surface_gravity = gravity
	w.add_child(planet)
	Universe.register_body(planet)
	var p: CharacterBody3D = PLAYER.instantiate()
	w.add_child(p)
	p.use_sim_input = true
	Universe.set_focus(p)
	var R := planet.config.radius
	# great circle through both poles and the "bottom" (tilted so it is not axis-aligned)
	var a0 := Vector3(1, 0.05, 0.1).normalized()
	var n := a0.cross(Vector3(0.2, 1, 0.1)).normalized()
	var b0 := n.cross(a0).normalized()
	var all_ok := true
	var total := Stats.new()
	var worst := ""
	var t_start := Time.get_ticks_msec()
	var station_fail := 0
	for i in stations:
		var ang := TAU * float(i) / float(stations)
		var dir := (a0 * cos(ang) + b0 * sin(ang)).normalized()
		var fwd := (a0 * -sin(ang) + b0 * cos(ang)).normalized()   # tangent along the circle
		var st := await _station(planet, p, dir, fwd)
		var ok := _ok(st, 0.08, TERRAIN_ALT_TOL)
		if not ok:
			all_ok = false
			station_fail += 1
			worst += "\n    station %d (%.0f°, dir %s): %s" % [i, rad_to_deg(ang), str(dir.snapped(Vector3.ONE * 0.01)), st.line()]
		total.frames += st.frames
		total.air += st.air
		total.air_high += st.air_high
		total.nofloor += st.nofloor
		total.up_err_max = maxf(total.up_err_max, st.up_err_max)
		total.alt_min = minf(total.alt_min, st.alt_min)
		total.alt_max = maxf(total.alt_max, st.alt_max)
		total.rescues += st.rescues
		total.steps += st.steps
		total.detours += st.detours
		total.dist += st.dist
	results.append("[Selene stations x%d, every %.0f°] %s (%d failed): %s, %.0f s" % [stations, 360.0 / stations,
		"PASS" if all_ok else "FAIL", station_fail, total.line(), (Time.get_ticks_msec() - t_start) / 1000.0] + worst)
	failed = failed or not all_ok
	# continuous paced segment (collision streaming must keep up with a sprinting player)
	var dir0 := (a0 * cos(0.3) + b0 * sin(0.3)).normalized()
	var st2 := await _station(planet, p, dir0, n.cross(dir0), 60 * 60, true)
	# Selene's height field has cliffs up to ~1.4 m (crater-cell borders) that a sprinting player
	# legitimately drops off, hence the larger altitude tolerance for this free-running segment.
	var ok2 := _ok(st2, 0.08, CLIFF_ALT_TOL)
	results.append("[Selene continuous 60 s sprint, paced 60 Hz] %s: %s, airborne %.1f%%" % [
		"PASS" if ok2 else "FAIL", st2.line(), 100.0 * st2.air / maxf(st2.frames, 1)])
	failed = failed or not ok2
	w.queue_free()
	await _frames(2)


func _station(planet: Planet, p: CharacterBody3D, dir: Vector3, fwd: Vector3, walk_frames := 360, paced := false) -> Stats:
	# floating origin: move the world so the station is near (0,0,0) — like the real game does
	Universe.shift_origin(planet.to_global(planet.get_surface_point(dir)))
	var surf := planet.to_global(planet.get_surface_point(dir))
	var up := dir
	p.velocity = Vector3.ZERO
	p.rescue_count = 0
	p.place_at(Transform3D(Basis.looking_at(fwd, up), surf + up * 1.0))
	planet.set_focus_global(p.global_position)
	planet.terrain.build_until_stable()
	var st := Stats.new()
	p.sim_move = Vector2.ZERO
	# settle: fall 1 m, land
	for i in 90:
		await physics_frame
		planet.set_focus_global(p.global_position)
	p.rescue_count = 0
	p.step_count = 0
	p.sim_move = Vector2(0, -1)
	p.sim_sprint = true
	var start: Vector3 = p.global_position
	var prev: Vector3 = start
	var blocked := 0
	for i in walk_frames:
		var t0 := Time.get_ticks_usec()
		await physics_frame
		planet.set_focus_global(p.global_position)
		st.dist += prev.distance_to(p.global_position)
		prev = p.global_position
		if i > 5:
			_check(p, planet, st)
		# like a player would: walk around obstacles that block us (cliffs, crater walls)
		if i > 30 and p.get_horizontal_speed() < 0.5:
			blocked += 1
			if blocked > 30:
				p.rotate_yaw(0.8)
				st.detours += 1
				blocked = 0
		else:
			blocked = 0
		if paced and OS.get_environment("ONFOOT_VERBOSE") != "" and i % 60 == 0:
			var fl := rad_to_deg(p.get_floor_normal().angle_to(p.up_direction)) if p.is_on_floor() else -1.0
			print("  t=%2ds dist=%.0f alt=%.2f floor_slope=%.0f° wall=%s hs=%.1f steps=%d fail=%s" % [i / 60, st.dist,
				planet.get_altitude_global(p.global_position), fl, p.is_on_wall(), p.get_horizontal_speed(), p.step_count, p.step_fail])
			if p.is_on_wall() and p.get_horizontal_speed() < 0.5:
				_profile(planet, p)
			if p.is_on_wall():
				for k in p.get_slide_collision_count():
					var c := p.get_slide_collision(k)
					var lp: Vector3 = c.get_position() - p.global_position
					var cn: Variant = _find_chunk(planet.terrain, c.get_collider())
					print("     hit %s n·up=%.2f h=%.2f level=%s/%d stats=%s" % [str(c.get_normal().snapped(Vector3.ONE * 0.01)),
						c.get_normal().dot(p.up_direction), lp.dot(p.up_direction), str(cn.level) if cn else "?",
						planet.terrain.max_level, str(planet.terrain.get_stats()).left(90)])
		if paced:
			var used := (Time.get_ticks_usec() - t0) / 1000.0
			OS.delay_msec(int(maxf(16.0 - used, 0.0)))
	st.rescues = p.rescue_count
	st.steps = p.step_count
	p.sim_move = Vector2.ZERO
	return st


func _find_chunk(t: PlanetTerrain, body: Object) -> Variant:
	var stack: Array = t._roots.duplicate()
	while not stack.is_empty():
		var n: Variant = stack.pop_back()
		if n.body == body:
			return n
		stack.append_array(n.children)
	return null


## Debug: analytic vs collision (raycast) height profile ahead of the player.
func _profile(planet: Planet, p: CharacterBody3D) -> void:
	var up: Vector3 = p.up_direction
	var f: Vector3 = p.get_flat_forward()
	var space := p.get_world_3d().direct_space_state
	var line := "     profile (d: analytic / ray):"
	for i in 13:
		var d := -0.4 + i * 0.1
		var pt: Vector3 = p.global_position + f * d
		var ana: float = -planet.get_altitude_global(pt)
		var q := PhysicsRayQueryParameters3D.create(pt + up * 2.0, pt - up * 2.0, 1)
		var hit := space.intersect_ray(q)
		var rh: float = (hit["position"] - p.global_position).dot(up) if hit else NAN
		line += " %.1f:%.2f/%.2f" % [d, ana, rh]
	print(line)


# ---------------------------------------------------------------------------- 3. enter/exit flow
func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await process_frame


func _test_flow() -> void:
	var scene: Node = (load("res://scenes/test/onfoot_test.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await _frames(30)
	var gm: Node = scene.get_node("GameMode")
	var p: CharacterBody3D = gm.player
	var ship: Node3D = gm.ship
	var log := []
	var ok := true
	# walk the player next to the hatch
	var hatch: Vector3 = ship.get_entry_point()
	var up: Vector3 = Universe.get_up(hatch)
	p.place_at(Transform3D(ship.global_basis, hatch + ship.global_basis.x * -2.5 + up * 0.05))
	await _frames(30)
	var near: float = gm.distance_to_hatch()
	var prompt: String = gm.hud.prompt_text
	log.append("near hatch %.2f m, prompt='%s'" % [near, prompt])
	ok = ok and prompt == "Сесть в корабль"
	await _press("interact")
	await _frames(90)
	var in_ship: bool = gm.state == 0 and ship.is_piloted and not p.visible and Universe.focus == ship \
		and root.get_viewport().get_camera_3d() == ship.get_camera()
	log.append("after F: state=%s piloted=%s player_visible=%s focus_ship=%s exit_prompt='%s'" % [gm.get_state_name(),
		ship.is_piloted, p.visible, Universe.focus == ship, gm.hud.prompt_text])
	ok = ok and in_ship
	# V without free_camera.gd: state unchanged
	var has_fc := ResourceLoader.exists("res://src/core/free_camera.gd")
	await _press("freecam_toggle")
	await _frames(5)
	if not has_fc:
		ok = ok and gm.state == 0
		log.append("V without free_camera.gd: state=%s (unchanged)" % gm.get_state_name())
	else:
		log.append("V with free_camera.gd: state=%s" % gm.get_state_name())
		await _press("freecam_toggle")
		await _frames(5)
	await _press("interact")
	await _frames(120)
	var exit_pt: Vector3 = ship.get_entry_point()
	var d: float = p.global_position.distance_to(exit_pt)
	var up_err: float = rad_to_deg(p.global_basis.y.angle_to(Universe.get_up(p.global_position)))
	var on_foot: bool = gm.state == 1 and p.visible and Universe.focus == p and not ship.is_piloted \
		and root.get_viewport().get_camera_3d() == p.get_camera()
	log.append("after F: state=%s player %.2f m from ExitPoint, up_err=%.2f°, on_floor=%s, rescues=%d" % [
		gm.get_state_name(), d, up_err, p.is_on_floor(), p.rescue_count])
	ok = ok and on_foot and d < 1.5 and up_err < 3.0 and p.is_grounded()
	results.append("[flow enter/exit] %s: %s" % ["PASS" if ok else "FAIL", "; ".join(log)])
	failed = failed or not ok
	scene.queue_free()
	await _frames(2)
