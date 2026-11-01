extends Node3D
## Stage 1 test scene: space backdrop + star Helios + post FX.
## Capture presets: space_wide, nebula_view, star_far, star_close, star_surface,
## star_eclipse, star_grazing (see apply_capture_preset).

const KM := 1000.0

@onready var camera: Camera3D = $Camera3D
@onready var star: Star = get_node_or_null("Star")
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
	# far/near must stay <= ~1e7: beyond that float32 projection math degenerates the far
	# frustum plane and Godot culls every mesh (see docs/reports/stage1_space.md).
	camera.far = float(Capture.args.get("far", "5e8"))
	camera.near = float(Capture.args.get("near", "50"))
	if Capture.args.has("debug"):
		print("star=", star, " children=", star.get_children() if star else [])
	if planet:
		planet.visible = false
	var env: Environment = $SpaceBackdrop.environment
	if Capture.args.has("tonemap"):
		env.tonemap_mode = int(Capture.args["tonemap"]) as Environment.ToneMapper
	if Capture.args.has("exposure"):
		env.tonemap_exposure = float(Capture.args["exposure"])
	if star and Capture.args.has("time_scale"):
		star.time_scale = float(Capture.args["time_scale"])
	var p := Capture.get_preset()
	apply_capture_preset(p if p != "" else "star_far")


func _process(delta: float) -> void:
	if _orbit:
		_orbit_angle += _orbit_speed * delta
		var pos := _orbit_center + Vector3(sin(_orbit_angle), 0.0, cos(_orbit_angle)) * _orbit_radius
		pos.y += _orbit_height
		camera.global_position = pos
		var side := (pos - _orbit_center).cross(Vector3.UP).normalized()
		camera.look_at(_orbit_center + side * 260.0 * KM + Vector3(0, 60.0 * KM, 0), Vector3.UP)


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
			_look_dir(-gc.normalized() * -20000.0 * KM, gc, 75.0)
		"nebula_view":
			var d := Vector3(float(Capture.args.get("nx", "0.10")), float(Capture.args.get("ny", "0.17")), float(Capture.args.get("nz", "-0.98")))
			_look_dir(d.normalized() * 20000.0 * KM, d, 55.0)
		"dir":
			# Debug: --dx= --dy= --dz= --fov=
			var d := Vector3(float(Capture.args.get("dx", "0")), float(Capture.args.get("dy", "0")), float(Capture.args.get("dz", "-1")))
			_look_dir(d.normalized() * 20000.0 * KM, d, float(Capture.args.get("fov", "70")))
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
			_look_dir(from, (to_star + side * 0.80 + Vector3.UP * 0.22).normalized(), 70.0)
		"orbit":
			_orbit = true
			_orbit_center = Vector3.ZERO
			_orbit_radius = 1900.0 * KM
			_orbit_speed = 0.035
			_orbit_height = 250.0 * KM
			camera.fov = 55.0
		_:
			_look(Vector3(-4000.0, 1500.0, 15000.0) * KM, Vector3.ZERO, 70.0)


func _setup_eclipse() -> void:
	# Planet (R=60 km) between camera and star; the star peeks out from behind its limb.
	var axis := Vector3(0.3, 0.12, 1.0).normalized()
	var d_sp := 24000.0 * KM          # star -> planet
	var d_cp := 900.0 * KM            # planet -> camera
	var planet_pos := axis * d_sp
	if planet:
		planet.global_position = planet_pos
	var rp := asin(60.0 / 900.0)
	var rs := asin(400.0 / (24000.0 + 900.0))
	var sep := rp - 0.35 * rs          # star centre slightly inside the planet limb
	var offset := sep / (1.0 / d_cp - 1.0 / (d_sp + d_cp))
	var perp := axis.cross(Vector3.UP).normalized().rotated(axis, 0.7)
	var cam_pos := planet_pos + axis * d_cp + perp * offset
	var to_star := (Vector3.ZERO - cam_pos).normalized()
	var to_planet := (planet_pos - cam_pos).normalized()
	_look_dir(cam_pos, (to_star * 0.35 + to_planet * 0.65).normalized(), 24.0)
