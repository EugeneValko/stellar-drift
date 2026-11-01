class_name LayerParams
extends RefCounted
## Helpers shared by planet layer components (atmosphere, clouds, ocean, gas giant, rings).
## Components accept their parameters as a Dictionary or any Object/Resource exposing
## properties with the same names (e.g. a PlanetConfig resource).

## Render priorities inside the transparent pass (higher = drawn later / on top).
## A planet manager can shift a whole planet with `render_priority_base` to order planets.
const PRIO_OCEAN := -10
const PRIO_ATMO_T := -9
const PRIO_ATMO_S := -8
const PRIO_CLOUDS := -7
const PRIO_RINGS := -6


## Reads `key` from a Dictionary / Object (Resource) with fallback.
static func get_param(cfg: Variant, key: String, default: Variant) -> Variant:
	if cfg == null:
		return default
	if cfg is Dictionary:
		return cfg.get(key, default)
	if cfg is Object:
		var v: Variant = (cfg as Object).get(key)
		return default if v == null else v
	return default


## Flattens cfg into a Dictionary (Resource properties included) for merging.
static func to_dict(cfg: Variant) -> Dictionary:
	if cfg == null:
		return {}
	if cfg is Dictionary:
		return (cfg as Dictionary).duplicate()
	var out := {}
	if cfg is Object:
		for prop in (cfg as Object).get_property_list():
			if int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				out[prop["name"]] = (cfg as Object).get(prop["name"])
	return out


static func merged(base: Dictionary, over: Variant) -> Dictionary:
	var d := base.duplicate(true)
	var o := to_dict(over)
	for k in o:
		d[k] = o[k]
	return d


static func col3(c: Variant) -> Vector3:
	if c is Color:
		return Vector3(c.r, c.g, c.b)
	if c is Vector3:
		return c
	return Vector3.ONE


static func apply_uniforms(mat: ShaderMaterial, uniforms: Dictionary) -> void:
	for k in uniforms:
		mat.set_shader_parameter(k, uniforms[k])


## Back-face proxy sphere used by full-screen-capable planet layers.
static func make_proxy_sphere(radius: float, segments: int = 96) -> SphereMesh:
	var m := SphereMesh.new()
	# Inflate so the polygonal sphere fully contains the analytic one.
	m.radius = radius * 1.03
	m.height = radius * 2.06
	m.radial_segments = segments
	m.rings = segments / 2
	return m
