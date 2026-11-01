extends Node3D
## Vegetation / rocks test scene (PlanetScatter on real planets). Camera presets:
##   meadow, forest_edge, hillside_view, rocky_slope, from_air      (Terra Nova)
##   ignis_basalt, glacia_ice, selene_boulders                      (other bodies)
##   lineup                                                         (every Terra asset in a row)
## Args: --no_atmo, --no_scatter, --mu_<slot>__<param>=value (material override), --stats (print scatter stats), --site_seed=N (pick another site),
##       --sun_elev=deg, --sun_az=deg, --planet=<preset> (override the preset's planet)
##
## Floating-origin emulation as in planet_test: the camera stays at the origin, the planet is moved
## to -camera_local. Scatter patches are planet children, so they follow automatically.

const PRESET_DIR := "res://src/planets/presets/"
const PlanetScene := preload("res://scenes/planets/planet.tscn")
const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")
const OCEAN_SCENE := preload("res://scenes/planets/ocean.tscn")

const VIEWS := {
	"meadow": "terra_nova", "forest_edge": "terra_nova", "hillside_view": "terra_nova",
	"rocky_slope": "terra_nova", "from_air": "terra_nova", "lineup": "terra_nova",
	"ignis_basalt": "ignis", "glacia_ice": "glacia", "selene_boulders": "selene",
}
const ATMO_PRESET := {"terra_nova": "terra_nova", "ignis": "ignis", "glacia": "glacia"}

@export var start_preset := "meadow"

var planet: Planet
var scatter: PlanetScatter
var atmo: AtmosphereLayer
var biome: ScatterBiome
var planet_key := ""
var cam_local := Vector3.ZERO
var sun_dir := Vector3.UP
var sun_color := Color(1.0, 0.96, 0.9)
var sun_energy := 2.2
var _lineup: Node3D

@onready var cam: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var env: Environment = $WorldEnvironment.environment


func _ready() -> void:
	add_to_group("capture_target")
	if not Capture.active:
		var p := Capture.get_preset()
		apply_capture_preset(p if p != "" else start_preset)


func _process(_dt: float) -> void:
	if planet:
		planet.position = -cam_local


