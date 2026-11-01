class_name PlaceholderBody
extends Node3D
## TEST-ONLY placeholder terrain (the real quadtree terrain is built by another system).
## A polar grid centred below the camera is projected onto the sphere in
## shaders/debug_placeholder_terrain.gdshader; call `focus(camera_local_pos)` after moving the
## camera. Height is mirrored on the CPU (`height_at`) to place cameras above the ground.

const SHADER := preload("res://shaders/debug_placeholder_terrain.gdshader")
const M32 := 0xFFFFFFFF

@export var radius := 60000.0
@export var style := 0          # 0 earth-like, 1 moon
@export var seed_value := 0.0
@export var feature_scale := 1.0
@export var amp := 1.0
@export var rings := 360
@export var segments := 448

var material: ShaderMaterial
var _mi: MeshInstance3D
var _last_focus := Vector3.INF


func _ready() -> void:
	if material == null:
		_init_material()


func _init_material() -> void:
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("dt_radius", radius)
	material.set_shader_parameter("dt_style", style)
	material.set_shader_parameter("dt_seed", seed_value)
	material.set_shader_parameter("dt_scale", feature_scale)
	material.set_shader_parameter("dt_amp", amp)
	_mi = MeshInstance3D.new()
	_mi.name = "Grid"
	_mi.material_override = material
	_mi.custom_aabb = AABB(Vector3.ONE * -radius * 1.2, Vector3.ONE * radius * 2.4)
	add_child(_mi)


## Rebuilds the grid around the sub-camera point. cam_local: camera in this node's space.
func focus(cam_local: Vector3) -> void:
	if material == null:
		_init_material()
	if cam_local.distance_to(_last_focus) < 1.0:
		return
	_last_focus = cam_local
	var up := cam_local.normalized()
	var t1 := (Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).cross(up).normalized()
	var t2 := up.cross(t1)
	material.set_shader_parameter("grid_up", up)
	material.set_shader_parameter("grid_t1", t1)
	material.set_shader_parameter("grid_t2", t2)
	var alt := maxf(cam_local.length() - radius, 2.0)
	var hmax := 5000.0 * amp
	var rmin := radius - 3000.0 * amp
	var th_max := minf(PI, acos(clampf(rmin / (radius + alt), -1.0, 1.0)) + acos(rmin / (radius + hmax)))
	var d0 := clampf(alt * 0.02, 2.0, 3000.0) / radius
	# geometric ring spacing: d0 * (q^n - 1) / (q - 1) = th_max
	var lo := 1.0000001
	var hi := 2.0
	for _i in 60:
		var q := (lo + hi) * 0.5
		var s := d0 * (pow(q, rings) - 1.0) / (q - 1.0)
		if s > th_max:
			hi = q
		else:
			lo = q
	var qq := (lo + hi) * 0.5
	if d0 * rings >= th_max:
		qq = 1.0
	var verts := PackedVector3Array()
	verts.resize((rings + 1) * (segments + 1))
	var k := 0
	for i in rings + 1:
		var th := (d0 * i) if qq == 1.0 else d0 * (pow(qq, i) - 1.0) / (qq - 1.0)
		th = minf(th, th_max)
		for j in segments + 1:
			verts[k] = Vector3(th, TAU * j / segments, 0.0)
			k += 1
	var idx := PackedInt32Array()
	idx.resize(rings * segments * 6)
	k = 0
	var w := segments + 1
	for i in rings:
		for j in segments:
			var a := i * w + j
			var b := a + 1
			var c := a + w
			var d := c + 1
			idx[k] = a; idx[k + 1] = b; idx[k + 2] = c
			idx[k + 3] = b; idx[k + 4] = d; idx[k + 5] = c
			k += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mi.mesh = mesh


# --- CPU mirror of debug_terrain_noise.gdshaderinc (value only) ------------------------------

static func _hash(ix: int, iy: int, iz: int) -> int:
	var x := ((ix & M32) * 1664525 + 1013904223) & M32
	var y := ((iy & M32) * 1664525 + 1013904223) & M32
	var z := ((iz & M32) * 1664525 + 1013904223) & M32
	x = (x + y * z) & M32
	y = (y + z * x) & M32
	z = (z + x * y) & M32
	x ^= x >> 16
	y ^= y >> 16
	z ^= z >> 16
	x = (x + y * z) & M32
	y = (y + z * x) & M32
	z = (z + x * y) & M32
	return x ^ y ^ z


static func _h(ix: int, iy: int, iz: int) -> float:
	return float(_hash(ix, iy, iz) & 16777215) / 16777215.0


static func _noise(p: Vector3) -> float:
	var fi := p.floor()
	var f := p - fi
	var ix := int(fi.x)
	var iy := int(fi.y)
	var iz := int(fi.z)
	var u := f * f * f * (f * (f * 6.0 - Vector3.ONE * 15.0) + Vector3.ONE * 10.0)
	var a := _h(ix, iy, iz)
	var b := _h(ix + 1, iy, iz)
	var c := _h(ix, iy + 1, iz)
	var d := _h(ix + 1, iy + 1, iz)
	var e := _h(ix, iy, iz + 1)
	var ff := _h(ix + 1, iy, iz + 1)
	var g := _h(ix, iy + 1, iz + 1)
	var h := _h(ix + 1, iy + 1, iz + 1)
	var k1 := b - a
	var k2 := c - a
	var k3 := e - a
	var k4 := a - b - c + d
	var k5 := a - c - e + g
	var k6 := a - b - e + ff
	var k7 := -a + b + c - d + e - ff - g + h
	var v := a + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z
	return v * 2.0 - 1.0


static func _fbm(x: Vector3, octaves: int) -> float:
	var s := 0.0
	var amp_ := 0.5
	var fr := 1.0
	var norm := 0.0
	for o in octaves:
		s += amp_ * _noise(x * fr + Vector3(o * 17.13, o * -9.71, o * 5.37))
		norm += amp_
		amp_ *= 0.5
		fr *= 2.03
	return s / norm


static func _ridged(x: Vector3, octaves: int) -> float:
	var s := 0.0
	var amp_ := 0.5
	var fr := 1.0
	var norm := 0.0
	var w := 1.0
	for o in octaves:
		var n := _noise(x * fr + Vector3(o * 31.7, o * 11.3, o * -7.9))
		var r := 1.0 - absf(n)
		var v := r * r
		s += amp_ * v * w
		norm += amp_
		w = clampf(0.35 + v, 0.0, 1.0)
		amp_ *= 0.5
		fr *= 2.1
	return s / norm


## Terrain height (m above radius) at planet-local unit direction.
func height_at(dir: Vector3, detail: int = 3) -> float:
	var q := dir.normalized() * radius / feature_scale + Vector3.ONE * seed_value * 1000.0
	var c := _fbm(q / 22000.0, 5)
	var land := c * 1.7 - 0.06
	var hgt := land * (900.0 if style == 1 else 2000.0)
	var r := _ridged(q / 7000.0, 4 + detail)
	var reg := _noise(q / 30000.0 + Vector3(5.2, 1.3, 7.7))
	var mk := smoothstep(0.03, 0.4, land + reg * 0.25)
	var mamp := 3400.0
	if style == 1:
		mk = 0.6
		mamp = 1200.0
	hgt += mk * r * mamp
	var hl := _fbm(q / 1300.0, 2 + detail)
	var lm := 1.0 if style == 1 else smoothstep(-0.02, 0.08, land)
	hgt += hl * 140.0 * lm
	return hgt * amp
