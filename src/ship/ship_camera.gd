class_name ShipCameraRig
extends Node3D
## Chase + cockpit cameras for the Ship (child "CameraRig" of the ship, runs top-level).
##
## Chase (cinematic): two-stage (critically smoothed) orientation lag — the ship visibly swings
## inside the frame when turning, eases in and out; the camera position rides a critically damped
## spring around the lagged offset (soft starts/stops, acceleration pull-back); horizon partly
## stabilised near the ground; speed-dependent FOV (+ boost, + warp kick from FX).
## Shake: continuous (boost, buffeting = air density x speed, re-entry heat, warp spool) plus
## "trauma" impulses (touchdown, sonic boom, warp engage / drop-out, impacts), rotational first.
## Cockpit: camera at the PilotEye marker with micro-shake. C toggles with a 0.55 s flight between
## the two poses (the chase camera flies into the canopy and hands over).
## Idle orbit ("photo mode"): landed, piloted, chase view and no input for `idle_orbit_delay` s —
## the camera slowly circles the ship; any input returns control (blends back).
## Near/far follow the speed mode (far/near <= 1e7, see DECISIONS).
## `view_override`: optional Callable(rig) -> Transform3D for scripted shots.

enum View { CHASE, COCKPIT }

@export var chase_offset := Vector3(0.0, 4.4, 20.0)
@export var look_ahead := Vector3(0.0, 1.0, -16.0)
@export var rot_follow := 8.0
@export var pos_spring := 7.5
@export var base_fov := 68.0
@export var cockpit_fov := 76.0
@export var shake_scale := 1.0
@export var cockpit_eye_offset := Vector3(0.0, 0.18, 0.0)
## Cockpit near plane (scaled space needs near >= 0.1 for a good depth range, see wave2_system).
@export var cockpit_near := 0.1
@export var view_blend_time := 0.55
@export_group("Idle orbit")
@export var idle_orbit := true
@export var idle_orbit_delay := 20.0
@export var orbit_radius := 26.0
@export var orbit_height := 5.5
@export var orbit_speed := 0.05          ## rad/s
@export_group("")
## Render-side extrapolation: physics runs at 60 Hz, so on a 144 Hz display the ship and the
## camera following it would move in 60 Hz steps against the world. The visual, the cockpit
## camera and the chase camera use the ship transform advanced by the elapsed part of the
## physics tick (Engine.get_physics_interpolation_fraction(); the engine-wide physics
## interpolation stays off, it fights the floating-origin shifts — see wave3_integration.md).
@export var render_extrapolation := true

var ship: Ship
var view: int = View.CHASE
var chase: Camera3D
var cockpit: Camera3D
var fov_kick := 0.0                  # extra FOV (deg) driven by FX (warp)
var shake_extra := 0.0               # extra shake amplitude from FX
## If set, called each frame with this rig; return a world Transform3D for the chase camera.
var view_override: Callable
## Capture: force the idle orbit on (0..1 = blend, 1 = orbiting) and its angle.
var force_orbit := -1.0
var force_orbit_ang := NAN
var idle_time := 0.0

var _basis := Basis.IDENTITY
var _basis1 := Basis.IDENTITY
var _lag := Vector3.ZERO
var _spring_x := Vector3.ZERO        # camera offset from the ship (world axes), spring state
var _spring_v := Vector3.ZERO
var _t := 0.0
var _fov := 68.0
var _initialized := false
var _trauma := 0.0
var _blend := 1.0
var _blend_from := Transform3D()     # ship-local pose at the start of a view switch
var _blend_from_fov := 68.0
var _orbit_k := 0.0
var _orbit_ang := 0.0
var _orbit_t := 0.0


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
	if ship:
		ship.touchdown.connect(func(v: float) -> void: add_trauma(clampf(v / 5.0, 0.08, 0.55)))
		ship.sonic_boom.connect(func() -> void: add_trauma(0.45))
		ship.warp_engaged.connect(func() -> void: add_trauma(0.5))
		ship.warp_dropped.connect(func() -> void: add_trauma(0.65))
		ship.takeoff.connect(func() -> void: add_trauma(0.12))
		ship.landed_changed.connect(func(_l: bool) -> void: idle_time = 0.0)


