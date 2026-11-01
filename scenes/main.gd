extends Node3D
## Main scene: the whole star system + a free camera (no ship yet).
## World (Universe.world_root) holds the SolarSystem and the camera; the camera is the
## floating-origin focus. Capture presets (tools/shot.sh scenes/main.tscn --cam=<name>):
##   system_overview, terra_orbit, terra_limb_sunrise, terra_entry, terra_low, terra_ground,
##   terra_sunset_ground, selene_surface_terra_rise, ignis_low, glacia_low, aurelion_rings,
##   vex_aurelion, star_from_ignis
## Extra args: --fov=<deg>, --exposure=<x> (manual), --no_shadows, --quality=0..2.

const START_PRESET := "terra_orbit"

@onready var world: Node3D = $World
@onready var system: SolarSystem = $World/SolarSystem
@onready var cam: FreeCamera = $World/FreeCamera
@onready var backdrop: WorldEnvironment = $SpaceBackdrop


func _ready() -> void:
	add_to_group("capture_target")
	Universe.set_world_root(world)
	Universe.set_focus(cam)
	system.camera = cam
	system.set_environment(backdrop.environment)
	if Capture.args.has("no_shadows"):
		system.shadows_enabled = false
	if Capture.args.has("quality"):
		system.set_quality(int(Capture.args["quality"]))
	# debug overrides on Terra Nova's layers: --cu_<uniform>=v (clouds), --au_ (atmosphere),
	# --ou_ (ocean), --tu_ (terrain)
	var terra := system.get_body("Terra Nova")
	for k: String in Capture.args:
		var v: Variant = str_to_var(Capture.args[k])
		if k.begins_with("cu_") and terra.clouds:
			terra.clouds.material.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("au_") and terra.atmo:
			terra.atmo.mat_scatter.set_shader_parameter(k.substr(3), v)
			terra.atmo.mat_transmit.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("ou_") and terra.ocean:
			terra.ocean.material.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("tu_"):
			terra.planet.terrain_material.set_shader_parameter(k.substr(3), v)
		elif k == "hide":   # --hide=Terra_Nova/Atmosphere+Aurelion (body or body/component)
			for item: String in String(Capture.args[k]).split("+"):
				var parts := item.replace("_", " ").split("/")
				var rec := system.get_body(parts[0])
				if parts.size() == 1:
					rec.node.visible = false
				elif rec.planet:
					rec.planet.get_component(parts[1]).visible = false
	cam.make_current()
	var capture_drives := Capture.active and (Capture.args.has("cam") or Capture.args.has("shots"))
	if Capture.args.has("bench"):
		_bench.call_deferred()
	elif not capture_drives:
		apply_capture_preset(Capture.get_preset() if Capture.get_preset() != "" else START_PRESET)


## CPU benchmark (headless ok): descent from 150 km to 50 m over Terra Nova in N frames,
## reports main-thread process time. `godot --headless --path . scenes/main.tscn -- --bench=600`
func _bench() -> void:
	var frames := int(Capture.args["bench"])
	if frames <= 1:
		frames = 600
	var t := system.get_body("Terra Nova")
	var n := Vector3(0.3, 0.5, -0.8).normalized()
	var ground := _ground_r(t, n)
	var samples: Array[float] = []
	for i in frames:
		var f := float(i) / float(frames - 1)
		var alt := 150000.0 * pow(50.0 / 150000.0, f)
		var off := n * (ground + alt)
		system.place_camera(cam, t.pos, off, off - n * 1000.0 + n.cross(Vector3.UP) * 3000.0, n.cross(Vector3.RIGHT))
		await get_tree().process_frame
		samples.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	samples.sort()
	var sum := 0.0
	for v in samples:
		sum += v
	print("[bench] %d frames: process avg %.2f ms, p50 %.2f, p95 %.2f, max %.2f ms" % [frames,
		sum / frames, samples[frames / 2], samples[int(frames * 0.95)], samples[frames - 1]])
	print("[bench] SolarSystem._frame avg %.3f ms, max %.3f ms" % [system.frame_ms_avg, system.frame_ms_max])
	print("[bench] terrain stats: ", t.planet.terrain.get_stats())
	get_tree().quit()


