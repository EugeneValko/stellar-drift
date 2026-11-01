extends Node3D
## Ship look-dev scene controller (scenes/test/ship_test.tscn). Capture presets:
## ship_hero, ship_side, ship_rear, ship_top, ship_landed  (tools/shot.sh ... --cam=<preset>)
## Extra Capture args: --thrust=0..1 overrides engine thrust.

@onready var ship: ShipVisual = $ShipVisual
@onready var cam: Camera3D = $Camera3D
@onready var key: DirectionalLight3D = $Key
@onready var rim: DirectionalLight3D = $Rim
@onready var env: WorldEnvironment = $WorldEnvironment
@onready var ground: Node3D = $Ground
@onready var figure: Node3D = $Figure

var _sky_mat: ShaderMaterial


func _ready() -> void:
	add_to_group("capture_target")
	_sky_mat = env.environment.sky.sky_material as ShaderMaterial
	var cap := get_node_or_null("/root/Capture")
	var preset := "ship_hero"
	if cap != null and String(cap.call("get_preset")) != "":
		preset = String(cap.call("get_preset"))
	apply_capture_preset(preset)


func _look(from: Vector3, at: Vector3, fov: float) -> void:
	cam.position = from
	cam.look_at(at, Vector3.UP)
	cam.fov = fov


func _light(n: DirectionalLight3D, dir: Vector3, energy: float, color: Color) -> void:
	n.basis = Basis.looking_at(dir.normalized(), Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.FORWARD)
	n.light_energy = energy
	n.light_color = color


func _space(on: bool) -> void:
	_sky_mat.set_shader_parameter("mode", 0 if on else 1)
	ground.visible = not on
	figure.visible = not on
	var e := env.environment
	e.ambient_light_energy = 0.55 if on else 0.9
	e.background_energy_multiplier = 1.0


func apply_capture_preset(preset: String) -> void:
	var cap := get_node_or_null("/root/Capture")
	var thrust_override := -1.0
	if cap != null and (cap.get("args") as Dictionary).has("thrust"):
		thrust_override = float((cap.get("args") as Dictionary)["thrust"])
	var warm := Color(1.0, 0.94, 0.86)
	var cool := Color(0.55, 0.7, 1.0)
	match preset:
		"ship_side":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.35)
			_look(Vector3(-31.0, 1.5, -0.5), Vector3(0, 0.1, -0.5), 34.0)
			_light(key, Vector3(0.55, -0.45, -0.7), 2.6, warm)
			_light(rim, Vector3(0.3, -0.2, 0.95), 2.2, cool)
		"ship_rear":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(1.0)
			_look(Vector3(8.5, 4.2, 21.0), Vector3(0.0, 0.0, 1.5), 42.0)
			_light(key, Vector3(-0.6, -0.5, 0.6), 2.4, warm)
			_light(rim, Vector3(0.5, -0.3, -0.8), 2.0, cool)
		"ship_top":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.5)
			_look(Vector3(0.01, 33.0, 4.0), Vector3(0, 0, 0.3), 40.0)
			_light(key, Vector3(0.35, -0.85, -0.4), 2.6, warm)
			_light(rim, Vector3(-0.4, -0.3, 0.85), 1.6, cool)
		"ship_landed":
			_space(false)
			ship.set_gear(true, true)
			ship.set_hatch(true, true)
			ship.set_thrust(0.0)
			var exitp := ship.get_marker("ExitPoint")
			if exitp:
				figure.global_position = exitp.global_position + Vector3(0.9, 0.9, -0.4)
			_look(Vector3(-13.5, -0.6, -15.5), Vector3(0.0, -1.2, -1.0), 42.0)
			_light(key, Vector3(0.75, -0.32, 0.55), 3.0, Color(1.0, 0.82, 0.62))
			_light(rim, Vector3(-0.5, -0.25, -0.8), 0.8, Color(0.5, 0.6, 0.9))
		_:  # ship_hero
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.6)
			_look(Vector3(-11.5, 2.4, -15.5), Vector3(0.6, -0.1, -0.2), 44.0)
			_light(key, Vector3(0.6, -0.55, 0.6), 2.8, warm)
			_light(rim, Vector3(-0.2, -0.35, -0.95), 2.6, cool)
	if thrust_override >= 0.0:
		ship.set_thrust(thrust_override)
	if cap != null:
		var a: Dictionary = cap.get("args")
		if a.has("hide_ship"):
			ship.visible = false
		if a.has("nonav"):
			ship.nav_lights = false
		if a.has("norim"):
			rim.visible = false
		if a.has("plain_mat"):  # debug: --plain_mat=Emissive replaces one slot with flat grey
			_plain(ship, ship._mats.get(String(a["plain_mat"])))
		if a.has("campos") and a.has("camat"):  # debug framing: --campos=x,y,z --camat=x,y,z [--fov=]
			_look(_vec(a["campos"]), _vec(a["camat"]), float(a.get("fov", "30")))


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _plain(n: Node, target: Material) -> void:
	var grey := StandardMaterial3D.new()
	for c in n.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				if mi.get_surface_override_material(i) == target:
					mi.set_surface_override_material(i, grey)
		_plain(c, target)
