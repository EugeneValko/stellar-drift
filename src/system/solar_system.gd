class_name SolarSystem
extends Node3D
## Builds the whole star system from SystemDef and runs it every frame:
##  * floating origin: body nodes sit at (true position - Universe origin), computed in 64-bit;
##  * scaled space: bodies too far for the camera far plane are drawn scaled about the camera
##    (exactly the same image, compressed depth) — see "Scaled space" below;
##  * lighting: one shadowed main DirectionalLight3D aimed star -> camera for the "focus group"
##    (planet + moons near the camera, the ship, the player), plus one unshadowed light per
##    other planet group (render-layer masks) so every body shows its correct phase;
##    SunGlobals + per-material `body_sun_dir` for the atmosphere/cloud/ocean/ring shaders;
##  * terrain LOD: only the focus planet refines around the camera, others drop to 6-24 chunks;
##  * render priorities of transparent planet layers sorted by distance;
##  * exposure / sky dimming between space, daylight surface and night side.
##
## Place it under Universe.world_root (it keeps its own position at zero after origin shifts).
##
## ## Scaled space
## Godot 4.7 culls everything when camera far/near > ~1e7 (measured: at near 0.1, far 1e6 a
## mesh at 0.9*far disappears; far/near 4e6 works). So camera far = near * `far_ratio` and
## every body group whose far edge would be beyond `F_max = 0.85 * far` is drawn by its own
## visual nodes (Planet: Terrain + Components, gas giant: body/atmosphere/rings) scaled by k
## about the camera: world = cam + (p - cam) * k. The body's node itself stays at the true
## position (gravity, Universe API, collisions are unaffected). All layer shaders divide
## camera-relative vectors and scene depth by the node scale, so the image is identical.
## k = compress(b) / b with b = distance to the unit's far edge; compress() is identity up
## to F_lin and a gentle power law above (monotonic -> occlusion order between groups kept).
## A group (planet + moons) shares one k (exact order inside); the focus body is split out
## and stays unscaled (k = 1) while its far edge fits in F_max.

signal system_built

const PLANET_SCENE := preload("res://scenes/planets/planet.tscn")
const STAR_SCENE := preload("res://scenes/space/star.tscn")
const GG_SCENE := preload("res://scenes/planets/gas_giant.tscn")
const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")
const CLOUDS_SCENE := preload("res://scenes/planets/clouds.tscn")
const OCEAN_SCENE := preload("res://scenes/planets/ocean.tscn")
const PRESET_DIR := "res://src/planets/presets/"

@export_group("Quality")
## 0 low / 1 medium / 2 high: atmosphere/cloud/ocean steps, gas giant octaves.
@export_range(0, 2) var quality := 1
## Cloud weather bake width (equirect, height = width / 2).
@export var cloud_weather_resolution := 2048

@export_group("Scaled space")
## Camera far = near * far_ratio (applied every frame). Godot 4.7 breaks at ~1e7.
@export var far_ratio := 4.0e6
@export var manage_camera_far := true
## Fraction of the far plane usable for geometry.
@export var far_usable := 0.85
## Unscaled range = F_max / lin_fraction_inv.
@export var lin_fraction_inv := 4.0
## Distance mapped onto F_max (beyond: scaled straight to F_max).
@export var compress_max_distance := 3.0e8
## A body is the "focus" (unscaled, LOD around camera, shadows) while the camera altitude
## is below max(radius * focus_altitude_factor, focus_min_altitude).
@export var focus_altitude_factor := 3.0
@export var focus_min_altitude := 60000.0

@export_group("Lighting")
@export var shadows_enabled := true
## Shadow distance = clamp(shadow_base + altitude * shadow_per_alt, shadow_base, shadow_max).
@export var shadow_base := 1500.0
@export var shadow_per_alt := 10.0
@export var shadow_max := 200000.0
@export var glow_threshold := 2.5

@export_group("Exposure")
@export var auto_exposure := true
@export var exposure_space := 1.0
@export var exposure_day_surface := 0.9
@export var exposure_night_surface := 2.6
## Background (stars, Milky Way) energy in a daylight sky (1 = space).
@export var sky_day_energy := 0.006
## Exposure adaptation speed (1/s); capture snaps instantly.
@export var adapt_speed := 1.5