func apply_capture_preset(preset: String) -> void:
	# site selection reads the baked cloud weather back: wait until it has been rendered
	var terra := system.get_body("Terra Nova")
	for i in 10:
		if terra.clouds == null or terra.clouds.weather_at(Vector3.UP).x >= 0.0:
			break
		await get_tree().process_frame
	cam.fov = 60.0
	cam.near = 0.1
	cam.velocity = Vector3.ZERO
	if terra.clouds:   # presets may rotate the weather for framing; start from the default
		var recv: Array = [terra.planet.terrain_material]
		if terra.ocean:
			recv.append(terra.ocean.material)
		terra.clouds.set_rotation_offset(0.0, recv)
	match preset:
		"system_overview": _system_overview()
		"terra_orbit": _terra_orbit()
		"terra_limb_sunrise": _terra_limb_sunrise()
		"terra_entry": _terra_entry()
		"terra_low": _terra_low()
		"terra_ground": _terra_ground()
		"terra_sunset_ground": _terra_sunset_ground()
		"selene_surface_terra_rise": _selene_terra_rise()
		"ignis_low": _ignis_low()
		"glacia_low": _glacia_low()
		"aurelion_rings": _aurelion_rings()
		"vex_aurelion": _vex_aurelion()
		"star_from_ignis": _star_from_ignis()
		"terra_night_ground": _terra_night_ground()
		"ignis_orbit": _orbit_view("Ignis", 3.4)
		"glacia_orbit": _orbit_view("Glacia", 3.6)
		"selene_orbit": _orbit_view("Selene", 4.0)
		"vex_orbit": _orbit_view("Vex", 4.0)
		_:
			push_warning("main: unknown preset " + preset)
			_terra_orbit()
	if Capture.args.has("fov"):
		cam.fov = float(Capture.args["fov"])
	var t0 := Time.get_ticks_msec()
	system.build_terrain_now(cam)
	if Capture.args.has("exposure"):
		system.auto_exposure = false
		system.exposure_space = float(Capture.args["exposure"])
	var f := system.focus
	if f:
		var upv := (cam.global_position - f.node.global_position).normalized()
		print("[main]   sun elev %.1f deg, sun_dir %s" % [rad_to_deg(asin(upv.dot(system.sun_dir))), str(system.sun_dir)])
	for bn in ["Aurelion", "Selene", "Terra Nova", "Helios"]:
		var bnode := system.get_body_node(bn)
		var vis := not cam.is_position_behind(bnode.global_position)
		var sp := cam.unproject_position(bnode.global_position) if vis else Vector2(-1, -1)
		var rr := system.get_body(bn)
		print("[main]   %s screen=%s dist=%.0f km k=%.5f prio=%d" % [bn, str(sp), bnode.global_position.length() / 1000.0, rr.k, rr.prio_base])
	print("[main] %s: focus=%s alt=%.0f m, terrain built in %d ms" % [preset,
		f.name if f else "-", _alt(f) if f else -1.0, Time.get_ticks_msec() - t0])


# ---------------------------------------------------------------------------------------
# Geometry helpers (system frame == world orientation; planets are not rotated)
# ---------------------------------------------------------------------------------------

func _rec(n: String) -> SolarSystem.BodyRec:
	return system.get_body(n)


func _alt(r: SolarSystem.BodyRec) -> float:
	return system._altitude(r, cam.global_position)


func _dir_to(from_body: String, to_body: String) -> Vector3:
	return (_rec(to_body).pos - _rec(from_body).pos).normalized()


## Surface height (m above radius) of a planet along a direction.
func _h(r: SolarSystem.BodyRec, n: Vector3) -> float:
	return r.planet.get_height(n)


## Ground radius (terrain or sea surface, whichever is higher).
func _ground_r(r: SolarSystem.BodyRec, n: Vector3) -> float:
	var g := r.radius + _h(r, n)
	if r.planet.config.has_ocean_surface():
		g = maxf(g, r.planet.config.get_ocean_radius())
	return g


