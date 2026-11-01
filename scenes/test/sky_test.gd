extends Node
## Sky / atmosphere capture scene (wave 4 beauty pass): the real system (scenes/main.tscn, bare
## system mode) plus extra camera presets for skies, sunsets, clouds and night views.
##
##   tools/shot.sh scenes/test/sky_test.tscn --shots=sunset_sun,sunset_anti --outdir=<dir>
##
## Presets (all on Terra Nova unless noted; every main.tscn system preset works too):
##   sunset_sun        sun 2.5 deg, looking toward the sun across the sea
##   sunset_anti       same site, looking away from the sun (Earth-shadow belt, pink anti-twilight)
##   blue_hour         sun -4 deg, looking toward the afterglow
##   blue_hour_anti    sun -4 deg, looking away (Earth shadow risen, first stars)
##   sunrise_clouds    3 km over broken cumulus, sun 4 deg ahead
##   golden_clouds     6 km above the cumulus tops, sun 9 deg to the side
##   cloud_field       14 km, looking down at a cumulus field (sun 35 deg)
##   day_sky           2 m, sun 40 deg behind, looking at mountains (aerial perspective)
##   day_zenith        2 m, looking 50 deg up (zenith gradient)
##   night_milky       night side, sun -30 deg, looking up at the Milky Way
##   orbit_sunrise     orbital sunrise over the limb (close, telephoto)
##   orbit_terminator  terminator from 900 km (sunset band on the clouds)
## Modifiers: --yaw=<deg> (turn around the local up), --pitch=<deg>, --sun_elev=<deg> (for the
## sunset/blue hour presets), --alt=<m>, --fly=<m/s> (movie: camera moves along its forward
## horizon direction, keeping its height; `orbit_sunrise` moves along the orbit).

@onready var main: Node = $Main

var _fly := 0.0
var _fly_body: SolarSystem.BodyRec
var _fly_n := Vector3.ZERO      # planet-relative position (body units, from the centre)
var _fly_dir := Vector3.ZERO
var _fly_look := Vector3.ZERO
var _fly_up_bias := 0.0


func _ready() -> void:
	# main.gd (child, ready before us) joined the group: take over the preset dispatch
	main.remove_from_group("capture_target")
	add_to_group("capture_target")
	process_priority = -2000   # before FreeCamera / SolarSystem


func apply_capture_preset(preset: String) -> void:
	var sys: SolarSystem = main.system
	var cam: FreeCamera = main.cam
	_fly = 0.0
	if preset in ["sunset_sun", "sunset_anti", "blue_hour", "blue_hour_anti", "sunrise_clouds",
			"golden_clouds", "cloud_field", "day_sky", "day_zenith", "night_milky",
			"orbit_sunrise", "orbit_terminator"]:
		await main.apply_capture_preset("terra_orbit")   # resets weather / camera state
		_custom(preset)
		sys.build_terrain_now(cam)
	else:
		await main.apply_capture_preset(preset)
	_modifiers()
	if Capture.args.has("fly"):
		_fly = float(Capture.args["fly"])
		_fly_body = sys.focus if sys.focus else main._rec("Terra Nova")
		_fly_n = cam.global_position - _fly_body.node.global_position
		var up := _fly_n.normalized()
		var f := -cam.global_basis.z
		_fly_dir = (f - up * f.dot(up)).normalized()
		if preset == "orbit_sunrise":
			_fly_dir = (sys.sun_dir - up * sys.sun_dir.dot(up)).normalized()
		_fly_look = f


func _modifiers() -> void:
	var cam: FreeCamera = main.cam
	var sys: SolarSystem = main.system
	var body: SolarSystem.BodyRec = sys.focus
	var up := Vector3.UP
	if body:
		up = (cam.global_position - body.node.global_position).normalized()
	if Capture.args.has("yaw"):
		cam.global_basis = cam.global_basis.rotated(up, deg_to_rad(float(Capture.args["yaw"])))
	if Capture.args.has("pitch"):
		var right := cam.global_basis.x
		cam.global_basis = cam.global_basis.rotated(right, deg_to_rad(float(Capture.args["pitch"])))