## Optional explicit camera (else the viewport's current camera).
var camera: Camera3D
var environment: Environment

var star: Star
var bodies: Array[BodyRec] = []
var by_name: Dictionary = {}
var main_light: DirectionalLight3D
var group_lights: Dictionary = {}   # group index -> DirectionalLight3D
var focus: BodyRec
var focus_group := -1
## World direction toward the star from the camera (what SunGlobals holds).
var sun_dir := Vector3.FORWARD

var _built := false
var _exposure := 1.0
var _sky_energy := 1.0
var _snap := true


## Runtime record of one body.
class BodyRec:
	var name := ""
	var kind := 0
	var group := 0
	var parent_name := ""
	var node: Node3D
	var planet: Planet
	var gg: GasGiantBody
	var atmo: AtmosphereLayer
	var clouds: CloudLayer
	var ocean: OceanLayer
	var pos := Vector3.ZERO          # true system-frame position (exact float32 constant)
	var radius := 0.0
	var bound := 0.0                 # radius of everything drawn (atmosphere shell, rings)
	var visuals: Array[Node3D] = []
	var k := 1.0
	var prio_base := 1 << 20
	var sun_dir_applied := Vector3(INF, INF, INF)
	var sun_mats: Array[ShaderMaterial] = []      # get body_sun_dir
	var prio_mats: Array = []                     # [ShaderMaterial, base priority]
	var rel := Vector3.ZERO                       # node position - camera (per frame)


func _ready() -> void:
	process_priority = -100   # before Star/PlanetTerrain/Planet components
	build()
	if not Universe.origin_shifted.is_connected(_on_origin_shifted):
		Universe.origin_shifted.connect(_on_origin_shifted)


func build() -> void:
	if _built:
		return
	_built = true
	_build_lights()
	for d in SystemDef.bodies():
		match int(d["kind"]):
			SystemDef.Kind.STAR:
				_build_star(d)
			SystemDef.Kind.PLANET:
				_build_planet(d)
			SystemDef.Kind.GAS_GIANT:
				_build_gas_giant(d)
	_update_positions()
	system_built.emit()


# ---------------------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------------------

func _build_lights() -> void:
	main_light = DirectionalLight3D.new()
	main_light.name = "SunLight"
	main_light.shadow_enabled = shadows_enabled
	main_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	main_light.directional_shadow_blend_splits = true
	main_light.directional_shadow_split_1 = 0.06
	main_light.directional_shadow_split_2 = 0.18
	main_light.directional_shadow_split_3 = 0.45
	main_light.directional_shadow_max_distance = shadow_base
	main_light.directional_shadow_pancake_size = 50.0
	main_light.shadow_bias = 0.03
	main_light.shadow_normal_bias = 1.5
	main_light.shadow_blur = 1.0
	main_light.light_angular_distance = 0.5
	add_child(main_light)
	for g in range(1, SystemDef.GROUPS.size()):
		var l := DirectionalLight3D.new()
		l.name = "GroupLight_" + String(SystemDef.GROUPS[g]).replace(" ", "")
		l.shadow_enabled = false
		l.light_cull_mask = group_layer(g)
		add_child(l)
		group_lights[g] = l


## Render-layer bit of a planet group (layer 1 = ship/player/props lit by the main light).
static func group_layer(g: int) -> int:
	return 1 << g


func _build_star(d: Dictionary) -> void:
	star = STAR_SCENE.instantiate() as Star
	star.name = d["name"]
	star.radius = d["radius"]
	star.temperature = d.get("temperature", 5900.0)
	star.light_energy = d.get("light_energy", 1.6)
	star.drive_light = false
	add_child(star)
	var rec := BodyRec.new()
	rec.name = d["name"]
	rec.kind = SystemDef.Kind.STAR
	rec.node = star
	rec.pos = d["pos"]
	rec.radius = d["radius"]
	rec.bound = rec.radius
	_register(rec)