## Unit surface normals n with n.s = sin(e1) and n.t = sin(e2) (sun elevation e1, target
## elevation e2). Returns up to two solutions (mirror images).
func _two_elev(s: Vector3, t: Vector3, e1_deg: float, e2_deg: float) -> Array[Vector3]:
	var a1 := sin(deg_to_rad(e1_deg))
	var a2 := sin(deg_to_rad(e2_deg))
	var c := s.dot(t)
	var det := 1.0 - c * c
	var out: Array[Vector3] = []
	if det < 1e-6:
		return out
	var a := (a1 - a2 * c) / det
	var b := (a2 - a1 * c) / det
	var p := s * a + t * b
	var rest := 1.0 - p.length_squared()
	if rest < 0.0:
		return out
	var w := s.cross(t).normalized()
	out.append((p + w * sqrt(rest)).normalized())
	out.append((p - w * sqrt(rest)).normalized())
	return out


## Tangent frame at normal n: forward = direction toward `toward` projected on the horizon.
func _horizon_dir(n: Vector3, toward: Vector3) -> Vector3:
	var f := toward - n * toward.dot(n)
	if f.length() < 1e-5:
		f = n.cross(Vector3.RIGHT)
	return f.normalized()


## Camera `height` m above the ground at surface normal n of body r, looking along `look`.
func _place_ground(r: SolarSystem.BodyRec, n: Vector3, height: float, look: Vector3) -> void:
	var off := n * (_ground_r(r, n) + height)
	system.place_camera(cam, r.pos, off, off + look * 1000.0, n)


## Camera at an offset from body r's centre looking at `target_off` (also relative to r).
func _place_space(r: SolarSystem.BodyRec, off: Vector3, target_off: Vector3, up := Vector3.UP) -> void:
	system.place_camera(cam, r.pos, off, target_off, up)


## Points on the circle of constant sun elevation at body r; returns the best by `score`.
func _search_sun_circle(r: SolarSystem.BodyRec, s: Vector3, elev_deg: float, score: Callable, n_samples := 720) -> Vector3:
	var a := (Vector3.UP if absf(s.y) < 0.9 else Vector3.RIGHT).cross(s).normalized()
	var b := s.cross(a)
	var e := sin(deg_to_rad(elev_deg))
	var c := sqrt(1.0 - e * e)
	var best := s
	var best_s := -INF
	for i in n_samples:
		var az := TAU * float(i) / float(n_samples)
		var n := (s * e + (a * cos(az) + b * sin(az)) * c).normalized()
		var v: float = score.call(n)
		if v > best_s:
			best_s = v
			best = n
	return best


## Cloud coverage (0..1) where the ray from surface normal n along `dir` crosses the cloud
## layer (0 when unknown).
func _cloud_cov(r: SolarSystem.BodyRec, n: Vector3, dir: Vector3) -> float:
	if r.clouds == null:
		return 0.0
	var up := maxf(dir.dot(n), 0.05)
	var c := 0.0
	for ch: float in [1500.0, 2500.0, 3500.0, 4500.0]:
		var p := n * r.radius + dir * (ch / up)
		c = maxf(c, r.clouds.weather_at(p.normalized()).x)
	return c


## Rotates the weather map of body r (capture framing) so the sky along `dirs` from the
## surface point n is as clear as possible (weights per direction).
func _clear_weather(r: SolarSystem.BodyRec, n: Vector3, dirs: Array, weights: Array) -> void:
	if r.clouds == null or r.clouds.weather_at(Vector3.UP).x < 0.0:
		return
	var recv: Array = [r.planet.terrain_material]
	if r.ocean:
		recv.append(r.ocean.material)
	var best_a := 0.0
	var best := INF
	for i in 72:
		var a := TAU * float(i) / 72.0
		r.clouds.set_rotation_offset(a)
		var c := 0.0
		for j in dirs.size():
			c += _cloud_cov(r, n, dirs[j]) * float(weights[j])
		if c < best:
			best = c
			best_a = a
	r.clouds.set_rotation_offset(best_a, recv)


