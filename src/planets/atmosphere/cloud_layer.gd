class_name CloudLayer
extends Node3D
## Volumetric cloud shell around a planet (procedural weather baked once on the GPU into an
## equirect map, 3D noise shapes, raymarched lighting). Works from orbit, inside and below.
##
##   var clouds := preload("res://scenes/planets/clouds.tscn").instantiate()
##   planet.add_child(clouds)
##   clouds.setup({"radius": 60000.0, "bottom": 2200.0, "top": 5200.0,
##                 "atmosphere": atmo, "ocean_radius": 60000.0})
##   ocean.set_clouds(clouds)          # cloud shadows on the water
##   clouds.apply_shadow_uniforms(terrain_material)   # terrain shadows (shader must include
##                                     # clouds_common.gdshaderinc and call cloud_shadow_m())
##
## Parameters (Dictionary or Resource, all optional):
##   radius            planet radius (m); bottom/top: cloud layer altitudes above it (m)
##   coverage          0..1 global cloud amount
##   density           extinction 1/m at full density (0.01 thin .. 0.06 thick)
##   seed              weather seed (float)
##   cyclones          number of cyclone swirls; cyclone_strength
##   stratus           0..1 share of flat stratus/stratocumulus decks (overcast regions, storm
##                     belts); weather_contrast (>1 = crisper clear vs overcast regions)
##   shape_size        m per shape noise tile; detail_size m per detail tile
##   rot_speed         weather drift around the axis (rad/s); wind_vel Vector3 (m/s) shape drift
##   brightness, ambient, albedo (Color)
##   cirrus_opacity (0 = off), cirrus_altitude (m above top), cirrus_scale   thin high cirrus sheet
##   atmosphere        AtmosphereLayer or its uniforms Dictionary (sun colour + aerial perspective)
##   ocean_radius      rays stop at this sphere (sea level); 0 = off
##   shadow_strength   for receivers (0..1, default 0.75)
##   quality           0/1/2 -> max steps 32/56/96, light steps 3/4/5 (q0: + bilinear weather and
##                     shorter light march beyond 30 km)
##   quad_share        2x2 pixel quads split the raymarch (default true, ~2x cheaper; see clouds.gdshader)
##   weather_resolution  equirect bake width (default 2048)
##   render_priority_base

const SHADER := preload("res://shaders/clouds.gdshader")
const BAKE_SHADER := preload("res://shaders/cloud_weather_bake.gdshader")

var params: Dictionary = {}
var uniforms: Dictionary = {}
var mesh_instance: MeshInstance3D
var material: ShaderMaterial
var weather_viewport: SubViewport
var _bake_mat: ShaderMaterial
var _weather_img: Image
var _weather_ready := false
var _bake_serial := 0
## Materials that got the shadow uniforms through set_atmosphere() (kept in sync on rotation).
var _shadow_receivers: Array[ShaderMaterial] = []


func setup(cfg: Variant = null) -> void:
	params = LayerParams.to_dict(cfg)
	var radius: float = params.get("radius", 60000.0)
	var bottom: float = radius + float(params.get("bottom", 2200.0))
	var top: float = radius + float(params.get("top", 5200.0))
	var q: int = clampi(int(params.get("quality", 1)), 0, 2)
	uniforms = {
		"cloud_shape_tex": CloudNoise.shape(),
		"cloud_detail_tex": CloudNoise.detail(),
		"cloud_bottom": bottom,
		"cloud_top": top,
		"cloud_coverage": float(params.get("coverage", 0.5)),
		"cloud_density": float(params.get("density", 0.03)),
		"cloud_shape_size": float(params.get("shape_size", 14000.0)),
		"cloud_detail_size": float(params.get("detail_size", 2000.0)),
		"cloud_weather_seed": float(params.get("seed", 0.0)),
		"cloud_rot_speed": float(params.get("rot_speed", 0.00002)),
		"cloud_rot_offset": float(params.get("rot_offset", 0.0)),
		"cloud_wind_vel": params.get("wind_vel", Vector3(6.0, 0.0, 3.0)),
		"cloud_cyclones": int(params.get("cyclones", 7)),
		"cloud_cyclone_strength": float(params.get("cyclone_strength", 1.0)),
		"cloud_stratus": float(params.get("stratus", 0.6)),
		"cloud_weather_contrast": float(params.get("weather_contrast", 1.0)),
		"cloud_billow": float(params.get("billow", 0.0)),
	}
	var cirrus_alt: float = float(params.get("cirrus_altitude", 3500.0))
	_ensure_nodes(top + (cirrus_alt if float(params.get("cirrus_opacity", 0.4)) > 0.0 else 0.0))
	_weather_ready = false
	_bake_weather(int(params.get("weather_resolution", 2048)))
	uniforms["cloud_weather_tex"] = weather_viewport.get_texture()
	var render := {
		"cloud_steps": int(params.get("steps", [32, 56, 96][q])),
		"cloud_light_steps": int(params.get("light_steps", [3, 4, 5][q])),
		# performance (docs/reports/perf_gpu.md): 2x2 quad sharing of the march at every level;
		# quality 0 also uses bilinear weather and a shorter light march beyond 30 km
		"cloud_quad_share": bool(params.get("quad_share", true)),
		"cloud_bicubic_distance": float(params.get("bicubic_distance", [30000.0, 1.0e9, 1.0e9][q])),
		"cloud_light_far": float(params.get("light_far", [30000.0, 1.0e9, 1.0e9][q])),
		"cloud_brightness": float(params.get("brightness", 1.0)),
		"cloud_ambient": float(params.get("ambient", 1.0)),
		"cloud_albedo": LayerParams.col3(params.get("albedo", Color.WHITE)),
		"cloud_ocean_radius": float(params.get("ocean_radius", 0.0)),
		"cirrus_opacity": float(params.get("cirrus_opacity", 0.4)),
		"cirrus_altitude": cirrus_alt,
		"cirrus_scale": float(params.get("cirrus_scale", 1.0)),
	}
	LayerParams.apply_uniforms(material, uniforms)
	LayerParams.apply_uniforms(material, render)
	material.render_priority = LayerParams.PRIO_CLOUDS + int(params.get("render_priority_base", 0))
	set_atmosphere(params.get("atmosphere", null))


