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
##   shape_size        m per shape noise tile; detail_size m per detail tile
##   rot_speed         weather drift around the axis (rad/s); wind_vel Vector3 (m/s) shape drift
##   brightness, ambient, albedo (Color)
##   atmosphere        AtmosphereLayer or its uniforms Dictionary (sun colour + aerial perspective)
##   ocean_radius      rays stop at this sphere (sea level); 0 = off
##   shadow_strength   for receivers (0..1, default 0.75)
##   quality           0/1/2 -> steps 24/40/64, light steps 3/4/5
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
		"cloud_shape_size": float(params.get("shape_size", 8000.0)),
		"cloud_detail_size": float(params.get("detail_size", 1300.0)),
		"cloud_weather_seed": float(params.get("seed", 0.0)),
		"cloud_rot_speed": float(params.get("rot_speed", 0.00002)),
		"cloud_wind_vel": params.get("wind_vel", Vector3(6.0, 0.0, 3.0)),
		"cloud_cyclones": int(params.get("cyclones", 7)),
		"cloud_cyclone_strength": float(params.get("cyclone_strength", 1.0)),
	}
	_ensure_nodes(top)
	_bake_weather(int(params.get("weather_resolution", 2048)))
	uniforms["cloud_weather_tex"] = weather_viewport.get_texture()
	var render := {
		"cloud_steps": int(params.get("steps", [24, 40, 64][q])),
		"cloud_light_steps": int(params.get("light_steps", [3, 4, 5][q])),
		"cloud_brightness": float(params.get("brightness", 1.0)),
		"cloud_ambient": float(params.get("ambient", 1.0)),
		"cloud_albedo": LayerParams.col3(params.get("albedo", Color.WHITE)),
		"cloud_ocean_radius": float(params.get("ocean_radius", 0.0)),
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


## Re-bakes the weather map (e.g. after changing coverage/seed, or periodically for evolution).
func rebake() -> void:
	LayerParams.apply_uniforms(_bake_mat, uniforms)
	weather_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func set_atmosphere(a: Variant) -> void:
	if a == null:
		LayerParams.apply_uniforms(material, {"atmo_rayleigh": Vector3.ZERO, "atmo_mie": Vector3.ZERO,
			"atmo_mie_absorb": Vector3.ZERO, "atmo_ozone": Vector3.ZERO, "atmo_top_radius": 0.0})
		return
	var u: Dictionary = a.uniforms if a is AtmosphereLayer else a
	LayerParams.apply_uniforms(material, u)


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
