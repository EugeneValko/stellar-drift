extends Node3D
## Stage 1 test scene: space backdrop + star Helios + post FX.
## Capture presets: space_wide, nebula_view, star_far, star_close, star_surface,
## star_eclipse, star_grazing (see apply_capture_preset).

const KM := 1000.0

@onready var camera: Camera3D = $Camera3D
@onready var star: Node3D = get_node_or_null("Star")
@onready var planet: Node3D = get_node_or_null("Planet")
@onready var sun_light: DirectionalLight3D = $SunLight

var _orbit := false
var _orbit_center := Vector3.ZERO
var _orbit_radius := 0.0
var _orbit_speed := 0.0
var _orbit_angle := 0.0
var _orbit_height := 0.0


func _ready() -> void:
	add_to_group("capture_target")
	camera.far = 1.0e9
	camera.near = 0.1
	if planet:
		planet.visible = false
	var p := Capture.get_preset()
	apply_capture_preset(p if p != "" else "star_far")


func _process(delta: float) -> void:
	if _orbit:
		_orbit_angle += _orbit_speed * delta
		var pos := _orbit_center + Vector3(sin(_orbit_angle), 0.0, cos(_orbit_angle)) * _orbit_radius
		pos.y += _orbit_height
		camera.global_position = pos
		camera.look_at(_orbit_center + Vector3(0, _orbit_height * 0.2, 0), Vector3.UP)


func _look(from: Vector3, target: Vector3, fov: float = 70.0, up: Vector3 = Vector3.UP) -> void:
	_orbit = false
	camera.fov = fov
	camera.global_position = from
	if absf((target - from).normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	camera.look_at(target, up)


func _look_dir(from: Vector3, dir: Vector3, fov: float = 70.0) -> void:
	_look(from, from + dir.normalized() * 1000.0, fov)


func _sky_param(name: String) -> Variant:
	var env: Environment = $SpaceBackdrop.environment
	var mat := env.sky.sky_material as ShaderMaterial
	var v: Variant = mat.get_shader_parameter(name)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), name)
	return v


func apply_capture_preset(preset_name: String) -> void:
	if planet:
		planet.visible = false
	var gc: Vector3 = _sky_param("galaxy_center")
	match preset_name:
		"space_wide":
			# Milky Way core, star behind the camera.
			_look_dir(Vector3(0, 0, 0) - gc.normalized() * 20000.0 * KM, gc, 75.0)
		"nebula_view":
			var d := Vector3(float(Capture.args.get("nx", "0.2")), float(Capture.args.get("ny", "0.5")), float(Capture.args.get("nz", "0.8")))
			_look_dir(-d.normalized() * 20000.0 * KM, d, 60.0)
		"dir":
			# Debug: --dx= --dy= --dz= --fov=
			var d := Vector3(float(Capture.args.get("dx", "0")), float(Capture.args.get("dy", "0")), float(Capture.args.get("dz", "-1")))
			_look_dir(-d.normalized() * 20000.0 * KM, d, float(Capture.args.get("fov", "70")))
		"star_far":
			_look(Vector3(-4000.0, 1500.0, 15000.0) * KM, Vector3.ZERO, 70.0)
		"star_close":
			_look(Vector3(-600.0, 350.0, 1700.0) * KM, Vector3(-180.0, 80.0, 0.0) * KM, 60.0)
		"star_surface":
			_look(Vector3(0.0, 120.0, 620.0) * KM, Vector3(0.0, 380.0, -100.0) * KM, 60.0)
		"star_eclipse":
			if planet:
				planet.visible = true
			_setup_eclipse()
		"star_grazing":
			var from := Vector3(9000.0, 2500.0, 12000.0) * KM
			var to_star := (Vector3.ZERO - from).normalized()
			var side := to_star.cross(Vector3.UP).normalized()
			_look_dir(from, (to_star + side * 0.62 + Vector3.UP * 0.18).normalized(), 70.0)
		"orbit":
			_orbit = true
			_orbit_center = Vector3.ZERO
			_orbit_radius = 2200.0 * KM
			_orbit_speed = 0.06
			_orbit_height = 300.0 * KM
		_:
			_look(Vector3(-4000.0, 1500.0, 15000.0) * KM, Vector3.ZERO, 70.0)
	_aim_light()


func _setup_eclipse() -> void:
	# Planet (R=60 km) between camera and star, star partially hidden behind its limb.
	var star_dist := 24000.0 * KM
	var cam_to_planet := 2600.0 * KM
	var axis := Vector3(0.3, 0.12, 1.0).normalized()
	var planet_pos := axis * (star_dist - cam_to_planet)
	var cam_pos := axis * star_dist
	if planet:
		planet.global_position = planet_pos
	var to_star := (Vector3.ZERO - cam_pos).normalized()
	var side := to_star.cross(Vector3.UP).normalized()
	_look_dir(cam_pos + side * 35.0 * KM + Vector3.UP * 25.0 * KM, to_star, 40.0)


func _aim_light() -> void:
	# Light travels from the star toward the camera / planet.
	var target := camera.global_position
	if planet and planet.visible:
		target = planet.global_position
	var dir := (target - Vector3.ZERO).normalized()
	sun_light.global_basis = Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT)