func _sun_elev() -> float:
	return float(Capture.args.get("sun_elev", "nan"))


func _custom(preset: String) -> void:
	var t: SolarSystem.BodyRec = main._rec("Terra Nova")
	var sys: SolarSystem = main.system
	var cam: FreeCamera = main.cam
	var s: Vector3 = sys.sun_dir_from("Terra Nova")
	var base: float = t.planet.config.get_base_level()
	var elev := _sun_elev()
	match preset:
		"sunset_sun", "sunset_anti", "blue_hour", "blue_hour_anti":
			var e := 2.5 if preset.begins_with("sunset") else -4.0
			if not is_nan(elev):
				e = elev
			var n: Vector3 = main._search_sun_circle(t, s, e, func(nn: Vector3) -> float:
				var h: float = main._h(t, nn) - base
				if h < 8.0 or h > 400.0:
					return -INF
				var f: Vector3 = main._horizon_dir(nn, s)
				var sea: float = main._max_ahead(t, nn, f, 6000.0, 6) - h
				var back: float = main._max_ahead(t, nn, -f, 9000.0, 6) - h
				var hills: float = main._max_ahead(t, nn, main._horizon_dir(nn, s.cross(nn)), 8000.0, 5) - h
				# open sea toward the sun, some relief behind (anti-sun) and to the side
				return -maxf(sea, 0.0) * 0.01 + clampf(hills, 0.0, 600.0) * 0.002 \
					+ clampf(back, 0.0, 800.0) * 0.0015 - h * 0.002)
			var f: Vector3 = main._horizon_dir(n, s)
			var look: Vector3
			if preset.ends_with("anti"):
				look = (-f).rotated(n, deg_to_rad(-12.0)) + n * 0.16
			else:
				look = f.rotated(n, deg_to_rad(18.0)) + n * 0.09
			main._place_ground(t, n, float(Capture.args.get("alt", "2.0")), look.normalized())
			cam.fov = 75.0
		"sunrise_clouds", "golden_clouds", "cloud_field":
			var e2 := {"sunrise_clouds": 4.0, "golden_clouds": 9.0, "cloud_field": 35.0}[preset] as float
			if not is_nan(elev):
				e2 = elev
			var alt := {"sunrise_clouds": 3000.0, "golden_clouds": 6200.0, "cloud_field": 14000.0}[preset] as float
			alt = float(Capture.args.get("alt", str(alt)))
			var side := 0.0 if preset == "sunrise_clouds" else (55.0 if preset == "golden_clouds" else 120.0)
			# a site over sea/lowland with broken clouds around (weather map coverage ~0.45)
			var n2: Vector3 = main._search_sun_circle(t, s, e2, func(nn: Vector3) -> float:
				var f2: Vector3 = main._horizon_dir(nn, s).rotated(nn, deg_to_rad(side))
				var c := 0.0
				for k in 6:
					var d := (nn * t.radius + f2 * (6000.0 + 7000.0 * k)).normalized()
					c += maxf(t.clouds.weather_at(d).x, 0.0)
				var here: float = maxf(t.clouds.weather_at(nn).x, 0.0)
				var h2: float = main._h(t, nn) - base
				return -absf(c / 6.0 - 0.5) * 3.0 - absf(here - 0.4) - maxf(h2 - 500.0, 0.0) * 0.001 \
					- smoothstep(0.5, 0.7, absf(nn.y)) * 4.0, 360)
			var f3: Vector3 = main._horizon_dir(n2, s).rotated(n2, deg_to_rad(side))
			var dip := -0.06 if preset == "sunrise_clouds" else (-0.12 if preset == "golden_clouds" else -0.55)
			main._place_ground(t, n2, alt, (f3 + n2 * dip).normalized())
			cam.fov = 70.0
		"day_sky", "day_zenith":
			var e3 := 40.0 if is_nan(elev) else elev
			var best_n := s
			var best_f := Vector3.FORWARD
			var best := -INF
			var a := Vector3.UP.cross(s).normalized()
			var b := s.cross(a)
			var se := sin(deg_to_rad(e3))
			for i in 360:
				var az := TAU * float(i) / 360.0
				var nn := (s * se + (a * cos(az) + b * sin(az)) * sqrt(1.0 - se * se)).normalized()
				var h3: float = main._h(t, nn) - base
				if h3 < 20.0 or h3 > 600.0 or absf(nn.y) > 0.6:
					continue
				var away: Vector3 = main._horizon_dir(nn, -s)
				for rot: float in [-50.0, -25.0, 0.0, 25.0, 50.0]:
					var f4 := away.rotated(nn, deg_to_rad(rot))
					var near: float = main._max_ahead(t, nn, f4, 3000.0, 4) - h3
					var far_m: float = main._max_ahead(t, nn, f4, 30000.0, 10) - h3
					var sc := clampf(far_m, 0.0, 3000.0) * 0.002 - maxf(near - 120.0, 0.0) * 0.01 \
						- maxf(t.clouds.weather_at(nn).x - 0.3, 0.0) * 2.0
					if sc > best:
						best = sc
						best_n = nn
						best_f = f4
			main._clear_weather(t, best_n, [s, best_f, best_n], [2.0, 1.0, 2.0])
			var up_k := 0.06 if preset == "day_sky" else 1.2
			main._place_ground(t, best_n, 2.0, (best_f + best_n * up_k).normalized())
			cam.fov = 70.0 if preset == "day_sky" else 85.0
		"night_milky":
			var e4 := -30.0 if is_nan(elev) else elev
			var n4: Vector3 = main._search_sun_circle(t, s, e4, func(nn: Vector3) -> float:
				var h4: float = main._h(t, nn) - base
				if h4 < 10.0 or h4 > 800.0:
					return -INF
				return -absf(nn.y) - maxf(t.clouds.weather_at(nn).x, 0.0) * 3.0, 180)
			main._clear_weather(t, n4, [n4], [1.0])
			# look toward the galactic band (sky shader galaxy_center direction)
			var gc := Vector3(-0.55, 0.15, -0.82).normalized()
			var f5: Vector3 = main._horizon_dir(n4, gc)
			main._place_ground(t, n4, 2.0, (f5 + n4 * 0.55).normalized())
			cam.fov = 80.0
		"orbit_sunrise":
			var dist := t.radius + float(Capture.args.get("alt", "9000.0"))
			var alpha := asin(t.radius / dist)
			var ang := alpha + deg_to_rad(float(Capture.args.get("sun_off", "-1.0")))
			var w := s.cross(Vector3.UP).normalized()
			var c := (-s * cos(ang) + w * sin(ang)).normalized()
			var off := c * dist
			var hz := (s - c * s.dot(c)).normalized()
			var look := (hz - c * 0.02).normalized()
			main._place_space(t, off, off + look * 1000.0, c)
			cam.fov = float(Capture.args.get("fov", "60"))
		"orbit_terminator":
			var w2 := s.cross(Vector3.UP).normalized()
			var c2 := (w2 * 0.9 + s * 0.25 + Vector3.UP * 0.3).normalized()
			var off2 := c2 * (t.radius + 450000.0)
			main._place_space(t, off2, (w2 * 0.6 + s * 0.15) * t.radius, Vector3.UP)
			cam.fov = 40.0


func _process(dt: float) -> void:
	if _fly == 0.0 or _fly_body == null:
		return
	var sys: SolarSystem = main.system
	var cam: FreeCamera = main.cam
	var r := _fly_n.length()
	var up := _fly_n / r
	var ang := _fly * dt / r
	var axis := up.cross(_fly_dir).normalized()
	_fly_n = _fly_n.rotated(axis, ang)
	_fly_dir = _fly_dir.rotated(axis, ang)
	_fly_look = _fly_look.rotated(axis, ang)
	var up2 := _fly_n.normalized()
	sys.place_camera(cam, _fly_body.pos, _fly_n, _fly_n + _fly_look * 1000.0, up2)