## Rotates the weather so the view from altitude shows broken clouds (mean coverage ~0.4).
func _partial_weather(r: SolarSystem.BodyRec, n: Vector3, look: Vector3) -> void:
	if r.clouds == null or r.clouds.weather_at(Vector3.UP).x < 0.0:
		return
	var recv: Array = [r.planet.terrain_material]
	if r.ocean:
		recv.append(r.ocean.material)
	var f := _horizon_dir(n, look)
	var side := n.cross(f)
	var best_a := 0.0
	var best := INF
	for i in 72:
		var a := TAU * float(i) / 72.0
		r.clouds.set_rotation_offset(a)
		var c := 0.0
		var cnt := 0.0
		for k in 6:
			for sgn: float in [-1.0, 0.0, 1.0]:
				var d := (n * r.radius + (f * (8000.0 + 9000.0 * k) + side * sgn * 9000.0)).normalized()
				c += maxf(r.clouds.weather_at(d).x, 0.0)
				cnt += 1.0
		var v := absf(c / cnt - 0.25)
		if v < best:
			best = v
			best_a = a
	r.clouds.set_rotation_offset(best_a, recv)


## How much (deg) the terrain toward the sun rises above the sun elevation (0 = sunlit).
func _sun_blocked(r: SolarSystem.BodyRec, n: Vector3, s: Vector3, sun_elev: float) -> float:
	var f := _horizon_dir(n, s)
	var h0 := _h(r, n)
	var worst := 0.0
	for k in 8:
		var dist := 150.0 * pow(1.8, k)
		var d := (n * r.radius + f * dist).normalized()
		# curvature drop of the far point below the local horizontal
		var drop := dist * dist / (2.0 * r.radius)
		var ang := rad_to_deg(atan2(_h(r, d) - h0 - drop, dist))
		worst = maxf(worst, ang - sun_elev + 1.5)
	return worst


## Max terrain height (above sea level / base) along `dir` from n, out to `dist` m.
func _max_ahead(r: SolarSystem.BodyRec, n: Vector3, dir: Vector3, dist: float, steps := 10) -> float:
	var m := -INF
	for k in steps:
		var d := (n * r.radius + dir * dist * float(k + 1) / float(steps)).normalized()
		m = maxf(m, _h(r, d))
	return m - r.planet.config.get_base_level()


# ---------------------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------------------

func _terra_orbit() -> void:
	var t := _rec("Terra Nova")
	var ds := _dir_to("Terra Nova", "Selene")
	var da := _dir_to("Terra Nova", "Aurelion")
	var mid := (ds + da).normalized()
	var u := (-mid + Vector3.UP * 0.25).normalized()
	var off := u * 205000.0
	var look := mid * 60000.0
	_place_space(t, off, look, Vector3.UP)
	cam.fov = 62.0


func _terra_limb_sunrise() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var dist := 128000.0
	var top := t.atmo.get_top_radius() if t.atmo else t.radius
	var alpha := asin((t.radius + 3000.0) / dist)       # limb of the visible planet
	var ang := alpha + deg_to_rad(0.35)               # sun centre just above the solid limb
	var w := s.cross(Vector3.UP).normalized()
	# camera direction c: angle between -c and s equals `ang`
	var c := (-s * cos(ang) + w * sin(ang)).normalized()
	c = c.rotated(s, deg_to_rad(-25.0))
	var off := c * dist
	var look := s.rotated(s.cross(c).normalized(), deg_to_rad(-6.0))
	_place_space(t, off, off + look * 1000.0, c)
	cam.fov = 55.0
	var _u := top


func _terra_entry() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var da := _dir_to("Terra Nova", "Aurelion")
	var base := t.planet.config.get_base_level()
	var n := _search_sun_circle(t, s, 28.0, func(nn: Vector3) -> float:
		var h := _h(t, nn) - base
		var f := _horizon_dir(nn, s.cross(nn))
		var land := _max_ahead(t, nn, f, 60000.0, 8)
		return -absf(h - 50.0) * 0.001 + clampf(land, 0.0, 3000.0) * 0.002 + nn.dot(da) * 2.0)
	var look := _horizon_dir(n, s.cross(n))
	# the horizon of a 60 km planet seen from 30 km is ~48 deg below the horizontal
	var gr := _ground_r(t, n)
	var dip := acos(gr / (gr + 30000.0))
	look = look.rotated(look.cross(n).normalized(), -(dip - deg_to_rad(14.0)))
	_partial_weather(t, n, look)
	_place_ground(t, n, 30000.0, look)
	cam.fov = 65.0


