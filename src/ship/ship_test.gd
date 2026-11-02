extends Node3D
## Ship look-dev scene controller (scenes/test/ship_test.tscn). Capture presets:
## ship_hero, ship_side, ship_rear, ship_top, ship_landed, ship_chase (game chase-camera framing),
## ship_night (landed, unlit side: only the ship's own lights), ship_cockpit (pilot eye), ship_gear (close-up),
## ship_front, ship_sunset  (tools/shot.sh ... --cam=<preset>)
## Extra Capture args: --thrust=0..1 overrides engine thrust, --gear=0..1 gear deploy parameter,
## --hatch=0|1, --canopy=0|1.

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
	key.visible = true
	rim.visible = true


## Night on an airless moon: starry sky, ground, no sun; only faint starlight/earthshine ambient.
func _night() -> void:
	_sky_mat.set_shader_parameter("mode", 0)
	ground.visible = true
	figure.visible = true
	var e := env.environment
	e.ambient_light_energy = 0.06
	e.background_energy_multiplier = 0.6
	key.visible = false
	rim.visible = true


func apply_capture_preset(preset: String) -> void:
	var cap := get_node_or_null("/root/Capture")
	var thrust_override := -1.0
	if cap != null and (cap.get("args") as Dictionary).has("thrust"):
		thrust_override = float((cap.get("args") as Dictionary)["thrust"])
	ship.rotation = Vector3.ZERO
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
		"ship_chase":
			# the in-game chase camera (ShipCameraRig chase_offset / look_ahead), sun behind-left, low
			_space(false)
			ship.set_gear(true, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.06)
			figure.visible = false
			_look(Vector3(0.0, 4.4, 20.0), Vector3(0.0, 1.0, -16.0), 68.0)
			_light(key, Vector3(0.45, -0.42, -0.78), 3.0, Color(1.0, 0.9, 0.78))
			_light(rim, Vector3(-0.5, -0.3, 0.8), 0.6, cool)
		"ship_chase_space":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.5)
			_look(Vector3(0.0, 4.4, 20.0), Vector3(0.0, 1.0, -16.0), 70.0)
			_light(key, Vector3(-0.7, -0.35, 0.6), 2.6, warm)
			_light(rim, Vector3(0.5, -0.3, -0.8), 1.4, cool)
		"ship_night":
			_night()
			ship.set_gear(true, true)
			ship.set_hatch(true, true)
			ship.set_thrust(0.0)
			var ep := ship.get_marker("ExitPoint")
			if ep:
				figure.global_position = ep.global_position + Vector3(2.6, 0.9, 0.0)
			_look(Vector3(-15.0, 1.2, -17.0), Vector3(0.0, -0.8, -0.5), 46.0)
			_light(rim, Vector3(0.3, -0.5, 0.8), 0.06, Color(0.5, 0.6, 0.9))
		"ship_night_chase":
			_night()
			ship.set_gear(true, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.06)
			figure.visible = false
			_look(Vector3(0.0, 4.4, 20.0), Vector3(0.0, 1.0, -16.0), 68.0)
			_light(rim, Vector3(0.3, -0.5, 0.8), 0.06, Color(0.5, 0.6, 0.9))
		"ship_cockpit":
			_space(false)
			ship.set_gear(true, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.06)
			figure.visible = false
			var eye := ship.get_marker("PilotEye")
			var ep2: Vector3 = (eye.global_position if eye else Vector3(0, 1.4, -4.0)) + Vector3(0, 0.18, 0)
			cam.position = ep2
			cam.basis = Basis.from_euler(Vector3(deg_to_rad(-6.0), 0.0, 0.0))
			cam.fov = 76.0
			cam.near = 0.05
			_light(key, Vector3(0.4, -0.5, 0.75), 2.8, Color(1.0, 0.9, 0.8))
			_light(rim, Vector3(-0.5, -0.3, -0.8), 0.5, cool)
		"ship_gear":
			_space(false)
			ship.set_gear(true, true)
			ship.set_hatch(true, true)
			ship.set_thrust(0.0)
			figure.visible = false
			_look(Vector3(-9.5, -1.6, 9.5), Vector3(-2.5, -1.6, 2.0), 40.0)
			_light(key, Vector3(0.6, -0.4, -0.7), 3.0, Color(1.0, 0.85, 0.7))
			_light(rim, Vector3(-0.5, -0.3, 0.8), 0.7, cool)
		"ship_front":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.4)
			_look(Vector3(11.0, 3.4, -21.0), Vector3(0.0, 0.0, -0.5), 42.0)
			_light(key, Vector3(-0.5, -0.55, 0.65), 2.8, warm)
			_light(rim, Vector3(0.6, -0.2, 0.75), 2.2, cool)
		"ship_belly":
			_space(true)
			ship.set_gear(false, true)
			ship.set_hatch(false, true)
			ship.set_thrust(0.3)
			_look(Vector3(-9.0, -17.0, -9.0), Vector3(0.0, -0.5, 0.5), 50.0)
			_light(key, Vector3(0.3, 0.6, 0.5), 2.2, warm)
			_light(rim, Vector3(-0.4, 0.5, -0.7), 1.2, cool)
		"ship_sunset":
			_space(false)
			ship.set_gear(true, true)
			ship.set_hatch(true, true)
			ship.set_thrust(0.0)
			figure.visible = false
			_look(Vector3(16.0, 0.2, 12.0), Vector3(0.0, -0.4, 0.5), 46.0)
			_light(key, Vector3(-0.85, -0.12, -0.5), 2.6, Color(1.0, 0.62, 0.35))
			_light(rim, Vector3(0.4, -0.3, 0.8), 0.5, Color(0.5, 0.55, 0.85))
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
			ship.rotation = Vector3(0.0, 0.0, deg_to_rad(5.0))
			_look(Vector3(-12.0, 5.2, -15.0), Vector3(0.8, -0.5, 0.2), 44.0)
			_light(key, Vector3(0.6, -0.55, 0.6), 2.8, warm)
			_light(rim, Vector3(-0.2, -0.35, -0.95), 2.6, cool)
	if thrust_override >= 0.0:
		ship.set_thrust(thrust_override)
	if cap != null:
		var a: Dictionary = cap.get("args")
		if a.has("gear"):
			ship._set_gear_t(float(a["gear"]))
		if a.has("hatch"):
			ship.set_hatch(String(a["hatch"]) == "1", true)
		if a.has("canopy"):
			ship.set_canopy(String(a["canopy"]) == "1", true)
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
