@tool
class_name Star
extends Node3D
## Procedural star (Helios): animated photosphere, corona, prominence loops and a screen-space
## glare overlay (god rays, starburst, lens ghosts) that fades when the disc is occluded or
## off-screen. Children are generated at runtime (not saved into the scene).
##
## For the lighting system: `light_color` (linear, follows `temperature` unless
## `auto_light_color` is off) and `light_energy`. If `sun_light` is set, the star aims it from
## itself toward the active camera every frame (disable `drive_light` to aim it yourself).

const SURFACE_SHADER := preload("res://shaders/star_surface.gdshader")
const CORONA_SHADER := preload("res://shaders/star_corona.gdshader")
const PROMINENCE_SHADER := preload("res://shaders/star_prominence.gdshader")
const FLARE_SHADER := preload("res://shaders/star_flare.gdshader")

@export var radius: float = 400000.0:
	set(v):
		radius = v
		_queue_rebuild()
## Photosphere temperature in kelvin (Helios: white-yellow ~5900 K).
@export_range(2000.0, 40000.0, 50.0) var temperature: float = 5900.0:
	set(v):
		temperature = v
		_update_materials()
## Extra multiplier on the black-body colour.
@export var tint: Color = Color(1, 1, 1):
	set(v):
		tint = v
		_update_materials()
@export var noise_seed: int = 1:
	set(v):
		noise_seed = v
		_queue_rebuild()

@export_group("Surface")
## HDR brightness of the disc centre (tonemapped by AgX, bloom threshold 1.0).
@export var surface_intensity: float = 9.0:
	set(v):
		surface_intensity = v
		_update_materials()
@export var granule_scale: float = 140.0:
	set(v):
		granule_scale = v
		_update_materials()
@export_range(0.0, 1.0) var spot_amount: float = 0.55:
	set(v):
		spot_amount = v
		_update_materials()
## "Eye adaptation" on the star only: when the disc grows large on screen its brightness is
## scaled toward `close_intensity_scale`, so surface detail stays readable up close while the
## distant star still blows out into a dazzling bloom. Angular radius range in radians.
@export var close_intensity_scale: float = 0.16
@export var adapt_radius_range: Vector2 = Vector2(0.03, 0.22)
## Mesh resolution (radial segments). 128 keeps the silhouette smooth at 600 km.
@export var sphere_segments: int = 160

@export_group("Corona")
@export var corona_intensity: float = 1.0:
	set(v):
		corona_intensity = v
		_update_materials()
@export var corona_extent: float = 7.0:
	set(v):
		corona_extent = v
		_update_materials()

@export_group("Prominences")
@export var prominence_count: int = 22:
	set(v):
		prominence_count = v
		_queue_rebuild()
@export var prominence_intensity: float = 7.0:
	set(v):
		prominence_intensity = v
		_update_materials()

@export_group("Glare")
@export var flare_enabled: bool = true
@export_range(0.0, 4.0) var flare_intensity: float = 1.0
## Ray-march samples of the screen-space god rays (quality knob: 24 low / 40 med / 64 high).
@export_range(8, 128) var flare_ray_samples: int = 40
@export var flare_layer: int = -10

@export_group("Light")
@export var auto_light_color: bool = true
@export var light_color: Color = Color(1.0, 0.95, 0.88)
@export var light_energy: float = 1.6
@export var sun_light: DirectionalLight3D
@export var drive_light: bool = true

@export_group("Scaled space")
## If > 0 and the camera is farther than this, the visual (disc, corona, prominences) is drawn at
## this distance along the same line of sight, scaled down to keep the exact angular size.
## Keeps the star inside a short camera far plane (Godot needs far/near <= ~1e7).
@export var max_render_distance: float = 0.0

@export_group("Animation")
@export var time_scale: float = 1.0:
	set(v):
		time_scale = v
		_update_materials()

var surface_material: ShaderMaterial
var corona_material: ShaderMaterial
var prominence_material: ShaderMaterial
var flare_material: ShaderMaterial

var _visual: Node3D
var _surface: MeshInstance3D
var _corona: MeshInstance3D
var _prominences: MeshInstance3D
var _flare_layer: CanvasLayer
var _flare_rect: ColorRect
var _built := false
var _rebuild_queued := false


func _ready() -> void:
	_build()


func _queue_rebuild() -> void:
	if not is_inside_tree() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_rebuild_queued = false
	_build()


## Linear-space colour of the photosphere (black-body * tint, max channel 1).
func get_star_color() -> Color:
	var c := Star.blackbody(temperature)
	return Color(c.r * tint.r, c.g * tint.g, c.b * tint.b)