func activate() -> void:
	_initialized = false
	_blend = 1.0
	_orbit_k = 0.0
	idle_time = 0.0
	_apply_view()


func toggle_view() -> void:
	set_view(View.COCKPIT if view == View.CHASE else View.CHASE, true)


func set_view(v: int, animate := false) -> void:
	if animate and v != view and ship and ship.is_piloted and not Capture.active:
		var cur := chase if _blend < 1.0 or _orbit_k > 0.0 else get_active_camera()
		if cur:
			_blend_from = ship.global_transform.affine_inverse() * cur.global_transform
			_blend_from_fov = cur.fov
			_blend = 0.0
	else:
		_blend = 1.0
	view = v
	_orbit_k = 0.0 if v == View.COCKPIT else _orbit_k
	_apply_view()


func get_active_camera() -> Camera3D:
	return cockpit if view == View.COCKPIT and cockpit else chase


## Impulsive camera shake (0..1, adds up, decays ~1.1/s; amplitude ~ trauma^2).
func add_trauma(a: float) -> void:
	_trauma = minf(_trauma + a, 1.0)


func is_orbiting() -> bool:
	return _orbit_k > 0.01


func _apply_view() -> void:
	var cam := chase if (_blend < 1.0 or _orbit_k > 0.01) else get_active_camera()
	if cam and not cam.current and (ship == null or ship.is_piloted or ship.capture_hold or ship.scripted):
		cam.make_current()


func _input(event: InputEvent) -> void:
	var active := false
	if event is InputEventKey and (event as InputEventKey).pressed:
		active = true
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		active = true
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() > 2.0:
		active = true
	elif event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.3:
		active = true
	if active:
		idle_time = 0.0


## Ship transform for this rendered frame (extrapolated within the physics tick).
func render_transform() -> Transform3D:
	var xf := ship.global_transform
	if not render_extrapolation or ship.freeze or ship.capture_hold or ship.vel.length() > Ship.TELEPORT_SPEED:
		return xf
	var h := Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second)
	if h <= 0.0:
		return xf
	var b := xf.basis
	var w := ship.angular_velocity
	if w.length_squared() > 1e-10:
		b = Basis(w.normalized(), w.length() * h) * b
	return Transform3D(b, xf.origin + ship.vel * h)