func apply_capture_preset(preset: String) -> void:
	if not VIEWS.has(preset):
		push_warning("scatter_test: unknown preset " + preset)
		return
	_ensure_planet(Capture.args.get("planet", VIEWS[preset]))
	if _lineup:
		_lineup.queue_free()
		_lineup = null
	var cfg := planet.config
	var R := cfg.radius
	var rnd := RandomNumberGenerator.new()
	rnd.seed = int(Capture.args.get("site_seed", "7")) + preset.hash()
	var look := Vector3.FORWARD
	var eye := 1.8
	var elev := 32.0
	var az := 140.0
	cam.fov = 70.0
	sun_color = Color(1.0, 0.96, 0.9)
	sun_energy = 2.2
	var d := Vector3.UP
	match preset:
		"meadow", "lineup":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - absf(b["forest"] - 0.12) * 4.0 - b["slope"] * 8.0 - b["rock"] * 3.0 - b["snow"] * 5.0 \
					- absf(b["moist"] - 0.55) * 2.0 - (3.0 if b["height"] < 40.0 or b["height"] > 900.0 else 0.0))
			d = s
			look = _toward_best(d, 120.0, func(b: Dictionary) -> float: return b["forest"] * 2.0 - b["slope"] * 3.0)
			look = (look + d * 0.02).normalized()
			az = 120.0
			elev = 28.0
		"forest_edge":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - absf(b["forest"] - 0.35) * 4.0 - b["slope"] * 8.0 - b["rock"] * 3.0 - b["snow"] * 5.0 \
					- (3.0 if b["height"] < 40.0 or b["height"] > 1500.0 else 0.0))
			d = s
			look = _toward_best(d, 50.0, func(b: Dictionary) -> float: return b["forest"])
			look = (look + d * 0.06).normalized()
			az = 200.0
			elev = 35.0
		"hillside_view":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 1.0 + b["slope"] * 4.0 - b["rock"] * 2.0 - b["snow"] * 4.0 - absf(b["forest"] - 0.5) \
					- (3.0 if b["height"] < 200.0 or b["height"] > 1800.0 or b["slope"] > 0.25 else 0.0))
			d = s
			eye = 50.0
			look = _toward_lowest(d, 1500.0)
			look = (look - d * 0.18).normalized()
			az = 110.0
			elev = 24.0
			cam.fov = 65.0
		"rocky_slope":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - absf(b["rock"] - 0.55) * 3.0 - absf(b["slope"] - 0.2) * 6.0 - b["snow"] * 4.0 \
					- (3.0 if b["height"] < 100.0 else 0.0))
			d = s
			eye = 2.0
			look = _toward_lowest(d, 300.0)
			look = (look - d * 0.08).normalized()
			az = 160.0
			elev = 30.0
		"from_air":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - absf(b["forest"] - 0.75) * 3.0 - b["slope"] * 3.0 - b["snow"] * 5.0 \
					- (3.0 if b["height"] < 80.0 or b["height"] > 1500.0 else 0.0))
			d = s
			eye = 300.0
			look = _toward_best(d, 900.0, func(b: Dictionary) -> float: return b["forest"])
			look = (look - d * 0.45).normalized()
			az = 120.0
			elev = 30.0
			cam.fov = 60.0
		"ignis_basalt":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - absf(b["lava"] - 0.08) * 6.0 - b["slope"] * 6.0)
			d = s
			eye = 2.5
			look = _toward_best(d, 120.0, func(b: Dictionary) -> float: return b["lava"])
			look = (look + d * 0.05).normalized()
			az = 150.0
			elev = 14.0
			sun_color = Color(1.0, 0.85, 0.7)
		"glacia_ice":
			var s := _find_site(rnd, func(b: Dictionary) -> float:
				return 2.0 - b["slope"] * 5.0 + b["ice"] * 0.5 - (2.0 if b["height"] > 1500.0 else 0.0))
			d = s
			eye = 2.0
			look = _toward_best(d, 2000.0, func(b: Dictionary) -> float: return b["height"] * 0.001)
			look = (look + d * 0.06).normalized()
			az = 140.0
			elev = 18.0
		"selene_boulders":
			var s := _find_site(rnd, func(b: Dictionary) -> float: return 1.0 - absf(b["slope"] - 0.06) * 8.0 + b["rock"])
			d = s
			eye = 1.8
			look = _toward_best(d, 300.0, func(b: Dictionary) -> float: return b["height"] * 0.01)
			look = (look + d * 0.03).normalized()
			az = 120.0
			elev = 9.0
			sun_energy = 2.6
	if Capture.args.has("sun_elev"):
		elev = float(Capture.args["sun_elev"])
	if Capture.args.has("sun_az"):
		az = float(Capture.args["sun_az"])
	cam_local = d * (R + planet.get_height(d) + eye)
	cam.near = 0.05 if eye < 10.0 else 0.3
	cam.far = R * 3.0
	_sun_at(d, look, elev, az)
	sun.directional_shadow_max_distance = 500.0 if eye < 100.0 else 1500.0
	planet.position = -cam_local
	cam.global_transform = Transform3D(Basis.looking_at(look, d), Vector3.ZERO)
	planet.set_focus(cam_local)
	var t0 := Time.get_ticks_msec()
	planet.terrain.build_until_stable()
	var t1 := Time.get_ticks_msec()
	if scatter:
		scatter.enabled = preset != "lineup"
		if preset == "lineup":
			scatter.clear()
	if preset == "lineup":
		_build_lineup(d, look)
	elif scatter:
		scatter.set_focus(cam_local)
		scatter.build_until_stable()
	print("[scatter_test] %s/%s alt=%.1f m: terrain %d ms, scatter %d ms" % [preset, planet_key,
		planet.terrain.get_altitude(cam_local), t1 - t0, Time.get_ticks_msec() - t1])
	if scatter and (Capture.args.has("stats") or true):
		var st := scatter.get_stats()
		print("[scatter_test] instances=%d tris<=%d patches=%d bodies=%d cells=%d avg_cell_ms=%.2f" % [
			st["instances"], st["tris_max"], st["patch_nodes"], st["bodies"], st["cells_built"], st["avg_cell_ms"]])
		if Capture.args.has("stats"):
			for k in st["layers"]:
				print("    ", k, " ", st["layers"][k])
		print("[scatter_test] site biome: ", _fmt(biome.evaluate(d)))


