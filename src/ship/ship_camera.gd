class_name ShipCameraRig
extends Node3D
## Chase + cockpit cameras for the Ship (child "CameraRig" of the ship, runs top-level).
##
## Chase: orientation follows the ship with a critically-damped lag (the ship visibly swings
## inside the frame when turning), a small acceleration lag in position, speed-based FOV and
## distance, procedural shake (boost, atmosphere buffeting, re-entry, impacts, warp spool).
## Cockpit: camera at the PilotEye marker with micro-shake.
## Near/far follow the speed mode (far/near <= 1e7, see DECISIONS).
## `view_override`: optional Callable(rig) -> Transform3D for scripted shots.

enum View { CHASE, COCKPIT }

@export var chase_offset := Vector3(0.0, 4.4, 20.0)
@export var look_ahead := Vector3(0.0, 1.0, -16.0)
@export var rot_follow := 5.5
@export var base_fov := 68.0
@export var cockpit_fov := 76.0
@export var shake_scale := 1.0

var ship: Ship
var view: int = View.CHASE
var chase: Camera3D
var cockpit: Camera3D
var fov_kick := 0.0                  # extra FOV (deg) driven by FX (warp)
var shake_extra := 0.0               # extra shake amplitude from FX
## If set, called each frame with this rig; return a world Transform3D for the chase camera.
var view_override: Callable

var _basis := Basis.IDENTITY
var _lag := Vector3.ZERO
var _t := 0.0
var _fov := 68.0
var _initialized := false


func _ready() -> void:
	top_level = true
	ship = get_parent() as Ship
	chase = get_node_or_null("ChaseCamera") as Camera3D
	if chase == null:
		chase = Camera3D.new()
		chase.name = "ChaseCamera"
		add_child(chase)
	cockpit = ship.get_node_or_null("CockpitCamera") as Camera3D if ship else null
	chase.fov = base_fov
	_fov = base_fov


func activate() -> void:
	_initialized = false
	_apply_view()


func toggle_view() -> void:
	view = View.COCKPIT if view == View.CHASE else View.CHASE
	_apply_view()


func set_view(v: int) -> void:
	view = v
	_apply_view()


func get_active_camera() -> Camera3D:
	return cockpit if view == View.COCKPIT and cockpit else chase


func _apply_view() -> void:
	var cam := get_active_camera()
	if cam:
		cam.make_current()
	if ship and ship.visual:
		# hide the canopy glass from inside? keep it: the faceted glass frames the view nicely
		pass


func _process(dt: float) -> void:
	if ship == null or not (ship.is_piloted or ship.capture_hold or ship.scripted):
		return
	_t += dt
	var sb := ship.global_basis.orthonormalized()
	if not _initialized:
		_basis = sb
		_lag = Vector3.ZERO
		_initialized = true
	var k := 1.0 - exp(-dt * rot_follow)
	_basis = Basis(Quaternion(_basis).slerp(Quaternion(sb), k)).orthonormalized()
	var speed := ship.vel.length()
	var sf := clampf(log(speed + 1.0) / log(3.0e7), 0.0, 1.0)     # 0..1 over all modes
	var lf := clampf(speed / 600.0, 0.0, 1.0)
	# shake amplitude
	var amp := 0.0
	amp += ship.boost_t * 0.025 * clampf(ship.thrust_norm.length(), 0.0, 1.0)
	amp += ship.density * clampf(speed / 500.0, 0.0, 1.5) * 0.06
	amp += ship.heat * 0.16
	amp += ship.impact * 0.35
	amp += shake_extra
	amp *= shake_scale
	var sh := Vector3(_noise(1.0), _noise(2.0), _noise(3.0)) * amp
	var shr := Vector3(_noise(4.0), _noise(5.0), _noise(6.0)) * amp * 0.012

	# FOV
	var fov_target := base_fov + 10.0 * sf * sf + 4.0 * ship.boost_t + fov_kick
	_fov = lerpf(_fov, fov_target, 1.0 - exp(-dt * 3.0))

	# position lag from acceleration (pulls the camera back on thrust, forward on braking)
	var a_loc := sb.transposed() * ship.accel_world
	var lag_t := Vector3(clampf(a_loc.x * -0.01, -1.2, 1.2), clampf(a_loc.y * -0.012, -1.2, 1.2),
		clampf(a_loc.z * 0.004, -1.5, 3.0))
	if speed > Ship.TELEPORT_SPEED:
		lag_t *= 0.3
	_lag = _lag.lerp(lag_t, 1.0 - exp(-dt * 4.0))

	# near/far per regime (far/near <= 1e7)
	var near := 0.5
	var far := 5.0e6
	if ship.mode >= Ship.Mode.CRUISE or speed > Ship.TELEPORT_SPEED:
		near = 3.0
		far = 3.0e7
	elif ship.altitude > 20000.0:
		near = 1.0
		far = 1.0e7

	var ship_pos := ship.global_position
	if view_override.is_valid():
		chase.global_transform = view_override.call(self)
	else:
		var off := chase_offset * (1.0 + 0.1 * lf + 0.08 * sf)
		var p := ship_pos + _basis * (off + _lag)
		var tgt := ship_pos + _basis * look_ahead
		var cb := Basis.looking_at(tgt - p, _basis.y)
		cb = cb * Basis.from_euler(shr)
		chase.global_transform = Transform3D(cb, p + cb * sh)
	chase.fov = _fov
	chase.near = near
	chase.far = far
	if cockpit:
		cockpit.fov = cockpit_fov + (_fov - base_fov) * 0.6
		cockpit.near = 0.05 if far < 1.0e7 else 0.3
		cockpit.far = 5.0e5 if far < 1.0e7 else 3.0e6
		var eye: Node3D = ship.visual.get_marker("PilotEye") if ship.visual else null
		var ep := eye.position if eye else Vector3(0, 1.12, -3.8)
		cockpit.transform = Transform3D(Basis.from_euler(shr * 0.6), ep + sh * 0.08)


func _noise(seed_v: float) -> float:
	var t := _t * 13.0
	return (sin(t * 1.37 + seed_v * 11.1) * 0.5 + sin(t * 2.93 + seed_v * 5.3) * 0.3
		+ sin(t * 5.71 + seed_v * 2.7) * 0.2)
