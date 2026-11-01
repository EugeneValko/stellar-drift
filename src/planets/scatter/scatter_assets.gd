class_name ScatterAssets
extends RefCounted
## Scatter meshes + materials for one planet.
##
## Meshes come from the GLBs built by tools/blender/{flora_terra,rocks,crystals}.py (one node per mesh,
## material slots named after SLOTS). Each planet gets its own ShaderMaterial per slot (palette from the
## PlanetConfig + ScatterRuleSet.material_params), layers may override parameters per slot
## (ScatterLayer.material_overrides) and get their own material copies.

const SLOTS := {
	"bark": ["res://shaders/flora_bark.gdshader", {"style": 0}],
	"bark_palm": ["res://shaders/flora_bark.gdshader", {"style": 1,
		"color_a": Color(0.6, 0.52, 0.42), "color_b": Color(0.33, 0.27, 0.21), "moss_amount": 0.15}],
	"needles": ["res://shaders/flora_leaves.gdshader", {"pattern": 0, "leaflets": 15.0, "slant": 0.9,
		"duty": 0.42, "rachis": 0.03, "envelope_round": 0.0}],
	"leaves": ["res://shaders/flora_leaves.gdshader", {"pattern": 1, "broad_leaves": 6}],
	"frond": ["res://shaders/flora_leaves.gdshader", {"pattern": 0, "leaflets": 20.0, "slant": 1.6,
		"duty": 0.55, "rachis": 0.04, "envelope_round": 1.0}],
	"grass": ["res://shaders/flora_grass.gdshader", {"mode": 0}],
	"flower": ["res://shaders/flora_grass.gdshader", {"mode": 1}],
	"glow": ["res://shaders/flora_grass.gdshader", {"mode": 2}],
	"far_foliage": ["res://shaders/flora_far.gdshader", {}],
	"rock": ["res://shaders/rock_scatter.gdshader", {"style": 0}],
	"basalt": ["res://shaders/rock_scatter.gdshader", {"style": 1, "roughness": 0.8}],
	"crystal": ["res://shaders/crystal_scatter.gdshader", {"mode": 0}],
	"ice": ["res://shaders/crystal_scatter.gdshader", {"mode": 1, "color_body": Color(0.3, 0.55, 0.75),
		"color_rim": Color(0.75, 0.9, 1.0), "color_glow": Color(0.4, 0.75, 1.0), "glow_energy": 0.6,
		"roughness": 0.06}],
}

static var _sources := {}   # glb path -> { node name: Mesh }
static var _shaders := {}

var materials := {}         # slot -> ShaderMaterial
var _variants := {}         # "slot|overrides" -> ShaderMaterial
var _meshes := {}           # "path:node|layer" -> Mesh (materials assigned)


func _init(cfg: PlanetConfig, rules: ScatterRuleSet) -> void:
	var tex := TerrainTextures.get_textures()
	var ground := {
		"color_grass": cfg.color_grass, "color_dry": cfg.color_dry,
		"color_base": cfg.color_forest * 0.55,
		"color_tip_dry": cfg.color_dry.lerp(Color(0.8, 0.72, 0.45), 0.3),
	}
	var rock := {"color_a": cfg.color_rock, "color_b": cfg.color_rock2, "color_snow": cfg.color_snow}
	for slot: String in SLOTS:
		var m := ShaderMaterial.new()
		m.shader = _shader(SLOTS[slot][0])
		m.resource_name = slot
		var params: Dictionary = (SLOTS[slot][1] as Dictionary).duplicate()
		if slot == "grass" or slot == "flower" or slot == "glow":
			params.merge(ground)
		if slot == "rock" or slot == "basalt":
			params.merge(rock)
		params.merge(rules.material_params.get(slot, {}), true)
		for k: String in params:
			m.set_shader_parameter(k, params[k])
		m.set_shader_parameter("tex_noise", tex["noise"])
		m.set_shader_parameter("tex_rock", tex["rock"])
		m.set_shader_parameter("wind_dir", rules.wind_dir)
		m.set_shader_parameter("wind_strength", rules.wind_strength)
		m.set_shader_parameter("wind_speed", rules.wind_speed)
		materials[slot] = m


static func _shader(path: String) -> Shader:
	if not _shaders.has(path):
		_shaders[path] = load(path)
	return _shaders[path]


## All meshes of a GLB by node name (imported once, shared by every planet).
static func source_meshes(path: String) -> Dictionary:
	if not _sources.has(path):
		var out := {}
		var ps: PackedScene = load(path)
		if ps == null:
			push_error("ScatterAssets: cannot load " + path)
		else:
			var root := ps.instantiate()
			for n in root.find_children("*", "MeshInstance3D", true, false):
				out[String(n.name)] = (n as MeshInstance3D).mesh
			root.free()
		_sources[path] = out
	return _sources[path]


func material_for(slot: String, overrides: Dictionary) -> Material:
	var base: ShaderMaterial = materials.get(slot)
	if base == null:
		return null
	var ov: Dictionary = overrides.get(slot, {})
	if ov.is_empty():
		return base
	var key := slot + "|" + str(ov)
	if not _variants.has(key):
		var m := base.duplicate() as ShaderMaterial
		for k: String in ov:
			m.set_shader_parameter(k, ov[k])
		_variants[key] = m
	return _variants[key]


## Copy of a source mesh with this planet's materials (cached per layer override set).
func mesh_for(layer: ScatterLayer, node_name: String) -> Mesh:
	if node_name == "":
		return null
	var key := "%s:%s|%s" % [layer.model, node_name, str(layer.material_overrides)]
	if _meshes.has(key):
		return _meshes[key]
	var src: Mesh = source_meshes(layer.model).get(node_name)
	if src == null:
		push_error("ScatterAssets: mesh %s not found in %s" % [node_name, layer.model])
		return null
	var m := src.duplicate() as Mesh
	for i in m.get_surface_count():
		var sm := src.surface_get_material(i)
		var slot: String = sm.resource_name if sm else m.surface_get_name(i)
		var mat := material_for(slot, layer.material_overrides)
		if mat:
			m.surface_set_material(i, mat)
		else:
			push_warning("ScatterAssets: no material for slot " + slot)
	_meshes[key] = m
	return m


static func triangle_count(m: Mesh) -> int:
	if m == null:
		return 0
	var t := 0
	for i in m.get_surface_count():
		var idx: PackedInt32Array = m.surface_get_arrays(i)[Mesh.ARRAY_INDEX]
		t += idx.size() / 3
	return t