func _build_planet(d: Dictionary) -> void:
	var cfg: PlanetConfig = load(PRESET_DIR + String(d["preset"]) + ".tres")
	var p := PLANET_SCENE.instantiate() as Planet
	p.name = String(d["name"]).replace(" ", "")
	p.config = cfg
	p.auto_focus_camera = false
	p.surface_gravity = d.get("gravity", 9.81)
	add_child(p)   # builds the terrain (Planet._ready)
	var rec := BodyRec.new()
	rec.name = d["name"]
	rec.kind = SystemDef.Kind.PLANET
	rec.group = d["group"]
	rec.parent_name = d.get("parent", "")
	rec.node = p
	rec.planet = p
	rec.pos = d["pos"]
	rec.radius = cfg.radius
	rec.bound = cfg.radius + cfg.height_amplitude
	var q := quality
	var sea := cfg.get_ocean_radius()
	var base_r := sea if sea > 0.0 else cfg.radius

	if d.get("atmosphere") != null:
		var ad: Dictionary = (d["atmosphere"] as Dictionary).duplicate()
		ad["radius"] = base_r
		ad["ground_radius"] = sea if sea > 0.0 else cfg.radius + float(ad.get("ground_offset", 0.0))
		ad["quality"] = q
		var atmo := ATMO_SCENE.instantiate() as AtmosphereLayer
		atmo.name = "Atmosphere"
		p.add_component(atmo, ad)
		rec.atmo = atmo
		rec.bound = maxf(rec.bound, atmo.get_top_radius() * 1.03)
		LayerParams.apply_uniforms(p.terrain_material, atmo.uniforms)
		p.terrain_material.set_shader_parameter("use_atmosphere", true)
		rec.prio_mats.append([atmo.mat_transmit, LayerParams.PRIO_ATMO_T])
		rec.prio_mats.append([atmo.mat_scatter, LayerParams.PRIO_ATMO_S])
		rec.sun_mats.append_array([atmo.mat_transmit, atmo.mat_scatter])
	if sea > 0.0:
		var ocean := OCEAN_SCENE.instantiate() as OceanLayer
		ocean.name = "Ocean"
		var od: Dictionary = (d.get("ocean", {}) as Dictionary).duplicate()
		od["radius"] = sea
		od["atmosphere"] = rec.atmo
		od["quality"] = q
		p.add_component(ocean, od)
		rec.ocean = ocean
		rec.prio_mats.append([ocean.material, LayerParams.PRIO_OCEAN])
		rec.sun_mats.append(ocean.material)
	if d.get("clouds") != null:
		var cd: Dictionary = (d["clouds"] as Dictionary).duplicate()
		cd["radius"] = base_r
		cd["atmosphere"] = rec.atmo
		cd["ocean_radius"] = sea
		cd["quality"] = q
		cd["weather_resolution"] = cloud_weather_resolution
		var clouds := CLOUDS_SCENE.instantiate() as CloudLayer
		clouds.name = "Clouds"
		p.add_component(clouds, cd)
		rec.clouds = clouds
		if rec.ocean:
			rec.ocean.set_clouds(clouds)
		clouds.apply_shadow_uniforms(p.terrain_material)
		rec.bound = maxf(rec.bound, (base_r + float(cd.get("top", 4000.0)) + 4000.0) * 1.03)
		rec.prio_mats.append([clouds.material, LayerParams.PRIO_CLOUDS])
		rec.sun_mats.append(clouds.material)
	rec.sun_mats.append(p.terrain_material)
	p.terrain.set_render_layers(group_layer(rec.group))
	rec.visuals = [p.terrain, p.components]
	_register(rec)


