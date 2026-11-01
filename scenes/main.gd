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
	cam.make_current()
	var capture_drives := Capture.active and (Capture.args.has("cam") or Capture.args.has("shots"))
	if not capture_drives:
		apply_capture_preset(Capture.get_preset() if Capture.get_preset() != "" else START_PRESET)


func apply_capture_preset(preset: String) -> void:
	cam.fov = 60.0
	cam.near = 0.1
	cam.velocity = Vector3.ZERO
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
	for bn in ["Aurelion", "Selene", "Terra Nova", "Helios"]:
		var bnode := system.get_body_node(bn)
		var vis := not cam.is_position_behind(bnode.global_position)
		var sp := cam.unproject_position(bnode.global_position) if vis else Vector2(-1, -1)
		print("[main]   %s screen=%s dist=%.0f km" % [bn, str(sp), bnode.global_position.length() / 1000.0])
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
	var u := -(ds + da).normalized()
	u = (u + Vector3.UP * 0.25).normalized()
	var off := u * 205000.0
	var look := (ds + da).normalized() * 60000.0
	_place_space(t, off, look, Vector3.UP)
	cam.fov = 62.0


func _terra_limb_sunrise() -> void:
	var t := _rec("Terra Nova")
	var s := system.sun_dir_from("Terra Nova")
	var dist := 128000.0
	var top := t.atmo.get_top_radius() if t.atmo else t.radius
	var alpha := asin((t.radius + 3000.0) / dist)       # limb of the visible planet
	var ang := alpha - deg_to_rad(0.6)                # sun centre just above the limb
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
	look = (look - n * 0.22).normalized()
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
	for e1: float in [11.0, 14.0, 17.0]:
		for e2: float in [9.0, 12.0, 15.0]:
			for n: Vector3 in _two_elev(s, da, e1, e2):
				for jitter in 24:
					var nn := n
					if jitter > 0:
						var rng := RandomNumberGenerator.new()
						rng.seed = jitter * 7919 + int(e1 * 13.0 + e2)
						nn = (n + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.02).normalized()
					var h := _h(t, nn) - base
					if h < 15.0 or h > 900.0:
						continue
					var f := _horizon_dir(nn, da)
					var m := _max_ahead(t, nn, f, 9000.0, 6) - h
					var e := 8.0 / t.radius
					var tt := nn.cross(f)
					var slope := absf(_h(t, (nn + f * e).normalized()) - _h(t, (nn - f * e).normalized())) \
						+ absf(_h(t, (nn + tt * e).normalized()) - _h(t, (nn - tt * e).normalized()))
					# some relief ahead (but not hiding the giant), gentle ground under the feet
					var score := clampf(m, -200.0, 500.0) * 0.004 - slope * 0.3 - absf(e2 - 12.0) * 0.05
					if score > best:
						best = score
						best_n = nn
	if best_n == Vector3.ZERO:
		best_n = _two_elev(s, da, 14.0, 12.0)[0]
	var look := _horizon_dir(best_n, da)
	look = (look + best_n * 0.12).normalized()
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
	var n := _search_sun_circle(r, s, 7.0, func(nn: Vector3) -> float:
		var f := _horizon_dir(nn, s)
		var lava := 0.0
		for k in 4:
			lava += gen.sample((nn * r.radius + f * (800.0 + 900.0 * k)).normalized(), 1e9).z
		var block := _max_ahead(r, nn, f, 12000.0, 6) - _h(r, nn)
		return lava - maxf(block - 300.0, 0.0) * 0.004)
	var look := (_horizon_dir(n, s) + n * 0.06).normalized()
	_place_ground(r, n, 40.0, look)
	cam.fov = 70.0


func _system_overview() -> void:
	var a := _rec("Aurelion")
	var s := system.sun_dir_from("Aurelion")
	var w := s.cross(Vector3.UP).normalized()
	var off := (-s * 0.82 + Vector3.UP * 0.32 + w * 0.48).normalized() * 2600000.0
	var target := off + (s + w * -0.08 - Vector3.UP * 0.12).normalized() * 1.0e6
	_place_space(a, off, target, Vector3.UP)
	cam.fov = 60.0
