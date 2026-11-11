extends Node3D
## Look-dev scene for the game-ready ST-7 Tern (assets/models/tern/tern_lod*.gltf).
## Capture presets (tools/shot.ps1 scenes/test/tern_test.tscn out.png --cam=<preset>):
##   hero, rear, top, cockpit, engines, belly  - LOD0 at hero / close-up distances
##   lod1, lod2                                 - that LOD alone at the distance it is meant for
##   lods                                       - LOD0 / LOD1 / LOD2 side by side (left to right)
## Model axes (glTF): +X starboard, +Y up, -Z nose; landing pads on y = -2.6.

@onready var cam: Camera3D = $Camera3D
@onready var key: DirectionalLight3D = $Key
@onready var fill: DirectionalLight3D = $Fill
@onready var lods: Array[Node3D] = [$LOD0, $LOD1, $LOD2]

const CENTER := Vector3(0.0, 0.0, 0.0)


func _ready() -> void:
	add_to_group("capture_target")
	var cap := get_node_or_null("/root/Capture")
	var preset := "hero"
	if cap != null and String(cap.call("get_preset")) != "":
		preset = String(cap.call("get_preset"))
	apply_capture_preset(preset)


func _show(which: Array, spread: float = 0.0) -> void:
	for i in lods.size():
		lods[i].visible = which.has(i)
		lods[i].position = Vector3((i - 1) * spread, 0.0, 0.0) if spread > 0.0 else Vector3.ZERO


## Camera on `dir` (target -> eye, ship axes converted to glTF) at `dist` metres from `at`.
func _look(at: Vector3, dir: Vector3, dist: float, fov: float) -> void:
	cam.position = at + dir.normalized() * dist
	cam.look_at(at, Vector3.UP)
	cam.fov = fov


func _light(n: DirectionalLight3D, dir: Vector3, energy: float, color: Color) -> void:
	n.basis = Basis.looking_at(dir.normalized(), Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.FORWARD)
	n.light_energy = energy
	n.light_color = color


func apply_capture_preset(preset: String) -> void:
	var warm := Color(1.0, 0.95, 0.88)
	var cool := Color(0.62, 0.74, 1.0)
	_light(key, Vector3(-0.55, -0.62, -0.45), 2.4, warm)
	_light(fill, Vector3(0.6, -0.25, 0.75), 0.55, cool)
	_show([0])
	match preset:
		"rear":
			_look(CENTER, Vector3(0.78, 0.36, 1.0), 23.0, 38.0)
			_light(key, Vector3(-0.35, -0.7, 0.6), 2.4, warm)
			_light(fill, Vector3(0.7, -0.2, -0.7), 0.6, cool)
		"top":
			_look(CENTER, Vector3(0.0, 1.0, 0.02), 30.0, 38.0)
		"belly":
			_look(CENTER + Vector3(0, -0.6, 0), Vector3(0.55, -0.45, -0.75), 19.0, 38.0)
			_light(fill, Vector3(0.3, 0.8, -0.4), 0.8, cool)
		"cockpit":
			_look(Vector3(1.0, 0.35, -4.4), Vector3(0.95, 0.22, -0.80), 6.2, 38.0)
		"engines":
			_look(Vector3(0.0, 0.4, 6.3), Vector3(0.50, 0.22, 1.0), 9.0, 38.0)
			_light(key, Vector3(-0.35, -0.7, 0.6), 2.4, warm)
			_light(fill, Vector3(0.7, -0.2, -0.7), 0.6, cool)
		"lod1":
			_show([1])
			_look(CENTER, Vector3(0.86, 0.25, -1.0), 45.0, 38.0)
		"lod2":
			_show([2])
			_look(CENTER, Vector3(0.86, 0.25, -1.0), 100.0, 38.0)
		"lods":
			_show([0, 1, 2], 17.0)
			_look(CENTER, Vector3(0.0, 0.32, -1.0), 44.0, 38.0)
		_:
			_look(CENTER, Vector3(0.86, 0.14, -1.0), 22.0, 38.0)