func _terra_low() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var base := t.planet.config.get_base_level()
	var best_n := s
	var best_look := Vector3.FORWARD
	var best := -INF
	for elev: float in [26.0, 34.0]:
		var a := (Vector3.UP).cross(s).normalized()
		var b := s.cross(a)
		var e := sin(deg_to_rad(elev))
		for i in 360:
			var az := TAU * float(i) / 360.0
			var n := (s * e + (a * cos(az) + b * sin(az)) * sqrt(1.0 - e * e)).normalized()
			var h := _h(t, n) - base
			if h < -150.0 or h > 60.0:
				continue
			# look across the sun (side light): mountains ahead, coast near
			for side: float in [-1.0, 1.0]:
				var f := _horizon_dir(n, s.cross(n) * side + s * 0.35)
				var m := _max_ahead(t, n, f, 14000.0, 7)
				var score := clampf(m, 0.0, 3500.0) - absf(h) * 4.0
				if score > best:
					best = score
					best_n = n
					best_look = f
	var look := (best_look - best_n * 0.12).normalized()
	_place_ground(t, best_n, 1000.0, look)
	cam.fov = 65.0


func _terra_ground() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var da := _dir_to("Terra Nova", "Aurelion")
	var base := t.planet.config.get_base_level()
	var best_n := Vector3.ZERO
	var best := -INF
	for e1: float in [14.0, 17.0]:
		for e2: float in [12.0, 14.0]:
			for n: Vector3 in _two_elev(s, da, e1, e2):
				for jitter in 40:
					var nn := n
					if jitter > 0:
						var rng := RandomNumberGenerator.new()
						rng.seed = jitter * 7919 + int(e1 * 13.0 + e2)
						nn = (n + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.05).normalized()
					var h := _h(t, nn) - base
					if h < 15.0 or h > 900.0:
						continue
					var f := _horizon_dir(nn, da)
					var m := _max_ahead(t, nn, f, 9000.0, 6) - h
					var tt := nn.cross(f)
					var slope := 0.0
					for em: float in [10.0, 60.0, 200.0]:
						var e := em / t.radius
						slope += (absf(_h(t, (nn + f * e).normalized()) - _h(t, (nn - f * e).normalized())) \
							+ absf(_h(t, (nn + tt * e).normalized()) - _h(t, (nn - tt * e).normalized()))) * 10.0 / em
					# relief to the sides (framing), open view toward the giant, gentle ground
					var side_m := maxf(_max_ahead(t, nn, (f + tt).normalized(), 7000.0, 5),
						_max_ahead(t, nn, (f - tt).normalized(), 7000.0, 5)) - h
					var shade := _sun_blocked(t, nn, s, e1)
					var clouds := _cloud_cov(t, nn, s) * 2.0 + _cloud_cov(t, nn, da) * 3.0
					var score := clampf(side_m, 0.0, 900.0) * 0.002 - maxf(m - 250.0, 0.0) * 0.01 \
						- slope * 1.0 - shade * 3.0 - clouds * 2.0
					if score > best:
						best = score
						best_n = nn
	if best_n == Vector3.ZERO:
		best_n = _two_elev(s, da, 18.0, 10.0)[0]
	_clear_weather(t, best_n, [s, da, best_n], [3.0, 3.0, 1.0])
	print("[main]   ground site: clouds sun %.2f view %.2f here %.2f" % [_cloud_cov(t, best_n, s),
		_cloud_cov(t, best_n, da), _cloud_cov(t, best_n, best_n)])
	var look := _horizon_dir(best_n, da)
	look = (look + best_n * 0.17).normalized()
	_place_ground(t, best_n, 2.0, look)
	cam.fov = 70.0


func _terra_sunset_ground() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var base := t.planet.config.get_base_level()
	var n := _search_sun_circle(t, s, 2.5, func(nn: Vector3) -> float:
		var h := _h(t, nn) - base
		if h < 8.0 or h > 400.0:
			return -INF
		var f := _horizon_dir(nn, s)
		var sea := _max_ahead(t, nn, f, 6000.0, 6) - h
		var hills := _max_ahead(t, nn, _horizon_dir(nn, s.cross(nn)), 8000.0, 5) - h
		return -maxf(sea, 0.0) * 0.01 + clampf(hills, 0.0, 600.0) * 0.002 - h * 0.002)
	var f := _horizon_dir(n, s)
	var look := (f.rotated(n, deg_to_rad(18.0)) + n * 0.07).normalized()
	_place_ground(t, n, 2.0, look)
	cam.fov = 70.0


