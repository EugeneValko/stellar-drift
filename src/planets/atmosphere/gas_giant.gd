class_name GasGiantBody
extends Node3D
## Gas giant body (procedural banded surface + storm) with optional atmosphere haze and rings.
##
##   var gg := preload("res://scenes/planets/gas_giant.tscn").instantiate()
##   system.add_child(gg)
##   gg.setup({"radius": 300000.0, "rings": true})
##
## Parameters (Dictionary or Resource, all optional):
##   radius                 m (default 300 km)
##   seed, band_scale, turbulence, flow_speed, brightness
##   col_zone/col_belt/col_mid/col_polar/col_accent/storm_color (Color)
##   storm_dir (Vector3 local), storm_size (Vector2 rad)
##   quality                0/1/2 -> fbm octaves 5/6/8, atmosphere steps 8/12/16
##   atmosphere             true/false or Dictionary for AtmosphereLayer (preset "aurelion")
##   rings                  true/false or Dictionary for RingSystem (inner/outer/opacity/...)
##   ring_tilt_deg          tilt of the rings+planet axis (around local X)
##   render_priority_base

const SHADER := preload("res://shaders/gas_giant.gdshader")
const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")

## Celestial-body interface (Universe): name, gravity, SOI = radius * soi_factor.
@export var body_name := "Aurelion"
@export var surface_gravity := 22.0
@export var soi_factor := 8.0

var params: Dictionary = {}
var body: MeshInstance3D
var material: ShaderMaterial
var atmosphere: AtmosphereLayer
var rings: RingSystem


func _ready() -> void:
	add_to_group("celestial_body")


func setup(cfg: Variant = null) -> void:
	params = LayerParams.to_dict(cfg)
	body_name = String(params.get("name", body_name))
	var radius: float = params.get("radius", 300000.0)
	var q: int = clampi(int(params.get("quality", 1)), 0, 2)
	if body == null:
		body = MeshInstance3D.new()
		body.name = "Body"
		var sm := SphereMesh.new()
		sm.radial_segments = 256
		sm.rings = 128
		body.mesh = sm
		material = ShaderMaterial.new()
		material.shader = SHADER
		body.material_override = material
		add_child(body)
	var sphere: SphereMesh = body.mesh
	sphere.radius = radius
	sphere.height = radius * 2.0
	var u := {"gg_radius": radius, "gg_octaves": [5, 6, 8][q]}
	var map := {"seed": "gg_seed", "band_scale": "gg_band_scale", "turbulence": "gg_turbulence",
		"flow_speed": "gg_flow_speed", "brightness": "gg_brightness", "col_zone": "gg_col_zone",
		"col_belt": "gg_col_belt", "col_mid": "gg_col_mid", "col_polar": "gg_col_polar",
		"col_accent": "gg_col_accent", "storm_color": "gg_storm_color", "storm_dir": "gg_storm_dir",
		"storm_size": "gg_storm_size"}
	for k in map:
		if params.has(k):
			var v: Variant = params[k]
			u[map[k]] = LayerParams.col3(v) if v is Color else v
	LayerParams.apply_uniforms(material, u)
	rotation_degrees.x = float(params.get("ring_tilt_deg", 0.0))

	var a_cfg: Variant = params.get("atmosphere", true)
	if a_cfg is Dictionary or a_cfg == true:
		if atmosphere == null:
			atmosphere = ATMO_SCENE.instantiate()
			add_child(atmosphere)
		var ad := {"preset": "aurelion", "radius": radius, "ground_radius": radius * 0.995,
			"quality": q, "render_priority_base": int(params.get("render_priority_base", 0))}
		if a_cfg is Dictionary:
			ad = LayerParams.merged(ad, a_cfg)
		atmosphere.setup(ad)

	var r_cfg: Variant = params.get("rings", false)
	if r_cfg is Dictionary or r_cfg == true:
		if rings == null:
			rings = RingSystem.new()
			rings.name = "Rings"
			add_child(rings)
		var rd := {"planet_radius": radius, "render_priority_base": int(params.get("render_priority_base", 0))}
		if r_cfg is Dictionary:
			rd = LayerParams.merged(rd, r_cfg)
		rings.setup(rd)
		LayerParams.apply_uniforms(material, rings.get_shadow_uniforms())
		material.set_shader_parameter("gg_ring_shadow", float(params.get("ring_shadow", 0.85)))
	else:
		material.set_shader_parameter("gg_ring_shadow", 0.0)


# --- Celestial body interface for Universe (see src/core/universe.gd) ---

func get_body_name() -> String:
	return body_name


func get_body_radius() -> float:
	return float(params.get("radius", 300000.0))


func get_soi_radius() -> float:
	return get_body_radius() * soi_factor


func get_surface_gravity() -> float:
	return surface_gravity


## Height of the visible haze layer (no solid surface: altitude is above the cloud tops).
func get_atmosphere_height() -> float:
	return atmosphere.get_top_radius() - get_body_radius() if atmosphere else 0.0


func get_altitude_global(world_pos: Vector3) -> float:
	return world_pos.distance_to(global_position) - get_body_radius()
