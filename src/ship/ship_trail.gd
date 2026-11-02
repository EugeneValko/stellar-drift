class_name ShipTrail
extends MeshInstance3D
## Camera-facing ribbon trail left in the air by a moving emitter (wingtip vortex condensation).
## Points are stored in world space (they stay in the air where they were emitted), shifted with
## the floating origin; width grows and alpha fades with age. For capture stills (`synthetic`)
## the trail is rebuilt every frame from the current velocity (the ship is frozen but "flying").

const TRAIL_SHADER := preload("res://shaders/ship_trail.gdshader")

@export var lifetime := 1.3
@export var width0 := 0.25
@export var width1 := 1.6
@export var min_step := 0.6          ## m between stored points
@export var max_points := 160

var emitter: Node3D
## 0..1 emission strength (alpha of new points).
var intensity := 0.0
## Synthetic trail (stills): world velocity of the emitter.
var synthetic := false
var synthetic_vel := Vector3.ZERO

var _pts: Array[Dictionary] = []     # {p: Vector3, t: float, a: float}
var _time := 0.0
var _im: ImmediateMesh
var _mat: ShaderMaterial


func _ready() -> void:
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_im = ImmediateMesh.new()
	mesh = _im
	_mat = ShaderMaterial.new()
	_mat.shader = TRAIL_SHADER
	_mat.render_priority = 1
	extra_cull_margin = 4000.0
	global_transform = Transform3D.IDENTITY
	Universe.origin_shifted.connect(func(d: Vector3) -> void:
		for q in _pts:
			q["p"] = (q["p"] as Vector3) - d)


func set_opacity(o: float) -> void:
	_mat.set_shader_parameter("opacity", o)


func clear_trail() -> void:
	_pts.clear()
	_im.clear_surfaces()


func _process(dt: float) -> void:
	_time += dt
	global_transform = Transform3D.IDENTITY
	if emitter == null or not is_instance_valid(emitter):
		return
	var ep := emitter.global_position
	if synthetic:
		_pts.clear()
		if intensity > 0.01 and synthetic_vel.length() > 1.0:
			var n := 40
			for i in n:
				var age := lifetime * float(i) / float(n - 1)
				_pts.push_front({"p": ep - synthetic_vel * age, "t": _time - age, "a": intensity})
	else:
		# age out
		while not _pts.is_empty() and _time - float(_pts[0]["t"]) > lifetime:
			_pts.pop_front()
		if intensity > 0.01:
			if _pts.is_empty() or (_pts[-1]["p"] as Vector3).distance_to(ep) > min_step:
				_pts.append({"p": ep, "t": _time, "a": intensity})
				if _pts.size() > max_points:
					_pts.pop_front()
			else:
				_pts[-1]["a"] = intensity
	_rebuild()


func _rebuild() -> void:
	_im.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	if _pts.size() < 2 or cam == null:
		visible = false
		return
	visible = true
	var cp := cam.global_position
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _mat)
	var n := _pts.size()
	var head := emitter.global_position if not synthetic else (_pts[-1]["p"] as Vector3)
	for i in n:
		var q: Dictionary = _pts[i]
		var p: Vector3 = q["p"]
		if i == n - 1 and not synthetic:
			p = head
		var a := clampf(_time - float(q["t"]), 0.0, lifetime) / lifetime
		var prev: Vector3 = (_pts[maxi(i - 1, 0)]["p"] as Vector3)
		var nxt: Vector3 = (_pts[mini(i + 1, n - 1)]["p"] as Vector3) if i < n - 1 else p
		var tang := nxt - prev
		if tang.length_squared() < 1e-8:
			tang = Vector3.FORWARD
		var side := tang.cross(cp - p)
		if side.length_squared() < 1e-8:
			side = tang.cross(Vector3.UP)
		side = side.normalized()
		var w := lerpf(width0, width1, sqrt(a))
		# fade in at the emitter, out with age
		var alpha := float(q["a"]) * pow(1.0 - a, 1.4) * smoothstep(0.0, 0.015, a)
		if i == n - 1:
			alpha = 0.0
		var u := float(q["t"]) * 2.0
		_im.surface_set_color(Color(1, 1, 1, alpha))
		_im.surface_set_uv(Vector2(u, 0.0))
		_im.surface_add_vertex(p - side * w * 0.5)
		_im.surface_set_color(Color(1, 1, 1, alpha))
		_im.surface_set_uv(Vector2(u, 1.0))
		_im.surface_add_vertex(p + side * w * 0.5)
	_im.surface_end()