func _build_gas_giant(d: Dictionary) -> void:
	var gg := GG_SCENE.instantiate() as GasGiantBody
	gg.name = String(d["name"])
	gg.surface_gravity = d.get("gravity", 22.0)
	add_child(gg)
	var gp: Dictionary = (d.get("params", {}) as Dictionary).duplicate(true)
	gp["name"] = d["name"]
	gp["radius"] = d["radius"]
	gp["ring_tilt_deg"] = d.get("ring_tilt_deg", 16.0)
	gp["quality"] = quality
	if not gp.has("rings"):
		gp["rings"] = true
	gg.setup(gp)
	gg.rotation_degrees.y = d.get("ring_yaw_deg", 0.0)
	var rec := BodyRec.new()
	rec.name = d["name"]
	rec.kind = SystemDef.Kind.GAS_GIANT
	rec.group = d["group"]
	rec.node = gg
	rec.gg = gg
	rec.pos = d["pos"]
	rec.radius = d["radius"]
	rec.bound = rec.radius * 1.1
	gg.body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rec.sun_mats.append(gg.material)
	if gg.atmosphere:
		rec.atmo = gg.atmosphere
		rec.bound = maxf(rec.bound, gg.atmosphere.get_top_radius() * 1.03)
		rec.prio_mats.append([gg.atmosphere.mat_transmit, LayerParams.PRIO_ATMO_T])
		rec.prio_mats.append([gg.atmosphere.mat_scatter, LayerParams.PRIO_ATMO_S])
		rec.sun_mats.append_array([gg.atmosphere.mat_transmit, gg.atmosphere.mat_scatter])
	if gg.rings:
		rec.bound = maxf(rec.bound, float(gg.rings.uniforms["ring_outer"]) * 1.01)
		rec.prio_mats.append([gg.rings.material, LayerParams.PRIO_RINGS])
		rec.sun_mats.append(gg.rings.material)
	for c in gg.get_children():
		if c is Node3D:
			rec.visuals.append(c)
	_register(rec)


func _register(rec: BodyRec) -> void:
	bodies.append(rec)
	by_name[rec.name] = rec


# ---------------------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------------------

func get_body(body_name: String) -> BodyRec:
	return by_name.get(body_name)


## Node of a body by name (Planet / GasGiantBody / Star).
func get_body_node(body_name: String) -> Node3D:
	var r: BodyRec = by_name.get(body_name)
	return r.node if r else null


## Unit direction from body toward the star (system frame == world orientation).
func sun_dir_from(body_name: String) -> Vector3:
	var r: BodyRec = by_name[body_name]
	return (star_pos() - r.pos).normalized()


func star_pos() -> Vector3:
	return (by_name[SystemDef.STAR["name"]] as BodyRec).pos


## Places `cam` at the true system-frame point (planet_pos + offset) by moving the floating
## origin there, then orients it toward `look_target_offset` (also relative to `planet_pos`).
func place_camera(cam: Camera3D, base: Vector3, offset: Vector3, look_offset: Vector3, up: Vector3) -> void:
	# 64-bit: base is an exact float32 constant, offset is small
	Universe.teleport_origin(float(base.x) + offset.x, float(base.y) + offset.y, float(base.z) + offset.z)
	position = Vector3.ZERO
	_update_positions()
	cam.global_position = Vector3.ZERO
	var dir := (look_offset - offset).normalized()
	cam.global_basis = Basis.looking_at(dir, up)
	_snap = true


## Synchronous terrain build of every planet for the current camera (capture/loading).
func build_terrain_now(cam: Camera3D = null) -> void:
	process_frame(cam)
	for r in bodies:
		if r.planet:
			r.planet.terrain.build_until_stable(60.0 if r == focus else 20.0)
	_snap = true


# ---------------------------------------------------------------------------------------
# Frame update
# ---------------------------------------------------------------------------------------

func _on_origin_shifted(_delta: Vector3) -> void:
	position = Vector3.ZERO
	_update_positions()


func _update_positions() -> void:
	for r in bodies:
		r.node.position = Universe.true_to_local(r.pos.x, r.pos.y, r.pos.z)


func _process(dt: float) -> void:
	if Engine.is_editor_hint():
		return
	var cam := camera if camera and camera.is_inside_tree() else get_viewport().get_camera_3d()
	if cam == null:
		return
	_frame(cam, dt)


## Runs one update with an explicit camera (used by capture presets before building LOD).
func process_frame(cam: Camera3D = null) -> void:
	if cam == null:
		cam = camera if camera else get_viewport().get_camera_3d()
	if cam:
		_frame(cam, 0.0)


func _frame(cam: Camera3D, dt: float) -> void:
	if position != Vector3.ZERO:
		position = Vector3.ZERO
	_update_positions()
	if manage_camera_far:
		cam.far = cam.near * far_ratio
	var cp := cam.global_position
	for r in bodies:
		r.rel = r.node.global_position - cp
	_pick_focus()
	_update_scaled_space(cam)
	_update_lights(cam)
	_update_terrain(cam)
	_update_exposure(cam, dt)
	_snap = false


