extends Node3D
## Main scene: the whole star system + the playable game (GameMode, Ship, Player, HUD, F1).
##
## World (Universe.world_root) holds the SolarSystem, the free camera and the Ship (a direct
## child, as Ship requires); GameMode spawns the Player under World. Start state: piloting the
## ship, landed on Terra Nova (meadow/coast near mountains, sun ~30 deg, Selene in the sky).
## Capture presets (tools/shot.sh scenes/main.tscn --cam=<name> / --shots=a,b):
##   gameplay (real Ship/Player, add --hud): start, takeoff, orbit_chase, selene_landed_onfoot,
##     warp_to_aurelion, aurelion_arrival
##   bare system (free camera, ship hidden): system_overview, terra_orbit, terra_limb_sunrise,
##     terra_entry, terra_low, terra_ground, terra_sunset_ground, selene_surface_terra_rise,
##     ignis_low, glacia_low, aurelion_rings, vex_aurelion, star_from_ignis (+ terra_night_ground,
##     ignis_orbit, glacia_orbit, selene_orbit, vex_orbit)
## Extra args: --fov=<deg>, --exposure=<x> (manual), --no_shadows, --quality=0..2,
##   --start=<preset> (gameplay start in another state, e.g. --start=orbit_chase),
##   --no_game (system only, free camera), --bench=<frames>,
##   --demo=takeoff|landing (scripted flight for tools/movie.sh; synchronous load, no intro),
##   --sync_load (skip the loading screen).
## Wave 4 gameplay presets: takeoff_dust, reentry_game, landing_selene, warp_game, warp_dropout,
##   cockpit_view, orbit_idle, pause_menu, loading_screen, intro (add --hud for the HUD).
##
## Session flow (game): LoadingScreen (progress per stage: sky, landing site, terrain per body,
## vegetation, sound) while the world streams in over frames -> fade-in -> IntroCard
## ("Terra Nova · система Helios") -> F1 hint. Esc -> PauseMenu. GameAudio synthesizes the sound
## bank on a worker thread meanwhile.

const GAME_PRESETS: Array[String] = ["start", "takeoff", "orbit_chase", "selene_landed_onfoot",
	"warp_to_aurelion", "aurelion_arrival", "takeoff_dust", "reentry_game", "landing_selene", "warp_game",
	"warp_dropout", "cockpit_view", "orbit_idle", "pause_menu", "loading_screen", "intro"]

@onready var world: Node3D = $World
@onready var system: SolarSystem = $World/SolarSystem
@onready var cam: FreeCamera = $World/FreeCamera
@onready var ship: Ship = $World/Ship
@onready var game: GameMode = $GameMode
@onready var hud: Hud = $Hud
@onready var help: HelpOverlay = $HelpOverlay
@onready var backdrop: WorldEnvironment = $SpaceBackdrop

## Session start (gameplay) finished: ship placed, terrain + vegetation built.
signal session_started
var started := false
var load_ms := 0
## Start site on Terra Nova (planet-local unit normal) and ship heading, chosen once.
var start_site := Vector3.ZERO
var start_heading := Vector3.ZERO
var audio: GameAudio
var pause: PauseMenu
var loading: LoadingScreen
var intro: IntroCard
var _t0 := 0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_t0 = t0
	add_to_group("capture_target")
	Universe.set_world_root(world)
	system.set_environment(backdrop.environment)
	pause = PauseMenu.new()
	pause.name = "PauseMenu"
	pause.enabled = false
	add_child(pause)
	intro = IntroCard.new()
	intro.name = "IntroCard"
	add_child(intro)
	if not Capture.active or Capture.args.has("audio"):
		audio = GameAudio.new()
		audio.name = "Audio"
		add_child(audio)
		audio.setup(ship, game)
	if Capture.args.has("no_shadows"):
		system.shadows_enabled = false
	if Capture.args.has("quality"):
		system.set_quality(int(Capture.args["quality"]))
	_debug_overrides()
	ship.hud_message.connect(func(t: String) -> void: hud.flash_message(t, 2.2))
	Controls.mouse_scale_changed.connect(func(v: float) -> void: hud.flash_message("Чувствительность мыши ×%.2f" % v, 1.5))
	game.state_changed.connect(_on_state_changed)
	var preset := Capture.get_preset()
	var shots: PackedStringArray = String(Capture.args.get("shots", "")).split(",", false)
	var first := preset if preset != "" else (shots[0] if not shots.is_empty() else "")
	var capture_drives := Capture.active and first != ""
	if Capture.args.has("bench") or Capture.args.has("no_game") or (capture_drives and not first in GAME_PRESETS):
		_system_only()
		if Capture.args.has("bench"):
			_bench.call_deferred()
		elif not capture_drives:
			apply_capture_preset(Capture.get_preset() if Capture.get_preset() != "" else "terra_orbit")
		return
	# gameplay session
	if capture_drives or Capture.args.has("demo") or Capture.args.has("sync_load") or Capture.args.has("start"):
		_start_session(String(Capture.args.get("start", "start")) if not capture_drives else "")
		load_ms = Time.get_ticks_msec() - t0
		print("[main] session ready in %d ms" % load_ms)
		if Capture.args.has("demo"):
			_run_demo.call_deferred(String(Capture.args["demo"]))
	else:
		_start_session_async()


