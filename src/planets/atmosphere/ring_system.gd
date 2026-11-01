class_name RingSystem
extends Node3D
## Planetary rings: flat annulus in the parent's local XZ plane (tilt the parent to tilt the
## rings). Procedural bands/gaps, planet shadow, forward scattering when back-lit.
##
## Parameters: planet_radius, inner, outer (m), opacity, seed, brightness, forward_scatter,
## color_a/color_b/color_c (Color), segments, render_priority_base.

const SHADER := preload("res://shaders/rings.gdshader")

var params: Dictionary = {}
var uniforms: Dictionary = {}
var mesh_instance: MeshInstance3D
var material: ShaderMaterial


func setup(cfg: Variant = null) -> void:
	params = LayerParams.to_dict(cfg)
	var pr: float = params.get("planet_radius", 300000.0)
	var inner: float = params.get("inner", pr * 1.3)
	var outer: float = params.get("outer", pr * 2.3)
	uniforms = {
		"ring_inner": inner,
		"ring_outer": outer,
		"ring_seed": float(params.get("seed", 0.0)),
		"ring_opacity": float(params.get("opacity", 1.0)),
	}
	for k in ["color_a", "color_b", "color_c"]:
		if params.has(k):
			uniforms["ring_" + k] = LayerParams.col3(params[k])
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "RingMesh"
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mesh_instance)
		material = ShaderMaterial.new()
		material.shader = SHADER
		mesh_instance.material_override = material
	mesh_instance.mesh = _annulus(inner * 0.995, outer * 1.005, int(params.get("segments", 512)))
	material.render_priority = LayerParams.PRIO_RINGS + int(params.get("render_priority_base", 0))
	LayerParams.apply_uniforms(material, uniforms)
	LayerParams.apply_uniforms(material, {
		"ring_planet_radius": pr,
		"ring_brightness": float(params.get("brightness", 1.0)),
		"ring_forward_scatter": float(params.get("forward_scatter", 1.0)),
	})


## Uniforms for a planet shader that draws the ring shadow (gas_giant.gdshader).
func get_shadow_uniforms() -> Dictionary:
	return uniforms.duplicate()


static func _annulus(r0: float, r1: float, seg: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	# Outer edge chord must not cut into the ring: inflate outer by 1/cos(pi/seg).
	var r1e := r1 / cos(PI / seg)
	for i in seg + 1:
		var a := TAU * i / seg
		var d := Vector3(cos(a), 0.0, sin(a))
		verts.append(d * r0)
		verts.append(d * r1e)
	for i in seg:
		var a0 := i * 2
		idx.append_array([a0, a0 + 1, a0 + 2, a0 + 1, a0 + 3, a0 + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