func _pick_focus() -> void:
	var best: BodyRec = null
	var best_alt := INF
	for r in bodies:
		if r.kind == SystemDef.Kind.STAR:
			continue
		var alt := r.rel.length() - r.radius
		if alt < best_alt:
			best_alt = alt
			best = r
	if best and best_alt < maxf(best.radius * focus_altitude_factor, focus_min_altitude):
		focus = best
		focus_group = best.group
	else:
		focus = null
		focus_group = -1


func _compress(x: float, f_lin: float, f_max: float) -> float:
	if x <= f_lin:
		return x
	if x >= compress_max_distance:
		return f_max
	var p := log(f_max / f_lin) / log(compress_max_distance / f_lin)
	return f_lin * pow(x / f_lin, p)


func _update_scaled_space(cam: Camera3D) -> void:
	var f_max := cam.far * far_usable
	var f_lin := f_max / lin_fraction_inv
	# units: focus body alone, then each group without the focus body
	var units: Array = []
	if focus:
		units.append([focus])
	var groups := {}
	for r in bodies:
		if r == focus or r.kind == SystemDef.Kind.STAR:
			continue
		if not groups.has(r.group):
			groups[r.group] = []
		groups[r.group].append(r)
	for g in groups:
		units.append(groups[g])
	var order: Array = []   # [scaled distance, unit]
	for u: Array in units:
		var primary: BodyRec = u[0]
		for m: BodyRec in u:
			if m.parent_name == "":
				primary = m
		var c := primary.rel
		var bnd := 0.0
		for m: BodyRec in u:
			bnd = maxf(bnd, (m.rel - c).length() + m.bound)
		var b := c.length() + bnd
		var k := 1.0
		if u.size() == 1 and u[0] == focus:
			k = 1.0 if b <= f_max else f_max / b
		else:
			k = _compress(b, f_lin, f_max) / b
		for m: BodyRec in u:
			_apply_scale(m, k, cam)
		order.append([c.length() * k, u])
	# star (its own visual scaling: Star.max_render_distance)
	var sr: BodyRec = by_name[SystemDef.STAR["name"]]
	var ds := sr.rel.length()
	var bs := ds + sr.radius
	var ks := _compress(bs, f_lin, f_max) / bs
	star.max_render_distance = ds * ks if ks < 0.9999 else 0.0
	# transparent layer order: farther units first (lower priority)
	order.sort_custom(func(a: Array, b2: Array) -> bool: return a[0] < b2[0])
	for i in order.size():
		for m: BodyRec in order[i][1]:
			_set_priority(m, -5 * i)


func _apply_scale(r: BodyRec, k: float, cam: Camera3D) -> void:
	r.k = k
	var t := Transform3D.IDENTITY
	if k < 0.99999:
		var cam_local := r.node.to_local(cam.global_position)
		t = Transform3D(Basis.from_scale(Vector3(k, k, k)), cam_local * (1.0 - k))
	for v in r.visuals:
		if is_instance_valid(v):
			v.transform = t


func _set_priority(r: BodyRec, base: int) -> void:
	if base == r.prio_base:
		return
	r.prio_base = base
	for pm: Array in r.prio_mats:
		(pm[0] as ShaderMaterial).render_priority = clampi(int(pm[1]) + base, -128, 127)