func _process(dt: float) -> void:
	if ship == null or not (ship.is_piloted or ship.capture_hold or ship.scripted):
		if ship and ship.visual and ship.visual.transform != Transform3D.IDENTITY:
			ship.visual.transform = Transform3D.IDENTITY
		return
	_t += dt
	var rx := render_transform()
	var local_off := ship.global_transform.affine_inverse() * rx
	var lean := Transform3D(Basis.from_euler(ship.visual_lean), Vector3.ZERO)
	if ship.visual:
		ship.visual.transform = local_off * lean
	var sb := rx.basis.orthonormalized()
	var ship_pos := rx.origin
	var speed := ship.vel.length()
	if not _initialized:
		_basis = sb
		_basis1 = sb
		_lag = Vector3.ZERO
		_spring_x = sb * chase_offset
		_spring_v = Vector3.ZERO
		_initialized = true
	# two-stage orientation lag: eases in and out of turns
	var k := 1.0 - exp(-dt * rot_follow)
	if speed > Ship.TELEPORT_SPEED or ship.mode >= Ship.Mode.CRUISE:
		k = 1.0 - exp(-dt * rot_follow * 1.4)
	_basis1 = Basis(Quaternion(_basis1).slerp(Quaternion(sb), k)).orthonormalized()
	_basis = Basis(Quaternion(_basis).slerp(Quaternion(_basis1), k)).orthonormalized()
	var sf := clampf(log(speed + 1.0) / log(3.0e7), 0.0, 1.0)     # 0..1 over all modes
	var lf := clampf(speed / 600.0, 0.0, 1.0)

	# --- shake: continuous + trauma impulses
	_trauma = maxf(_trauma - dt * 1.1, 0.0)
	var amp := 0.0
	amp += ship.boost_t * 0.022 * clampf(ship.thrust_norm.length(), 0.0, 1.0)
	amp += ship.density * clampf(speed / 500.0, 0.0, 1.5) * 0.05
	amp += ship.heat * 0.14
	amp += ship.impact * 0.3
	amp += shake_extra
	amp *= shake_scale
	var tr := _trauma * _trauma * shake_scale
	if Capture.active:
		tr = 0.0
	var sh := Vector3(_noise(1.0), _noise(2.0), _noise(3.0)) * (amp + tr * 0.25)
	var shr := Vector3(_noise(4.0), _noise(5.0), _noise(6.0) * 0.6) * (amp * 0.012 + tr * 0.035)
	# slow re-entry sway (the hull is being pushed around)
	shr += Vector3(_slow(7.0), _slow(8.0), _slow(9.0) * 1.5) * ship.heat * 0.012 * shake_scale

	# --- FOV
	var fov_target := base_fov + 10.0 * sf * sf + 3.0 * lf * ship.density + 4.0 * ship.boost_t + fov_kick
	_fov = lerpf(_fov, fov_target, 1.0 - exp(-dt * 3.0))

	# --- position: acceleration pull-back + critically damped spring around the lagged offset
	var a_loc := sb.transposed() * ship.accel_world
	var lag_t := Vector3(clampf(a_loc.x * -0.01, -1.2, 1.2), clampf(a_loc.y * -0.012, -1.2, 1.2),
		clampf(a_loc.z * 0.004, -1.5, 3.0))
	if speed > Ship.TELEPORT_SPEED:
		lag_t *= 0.3
	_lag = _lag.lerp(lag_t, 1.0 - exp(-dt * 4.0))
	var off := chase_offset * (1.0 + 0.1 * lf + 0.08 * sf)
	var target_off := _basis * (off + _lag)
	var w := pos_spring
	if dt > 0.0:
		var acc := (target_off - _spring_x) * w * w - _spring_v * 2.0 * w
		_spring_v += acc * dt
		_spring_x += _spring_v * dt
		# never let the spring trail more than a few metres (teleports, huge accelerations)
		var err := _spring_x - target_off
		if err.length() > 6.0:
			_spring_x = target_off + err.normalized() * 6.0
	else:
		_spring_x = target_off

	# --- near/far per regime (far/near <= 1e7)
	var near := 0.5
	var far := 5.0e6
	if ship.mode >= Ship.Mode.CRUISE or speed > Ship.TELEPORT_SPEED:
		near = 3.0
		far = 3.0e7
	elif ship.altitude > 20000.0:
		near = 1.0
		far = 1.0e7

	# --- chase pose
	var chase_xf: Transform3D
	if view_override.is_valid():
		chase_xf = view_override.call(self)
	else:
		var p := ship_pos + _spring_x
		var tgt := ship_pos + _basis * look_ahead
		# partly stabilised horizon close to the ground / slow (cinematic, less nausea)
		var up := _basis.y
		if ship.body and ship.altitude < 3000.0 and speed < 250.0:
			var hk := 0.55 * (1.0 - smoothstep(1000.0, 3000.0, ship.altitude)) * (1.0 - smoothstep(120.0, 250.0, speed))
			up = up.lerp(ship.up_dir, hk).normalized()
		var cb := Basis.looking_at(tgt - p, up)
		cb = cb * Basis.from_euler(shr)
		chase_xf = Transform3D(cb, p + cb * sh)
	var chase_fov := _fov

	# --- idle orbit ("photo mode")
	# only while the player is actually looking through the ship's chase camera (not the free
	# camera / loading / scripted runs) and the game is running
	var vc := get_viewport().get_camera_3d()
	var can_orbit := idle_orbit and ship.landed and ship.is_piloted and view == View.CHASE \
		and not view_override.is_valid() and ship.input_enabled and (vc == chase or vc == cockpit) \
		and ((not Capture.active and not ship.scripted) or force_orbit >= 0.0)
	if can_orbit:
		idle_time += dt
	else:
		idle_time = 0.0
	var want_orbit := 1.0 if (can_orbit and idle_time > idle_orbit_delay) else 0.0
	if force_orbit >= 0.0:
		want_orbit = force_orbit
	if want_orbit > 0.0 and _orbit_k <= 0.001:
		# start the circle where the chase camera is
		var rel := chase_xf.origin - ship_pos
		var up0 := ship.up_dir
		var flat := rel - up0 * rel.dot(up0)
		var ref := _orbit_ref(up0)
		_orbit_ang = atan2(flat.dot(up0.cross(ref)), flat.dot(ref))
		_orbit_t = 0.0
	if force_orbit >= 0.0:
		_orbit_k = force_orbit
		if not is_nan(force_orbit_ang):
			_orbit_ang = force_orbit_ang
	else:
		_orbit_k = move_toward(_orbit_k, want_orbit, dt / (5.0 if want_orbit > _orbit_k else 1.1))
	if _orbit_k > 0.001:
		_orbit_t += dt
		_orbit_ang += orbit_speed * dt * smoothstep(0.0, 1.0, _orbit_k)
		var ob := _orbit_pose(ship_pos)
		var e := _orbit_k * _orbit_k * (3.0 - 2.0 * _orbit_k)
		chase_xf = chase_xf.interpolate_with(ob, e)
		chase_fov = lerpf(chase_fov, 52.0, e)

	# --- cockpit pose
	var eye: Node3D = ship.visual.get_marker("PilotEye") if ship.visual else null
	var ep := eye.position if eye else Vector3(0, 1.12, -3.8)
	# eye slightly above the marker and pitched down a touch: over the glowing dash display
	var ck_local := local_off * lean * Transform3D(Basis.from_euler(Vector3(deg_to_rad(-6.0), 0, 0) + shr * 0.6),
		ep + cockpit_eye_offset + sh * 0.08)
	var ck_fov := cockpit_fov + (_fov - base_fov) * 0.6

	# --- view switch flight
	var cam_near := near
	if _blend < 1.0:
		_blend = minf(_blend + dt / view_blend_time, 1.0)
		var e := _blend * _blend * _blend * (_blend * (_blend * 6.0 - 15.0) + 10.0)
		var from_w := ship.global_transform * _blend_from
		var to_w := ship.global_transform * ck_local if view == View.COCKPIT else chase_xf
		chase_xf = from_w.interpolate_with(to_w, e)
		chase_fov = lerpf(_blend_from_fov, ck_fov if view == View.COCKPIT else chase_fov, e)
		cam_near = cockpit_near
		if _blend >= 1.0:
			_apply_view()
	elif view == View.COCKPIT and chase.current and cockpit:
		_apply_view()
	if _orbit_k > 0.01 and not chase.current and _blend >= 1.0 and view == View.CHASE:
		chase.make_current()

	chase.global_transform = chase_xf
	chase.fov = chase_fov
	chase.near = cam_near
	chase.far = far if cam_near == near else cam_near * 4.0e6
	if cockpit:
		cockpit.fov = ck_fov
		cockpit.near = cockpit_near if far < 1.0e7 else 0.3
		cockpit.far = 5.0e5 if far < 1.0e7 else 3.0e6
		cockpit.transform = ck_local