func _fmt(b: Dictionary) -> String:
	var s := ""
	for k in b:
		s += "%s=%.2f " % [k, b[k]]
	return s


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
	planet_key = key
	biome = ScatterBiome.new(planet.terrain.generator, cfg)
	atmo = null
	if ATMO_PRESET.has(key) and not Capture.args.has("no_atmo"):
		atmo = ATMO_SCENE.instantiate()
		planet.components.add_child(atmo)
		atmo.setup({"preset": ATMO_PRESET[key], "radius": cfg.radius, "quality": 2})
	if cfg.has_ocean_surface():
		var ocean: Node = OCEAN_SCENE.instantiate()
		planet.components.add_child(ocean)
		ocean.setup({"radius": cfg.get_ocean_radius(), "atmosphere": atmo, "quality": 2})
	scatter = null
	if not Capture.args.has("no_scatter"):
		scatter = PlanetScatter.new()
		scatter.name = "Scatter"
		planet.add_component(scatter)
		# debug: --mu_<slot>__<param>=value overrides a scatter material parameter
		for k: String in Capture.args:
			if k.begins_with("mu_") and scatter.assets:
				var parts := k.substr(3).split("__")
				var m: ShaderMaterial = scatter.assets.materials.get(parts[0])
				if m:
					m.set_shader_parameter(parts[1], str_to_var(Capture.args[k]))
					for vk in scatter.assets._variants:
						if String(vk).begins_with(parts[0] + "|"):
							scatter.assets._variants[vk].set_shader_parameter(parts[1], str_to_var(Capture.args[k]))
	# environment: brighter test sky ambient per planet
	match key:
		"terra_nova":
			env.ambient_light_color = Color(0.42, 0.52, 0.7)
			env.ambient_light_energy = 0.55
		"glacia":
			env.ambient_light_color = Color(0.45, 0.6, 0.75)
			env.ambient_light_energy = 0.55
		"ignis":
			env.ambient_light_color = Color(0.55, 0.36, 0.25)
			env.ambient_light_energy = 0.45
		_:
			env.ambient_light_color = Color(0.12, 0.13, 0.16)
			env.ambient_light_energy = 0.3


func _sun_at(d: Vector3, view: Vector3, elev_deg: float, az_deg: float) -> void:
	var up := d.normalized()
	var fwd := (view - up * view.dot(up)).normalized()
	var horiz := fwd.rotated(up, deg_to_rad(az_deg))
	sun_dir = (horiz * cos(deg_to_rad(elev_deg)) + up * sin(deg_to_rad(elev_deg))).normalized()
	var col := sun_color
	if atmo:
		# terrain / scatter use the stock light: tint it by the atmosphere along the sun path
		var t: Vector3 = atmo.sun_transmittance(d * (planet.config.radius + planet.get_height(d) + 2.0), sun_dir)
		col = Color(sun_color.r * t.x, sun_color.g * t.y, sun_color.b * t.z)
	sun.light_color = col
	sun.light_energy = sun_energy
	SunGlobals.aim_light(sun, sun_dir)
	SunGlobals.set_sun(sun_dir, sun_color, sun_energy)