## Bare-system mode (benchmarks, system capture presets): free camera, no ship/player.
func _system_only() -> void:
	ship.visible = false
	ship.process_mode = Node.PROCESS_MODE_DISABLED
	ship.freeze = true
	hud.set_mode(Hud.Mode.NONE)
	Universe.set_focus(cam)
	system.camera = cam
	cam.make_current()


func _debug_overrides() -> void:
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
	if preset in GAME_PRESETS:
		await _game_preset(preset)
		return
	if not ship.process_mode == Node.PROCESS_MODE_DISABLED:
		_system_only()
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
	print("[main]   weather rotated %.0f deg (coverage err %.2f)" % [rad_to_deg(best_a), best])


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
		# temperate latitudes (no polar ice caps), land with relief ahead, toward the giant
		return -absf(h - 50.0) * 0.001 + clampf(land, 0.0, 3000.0) * 0.002 + nn.dot(da) * 2.0 \
			- smoothstep(0.35, 0.6, absf(nn.y)) * 6.0)
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


# ---------------------------------------------------------------------------------------
# Gameplay session
# ---------------------------------------------------------------------------------------

## Places the ship landed at the Terra Nova start site, starts GameMode (piloting), builds the
## terrain + vegetation around the chase camera synchronously (loading), then fades in.
## `then_preset`: optional gameplay preset to switch to right away (--start=<preset>).
func _start_session(then_preset: String) -> void:
	hud.fade_to(1.0, 0.0)
	_place_start()
	system.gameplay_body = ship
	game.ensure_started()   # SHIP state: enter_pilot(), chase camera current, Universe focus
	_sync_ship_camera()
	system.build_terrain_now(system.camera)
	started = true
	if not Capture.active:
		# cosmetic: rotate the weather for a clear sky toward Selene and the sun once the
		# weather map can be read back (a few frames after the bake)
		_clear_start_weather.call_deferred()
	if then_preset != "" and then_preset != "start":
		await _game_preset(then_preset)
	session_started.emit()
	if audio:
		audio.fade_target = 1.0
	if Capture.active:
		hud.fade_to(0.0, 0.0)
	else:
		pause.enabled = true
		await get_tree().process_frame
		hud.fade_to(0.0, 0.8)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Game start with the loading screen: the world is built over frames (workers keep running while
## the screen animates), progress per stage; then fade-in, intro caption, F1 hint.
func _start_session_async() -> void:
	loading = LoadingScreen.new()
	loading.name = "Loading"
	add_child(loading)
	hud.fade_to(1.0, 0.0)
	hud.set_shown(false)
	help.show_hint_on_start = false
	help._hint.visible = false
	loading.set_progress(0.02, "Звёзды и небо системы Helios")
	await _frames(3)
	loading.set_progress(0.05, "Место посадки · Terra Nova")
	await _frames(1)
	_place_start()
	system.gameplay_body = ship
	game.ensure_started()
	_sync_ship_camera()
	await _frames(1)
	await _build_world_async(system.camera, func(p: float, txt: String) -> void:
		loading.set_progress(0.07 + 0.86 * p, txt))
	if audio:
		var tw := Time.get_ticks_msec()
		while not audio.is_ready() and Time.get_ticks_msec() - tw < 20000:
			loading.set_progress(0.95, "Звук: синтез")
			await get_tree().process_frame
	loading.set_progress(1.0, "Готово")
	started = true
	_clear_start_weather.call_deferred()
	await _frames(2)
	load_ms = Time.get_ticks_msec() - _t0
	print("[main] session ready in %d ms (loading screen)" % load_ms)
	session_started.emit()
	await loading.finish(0.7)
	loading = null
	hud.set_shown(true)
	pause.enabled = true
	if audio:
		audio.fade_target = 1.0
	await hud.fade_to(0.0, 1.8)
	await intro.play("Terra Nova · система Helios", "STELLAR DRIFT")
	help.show_hint(7.0)


## Asynchronous version of SolarSystem.build_terrain_now(): every planet's LOD (focus last) and the
## focus vegetation are refined level by level while frames keep rendering (the worker threads
## build chunks between frames). Uses the terrain/scatter internals of build_until_stable() and
## falls back to the blocking call if they ever change. on_progress(0..1, stage text).
func _build_world_async(cam: Camera3D, on_progress: Callable) -> void:
	system.process_frame(cam)
	var recs: Array = []
	for r in system.bodies:
		if r.planet and r != system.focus:
			recs.append(r)
	if system.focus and system.focus.planet:
		recs.append(system.focus)
	var n := float(recs.size())
	var i := 0.0
	# the focus planet dominates the cost: 60 % of the bar, the others share 15 %
	for r in recs:
		var is_focus: bool = r == system.focus
		var p0 := 0.15 * i / maxf(n - 1.0, 1.0) if not is_focus else 0.15
		var span := 0.15 / maxf(n - 1.0, 1.0) if not is_focus else 0.6
		var txt := "Рельеф · %s" % r.name
		await _terrain_async(r.planet.terrain, 60.0 if is_focus else 20.0, func(f: float) -> void:
			on_progress.call(p0 + span * f, txt))
		i += 1.0
	system.process_frame(cam)   # enables the focus vegetation
	if system.focus and system.focus.scatter:
		await _scatter_async(system.focus.scatter, func(f: float) -> void:
			on_progress.call(0.75 + 0.25 * f, "Растительность · %s" % system.focus.name))
	on_progress.call(1.0, "Последние штрихи")
	system.build_terrain_now(cam)   # everything idle by now: instant; snaps exposure / ambient


func _terrain_async(t: PlanetTerrain, max_s: float, prog: Callable) -> void:
	if not ("_jobs" in t and t.has_method("_update_tree") and t.has_method("_dispatch") and t.has_method("_collect")):
		t.build_until_stable(max_s)
		prog.call(1.0)
		return
	var t0 := Time.get_ticks_msec()
	var built0: int = t.get("_built_total")
	var est := 1.0
	while true:
		t.call("_update_tree", true)
		t.call("_dispatch", true)
		var jobs: Array = t.get("_jobs")
		est = maxf(est, float(t.get("_built_total") - built0) + jobs.size() * 1.6 + 1.0)
		while not jobs.is_empty():
			t.call("_collect", 1 << 30, 12.0, false)
			prog.call(clampf(float(t.get("_built_total") - built0) / est, 0.0, 0.98))
			await get_tree().process_frame
			jobs = t.get("_jobs")
			if Time.get_ticks_msec() - t0 > max_s * 1000.0:
				break
		t.call("_update_tree", true)
		if t.is_idle() or Time.get_ticks_msec() - t0 > max_s * 1000.0:
			break
	t.build_until_stable(5.0)   # finishes anything left (bodies, edge flags); instant when idle
	prog.call(1.0)


func _scatter_async(sc: PlanetScatter, prog: Callable) -> void:
	if not ("_jobs" in sc and "_queue" in sc and sc.has_method("_dispatch") and sc.has_method("_collect") \
			and sc.has_method("_scan") and sc.has_method("_update_focus")):
		sc.build_until_stable(60.0)
		prog.call(1.0)
		return
	if not bool(sc.get("_ready_to_run")):
		prog.call(1.0)
		return
	var t0 := Time.get_ticks_msec()
	sc.call("_update_focus")
	sc.call("_scan", true)
	var total := float((sc.get("_queue") as Array).size()) + 1.0
	while not (sc.get("_queue") as Array).is_empty() or not (sc.get("_jobs") as Array).is_empty():
		sc.call("_dispatch", maxi(sc.max_jobs, OS.get_processor_count() - 1))
		sc.call("_collect", 1 << 30, 12.0, false)
		var left := float((sc.get("_queue") as Array).size() + (sc.get("_jobs") as Array).size())
		total = maxf(total, left)
		prog.call(clampf(1.0 - left / total, 0.0, 0.98))
		await get_tree().process_frame
		if Time.get_ticks_msec() - t0 > 60000:
			break
	sc.build_until_stable(5.0)
	prog.call(1.0)


func _on_state_changed(_st: int) -> void:
	system.gameplay_body = game.get_gameplay_body()
	system.camera = get_viewport().get_camera_3d()


## Chase/cockpit camera transform for this frame (before SolarSystem uses it).
func _sync_ship_camera() -> void:
	var rig := ship.camera_rig as ShipCameraRig
	if rig:
		rig.activate()
		rig._process(0.0)
	system.camera = ship.get_camera()


func _place_start() -> void:
	var t := _rec("Terra Nova")
	if start_site == Vector3.ZERO:
		var t0 := Time.get_ticks_msec()
		_choose_start_site(t)
		print("[main] start site %s heading %s (%d ms)" % [str(start_site), str(start_heading),
			Time.get_ticks_msec() - t0])
	_land_ship(t, start_site, start_heading)


## Lands the ship on body r at unit normal n facing `heading` (floating origin moved there first).
func _land_ship(r: SolarSystem.BodyRec, n: Vector3, heading: Vector3) -> void:
	var off := n * (_ground_r(r, n) + 5.0)
	Universe.teleport_origin(float(r.pos.x) + off.x, float(r.pos.y) + off.y, float(r.pos.z) + off.z)
	ship.land_at(r.node, n, heading)
	Universe.shift_origin(ship.global_position)
	ship._update_environment()


## Ship in free flight at body r + `off` (true system frame, 64-bit origin), oriented by `b`.
func _ship_at(r: SolarSystem.BodyRec, off: Vector3, b: Basis, v := Vector3.ZERO, mode := Ship.Mode.SPACE) -> void:
	Universe.teleport_origin(float(r.pos.x) + off.x, float(r.pos.y) + off.y, float(r.pos.z) + off.z)
	ship.landed = false
	ship.autopilot = false
	ship.throttle = 0.0
	ship.gear_contacts = 0
	ship.teleport(Transform3D(b.orthonormalized(), Vector3.ZERO), v, ship.capture_hold)
	if mode == Ship.Mode.WARP:
		ship.mode = Ship.Mode.WARP
		ship.warp_state = Ship.WarpState.ACTIVE
		ship.warp_spool = 1.0
	else:
		ship.set_mode(mode, true)
	ship.set_gear(mode == Ship.Mode.HOVER, true)
	ship._update_environment()


## Basis with nose (-Z) along `fwd` and up close to `up`.
static func _nose_basis(fwd: Vector3, up: Vector3) -> Basis:
	var f := fwd.normalized()
	var r := f.cross(up).normalized()
	return Basis(r, r.cross(f), -f)


## Max relative height difference (rise/run) of the ground around n at scale `e` metres.
func _slope(r: SolarSystem.BodyRec, n: Vector3, e: float) -> float:
	var t1 := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := n.cross(t1)
	var k := e / r.radius
	var s := 0.0
	for t: Vector3 in [t1, t2, (t1 + t2).normalized(), (t1 - t2).normalized()]:
		s = maxf(s, absf(_h(r, (n + t * k).normalized()) - _h(r, (n - t * k).normalized())) / (2.0 * e))
	return s


## Start site: daylight (sun ~30 deg, behind-side so the ship and the view are lit), a gentle open
## meadow 8-260 m above the sea, mountains and the coast in the view, Selene in the sky if possible.
func _choose_start_site(t: SolarSystem.BodyRec) -> void:
	var s := system.sun_dir_from("Terra Nova")
	var ds := _dir_to("Terra Nova", "Selene")
	var base := t.planet.config.get_base_level()
	var biome: ScatterBiome = t.scatter.biome if t.scatter else null
	var best := -INF
	var best_n := Vector3.ZERO
	var best_f := Vector3.ZERO
	var best_info := ""
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261101
	var a := (Vector3.UP if absf(s.y) < 0.9 else Vector3.RIGHT).cross(s).normalized()
	var b := s.cross(a)
	for i in 1400:
		var e := sin(deg_to_rad(rng.randf_range(28.5, 31.5)))
		var az := rng.randf() * TAU
		var nn := (s * e + (a * cos(az) + b * sin(az)) * sqrt(1.0 - e * e)).normalized()
		if absf(nn.y) > 0.6:
			continue   # polar ice caps
		var h := _h(t, nn) - base
		if h < 8.0 or h > 260.0:
			continue
		var sl := _slope(t, nn, 12.0)
		if sl > 0.1:
			continue
		var bio_pen := 0.0
		if biome:
			var bio := biome.evaluate(nn)
			bio_pen = float(bio["forest"]) * 2.5 + float(bio["rock"]) * 1.5 + float(bio["snow"]) * 3.0 \
				+ float(bio["beach"]) * 1.0 + float(bio["desert"]) * 0.8
			if bio_pen > 1.2:
				continue
		var shade := _sun_blocked(t, nn, s, 30.0)
		if shade > 0.0:
			continue
		var sun_h := _horizon_dir(nn, s)
		var sel_h := _horizon_dir(nn, ds)
		var sel_el := rad_to_deg(asin(clampf(nn.dot(ds), -1.0, 1.0)))
		for rel: float in [-145.0, -125.0, -105.0, 105.0, 125.0, 145.0]:
			var f := sun_h.rotated(nn, deg_to_rad(rel))
			var tt := nn.cross(f)
			var m := -INF
			for lat: float in [-0.4, 0.0, 0.4]:
				m = maxf(m, _max_ahead(t, nn, (f + tt * lat).normalized(), 16000.0, 6))
			m -= h
			var near_wall := _max_ahead(t, nn, f, 2000.0, 4) - h
			var sea := 0.0
			for dist: float in [1500.0, 3500.0, 6500.0]:
				for lat: float in [-0.55, 0.0, 0.55]:
					var d := (nn * t.radius + (f + tt * lat).normalized() * dist).normalized()
					if _h(t, d) < base:
						sea += 1.0 / 9.0
			var coast := 1.0 - absf(sea - 0.35) * 2.2
			var sel := 0.0
			if sel_el > 4.0 and sel_el < 26.0:
				sel = clampf(1.0 - rad_to_deg(f.angle_to(sel_h)) / 30.0, 0.0, 1.0)
			var score := clampf(m, 0.0, 2200.0) * 0.0012 + coast * 1.5 + sel * 2.0 \
				- maxf(near_wall - 150.0, 0.0) * 0.01 - sl * 8.0 - bio_pen
			if score > best:
				best = score
				best_n = nn
				best_f = f
				best_info = "mountains %.0f m, sea %.2f, Selene %.1f deg up / %.0f deg off-axis, sun %.0f deg to the side" % [
					m, sea, sel_el, rad_to_deg(f.angle_to(sel_h)), rel]
	if best_n == Vector3.ZERO:
		best_n = _two_elev(s, ds, 30.0, 12.0)[0]
		best_f = _horizon_dir(best_n, ds)
	start_site = best_n
	start_heading = best_f
	print("[main]   start: sun %.1f deg, height %.0f m, slope %.3f, score %.2f: %s" % [
		rad_to_deg(asin(best_n.dot(s))), _h(t, best_n) - base, _slope(t, best_n, 12.0), best, best_info])


func _clear_start_weather() -> void:
	var t := _rec("Terra Nova")
	for i in 20:
		if t.clouds == null or t.clouds.weather_at(Vector3.UP).x >= 0.0:
			break
		await get_tree().process_frame
	var tt := start_site.cross(start_heading)
	_clear_weather(t, start_site, [system.sun_dir_from("Terra Nova"), _dir_to("Terra Nova", "Selene"),
		(start_heading + start_site * 0.25).normalized(), (start_heading + tt * 0.5 + start_site * 0.3).normalized(),
		(start_heading - tt * 0.5 + start_site * 0.3).normalized(), start_site], [2.0, 1.5, 3.0, 1.5, 1.5, 1.0])


## Gameplay capture presets (real Ship / Player through GameMode; ship frozen for stills).
func _game_preset(preset: String) -> void:
	if not started:
		await session_started
	var fx := ship.get_node("FX") as ShipFX
	fx.force_heat = -1.0
	fx.force_vapor = -1.0
	fx.force_warp = -1.0
	fx.force_thrust = -1.0
	fx.force_dust = -1.0
	fx.force_vortex = -1.0
	fx.force_haze = -1.0
	fx.force_ground = ""
	fx.clear_dropout()
	ship.thrust_norm = Vector3.ZERO   # frozen stills keep the last preset's engine glow otherwise
	ship.visual_lean = Vector3.ZERO
	ship.heat = 0.0
	ship.vapor = 0.0
	help._hint.visible = false        # the F1 hint belongs to the start frame only
	ship.target = null
	if pause.is_open:
		pause.set_open(false, true)
	intro.freeze_at = -1.0
	if loading and preset != "loading_screen":
		loading.queue_free()
		loading = null
	var rig := ship.camera_rig as ShipCameraRig
	rig.view_override = Callable()
	rig.force_orbit = -1.0
	rig.set_view(ShipCameraRig.View.CHASE)
	ship.capture_hold = Capture.active
	if game.state != GameMode.State.SHIP:
		game.force_ship()
	var t := _rec("Terra Nova")
	match preset:
		"start":
			_place_start()
			await _clear_start_weather()
			if Capture.args.has("hud"):
				help.show_hint(30.0)
				help._hint.modulate.a = 1.0   # skip the fade-in for the still
			if Capture.args.has("cockpit"):
				rig.set_view(ShipCameraRig.View.COCKPIT)
		"takeoff":
			_place_start()
			var b := ship.global_basis
			ship.landed = false
			ship.teleport(Transform3D(b, ship.global_position + ship.up_dir * 16.0), ship.up_dir * 7.0, true)
			ship.set_mode(Ship.Mode.HOVER, true)
			ship.thrust_norm = Vector3(0.0, 0.7, -0.15)
			fx.force_thrust = 0.55
			fx.force_dust = 1.0
			rig.view_override = _rig_cam.bind(Vector3(-14.0, -6.5, 26.0), Vector3(0.0, -1.0, -4.0))
		"orbit_chase":
			var s := system.sun_dir_from("Terra Nova")
			var n := _search_sun_circle(t, s, 38.0, func(nn: Vector3) -> float:
				return -absf(nn.y) - _cloud_cov(t, nn, nn) * 0.5)
			var fwd := _horizon_dir(n, s.cross(n))
			var off := n * (t.radius + 70000.0)
			# the limb is ~62 deg below the horizontal at 70 km: nose (and the chase view) pitched down
			var b := _nose_basis(fwd.rotated(fwd.cross(n).normalized(), deg_to_rad(-44.0)), n)
			_ship_at(t, off, b, -b.z * 2400.0, Ship.Mode.SPACE)
			fx.force_thrust = 0.5
			rig.view_override = _rig_cam.bind(Vector3(9.0, 7.0, 25.0), Vector3(0.0, -6.0, -20.0))
		"selene_landed_onfoot":
			_selene_onfoot()
		"warp_to_aurelion":
			var a := _rec("Aurelion")
			var to_a := (a.pos - t.pos).normalized()
			var off := to_a * 2.6e6
			var b := _nose_basis(to_a, Vector3.UP)
			_ship_at(t, off, b, -b.z * 2.0e7, Ship.Mode.WARP)
			ship.target = a.node
			fx.force_warp = 1.0
			fx.force_thrust = 1.0
		"aurelion_arrival":
			var a := _rec("Aurelion")
			var nrm := SystemDef.aurelion_ring_normal()
			var s := system.sun_dir_from("Aurelion")
			var sp := (s - nrm * s.dot(nrm)).normalized()
			# sunlit side, a little above the ring plane, ~95 km above the cloud tops
			var d := (sp.rotated(nrm, deg_to_rad(-55.0)) + nrm * 0.16).normalized()
			var alt := ship.safe_orbit_altitude(a.node) + 5000.0
			var off := d * (a.radius + alt)
			var look := (-d).rotated(nrm, deg_to_rad(-38.0))
			var b := _nose_basis(look, nrm)
			_ship_at(a, off, b, -b.z * 300.0, Ship.Mode.SPACE)
			ship.target = a.node
			rig.view_override = _rig_cam.bind(Vector3(-10.0, 5.0, 26.0), Vector3(0.0, -2.0, -30.0))
		_:
			await _wave4_preset(preset, fx, rig)
	if game.state == GameMode.State.ON_FOOT:
		game.player.get_camera().make_current()
		system.camera = game.player.get_camera()
	else:
		_sync_ship_camera()
	system.gameplay_body = game.get_gameplay_body()
	system.build_terrain_now(system.camera)
	system.process_frame(system.camera)
	print("[main] game preset %s: state %s, body %s, alt %.0f m, speed %.0f m/s, light tint %s, ambient %s" % [preset,
		game.get_state_name(), ship.body.get_body_name() if ship.body else "-", ship.altitude, ship.vel.length(),
		str(system.light_tint), str(system.ambient_color)])


## Chase camera at a fixed ship-local offset looking at a ship-local point (still framing).
func _rig_cam(_rig: ShipCameraRig, offset: Vector3, look: Vector3) -> Transform3D:
	var B := ship.global_basis.orthonormalized()
	var p := ship.global_position + B * offset
	var tgt := ship.global_position + B * look
	if ship.body and ship.body is Planet:
		var ga: float = ship.body.get_altitude_global(p)
		if ga < 1.7:
			p += ship.up_dir * (1.7 - ga)
	return Transform3D(Basis.looking_at(tgt - p, B.y), p)


## Selene: ship landed on a flat spot (sun 16 deg, Terra 13 deg up), pilot on foot 15 m away
## looking back at the ship with Terra above it.
func _selene_onfoot() -> void:
	var r := _rec("Selene")
	var s := system.sun_dir_from("Selene")
	var dt := _dir_to("Selene", "Terra Nova")
	var cands := _two_elev(s, dt, 16.0, 13.0)
	var n0: Vector3 = cands[0] if not cands.is_empty() else -dt
	var best := n0
	var best_s := INF
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 160:
		var nn := (n0 + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.03).normalized()
		var f := _horizon_dir(nn, dt)
		var sl := _slope(r, nn, 12.0) + _slope(r, (nn * r.radius - f * 15.0).normalized(), 4.0)
		# open horizon toward Terra
		var block := maxf(_max_ahead(r, nn, f, 2500.0, 6) - _h(r, nn), 0.0) * 0.004
		if sl + block < best_s:
			best_s = sl + block
			best = nn
	var fwd := _horizon_dir(best, dt)
	_land_ship(r, best, fwd.rotated(best, deg_to_rad(70.0)))
	ship.visual.set_hatch(true, true)
	game.force_on_foot()
	var pl := game.player
	# stand 15 m from the ship, on the side away from Terra, looking at the ship / Terra
	var p_dir := (best * r.radius - fwd * 15.0 - best.cross(fwd) * 4.0).normalized()
	var feet := r.node.global_position + p_dir * (r.radius + _h(r, p_dir) + 0.05)
	pl.place_at(Transform3D(Basis.looking_at(ship.global_position - feet, best), feet))
	pl.look_at_point(ship.global_position + best * 2.5)
	pl.set_pitch_deg(9.0)
	Universe.set_focus(pl)
	ship.capture_hold = Capture.active


# ---------------------------------------------------------------------------------------
# Wave 4 presets (gameplay polish captures) and the movie demo
# ---------------------------------------------------------------------------------------

## Flat Selene spot with Terra Nova `terra_el` deg above the horizon and the sun at `sun_el`.
func _selene_site(sun_el: float, terra_el: float) -> Vector3:
	var r := _rec("Selene")
	var s := system.sun_dir_from("Selene")
	var dt := _dir_to("Selene", "Terra Nova")
	var cands := _two_elev(s, dt, sun_el, terra_el)
	var n0: Vector3 = cands[0] if not cands.is_empty() else -dt
	var best := n0
	var best_s := INF
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 160:
		var nn := (n0 + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.03).normalized()
		var f := _horizon_dir(nn, dt)
		var sl := _slope(r, nn, 14.0)
		var block := maxf(_max_ahead(r, nn, f, 2500.0, 6) - _h(r, nn), 0.0) * 0.004
		if sl + block < best_s:
			best_s = sl + block
			best = nn
	return best


func _wave4_preset(preset: String, fx: ShipFX, rig: ShipCameraRig) -> void:
	var t := _rec("Terra Nova")
	match preset:
		"takeoff_dust":
			_place_start()
			var b := ship.global_basis
			var up := ship.up_dir
			ship.landed = false
			ship.teleport(Transform3D(b, ship.global_position + up * 6.5), up * 4.0, true)
			ship.set_mode(Ship.Mode.HOVER, true)
			ship.thrust_norm = Vector3(0.0, 0.85, -0.1)
			ship.visual_lean = Vector3(deg_to_rad(3.0), 0.0, 0.0)
			fx.force_thrust = 0.55
			fx.force_dust = 1.0
			rig.view_override = _rig_cam.bind(Vector3(-21.0, -1.2, -13.0), Vector3(0.0, -2.4, 1.0))
			await _frames(2)
			fx.prewarm_ground(3.5)
		"reentry_game":
			var s := system.sun_dir_from("Terra Nova")
			var n := _search_sun_circle(t, s, 35.0, func(nn: Vector3) -> float:
				return -absf(nn.y) - _cloud_cov(t, nn, nn) * 0.3)
			var fwd := _horizon_dir(n, s.cross(n))
			var off := n * (t.radius + 22000.0)
			var dirv := fwd.rotated(fwd.cross(n).normalized(), deg_to_rad(-16.0))
			var b := _nose_basis(dirv.rotated(fwd.cross(n).normalized(), deg_to_rad(8.0)), n)
			_ship_at(t, off, b, dirv * 2300.0, Ship.Mode.SPACE)
			fx.force_heat = 0.9
			fx.force_thrust = 0.15
			ship.heat = 0.9
			rig.view_override = _rig_cam.bind(Vector3(-26.0, 9.0, 6.0), Vector3(0.0, -1.0, 7.0))
		"landing_selene":
			var r := _rec("Selene")
			var n := _selene_site(18.0, 14.0)
			var dt := _dir_to("Selene", "Terra Nova")
			var fwd := _horizon_dir(n, dt).rotated(n, deg_to_rad(-25.0))
			_land_ship(r, n, fwd)
			var up := ship.up_dir
			ship.landed = false
			ship.gear_contacts = 0
			ship.teleport(Transform3D(ship.global_basis, ship.global_position + up * 11.0), -up * 1.4, true)
			ship.set_mode(Ship.Mode.HOVER, true)
			ship.target = r.node
			ship.thrust_norm = Vector3(0.0, 0.6, 0.0)
			fx.force_thrust = 0.42
			fx.force_dust = 0.9
			rig.view_override = _rig_cam.bind(Vector3(-15.0, 3.0, 24.0), Vector3(0.0, -4.5, -6.0))
			await _frames(2)
			fx.prewarm_ground(3.0)
		"warp_game", "warp_dropout":
			var a := _rec("Aurelion")
			var to_a := (a.pos - t.pos).normalized()
			if preset == "warp_game":
				var off := to_a * 2.6e6
				var b := _nose_basis(to_a, Vector3.UP)
				_ship_at(t, off, b, -b.z * 2.0e7, Ship.Mode.WARP)
				fx.force_warp = 1.0
				fx.force_thrust = 1.0
			else:
				# just dropped out of warp in front of Aurelion: flash + ripple frozen mid-way
				var d := (t.pos - a.pos).normalized()
				var nrm := SystemDef.aurelion_ring_normal()
				var dd := (d + nrm * 0.12).normalized()
				var off := dd * (a.radius + 900000.0)
				var b := _nose_basis(-dd, nrm)
				_ship_at(a, off, b, -b.z * 120000.0, Ship.Mode.CRUISE)
				fx.force_warp = 0.25
				fx.force_thrust = 0.8
				fx.preview_dropout(0.32)
			ship.target = a.node
		"cockpit_view":
			if start_site == Vector3.ZERO:
				_place_start()
			var n := start_site
			var fwd := start_heading.rotated(n, deg_to_rad(-20.0))
			var off := n * (_ground_r(t, n) + 420.0)
			var b := _nose_basis(fwd.rotated(fwd.cross(n).normalized(), deg_to_rad(-7.0)), n)
			_ship_at(t, off, b, -b.z * 150.0, Ship.Mode.ATMOSPHERE)
			ship.set_gear(false, true)
			fx.force_thrust = 0.45
			rig.set_view(ShipCameraRig.View.COCKPIT)
		"orbit_idle":
			_place_start()
			await _clear_start_weather()
			rig.force_orbit = 1.0
			rig.force_orbit_ang = 2.5
		"pause_menu":
			_place_start()
			await _clear_start_weather()
			pause.enabled = true
			pause.set_open(true, true)
			pause.show_section("sound")
		"loading_screen":
			if loading == null:
				loading = LoadingScreen.new()
				add_child(loading)
			loading.set_progress(0.64, "Рельеф · Terra Nova")
			loading.shown_progress = 0.64
		"intro":
			_place_start()
			await _clear_start_weather()
			intro.freeze_at = 2.6
			help.show_hint(30.0)
			help._hint.modulate.a = 1.0


## Scripted flights for tools/movie.sh (the session loads synchronously before the first frame).
##   --demo=takeoff: lift-off from the Terra Nova start site in a dust cloud, gear up, climb out.
##   --demo=landing: hover-down onto the start meadow from 70 m.
func _run_demo(kind: String) -> void:
	if not started:
		await session_started
	help._hint.visible = false
	help.show_hint_on_start = false
	pause.enabled = false
	ship.scripted = true
	var rig := ship.camera_rig as ShipCameraRig
	rig.idle_orbit = false
	if kind == "landing":
		var up := ship.up_dir
		ship.landed = false
		ship.teleport(Transform3D(ship.global_basis, ship.global_position + up * 70.0), -up * 6.0, false)
		ship.set_mode(Ship.Mode.HOVER, true)
		ship.set_gear(true, true)
	var t := 0.0
	print("[demo] %s start" % kind)
	while t < 30.0:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		t += dt
		ship.in_move = Vector3.ZERO
		ship.steer_dir = Vector3.ZERO
		var up := ship.up_dir
		var fwd := -ship.global_basis.z
		fwd = (fwd - up * fwd.dot(up)).normalized()
		match kind:
			"takeoff":
				if t < 0.8:
					pass
				elif t < 4.6:
					if ship.mode != Ship.Mode.HOVER:
						ship.set_mode(Ship.Mode.HOVER, true)
					ship.in_move.y = clampf((t - 0.8) / 1.2, 0.0, 1.0) * 0.6
				else:
					if ship.mode != Ship.Mode.ATMOSPHERE:
						ship.set_mode(Ship.Mode.ATMOSPHERE, true)
						ship.throttle = 0.0
					ship.throttle = minf(ship.throttle + dt * 0.22, 0.6)
					ship.in_move.y = clampf(1.0 - (t - 4.6) / 2.0, 0.0, 1.0) * 0.5
					ship.steer_dir = (fwd + up * 0.3).normalized()
					ship.steer_up = up
			"landing":
				ship.in_move.y = -1.0 if ship.altitude > 6.0 else (-0.25 if ship.altitude > 0.8 else 0.0)
				ship.steer_dir = fwd
				ship.steer_up = up
		if int(t * 60.0) % 30 == 0:
			print("[demo] t=%.1f alt=%.1f v=%.1f vs=%.1f mode=%s gear=%s landed=%s spool=%.2f" % [t, ship.altitude,
				ship.vel.length(), ship.vel.dot(up), Ship.MODE_NAMES[ship.mode], ship.gear_down, ship.landed,
				(ship.get_node("FX") as ShipFX).engine_spool])