func _orbit_ref(up: Vector3) -> Vector3:
	var r := ship.global_basis.z - up * ship.global_basis.z.dot(up)
	if r.length_squared() < 1e-4:
		r = up.cross(Vector3.RIGHT)
	return r.normalized()


func _orbit_pose(ship_pos: Vector3) -> Transform3D:
	var up := ship.up_dir
	var ref := _orbit_ref(up)
	var side := up.cross(ref)
	var dir := ref * cos(_orbit_ang) + side * sin(_orbit_ang)
	var h := orbit_height + 1.8 * sin(_orbit_t * 0.07)
	var r := orbit_radius * (1.0 + 0.08 * sin(_orbit_t * 0.05 + 1.0))
	var p := ship_pos + dir * r + up * h
	if ship.body and ship.body is Planet:
		var ga: float = ship.body.get_altitude_global(p)
		if ga < 2.5:
			p += up * (2.5 - ga)
	var tgt := ship_pos + up * 1.2
	return Transform3D(Basis.looking_at(tgt - p, up), p)


func _noise(seed_v: float) -> float:
	var t := _t * 13.0
	return (sin(t * 1.37 + seed_v * 11.1) * 0.5 + sin(t * 2.93 + seed_v * 5.3) * 0.3
		+ sin(t * 5.71 + seed_v * 2.7) * 0.2)


func _slow(seed_v: float) -> float:
	var t := _t * 1.6
	return sin(t * 1.13 + seed_v * 3.1) * 0.6 + sin(t * 2.07 + seed_v * 1.7) * 0.4
