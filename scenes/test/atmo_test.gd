extends Node3D
## Test scene for Stage 2b: atmosphere, clouds, ocean, gas giant, rings.
## Placeholder Terra Nova (R = 60 km) + Aurelion (R = 300 km) with a moon.
## Presets: orbit, terminator, atmo_entry, above_clouds, in_atmo_day, sunset_ground,
## ocean_glint, gasgiant, rings, gasgiant_from_moon.

const R_TERRA := 60000.0
const R_GG := 300000.0
const R_MOON := 12000.0
const MOON_DIST := 900000.0

const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")
const OCEAN_SCENE := preload("res://scenes/planets/ocean.tscn")
const CLOUDS_SCENE := preload("res://scenes/planets/clouds.tscn")
const GG_SCENE := preload("res://scenes/planets/gas_giant.tscn")

var sun_dir := Vector3(1.0, 0.18, 0.32).normalized()
var sun_color := Color(1.0, 0.96, 0.9)
var sun_energy := 1.6

var cam: Camera3D
var light: DirectionalLight3D
var env: Environment
var terra: Node3D
var terra_ground: PlaceholderBody
var terra_atmo: AtmosphereLayer
var terra_clouds: CloudLayer
var terra_ocean: OceanLayer
var gg_root: Node3D
var gg: GasGiantBody
var moon_root: Node3D
var moon_ground: PlaceholderBody
var _focus_body: PlaceholderBody


func _ready() -> void:
	add_to_group("capture_target")
	_build_env()
	_build_terra()
	_build_aurelion()
	var p: String = Capture.get_preset()
	apply_capture_preset(p if p != "" else "orbit")


func _build_env() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/debug_space_bg.gdshader")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0, 0, 0)
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.2
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	light = DirectionalLight3D.new()
	light.name = "Sun"
	light.light_color = sun_color
	light.light_energy = sun_energy
	light.shadow_enabled = false
	add_child(light)
	cam = Camera3D.new()
	cam.near = float(Capture.args.get("near", "1.0"))
	cam.far = float(Capture.args.get("far", "4.0e6"))
	cam.fov = 55.0
	add_child(cam)
	cam.make_current()


func _build_terra() -> void:
	terra = Node3D.new()
	terra.name = "TerraNova"
	add_child(terra)
	terra_ground = PlaceholderBody.new()
	terra_ground.radius = R_TERRA
	terra.add_child(terra_ground)
	terra_atmo = ATMO_SCENE.instantiate()
	terra.add_child(terra_atmo)
	terra_atmo.setup({"preset": "terra_nova", "radius": R_TERRA, "quality": 2})
	LayerParams.apply_uniforms(terra_ground.material, terra_atmo.uniforms)
	terra_ocean = OCEAN_SCENE.instantiate()
	terra.add_child(terra_ocean)
	terra_ocean.setup({"radius": R_TERRA, "atmosphere": terra_atmo, "quality": 2})
	terra_clouds = CLOUDS_SCENE.instantiate()
	terra.add_child(terra_clouds)
	terra_clouds.setup({"radius": R_TERRA, "bottom": 2200.0, "top": 4800.0, "coverage": 0.45, "brightness": 2.2, "cyclones": 5,
		"atmosphere": terra_atmo, "ocean_radius": R_TERRA, "quality": 2})
	terra_ocean.set_clouds(terra_clouds)
	terra_clouds.apply_shadow_uniforms(terra_ground.material)
	if Capture.args.has("no_clouds"):
		terra_clouds.visible = false
	# debug overrides: --cu_<uniform>=v (clouds), --ou_ (ocean), --au_ (atmosphere), --tu_ (terrain)
	for k: String in Capture.args:
		var v: Variant = str_to_var(Capture.args[k])
		if k.begins_with("cu_"):
			terra_clouds.material.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("ou_"):
			terra_ocean.material.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("au_"):
			terra_atmo.mat_scatter.set_shader_parameter(k.substr(3), v)
			terra_atmo.mat_transmit.set_shader_parameter(k.substr(3), v)
		elif k.begins_with("tu_"):
			terra_ground.material.set_shader_parameter(k.substr(3), v)
	if Capture.args.has("atmo_debug"):
		terra_atmo.mat_scatter.set_shader_parameter("atmo_debug", int(Capture.args["atmo_debug"]))
	if Capture.args.has("ocean_debug"):
		terra_ocean.material.set_shader_parameter("ocean_debug", int(Capture.args["ocean_debug"]))
	if Capture.args.has("no_atmo"):
		terra_atmo.visible = false