func _selene_terra_rise() -> void:
	var r := _rec("Selene")
	var s := system.sun_dir_from("Selene")
	var dt := _dir_to("Selene", "Terra Nova")
	var cands := _two_elev(s, dt, 14.0, 5.0)
	var n: Vector3 = cands[0] if not cands.is_empty() else -dt
	# a high spot (crater rim) nearby for an open horizon toward Terra
	var best := n
	var best_h := -INF
	var a := n.cross(Vector3.UP).normalized()
	var b := n.cross(a)
	for i in 64:
		var ang := TAU * float(i) / 64.0
		for rr: float in [0.0, 1500.0, 3000.0]:
			var d := (n * r.radius + (a * cos(ang) + b * sin(ang)) * rr).normalized()
			var hh := _h(r, d)
			if hh > best_h:
				best_h = hh
				best = d
	var look := _horizon_dir(best, dt)
	look = (look + best * 0.16).normalized()
	_place_ground(r, best, 2.0, look)
	cam.fov = 60.0


func _ignis_low() -> void:
	var r := _rec("Ignis")
	var s := system.sun_dir_from("Ignis")
	var gen := r.planet.terrain.generator
	var best_n := s
	var best_f := Vector3.FORWARD
	var best := -INF
	var a := Vector3.UP.cross(s).normalized()
	var b := s.cross(a)
	for elev: float in [18.0, 24.0, 30.0]:
		var e := sin(deg_to_rad(elev))
		for i in 240:
			var az := TAU * float(i) / 240.0
			var n := (s * e + (a * cos(az) + b * sin(az)) * sqrt(1.0 - e * e)).normalized()
			for side: float in [-1.0, 1.0]:
				var f := _horizon_dir(n, s.cross(n) * side - s * 0.25)
				var lava := 0.0
				for k in 5:
					var d := (n * r.radius + f * (1500.0 + 1200.0 * k)).normalized()
					lava += gen.sample(d, 1e9).z
				var relief := _max_ahead(r, n, f, 9000.0, 5) - _h(r, n)
				var score := lava + clampf(relief, 0.0, 1500.0) * 0.001
				if score > best:
					best = score
					best_n = n
					best_f = f
	var look := (best_f - best_n * 0.3).normalized()
	_place_ground(r, best_n, 1300.0, look)
	cam.fov = 65.0


func _glacia_low() -> void:
	var r := _rec("Glacia")
	var s := system.sun_dir_from("Glacia")
	var best_n := s
	var best_f := Vector3.FORWARD
	var best := -INF
	var a := Vector3.UP.cross(s).normalized()
	var b := s.cross(a)
	for elev: float in [16.0, 22.0]:
		var e := sin(deg_to_rad(elev))
		for i in 240:
			var az := TAU * float(i) / 240.0
			var n := (s * e + (a * cos(az) + b * sin(az)) * sqrt(1.0 - e * e)).normalized()
			var h := _h(r, n)
			if h > 1500.0:
				continue
			for side: float in [-1.0, 1.0]:
				var f := _horizon_dir(n, s.cross(n) * side + s * 0.3)
				var m := _max_ahead(r, n, f, 16000.0, 8) - h
				if m > best:
					best = m
					best_n = n
					best_f = f
	var look := (best_f - best_n * 0.06).normalized()
	_place_ground(r, best_n, 900.0, look)
	cam.fov = 65.0


func _aurelion_rings() -> void:
	var r := _rec("Aurelion")
	var nrm := SystemDef.aurelion_ring_normal()
	var s := system.sun_dir_from("Aurelion")
	var sp := (s - nrm * s.dot(nrm)).normalized()
	var d := sp.rotated(nrm, deg_to_rad(-70.0))
	var side := nrm.cross(d).normalized()
	var off := d * 820000.0 + nrm * 45000.0 + side * 120000.0
	var target := d * 120000.0 - side * 150000.0 - nrm * 30000.0
	_place_space(r, off, target, nrm)
	cam.fov = 62.0