func _ensure_nodes(top: float) -> void:
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "CloudShell"
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mesh_instance)
		material = ShaderMaterial.new()
		material.shader = SHADER
		mesh_instance.material_override = material
	mesh_instance.mesh = LayerParams.make_proxy_sphere(top)


## Renders the procedural weather (expensive cyclone/warp fbm) once into an equirect texture.
func _bake_weather(width: int) -> void:
	if weather_viewport == null:
		weather_viewport = SubViewport.new()
		weather_viewport.name = "WeatherBake"
		weather_viewport.disable_3d = true
		weather_viewport.transparent_bg = false
		weather_viewport.use_hdr_2d = true   # 16-bit float: 8-bit coverage creates contour streaks
		weather_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		add_child(weather_viewport)
		var rect := ColorRect.new()
		_bake_mat = ShaderMaterial.new()
		_bake_mat.shader = BAKE_SHADER
		rect.material = _bake_mat
		weather_viewport.add_child(rect)
	weather_viewport.size = Vector2i(width, width / 2)
	var rect2: ColorRect = weather_viewport.get_child(0)
	rect2.size = Vector2(width, width / 2)
	LayerParams.apply_uniforms(_bake_mat, uniforms)
	weather_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_baked()


## weather_at() becomes valid once the bake has actually been drawn.
func _mark_baked() -> void:
	_bake_serial += 1
	var serial := _bake_serial
	_weather_img = null
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if serial == _bake_serial:
		_weather_ready = true


## Re-bakes the weather map (e.g. after changing coverage/seed, or periodically for evolution).
func rebake() -> void:
	_weather_ready = false
	LayerParams.apply_uniforms(_bake_mat, uniforms)
	weather_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_mark_baked()


## CPU readback of the baked weather (R = coverage, G = type) at a planet-local direction.
## Slow the first time (GPU -> CPU copy); for tools / capture site selection, not per frame.
## Returns Vector2(-1, -1) until the bake has been rendered.
func weather_at(dir_local: Vector3) -> Vector2:
	if not _weather_ready:
		return Vector2(-1, -1)
	if _weather_img == null:
		var tex := weather_viewport.get_texture()
		if tex == null:
			return Vector2(-1, -1)
		_weather_img = tex.get_image()
		if _weather_img == null or _weather_img.is_empty():
			_weather_img = null
			return Vector2(-1, -1)
	var d := dir_local.normalized()
	var a: float = uniforms.get("cloud_rot_offset", 0.0)
	d = Vector3(cos(a) * d.x - sin(a) * d.z, d.y, sin(a) * d.x + cos(a) * d.z)
	var u := atan2(d.z, d.x) / TAU + 0.5
	var v := acos(clampf(d.y, -1.0, 1.0)) / PI
	var w := _weather_img.get_width()
	var h := _weather_img.get_height()
	var c := _weather_img.get_pixel(clampi(int(u * w), 0, w - 1), clampi(int(v * h), 0, h - 1))
	return Vector2(c.r, c.g)


## Rotates the whole weather map around the planet axis (radians) on the cloud material and
## on shadow receivers (terrain / ocean materials that use cloud_shadow_*()).
func set_rotation_offset(a: float, receivers: Array = []) -> void:
	uniforms["cloud_rot_offset"] = a
	params["rot_offset"] = a
	material.set_shader_parameter("cloud_rot_offset", a)
	for m: ShaderMaterial in receivers:
		m.set_shader_parameter("cloud_rot_offset", a)
	for m: ShaderMaterial in _shadow_receivers:
		m.set_shader_parameter("cloud_rot_offset", a)


func set_atmosphere(a: Variant) -> void:
	if a == null:
		LayerParams.apply_uniforms(material, {"atmo_rayleigh": Vector3.ZERO, "atmo_mie": Vector3.ZERO,
			"atmo_mie_absorb": Vector3.ZERO, "atmo_ozone": Vector3.ZERO, "atmo_top_radius": 0.0})
		return
	var u: Dictionary = a.uniforms if a is AtmosphereLayer else a
	LayerParams.apply_uniforms(material, u)
	# wave 4: cloud shadows inside the atmosphere's in-scattering (crepuscular rays)
	if a is AtmosphereLayer and (a as AtmosphereLayer).mat_scatter:
		var m: ShaderMaterial = (a as AtmosphereLayer).mat_scatter
		var su := get_shadow_uniforms()
		su["cloud_shadow_strength"] = float(params.get("air_shadow_strength", 0.7))
		LayerParams.apply_uniforms(m, su)
		if not _shadow_receivers.has(m):
			_shadow_receivers.append(m)


## Uniforms a receiver shader (including clouds_common.gdshaderinc) needs for cloud_shadow_*().
func get_shadow_uniforms() -> Dictionary:
	var u := uniforms.duplicate()
	u["cloud_shadow_strength"] = float(params.get("shadow_strength", 0.75))
	return u


func apply_shadow_uniforms(mat: ShaderMaterial) -> void:
	LayerParams.apply_uniforms(mat, get_shadow_uniforms())


func set_quality(q: int) -> void:
	params["quality"] = q
	params.erase("steps")
	params.erase("light_steps")
	setup(params)