func _build_aurelion() -> void:
	gg_root = Node3D.new()
	gg_root.name = "AurelionSystem"
	add_child(gg_root)
	gg = GG_SCENE.instantiate()
	gg_root.add_child(gg)
	gg.setup({"radius": R_GG, "rings": true, "ring_tilt_deg": GG_TILT, "quality": 2})
	moon_root = Node3D.new()
	moon_root.name = "Moon"
	gg_root.add_child(moon_root)
	moon_root.position = moon_offset()
	moon_ground = PlaceholderBody.new()
	moon_ground.radius = R_MOON
	moon_ground.style = 1
	moon_ground.seed_value = 3.0
	moon_ground.feature_scale = 0.35
	moon_ground.amp = 0.45
	moon_root.add_child(moon_ground)
	moon_ground.material.set_shader_parameter("use_atmosphere", false)
	gg_root.visible = false


const GG_TILT := 16.0


## Moon position relative to Aurelion: just above the ring plane, outside the rings.
func moon_offset() -> Vector3:
	var up := Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(GG_TILT))
	var d := Vector3(0.62, 0.0, -0.78).normalized()
	d = (d - up * d.dot(up)).normalized()
	return (d + up * 0.1).normalized() * MOON_DIST


func _gg_up() -> Vector3:
	return Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(GG_TILT))


func _set_sun(d: Vector3) -> void:
	sun_dir = d.normalized()
	SunGlobals.aim_light(light, sun_dir)
	SunGlobals.set_sun(sun_dir, sun_color, sun_energy)


func _look(from: Vector3, at: Vector3, up: Vector3) -> void:
	cam.global_transform = Transform3D(Basis.IDENTITY, from).looking_at(at, up)


## Finds a surface direction where the sun is at `elev_deg` above the horizon and the terrain
## satisfies the predicate (height range). Searches the circle of equal sun elevation.
## ahead_max/ahead_dist: terrain toward the sun (tangent) must stay below ahead_max for
## ahead_dist metres (open view to the sun / sea toward the sun).
func _find_site(elev_deg: float, hmin: float, hmax: float, start_az: float = 0.0,
		ahead_max: float = INF, ahead_dist: float = 0.0, side: float = 0.0) -> Vector3:
	var l := sun_dir
	var a := (Vector3.UP if absf(l.y) < 0.9 else Vector3.RIGHT).cross(l).normalized()
	var b := l.cross(a)
	var s := sin(deg_to_rad(elev_deg))
	var c := sqrt(1.0 - s * s)
	for i in 1440:
		var az := start_az + TAU * i / 1440.0
		var n := (l * s + (a * cos(az) + b * sin(az)) * c).normalized()
		var h := terra_ground.height_at(n, 1)
		if h < hmin or h > hmax:
			continue
		if ahead_dist > 0.0:
			var fr := _frame(n)
			var dirv: Vector3 = (fr[1] + fr[2] * side).normalized()
			var ok := true
			for k in 12:
				var dist := ahead_dist * (k + 1) / 12.0
				var m := (n * R_TERRA + dirv * dist).normalized()
				if terra_ground.height_at(m, 1) > ahead_max:
					ok = false
					break
			if not ok:
				continue
		return n
	push_warning("site not found")
	return (l * s + a * c).normalized()


## Local frame at surface direction n: (up, toward-sun tangent, right)
func _frame(n: Vector3) -> Array:
	var f := sun_dir - n * sun_dir.dot(n)
	if f.length() < 1e-4:
		f = n.cross(Vector3.RIGHT)
	f = f.normalized()
	return [n, f, f.cross(n).normalized()]