func _vex_aurelion() -> void:
	var r := _rec("Vex")
	var s := system.sun_dir_from("Vex")
	var da := _dir_to("Vex", "Aurelion")
	var cands := _two_elev(s, da, 10.0, 22.0)
	var n: Vector3 = cands[0] if not cands.is_empty() else -da
	var look := _horizon_dir(n, da)
	look = (look + n * 0.45).normalized()
	_place_ground(r, n, 3.0, look)
	cam.fov = 75.0


func _star_from_ignis() -> void:
	var r := _rec("Ignis")
	var s := system.sun_dir_from("Ignis")
	var gen := r.planet.terrain.generator
	var n := _search_sun_circle(r, s, 9.0, func(nn: Vector3) -> float:
		var f := _horizon_dir(nn, s)
		var lava := 0.0
		for k in 4:
			lava += gen.sample((nn * r.radius + f * (2500.0 + 1500.0 * k)).normalized(), 1e9).z
		var here := gen.sample(nn, 1e9).z
		var block := _max_ahead(r, nn, f, 12000.0, 6) - _h(r, nn)
		# a lava channel in the middle distance, dark basalt underfoot, open view to the star
		return minf(lava, 1.5) - here * 3.0 - maxf(block - 500.0, 0.0) * 0.004)
	var look := (_horizon_dir(n, s) + n * 0.02).normalized()
	_place_ground(r, n, 120.0, look)
	cam.fov = 70.0


func _system_overview() -> void:
	var a := _rec("Aurelion")
	var s := system.sun_dir_from("Aurelion")
	var w := s.cross(Vector3.UP).normalized()
	var dt := _dir_to("Aurelion", "Terra Nova")
	var off := (-s * 0.55 + Vector3.UP * 0.32 - w * 0.75).normalized() * 2300000.0
	# frame: Aurelion on one side, the star (with Terra/Selene near it) on the other
	var to_a := (-off).normalized()
	var to_star := (system.star_pos() - (_rec("Aurelion").pos + off)).normalized()
	var target := off + (to_a * 0.5 + to_star * 0.5).normalized() * 1.0e6
	var _dt := dt
	_place_space(a, off, target, Vector3.UP)
	cam.fov = 60.0


## Generic orbit view: gibbous phase (sun 55 deg to the side), body centred.
func _orbit_view(body: String, dist_r: float) -> void:
	var r := _rec(body)
	var s := system.sun_dir_from(body)
	var w := s.cross(Vector3.UP).normalized()
	var off := (s.rotated(Vector3.UP, deg_to_rad(-60.0)) + Vector3.UP * 0.25).normalized() * r.radius * dist_r
	_place_space(r, off, Vector3.ZERO, Vector3.UP)
	cam.fov = 45.0
	var _w := w


## Night side of Terra: sun 25 deg below the horizon, Aurelion (opposite the star) high in the
## sky — checks the night exposure / starlight floor.
func _terra_night_ground() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var da := _dir_to("Terra Nova", "Aurelion")
	var base := t.planet.config.get_base_level()
	var best_n := Vector3.ZERO
	var best := -INF
	for n: Vector3 in _two_elev(s, da, -25.0, 30.0):
		for j in 30:
			var rng := RandomNumberGenerator.new()
			rng.seed = j * 104729 + 7
			var nn := (n + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.05).normalized()
			var h := _h(t, nn) - base
			if h < 10.0 or h > 1500.0:
				continue
			var f := _horizon_dir(nn, da)
			var relief := _max_ahead(t, nn, f, 12000.0, 6) - h
			var score := clampf(relief, 0.0, 1500.0) * 0.002 - maxf(relief - 1500.0, 0.0) * 0.01
			if score > best:
				best = score
				best_n = nn
	if best_n == Vector3.ZERO:
		best_n = _two_elev(s, da, -25.0, 30.0)[0]
	var look := (_horizon_dir(best_n, da) + best_n * 0.3).normalized()
	_place_ground(t, best_n, 2.0, look)
	cam.fov = 70.0
