extends Node3D
## Terrain test scene. Camera presets (tools/shot.sh --cam=... / --shots=...):
##   orbit, high_alt, low_flight, surface, surface_sunset   (Terra Nova)
##   moon_orbit (Selene), ignis_low, glacia_low, vex_orbit, nyx_orbit
## Extra args: --planet=<preset name> overrides the planet of the chosen camera preset.
##
## Floating-origin emulation: the camera stays at the world origin and the planet node is
## moved to -camera_local, exactly what the future Universe system will do.

const PRESET_DIR := "res://src/planets/presets/"
const OceanScript := preload("res://scenes/test/placeholder_ocean.gd")
const PlanetScene := preload("res://scenes/planets/planet.tscn")

const VIEWS := {
	"orbit": {"planet": "terra_nova"},
	"high_alt": {"planet": "terra_nova"},
	"low_flight": {"planet": "terra_nova"},
	"surface": {"planet": "terra_nova"},
	"surface_sunset": {"planet": "terra_nova"},
	"moon_orbit": {"planet": "selene"},
	"ignis_low": {"planet": "ignis"},
	"glacia_low": {"planet": "glacia"},
	"ignis_orbit": {"planet": "ignis"},
	"glacia_orbit": {"planet": "glacia"},
	"vex_orbit": {"planet": "vex"},
	"nyx_orbit": {"planet": "nyx"},
	"selene_surface": {"planet": "selene"},
}

@export var start_preset := "orbit"

var planet: Planet
var planet_key := ""
var cam_local := Vector3.ZERO

@onready var cam: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var env: Environment = $WorldEnvironment.environment


func _ready() -> void:
	add_to_group("capture_target")
	if not Capture.active:
		var p := Capture.get_preset()
		apply_capture_preset(p if p != "" else start_preset)


func _process(_dt: float) -> void:
	if planet and not Capture.active:
		# keep floating-origin emulation consistent if something moves the camera
		planet.position = -cam_local


func apply_capture_preset(preset: String) -> void:
	if not VIEWS.has(preset):
		push_warning("planet_test: unknown preset " + preset)
		return
	var key: String = Capture.args.get("planet", VIEWS[preset]["planet"])
	_ensure_planet(key)
	var cfg := planet.config
	var R := cfg.radius
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	env.fog_enabled = false
	var look_dir := Vector3.FORWARD
	var up := Vector3.UP
	match preset:
		"orbit", "moon_orbit", "ignis_orbit", "glacia_orbit", "vex_orbit", "nyx_orbit":
			var d := Vector3(0.35, 0.3, 1.0).normalized()
			cam_local = d * R * 3.9
			look_dir = (-cam_local).normalized()
			_sun_from(Vector3(1.0, 0.25, -0.05))
			up = Vector3.UP
			sun.shadow_enabled = false
			cam.near = 20.0
			cam.far = R * 20.0
			cam.fov = 40.0
		"high_alt":
			var site := _find_peak()
			var d := _offset_dir(site, Vector3.UP, 30000.0)
			cam_local = d * (R + planet.get_height(d) + 20000.0)
			look_dir = (site * R - cam_local).normalized()
			_sun_at(site, look_dir, 28.0, 135.0)
			sun.directional_shadow_max_distance = 60000.0
			cam.near = 5.0
			cam.far = R * 6.0
			cam.fov = 60.0
		"low_flight", "ignis_low", "glacia_low":
			var site := _find_lava() if preset == "ignis_low" else _find_peak()
			var dist_m := 2200.0 if preset == "ignis_low" else 11000.0
			var d := _lowest_around(site, float(Capture.args.get("dist", str(dist_m))))
			if preset == "ignis_low":
				d = _highest_around(site, dist_m)
			var alt := planet.get_height(d) + 500.0
			cam_local = d * (R + alt)
			var to_peak := (site * (R + planet.get_height(site)) - cam_local).normalized()
			var level := (to_peak - d * to_peak.dot(d)).normalized()
			var min_pitch := -0.55 if preset == "ignis_low" else -0.15
			look_dir = (level + d * clampf(to_peak.dot(d) * 0.8, min_pitch, 0.2)).normalized()
			_sun_at(d, look_dir, 24.0, 140.0)
			sun.directional_shadow_max_distance = 20000.0
			cam.near = 0.5
			cam.far = R * 4.0
			cam.fov = 65.0
		"surface", "surface_sunset", "selene_surface":
			var site := _find_peak()
			var d := _find_ground_near(site)
			cam_local = d * (R + planet.get_height(d) + 2.0)
			var to_peak := (site * (R + planet.get_height(site)) - cam_local).normalized()
			look_dir = (to_peak - d * to_peak.dot(d) + d * 0.02).normalized()
			if preset == "surface_sunset":
				_sun_at(d, look_dir, 4.0, 215.0)
				sun.light_color = Color(1.0, 0.6, 0.34)
				sun.light_energy = 2.2
			else:
				_sun_at(d, look_dir, 35.0, 145.0)
			sun.directional_shadow_max_distance = 3000.0
			cam.near = 0.05
			cam.far = R * 3.0
			cam.fov = 70.0
	if not preset.ends_with("orbit"):
		up = cam_local.normalized()
	planet.position = -cam_local
	cam.global_transform = Transform3D(Basis.looking_at(look_dir, up), Vector3.ZERO)
	planet.set_focus(cam_local)
	var t0 := Time.get_ticks_msec()
	planet.terrain.build_until_stable()
	var st := planet.terrain.get_stats()
	print("[planet_test] %s/%s alt=%.1f m: built in %d ms, %s" % [preset, key,
		planet.terrain.get_altitude(cam_local), Time.get_ticks_msec() - t0, str(st)])