func apply_capture_preset(preset: String) -> void:
	terra.visible = true
	gg_root.visible = false
	_focus_body = terra_ground
	_set_sun(Vector3(1.0, 0.18, 0.32))
	match preset:
		"orbit":
			var d := sun_dir.rotated(Vector3.UP, deg_to_rad(-55.0)).rotated(Vector3.RIGHT, deg_to_rad(-12.0))
			_look(d * 175000.0, Vector3(0, 0, 0), Vector3.UP)
		"terminator":
			# night side above the terminator, looking along the dusk line toward the limb
			var a := sun_dir.cross(Vector3.UP).normalized()
			var n := (a * 0.97 - sun_dir * 0.25).normalized()
			var pos := n * (R_TERRA + 45000.0)
			_look(pos, a.cross(sun_dir).normalized() * 0.0 + n * R_TERRA * 0.85 + sun_dir * 30000.0, n)
		"atmo_entry":
			var n := _find_site(35.0, 0.0, 6000.0, 0.6)
			var fr := _frame(n)
			var pos: Vector3 = n * (R_TERRA + 30000.0)
			_look(pos, pos - n * 30000.0 + fr[2] * 22000.0 + fr[1] * 10000.0, fr[2])
		"above_clouds":
			var n := _find_site(12.0, -5000.0, 6000.0, 1.2)
			var fr := _frame(n)
			var pos: Vector3 = n * (R_TERRA + 7200.0)
			_look(pos, pos + fr[1] * 10000.0 + fr[2] * 6000.0 - n * 600.0, n)
		"in_atmo_day":
			var n := _find_site(38.0, 50.0, 400.0, 2.0)
			var fr := _frame(n)
			var pos: Vector3 = n * (R_TERRA + terra_ground.height_at(n) + 500.0)
			_look(pos, pos + fr[2] * 10000.0 + fr[1] * 3000.0 - n * 300.0, n)
		"sunset_ground":
			var n := _find_site(2.0, 20.0, 150.0, 3.0, -5.0, 20000.0)
			var fr := _frame(n)
			var pos: Vector3 = n * (R_TERRA + terra_ground.height_at(n) + 60.0)
			_look(pos, pos + fr[1] * 10000.0 + fr[2] * 1500.0 + n * 400.0, n)
		"ocean_glint":
			var n := _find_site(16.0, -6000.0, -300.0, 4.0, -50.0, 25000.0)
			var fr := _frame(n)
			var pos: Vector3 = n * (R_TERRA + 900.0)
			_look(pos, pos + fr[1] * 10000.0 - n * 1300.0, n)
		"gasgiant", "rings", "gasgiant_from_moon":
			_gg_preset(preset)
		_:
			push_warning("unknown preset " + preset)
	_after_camera()


func _gg_preset(preset: String) -> void:
	terra.visible = false
	gg_root.visible = true
	gg_root.position = Vector3.ZERO
	_focus_body = null
	var up := _gg_up()
	var m := moon_offset()
	match preset:
		"gasgiant":
			# three-quarter phase, slightly above the ring plane: ring shadow on the planet
			var c := Vector3(0.3, 0.0, 1.0).normalized()
			c = (c - up * c.dot(up)).normalized()
			_set_sun((c.rotated(up, deg_to_rad(-75.0)) + up * 0.42).normalized())
			var pos := (c + up * 0.32).normalized() * 1.75e6
			_look(pos, Vector3(0, -40000, 0), up)
		"rings":
			# just above the ring plane near the outer A ring, looking across the rings at the planet
			var c := Vector3(-0.2, 0.0, 1.0).normalized()
			c = (c - up * c.dot(up)).normalized()
			var side := up.cross(c).normalized()
			_set_sun((-c * 0.55 + side * 0.65 + up * 0.38).normalized())
			var pos := c * 700000.0 + up * 38000.0 + side * 150000.0
			_look(pos, c * 150000.0 + side * -160000.0 + up * -60000.0, up)
		"gasgiant_from_moon":
			gg_root.position = -m       # floating origin: the moon at the world origin
			_focus_body = moon_ground
			var g := -m.normalized()    # toward the gas giant (moon-local)
			var side := g.cross(up).normalized()
			var n := (g * 0.5 + up * 0.85 + side * 0.15).normalized()
			_set_sun((side * 0.55 + g * -0.35 + up * 0.5 + n * 0.25).normalized())
			var h := moon_ground.height_at(n)
			var pos := n * (R_MOON + h + 3.0)
			var look := (g - n * g.dot(n)).normalized()
			_look(pos, pos + look * 1000.0 + n * 420.0, n)
	_after_camera()


func _after_camera() -> void:
	print("[atmo_test] cam ", cam.global_position, " fwd ", -cam.global_basis.z, " current ", cam.current)
	if _focus_body != null:
		_focus_body.focus(_focus_body.to_local(cam.global_position))
