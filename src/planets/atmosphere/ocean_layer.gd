class_name OceanLayer
extends Node3D
## Planet ocean (analytic sphere at sea level, raytraced on a back-face proxy).
##
##   var ocean := preload("res://scenes/planets/ocean.tscn").instantiate()
##   planet.add_child(ocean)
##   ocean.setup({"radius": 60000.0, "atmosphere": atmo.uniforms, "clouds": clouds})
##
## Parameters (Dictionary or Resource, all optional):
##   radius          sea level radius, m
##   atmosphere      Dictionary of atmo_* uniforms (AtmosphereLayer.uniforms) or an AtmosphereLayer
##   clouds          CloudLayer (or its shadow uniform Dictionary) for cloud shadows on the water
##   scatter_color   Color, deep water body color
##   shallow_tint    Color, shallow water (turquoise) tint
##   absorption      Vector3, 1/m per channel
##   wave_length     longest wave (m), wave_min shortest (m), steepness, base_roughness
##   foam_depth      m, foam_amount, refraction, time_scale
##   quality         0/1/2 -> waves 12/20/28, sky steps 4/5/6
##   render_priority_base

const SHADER := preload("res://shaders/ocean.gdshader")

var params: Dictionary = {}
var mesh_instance: MeshInstance3D
var material: ShaderMaterial


func setup(cfg: Variant = null) -> void:
	params = LayerParams.to_dict(cfg)
	var radius: float = params.get("radius", params.get("sea_level", 60000.0))
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "OceanProxy"
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mesh_instance)
		material = ShaderMaterial.new()
		material.shader = SHADER
		mesh_instance.material_override = material
	mesh_instance.mesh = LayerParams.make_proxy_sphere(radius)
	material.render_priority = LayerParams.PRIO_OCEAN + int(params.get("render_priority_base", 0))
	var q: int = clampi(int(params.get("quality", 1)), 0, 2)
	var u := {
		"ocean_radius": radius,
		"ocean_waves": int(params.get("waves", [12, 20, 28][q])),
		"ocean_sky_steps": int(params.get("sky_steps", [4, 5, 6][q])),
		"cloud_detail_tex": CloudNoise.detail(),
		"cloud_shape_tex": CloudNoise.shape(),
	}
	var map := {
		"scatter_color": "ocean_scatter_color", "shallow_tint": "ocean_shallow_tint",
		"absorption": "ocean_absorption", "turbidity": "ocean_turbidity",
		"wave_length": "ocean_wave_length", "wave_min": "ocean_wave_min",
		"steepness": "ocean_steepness", "base_roughness": "ocean_base_roughness",
		"time_scale": "ocean_time_scale", "foam_depth": "ocean_foam_depth",
		"foam_amount": "ocean_foam_amount", "refraction": "ocean_refraction",
		"sun_spec": "ocean_sun_spec",
	}
	for k in map:
		if params.has(k):
			var v: Variant = params[k]
			u[map[k]] = LayerParams.col3(v) if v is Color else v
	LayerParams.apply_uniforms(material, u)
	set_atmosphere(params.get("atmosphere", null))
	set_clouds(params.get("clouds", null))


## Accepts AtmosphereLayer or its uniforms Dictionary.
func set_atmosphere(a: Variant) -> void:
	if a == null:
		# no atmosphere: zero scattering, sun unattenuated
		LayerParams.apply_uniforms(material, {"atmo_rayleigh": Vector3.ZERO, "atmo_mie": Vector3.ZERO,
			"atmo_mie_absorb": Vector3.ZERO, "atmo_ozone": Vector3.ZERO, "atmo_top_radius": 0.0})
		return
	var u: Dictionary = a.uniforms if a is AtmosphereLayer else a
	LayerParams.apply_uniforms(material, u)


## Accepts CloudLayer or a cloud shadow uniform Dictionary.
func set_clouds(c: Variant) -> void:
	if c == null:
		material.set_shader_parameter("cloud_shadow_strength", 0.0)
		return
	var u: Dictionary = c.get_shadow_uniforms() if c is Object else c
	LayerParams.apply_uniforms(material, u)