func _update_lights(cam: Camera3D) -> void:
	var sp := star.global_position
	var cp := cam.global_position
	var to_sun := (sp - cp).normalized()
	sun_dir = to_sun
	SunGlobals.aim_light(main_light, to_sun)
	main_light.light_color = star.light_color
	main_light.light_energy = star.light_energy
	SunGlobals.set_sun(to_sun, star.light_color, star.light_energy)
	main_light.light_cull_mask = 1 | (group_layer(focus_group) if focus_group > 0 else 0)
	for g in group_lights:
		var l: DirectionalLight3D = group_lights[g]
		l.visible = g != focus_group
		l.light_color = star.light_color
		l.light_energy = star.light_energy
	for r in bodies:
		if r.kind == SystemDef.Kind.STAR:
			continue
		var want := Vector3.ZERO
		if r.group != focus_group:
			want = (star_pos() - _group_primary_pos(r.group)).normalized()
		if want != r.sun_dir_applied:
			r.sun_dir_applied = want
			for m in r.sun_mats:
				m.set_shader_parameter("body_sun_dir", want)
	for g in group_lights:
		var l2: DirectionalLight3D = group_lights[g]
		if l2.visible:
			SunGlobals.aim_light(l2, (star_pos() - _group_primary_pos(g)).normalized())
	# shadow distance follows the altitude over the focus body
	var alt := 1.0e9
	if focus:
		alt = _altitude(focus, cp)
	main_light.directional_shadow_max_distance = clampf(shadow_base + alt * shadow_per_alt, shadow_base, shadow_max)
	main_light.shadow_enabled = shadows_enabled and focus != null


func _group_primary_pos(g: int) -> Vector3:
	for r in bodies:
		if r.group == g and r.parent_name == "" and r.kind != SystemDef.Kind.STAR:
			return r.pos
	return Vector3.ZERO


func _altitude(r: BodyRec, world_pos: Vector3) -> float:
	if r.planet:
		var a := r.planet.get_altitude_global(world_pos)
		if r.planet.config.has_ocean_surface():
			a = minf(a, world_pos.distance_to(r.node.global_position) - r.planet.config.get_ocean_radius())
		return a
	return world_pos.distance_to(r.node.global_position) - r.radius


func _update_terrain(cam: Camera3D) -> void:
	var vp_h := float(get_viewport().get_visible_rect().size.y)
	var t := tan(deg_to_rad(cam.fov) * 0.5)
	for r in bodies:
		if r.planet == null or r.planet.terrain == null:
			continue
		var cam_local := r.node.to_local(cam.global_position)
		r.planet.set_focus(cam_local)
		var lvl := 2
		if r != focus:
			var d := maxf(cam_local.length(), r.radius * 1.01)
			var px := r.radius / d / t * vp_h * 0.5
			lvl = 0 if px < 120.0 else (1 if px < 450.0 else 2)
		r.planet.terrain.set_min_level(lvl)
		r.planet.terrain.set_cast_shadows(r == focus)


## Exposure + star-field dimming: brighter on a night side near the ground, slightly darker in
## a daylight sky; stars/Milky Way fade under a bright atmosphere.
func _update_exposure(cam: Camera3D, dt: float) -> void:
	if environment == null:
		return
	var target := exposure_space
	var sky := 1.0
	if focus and focus.kind == SystemDef.Kind.PLANET:
		var cp := cam.global_position
		var up := (cp - focus.node.global_position).normalized()
		var sun_up := up.dot(sun_dir)
		var alt := _altitude(focus, cp)
		var h := 20000.0
		if focus.atmo:
			h = focus.atmo.get_top_radius() - focus.radius
		var inside := 1.0 - smoothstep(0.15 * h, 1.0 * h, alt)
		var night := 1.0 - smoothstep(-0.18, 0.06, sun_up)
		var day_surface := exposure_day_surface if focus.atmo else exposure_space
		target = lerpf(exposure_space, lerpf(day_surface, exposure_night_surface, night), inside)
		if focus.atmo:
			var day := smoothstep(-0.12, 0.12, sun_up)
			var dense := 1.0 - smoothstep(0.05 * h, 0.6 * h, alt)
			sky = lerpf(1.0, sky_day_energy, day * dense)
	if not auto_exposure:
		target = exposure_space
	var a := 1.0 if _snap or Capture.active else 1.0 - exp(-dt * adapt_speed)
	_exposure = lerpf(_exposure, target, a)
	_sky_energy = lerpf(_sky_energy, sky, a)
	environment.tonemap_exposure = _exposure
	environment.background_energy_multiplier = _sky_energy


## Uses `env` for exposure / glow settings (the SpaceSky WorldEnvironment's Environment).
func set_environment(env: Environment) -> void:
	environment = env
	if env:
		env.glow_hdr_threshold = glow_threshold