func _ensure_planet(key: String) -> void:
	if planet and planet_key == key:
		return
	if planet:
		planet.queue_free()
	var cfg: PlanetConfig = load(PRESET_DIR + key + ".tres")
	planet = PlanetScene.instantiate() as Planet
	planet.name = "Planet_" + key
	planet.config = cfg
	planet.auto_focus_camera = false
	add_child(planet)
	if cfg.has_ocean_surface() and Capture.args.get("ocean", "1") != "0":
		var ocean := MeshInstance3D.new()
		ocean.set_script(OceanScript)
		planet.add_component(ocean)
	planet_key = key


## Sun pointing from planet-local direction `from` (light travels opposite).
func _sun_from(from: Vector3) -> void:
	sun.global_transform = Transform3D(Basis.looking_at(-from.normalized(), Vector3.UP), Vector3.ZERO)


## Sun at `elev_deg` above the local horizon at surface dir `d`, `az_deg` to the side of view.
func _sun_at(d: Vector3, view: Vector3, elev_deg: float, az_deg: float) -> void:
	var up := d.normalized()
	var fwd := (view - up * view.dot(up)).normalized()
	var horiz := fwd.rotated(up, deg_to_rad(az_deg))
	var from := horiz * cos(deg_to_rad(elev_deg)) + up * sin(deg_to_rad(elev_deg))
	sun.global_transform = Transform3D(Basis.looking_at(-from, up), Vector3.ZERO)


## Highest sampled point (fibonacci sphere, |lat| < 0.65) — the scenic mountain site.
func _find_peak() -> Vector3:
	var best := Vector3.UP
	var best_h := -1e9
	var n := 6000
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
		if absf(y) > 0.65:
			continue
		var r := sqrt(1.0 - y * y)
		var d := Vector3(cos(ga * i) * r, y, sin(ga * i) * r)
		var h := planet.get_height(d)
		if planet.config.type == PlanetConfig.PlanetType.EARTHLIKE \
				and planet.terrain.generator.moisture(d) < 0.6:
			continue   # prefer green ranges
		if h > best_h:
			best_h = h
			best = d
	best_h = planet.get_height(best)
	# refine locally
	for it in 3:
		var step := 2000.0 / pow(3.0, it) / planet.config.radius
		var c := best
		for k in 24:
			var a := TAU * k / 24.0
			var t1 := c.cross(Vector3.UP).normalized()
			var t2 := c.cross(t1)
			var d := (c + (t1 * cos(a) + t2 * sin(a)) * step).normalized()
			var h := planet.get_height(d)
			if h > best_h:
				best_h = h
				best = d
	return best