## Best-scoring land site (fibonacci sphere samples, |lat| < 0.7).
func _find_site(rnd: RandomNumberGenerator, score: Callable) -> Vector3:
	var best := Vector3.UP
	var best_s := -1e9
	var n := 2500
	var off := rnd.randf() * 1000.0
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
		if absf(y) > 0.7:
			continue
		var r := sqrt(1.0 - y * y)
		var d := Vector3(cos(ga * (i + off)) * r, y, sin(ga * (i + off)) * r)
		var b := biome.evaluate(d)
		if planet.config.has_ocean_surface() and b["height"] < 5.0:
			continue
		var s: float = score.call(b) + rnd.randf() * 0.2
		if s > best_s:
			best_s = s
			best = d
	# local refinement
	for it in 3:
		var step := 600.0 / pow(3.0, it) / planet.config.radius
		var c := best
		var t1 := c.cross(Vector3.UP).normalized()
		var t2 := c.cross(t1)
		for k in 16:
			var a := TAU * k / 16.0
			var d := (c + (t1 * cos(a) + t2 * sin(a)) * step).normalized()
			var b := biome.evaluate(d)
			if planet.config.has_ocean_surface() and b["height"] < 5.0:
				continue
			var s: float = score.call(b)
			if s > best_s:
				best_s = s
				best = d
	return best


## Horizontal direction (tangent at d) toward the best-scoring point on a ring of `dist` metres.
func _toward_best(d: Vector3, dist: float, score: Callable) -> Vector3:
	var t1 := d.cross(Vector3.UP).normalized()
	var t2 := d.cross(t1)
	var best := t1
	var best_s := -1e9
	for k in 24:
		var a := TAU * k / 24.0
		var dir := t1 * cos(a) + t2 * sin(a)
		var s := 0.0
		for f in [0.5, 1.0]:
			s += score.call(biome.evaluate((d + dir * (dist * f / planet.config.radius)).normalized()))
		if s > best_s:
			best_s = s
			best = dir
	return best


func _toward_lowest(d: Vector3, dist: float) -> Vector3:
	return _toward_best(d, dist, func(b: Dictionary) -> float: return -b["height"] + b["forest"] * 200.0)


## Every Terra Nova asset in two rows in front of the camera (asset review).
func _build_lineup(d: Vector3, look: Vector3) -> void:
	_lineup = Node3D.new()
	_lineup.name = "Lineup"
	planet.components.add_child(_lineup)
	var assets := scatter.assets if scatter else ScatterAssets.new(planet.config,
		load("res://src/planets/scatter/presets/terra_nova.tres"))
	var big := ["spirepine_lod0", "parasol_lod0", "fernpalm_lod0", "spirepine_lod1", "parasol_lod1",
		"fernpalm_lod1", "spirepine_lod2", "parasol_lod2", "fernpalm_lod2"]
	var small := ["bush_round_lod0", "bush_quill_lod0", "fern_lod0", "grass_lod0", "grass_tall_lod0",
		"flower_a_lod0", "flower_b_lod0", "boulder_a_lod0", "boulder_b_lod0", "rock_cluster_lod0", "pebbles_lod0"]
	var side := look.cross(d).normalized()
	var fwd := (look - d * look.dot(d)).normalized()
	var layer := ScatterLayer.new()
	var R := planet.config.radius
	for row in 2:
		var names: Array = big if row == 0 else small
		var spacing := 15.0 if row == 0 else 2.4
		var dist := 70.0 if row == 0 else 9.0
		for k in names.size():
			var nm: String = names[k]
			layer.model = "res://assets/models/rocks.glb" if nm.begins_with("boulder") or nm.begins_with("rock") \
				or nm.begins_with("pebbles") else "res://assets/models/flora_terra.glb"
			var mi := MeshInstance3D.new()
			mi.mesh = assets.mesh_for(layer, nm)
			var p := cam_local + fwd * dist + side * (k - (names.size() - 1) * 0.5) * spacing
			var dd := p.normalized()
			var surf := dd * (R + planet.get_height(dd))
			var s := 0.8 if row == 0 else (2.0 if nm.begins_with("grass") or nm.begins_with("flower") else 1.0)
			mi.transform = Transform3D(Basis(side * s, dd * s, side.cross(dd) * s), surf)
			_lineup.add_child(mi)