func _build() -> void:
	for c in [_visual, _flare_layer]:
		if c:
			c.queue_free()
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)
	_surface = null
	_corona = null
	_prominences = null
	_flare_layer = null

	surface_material = ShaderMaterial.new()
	surface_material.shader = SURFACE_SHADER
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = sphere_segments
	sphere.rings = sphere_segments / 2
	_surface = MeshInstance3D.new()
	_surface.name = "Surface"
	_surface.mesh = sphere
	_surface.material_override = surface_material
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(_surface)

	corona_material = ShaderMaterial.new()
	corona_material.shader = CORONA_SHADER
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_corona = MeshInstance3D.new()
	_corona.name = "Corona"
	_corona.mesh = quad
	_corona.material_override = corona_material
	_corona.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var e := radius * corona_extent
	_corona.custom_aabb = AABB(Vector3(-e, -e, -e), Vector3(e, e, e) * 2.0)
	_visual.add_child(_corona)

	prominence_material = ShaderMaterial.new()
	prominence_material.shader = PROMINENCE_SHADER
	if prominence_count > 0:
		_prominences = MeshInstance3D.new()
		_prominences.name = "Prominences"
		_prominences.mesh = _build_prominence_mesh()
		_prominences.material_override = prominence_material
		_prominences.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_visual.add_child(_prominences)

	if not Engine.is_editor_hint():
		flare_material = ShaderMaterial.new()
		flare_material.shader = FLARE_SHADER
		_flare_layer = CanvasLayer.new()
		_flare_layer.name = "Glare"
		_flare_layer.layer = flare_layer
		_flare_rect = ColorRect.new()
		_flare_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_flare_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_flare_rect.material = flare_material
		_flare_layer.add_child(_flare_rect)
		add_child(_flare_layer)
	_built = true
	_update_materials()


func _update_materials() -> void:
	if not _built:
		return
	var c := get_star_color()
	var cv := Vector3(c.r, c.g, c.b)
	if auto_light_color:
		light_color = c
	surface_material.set_shader_parameter("star_color", cv)
	surface_material.set_shader_parameter("intensity", surface_intensity)
	surface_material.set_shader_parameter("granule_scale", granule_scale)
	surface_material.set_shader_parameter("spot_amount", spot_amount)
	surface_material.set_shader_parameter("seed", noise_seed)
	surface_material.set_shader_parameter("time_scale", time_scale)
	corona_material.set_shader_parameter("star_color", cv)
	corona_material.set_shader_parameter("star_radius", radius)
	corona_material.set_shader_parameter("extent", corona_extent)
	corona_material.set_shader_parameter("intensity", corona_intensity)
	corona_material.set_shader_parameter("seed", noise_seed)
	corona_material.set_shader_parameter("time_scale", time_scale)
	prominence_material.set_shader_parameter("intensity", prominence_intensity)
	prominence_material.set_shader_parameter("star_radius", radius)
	prominence_material.set_shader_parameter("time_scale", time_scale)
	if flare_material:
		flare_material.set_shader_parameter("tint", Vector3(lerpf(1.0, c.r, 0.6), lerpf(1.0, c.g, 0.6), lerpf(1.0, c.b, 0.6)))
		flare_material.set_shader_parameter("ray_samples", flare_ray_samples)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or not _built:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	if sun_light and drive_light:
		var dir := (cam.global_position - global_position).normalized()
		if dir.length_squared() > 0.5:
			var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
			sun_light.global_basis = Basis.looking_at(dir, up)
		sun_light.light_color = light_color
		sun_light.light_energy = light_energy
	_update_scaled_space(cam)
	_update_adaptation(cam)
	_update_flare(cam)


## Current apparent angular radius of the disc (radians) for `cam`.
func get_angular_radius(cam: Camera3D) -> float:
	var dist := cam.global_position.distance_to(global_position)
	return asin(clampf(radius / maxf(dist, radius * 1.0001), 0.0, 1.0))


func _update_adaptation(cam: Camera3D) -> void:
	var t := smoothstep(adapt_radius_range.x, adapt_radius_range.y, get_angular_radius(cam))
	var k := lerpf(1.0, close_intensity_scale, t)
	surface_material.set_shader_parameter("intensity", surface_intensity * k)
	corona_material.set_shader_parameter("intensity", corona_intensity * lerpf(1.0, close_intensity_scale * 1.6, t))
	prominence_material.set_shader_parameter("intensity", prominence_intensity * lerpf(1.0, close_intensity_scale * 2.0, t))


func _update_scaled_space(cam: Camera3D) -> void:
	var k := 1.0
	var cp := cam.global_position
	var d := cp.distance_to(global_position)
	if max_render_distance > 0.0 and d > max_render_distance:
		k = max_render_distance / d
	if k < 1.0:
		_visual.global_position = cp + (global_position - cp) * k
		_visual.scale = Vector3.ONE * k
	elif _visual.scale != Vector3.ONE:
		_visual.position = Vector3.ZERO
		_visual.scale = Vector3.ONE
	corona_material.set_shader_parameter("star_radius", radius * k)