## Lava channel with the deepest surroundings (canyon floor) — Ignis showcase.
func _find_lava() -> Vector3:
	var gen := planet.terrain.generator
	var best := Vector3.UP
	var best_s := -1e9
	var n := 5000
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
		var r := sqrt(1.0 - y * y)
		var d := Vector3(cos(ga * i) * r, y, sin(ga * i) * r)
		var s := gen.sample(d, 1e9)
		if s.z < 0.8:
			continue
		var t1 := d.cross(Vector3.UP).normalized()
		var t2 := d.cross(t1)
		var e := 1200.0 / planet.config.radius
		var around := 0.0
		for k in 4:
			var a := TAU * k / 4.0
			around += planet.get_height((d + (t1 * cos(a) + t2 * sin(a)) * e).normalized())
		var score := around * 0.25 - s.x
		if score > best_s:
			best_s = score
			best = d
	return best


func _highest_around(site: Vector3, meters: float) -> Vector3:
	var t1 := site.cross(Vector3.UP).normalized()
	var t2 := site.cross(t1)
	var best := site
	var best_h := -1e9
	for k in 12:
		var a := TAU * k / 12.0
		var d := (site + (t1 * cos(a) + t2 * sin(a)) * (meters / planet.config.radius)).normalized()
		var h := planet.get_height(d)
		if h > best_h:
			best_h = h
			best = d
	return best


## Lowest of 12 points at `meters` around `site` (a valley in front of the range).
func _lowest_around(site: Vector3, meters: float) -> Vector3:
	var t1 := site.cross(Vector3.UP).normalized()
	var t2 := site.cross(t1)
	var best := site
	var best_h := 1e9
	for k in 12:
		var a := TAU * k / 12.0
		var d := (site + (t1 * cos(a) + t2 * sin(a)) * (meters / planet.config.radius)).normalized()
		var h := planet.get_height(d)
		if h < best_h and h > planet.config.get_base_level() + 50.0:
			best_h = h
			best = d
	return best


## Direction offset from `d` by `meters` along the tangent closest to `toward`.
func _offset_dir(d: Vector3, toward: Vector3, meters: float) -> Vector3:
	var t := (toward - d * toward.dot(d)).normalized()
	if t.length() < 0.5:
		t = d.cross(Vector3.RIGHT).normalized()
	return (d + t * (meters / planet.config.radius)).normalized()


## A gentle, low (but dry) spot 4–14 km from the site, so the peak dominates the horizon.
func _find_ground_near(site: Vector3) -> Vector3:
	var cfg := planet.config
	var base := cfg.get_base_level()
	var best := _offset_dir(site, Vector3.UP, 8000.0)
	var best_score := -1e9
	var t1 := site.cross(Vector3.UP).normalized()
	var t2 := site.cross(t1)
	for ring in 6:
		var dist := 4000.0 + ring * 2000.0
		for k in 36:
			var a := TAU * k / 36.0
			var d := (site + (t1 * cos(a) + t2 * sin(a)) * (dist / cfg.radius)).normalized()
			var h := planet.get_height(d) - base
			if h < 20.0:
				continue
			var e := 6.0 / cfg.radius
			var dh := absf(planet.get_height((d + t1 * e).normalized()) - planet.get_height((d - t1 * e).normalized())) \
				+ absf(planet.get_height((d + t2 * e).normalized()) - planet.get_height((d - t2 * e).normalized()))
			var score := -dh * 3.0 - absf(h - 250.0) * 0.01 - dist * 0.0002
			if score > best_score:
				best_score = score
				best = d
	return best