func _update_flare(cam: Camera3D) -> void:
	if flare_material == null:
		return
	_flare_layer.visible = flare_enabled
	if not flare_enabled:
		return
	var vp_size := get_viewport().get_visible_rect().size
	var p := global_position
	var behind := cam.is_position_behind(p)
	var dist := cam.global_position.distance_to(p)
	var uv := Vector2(0.5, 0.5)
	if not behind:
		uv = cam.unproject_position(p) / vp_size
	var ang := asin(clampf(radius / maxf(dist, radius * 1.0001), 0.0, 1.0))
	var half_fov := deg_to_rad(cam.fov) * 0.5
	var r_px := tan(ang) / tan(half_fov) * vp_size.y * 0.5
	flare_material.set_shader_parameter("star_uv", uv)
	flare_material.set_shader_parameter("star_radius_px", r_px)
	flare_material.set_shader_parameter("in_front", 0.0 if behind else 1.0)
	flare_material.set_shader_parameter("intensity", flare_intensity)
	flare_material.set_shader_parameter("time", Time.get_ticks_msec() * 0.001 * time_scale)


func _build_prominence_mesh() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(noise_seed * 7919 + 13)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var segs := 40
	var sides := 8
	for i in prominence_count:
		# footpoint centre in the active latitudes
		var lat := deg_to_rad(rng.randf_range(8.0, 50.0)) * (1.0 if rng.randf() < 0.5 else -1.0)
		var lon := rng.randf_range(0.0, TAU)
		var c := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
		var t0 := c.cross(Vector3.UP if absf(c.y) < 0.95 else Vector3.RIGHT).normalized()
		var tdir := t0.rotated(c, rng.randf_range(0.0, TAU))
		var half := rng.randf_range(0.05, 0.16)
		var height := radius * rng.randf_range(0.10, 0.34)
		var axis := c.cross(tdir).normalized()
		var a := c.rotated(axis, -half)
		var b := c.rotated(axis, half)
		var lean := rng.randf_range(-0.5, 0.5)
		var strands := 5
		var twist := rng.randf_range(3.0, 9.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		for k in strands:
			var hk := height * rng.randf_range(0.85, 1.12)
			var wk := radius * rng.randf_range(0.012, 0.03)
			var rope := Vector3(radius * rng.randf_range(0.006, 0.026), TAU * float(k) / strands + rng.randf_range(-0.4, 0.4), twist)
			var id := float(i * strands + k) + 0.37
			_add_arc(verts, norms, uvs, uv2s, idx, a, b, axis, hk, wk, lean, rope, id, segs, sides)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _arc_point(a: Vector3, b: Vector3, axis: Vector3, s: float, h: float, lean: float) -> Vector3:
	var dir := a.slerp(b, s).normalized()
	var lift := pow(sin(PI * s), 0.85)
	var p := dir * (radius * 0.995 + h * lift)
	p += axis * (h * lift * lean)
	return p


func _add_arc(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array,
		uv2s: PackedVector2Array, idx: PackedInt32Array, a: Vector3, b: Vector3, axis: Vector3,
		h: float, w: float, lean: float, rope: Vector3, id: float, segs: int, sides: int) -> void:
	# rope = (strand distance from the loop axis, start angle, twist in radians along the loop)
	var base := verts.size()
	for si in segs + 1:
		var s := float(si) / segs
		var p := _arc_point(a, b, axis, s, h, lean)
		var p2 := _arc_point(a, b, axis, minf(s + 0.01, 1.0), h, lean)
		var p1 := _arc_point(a, b, axis, maxf(s - 0.01, 0.0), h, lean)
		var tan := (p2 - p1).normalized()
		var n1 := tan.cross(p.normalized()).normalized()
		var n2 := tan.cross(n1).normalized()
		var phi := rope.y + rope.z * s
		var spread := sin(PI * s) * 0.8 + 0.2
		p += (n1 * cos(phi) + n2 * sin(phi)) * rope.x * spread
		var ww := w * (0.55 + 0.6 * sin(PI * s))
		for j in sides:
			var th := TAU * float(j) / sides
			var nrm := n1 * cos(th) + n2 * sin(th)
			verts.append(p + nrm * ww)
			norms.append(nrm)
			uvs.append(Vector2(s, float(j) / sides))
			uv2s.append(Vector2(id, 0.0))
	for si in segs:
		for j in sides:
			var j2 := (j + 1) % sides
			var i0 := base + si * sides + j
			var i1 := base + si * sides + j2
			var i2 := base + (si + 1) * sides + j
			var i3 := base + (si + 1) * sides + j2
			idx.append_array([i0, i2, i1, i1, i2, i3])


## Approximate black-body colour (Tanner Helland fit), returned in linear space, max channel 1.
static func blackbody(kelvin: float) -> Color:
	var t := clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r: float
	var g: float
	var b: float
	if t <= 66.0:
		r = 1.0
		g = clampf(0.39008158 * log(t) - 0.63184144, 0.0, 1.0)
		b = 0.0 if t <= 19.0 else clampf(0.54320679 * log(t - 10.0) - 1.19625409, 0.0, 1.0)
	else:
		r = clampf(1.29293619 * pow(t - 60.0, -0.1332047592), 0.0, 1.0)
		g = clampf(1.12989086 * pow(t - 60.0, -0.0755148492), 0.0, 1.0)
		b = 1.0
	var c := Color(pow(r, 2.2), pow(g, 2.2), pow(b, 2.2))
	var m := maxf(c.r, maxf(c.g, c.b))
	return Color(c.r / m, c.g / m, c.b / m)
