class_name Ship
extends RigidBody3D
## The flyable player ship (SD-7 "Kestrel").
##
## * RigidBody3D, default integrator; all control forces are applied as velocity changes in
##   `_integrate_forces` (gravity from Universe, simplified aero, flight assist).
## * Landing gear = analytic spring/damper suspension against the planet height function
##   (works even when terrain collision chunks are not built yet) + landing clamps (freeze)
##   once settled, so the ship sits rock-steady on slopes. Hull collision shapes handle crashes;
##   an analytic hull clamp is the last-resort guard against falling through terrain.
## * Speed modes HOVER / ATMOSPHERE / SPACE / CRUISE / WARP with altitude/proximity speed caps.
## * Above TELEPORT_SPEED the body is parked and the ship is moved by translating the floating
##   origin every tick (no float32 drift, no physics tunnelling), with a swept body check.
## * Pilot API for the on-foot / game-mode layer: see docs/reports/wave2_ship_flight.md.
##
## Axes: nose = -Z, up = +Y (ShipVisual convention).

signal pilot_entered
signal pilot_exited(exit_xform: Transform3D)
signal mode_changed(mode: int)
signal landed_changed(is_landed: bool)
signal gear_changed(down: bool)
signal warp_engaged
signal warp_dropped
signal hud_message(text: String)

enum Mode { HOVER, ATMOSPHERE, SPACE, CRUISE, WARP }
enum WarpState { IDLE, SPOOL, ACTIVE }

const MODE_NAMES: Array[String] = ["HOVER", "ATMOSPHERE", "SPACE", "CRUISE", "WARP"]
const MODE_MAX: Array[float] = [50.0, 600.0, 5000.0, 300000.0, 3.0e7]
## Per-mode handling. acc/acc_k: forward accel = acc + acc_k * speed (m/s^2) -> exponential
## build-up at high speed. lat/lat_k: lateral/vertical accel. strafe: FA strafe speed.
## rate: max turn rate (pitch, yaw, roll) deg/s. tau: FA velocity time constant.
## thr: throttle change per second (W/S). rev: lowest throttle (reverse).
const MODES: Array[Dictionary] = [
	{"acc": 24.0, "acc_k": 0.0, "lat": 18.0, "lat_k": 0.0, "strafe": 22.0,
		"rate": Vector3(50, 42, 80), "tau": 0.45, "thr": 3.0, "rev": -0.4},
	{"acc": 42.0, "acc_k": 0.3, "lat": 24.0, "lat_k": 0.25, "strafe": 45.0,
		"rate": Vector3(70, 34, 150), "tau": 0.7, "thr": 0.9, "rev": -0.15},
	{"acc": 80.0, "acc_k": 0.6, "lat": 40.0, "lat_k": 0.35, "strafe": 180.0,
		"rate": Vector3(60, 46, 120), "tau": 0.9, "thr": 0.6, "rev": -0.1},
	{"acc": 600.0, "acc_k": 0.85, "lat": 80.0, "lat_k": 0.6, "strafe": 0.0,
		"rate": Vector3(30, 24, 70), "tau": 1.1, "thr": 0.5, "rev": 0.0},
	{"acc": 3.0e4, "acc_k": 1.3, "lat": 0.0, "lat_k": 0.9, "strafe": 0.0,
		"rate": Vector3(9, 7, 30), "tau": 1.0, "thr": 0.5, "rev": 0.0},
]

const TELEPORT_SPEED := 6000.0      # above this the ship is moved by origin shifts
const CRUISE_K := 0.5               # cruise cap = k * altitude (1/s)
const CRUISE_MIN_ALT := 10000.0     # cruise disengages below this (or inside an atmosphere)
const WARP_K := 1.0                 # warp cap = k * distance to nearest surface (1/s)
const WARP_LOCK_DIST := 600000.0    # mass lock: no warp engage closer than this to a surface
const WARP_SPOOL_TIME := 2.0
## Gear feet (pad bottom at full extension, minus the static sag so pads rest on the ground).
const FEET: Array[Vector3] = [Vector3(0.0, -3.1, -6.45), Vector3(-2.8, -3.1, 4.5), Vector3(2.8, -3.1, 4.5)]
const GEAR_TRAVEL := 0.55
const GROUND_OFFSET := 2.95         # ship origin height above the pads (GroundPoint)
## Hull probe points for the analytic last-resort terrain clamp.
const HULL_PROBES: Array[Vector3] = [Vector3(0, -0.2, -10.2), Vector3(0, 0.2, 9.8), Vector3(-7.4, -0.5, 5.3),
	Vector3(7.4, -0.5, 5.3), Vector3(0, -1.4, 0), Vector3(0, 2.3, 6.0), Vector3(-2.8, -1.1, 8.0),
	Vector3(2.8, -1.1, 8.0), Vector3(0, -1.2, -6.0)]

@export_group("Control")
@export var start_piloted := false
@export var mouse_sensitivity := 0.0035
## Virtual-joystick return to centre (1/s). 0 = pure virtual joystick (stick holds).
@export var mouse_return := 2.2
@export var stick_deadzone := 0.03
@export var stick_expo := 1.45
@export var boost_mult := 1.6
@export var auto_gear := true
@export_group("Physics")
@export var drag_k := 1.6e-5
@export var lift_k := 1.4
@export var gear_stiffness := 6.0e5     # N/m per foot
@export var gear_damping := 1.1e5       # N*s/m per foot
@export var gear_friction := 1.3
@export_group("")

var is_piloted := false
var mode: int = Mode.SPACE
var throttle := 0.0
var flight_assist := true
var gear_down := true
var landed := false
var autopilot := false
var target: Node3D
var heat := 0.0
var vapor := 0.0
var warp_state: int = WarpState.IDLE
var warp_spool := 0.0
## Authoritative velocity (also valid while parked in teleport mode).
var vel := Vector3.ZERO
## Freeze simulation (capture stills): VFX read `vel`/`heat` as set by the preset.
var capture_hold := false

# --- inputs (player devices, demo driver or autopilot write these) ---
var in_move := Vector3.ZERO       # x strafe right, y up, z forward (W)
var in_stick := Vector2.ZERO      # x yaw right, y pitch up (virtual joystick, -1..1)
var in_roll := 0.0                # + = roll left (Q)
var in_boost := false
## External steering (autopilot / demo): world direction the nose should point to.
var steer_dir := Vector3.ZERO
var steer_up := Vector3.ZERO
## A demo/scripted driver owns the inputs (player input ignored).
var scripted := false

# --- environment (updated each physics tick) ---
var body: Node3D                  # dominant (or nearest) body
var nearest: Node3D
var up_dir := Vector3.UP
var altitude := INF               # ground (terrain/ocean) altitude of the pads, m
var surface_dist := INF           # distance to the nearest body's mean surface, m
var density := 0.0
var speed_cap := 50.0
var in_atmosphere := false

# --- telemetry for FX / camera ---
var thrust_local := Vector3.ZERO  # commanded accel (local, m/s^2) excl. gravity
var thrust_norm := Vector3.ZERO   # same, normalised by the axis limits (-1..1)
var ang_accel_local := Vector3.ZERO
var accel_world := Vector3.ZERO   # actual acceleration (for camera lag)
var gear_contacts := 0
var impact := 0.0                 # recent impact strength (camera shake), decays
var boost_t := 0.0

var visual: ShipVisual
var camera_rig: Node3D

var _stick_raw := Vector2.ZERO
var _braking := false
var _teleport := false
var _use_vel_once := false
var _disp := Vector3.ZERO
var _land_timer := 0.0
var _prev_vel := Vector3.ZERO
var _message := ""
var _message_t := 0.0
var _ocean_r: Dictionary = {}
var _mode_suggest := -1
var _pending_xf := Transform3D()
var _has_pending_xf := false


func _ready() -> void:
	visual = get_node_or_null("ShipVisual") as ShipVisual
	camera_rig = get_node_or_null("CameraRig")
	gravity_scale = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	continuous_cd = true
	can_sleep = false
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	if visual:
		gear_down = visual.gear_deployed
	Universe.origin_shifted.connect(_on_origin_shifted)
	if start_piloted:
		enter_pilot.call_deferred()


# =====================================================================================
# Pilot API
# =====================================================================================

func enter_pilot() -> void:
	if is_piloted:
		return
	is_piloted = true
	if visual:
		visual.set_hatch(false)
	if camera_rig and camera_rig.has_method("activate"):
		camera_rig.activate()
	Universe.set_focus(self)
	if not Capture.active and DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	pilot_entered.emit()


## Leaves the pilot seat. Returns the world transform at ExitPoint (on the ground, oriented
## to local up, facing the ship's heading). Only allowed when `can_exit()`; otherwise returns
## Transform3D.IDENTITY and stays piloted.
func exit_pilot() -> Transform3D:
	if not is_piloted or not can_exit():
		return Transform3D.IDENTITY
	is_piloted = false
	autopilot = false
	throttle = 0.0
	in_move = Vector3.ZERO
	in_stick = Vector2.ZERO
	_stick_raw = Vector2.ZERO
	in_roll = 0.0
	if visual:
		visual.set_hatch(true)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var xf := get_exit_transform()
	pilot_exited.emit(xf)
	return xf


## Moves the ship instantly (spawns, scripted shots, save/load). Robust against the physics
## server keeping a stale transform (also re-applied inside the next _integrate_forces).
func teleport(xf: Transform3D, v := Vector3.ZERO, frozen := false) -> void:
	freeze = frozen
	global_transform = xf
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	linear_velocity = Vector3.ZERO if frozen else v
	angular_velocity = Vector3.ZERO
	vel = v
	_prev_vel = v
	accel_world = Vector3.ZERO
	_disp = Vector3.ZERO
	_teleport = false
	_use_vel_once = not frozen
	_pending_xf = xf
	_has_pending_xf = true
	_update_environment()


func _on_origin_shifted(delta: Vector3) -> void:
	if _has_pending_xf:
		_pending_xf.origin -= delta


func can_exit() -> bool:
	return landed or vel.length() < 3.0


## World transform where the pilot appears on foot (ExitPoint snapped to the ground).
func get_exit_transform() -> Transform3D:
	var m: Node3D = visual.get_marker("ExitPoint") if visual else null
	var p: Vector3 = m.global_position if m else global_transform * Vector3(0, -GROUND_OFFSET, -3.8)
	var up := up_dir
	if body:
		var a := _ground_alt(body, p)
		if a < 50.0:
			p -= up * a
	p += up * 0.05
	var fwd := -global_basis.z
	fwd = (fwd - up * fwd.dot(up))
	if fwd.length_squared() < 1e-4:
		fwd = up.cross(global_basis.x)
	return Transform3D(Basis.looking_at(fwd.normalized(), up), p)


func get_pilot_seat_transform() -> Transform3D:
	var m: Node3D = visual.get_marker("PilotSeat") if visual else null
	return m.global_transform if m else global_transform


func get_camera() -> Camera3D:
	if camera_rig and camera_rig.has_method("get_active_camera"):
		return camera_rig.get_active_camera()
	return null


func get_hud_data() -> Dictionary:
	var tname := ""
	var tdist := -1.0
	if target and is_instance_valid(target):
		tname = target.get_body_name()
		tdist = maxf(target.global_position.distance_to(global_position) - target.get_body_radius(), 0.0)
	var vs := vel.dot(up_dir) if body else 0.0
	return {
		"speed": vel.length(),
		"vertical_speed": vs,
		"mode": mode,
		"mode_name": MODE_NAMES[mode],
		"mode_max_speed": speed_cap,
		"altitude": altitude if body else -1.0,
		"body_name": body.get_body_name() if body else "",
		"target_name": tname,
		"target_distance": tdist,
		"throttle": throttle,
		"gear_down": gear_down,
		"landed": landed,
		"flight_assist": flight_assist,
		"atmosphere_density": density,
		"heat": heat,
		"autopilot": autopilot,
		# extras
		"warp_state": warp_state,
		"warp_spool": warp_spool,
		"boost": in_boost,
		"mode_suggest": _mode_suggest,
		"gear_suggest": not gear_down and altitude < 150.0 and vel.length() < 40.0,
		"can_exit": can_exit(),
		"message": _message if _message_t > 0.0 else "",
	}


# =====================================================================================
# Commands (keys or other systems)
# =====================================================================================

func set_mode(m: int, quiet := false) -> bool:
	m = clampi(m, 0, Mode.WARP)
	if m == mode and not (m == Mode.WARP and warp_state == WarpState.IDLE):
		return true
	if m == Mode.CRUISE and not _cruise_allowed():
		if not quiet:
			_msg("CRUISE BLOCKED: " + ("ATMOSPHERE" if in_atmosphere else "TOO LOW"))
		return false
	if m == Mode.WARP:
		if _warp_locked():
			if not quiet:
				_msg("WARP: MASS LOCKED")
			return false
		if landed:
			return false
		warp_state = WarpState.SPOOL
		warp_spool = 0.0
		throttle = 1.0
		_msg("WARP DRIVE SPOOLING")
	else:
		if warp_state != WarpState.IDLE and mode == Mode.WARP:
			warp_state = WarpState.IDLE
			warp_spool = 0.0
			warp_dropped.emit()
	var old := mode
	mode = m
	var md: Dictionary = MODES[mode]
	throttle = clampf(throttle, md["rev"], 1.0)
	if old != mode:
		mode_changed.emit(mode)
		if not quiet and mode != Mode.WARP:
			_msg(MODE_NAMES[mode])
	return true


func cycle_mode() -> void:
	for i in range(1, 6):
		var m := (mode + i) % 5
		if set_mode(m, true):
			_msg(MODE_NAMES[m])
			return


func full_stop() -> void:
	throttle = 0.0
	autopilot = false
	_braking = true
	if mode == Mode.WARP:
		set_mode(Mode.CRUISE, true)
	_msg("ALL STOP")


func toggle_gear() -> void:
	set_gear(not gear_down)


func set_gear(down: bool, instant := false) -> void:
	if down == gear_down:
		return
	if not down and (landed or gear_contacts > 0):
		_msg("GEAR LOCKED: WEIGHT ON WHEELS")
		return
	gear_down = down
	if visual:
		visual.set_gear(down, instant)
	gear_changed.emit(down)


func toggle_flight_assist() -> void:
	flight_assist = not flight_assist
	_msg("FLIGHT ASSIST " + ("ON" if flight_assist else "OFF"))


func cycle_target() -> void:
	var bodies: Array[Node3D] = Universe.get_bodies().duplicate()
	if bodies.is_empty():
		target = null
		return
	var p := global_position
	bodies.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_squared_to(p) < b.global_position.distance_squared_to(p))
	var idx := bodies.find(target)
	target = bodies[(idx + 1) % bodies.size()]
	_msg("TARGET " + target.get_body_name())


func toggle_autopilot() -> void:
	if autopilot:
		autopilot = false
		steer_dir = Vector3.ZERO
		_msg("AUTOPILOT OFF")
		return
	if target == null or not is_instance_valid(target):
		cycle_target()
	if target == null:
		_msg("AUTOPILOT: NO TARGET")
		return
	if landed:
		_takeoff()
	autopilot = true
	_msg("AUTOPILOT → " + target.get_body_name())


## Safe arrival distance above a body's mean surface used by the autopilot.
func safe_orbit_altitude(b: Node3D) -> float:
	var ah: float = b.get_atmosphere_height()
	return maxf(maxf(2.0 * ah, 0.3 * b.get_body_radius()), 5000.0)


# =====================================================================================
# Input
# =====================================================================================

func _player_input_active() -> bool:
	return is_piloted and not scripted and not Capture.active


func _unhandled_input(event: InputEvent) -> void:
	if not _player_input_active():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var r: Vector2 = (event as InputEventMouseMotion).relative
		_stick_raw = (_stick_raw + Vector2(r.x, -r.y) * mouse_sensitivity).limit_length(1.0)
	elif event is InputEventMouseButton and event.is_pressed() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("speed_mode_next"):
		cycle_mode()
	elif event.is_action_pressed("ship_stop"):
		full_stop()
	elif event.is_action_pressed("gear_toggle"):
		toggle_gear()
	elif event.is_action_pressed("target_next"):
		cycle_target()
	elif event.is_action_pressed("autopilot"):
		toggle_autopilot()
	elif event.is_action_pressed("flight_assist_toggle"):
		toggle_flight_assist()
	elif event.is_action_pressed("camera_toggle"):
		if camera_rig and camera_rig.has_method("toggle_view"):
			camera_rig.toggle_view()
	else:
		for i in 5:
			if event.is_action_pressed("mode_%d" % (i + 1)):
				set_mode(i)


func _read_player_input(dt: float) -> void:
	in_move = Vector3(Input.get_axis("move_left", "move_right"), Input.get_axis("move_down", "move_up"),
		Input.get_axis("move_back", "move_forward"))
	in_roll = Input.get_axis("roll_right", "roll_left")
	in_boost = Input.is_action_pressed("boost")
	if mouse_return > 0.0:
		_stick_raw *= exp(-mouse_return * dt)
	in_stick = _stick_raw
	if in_move.z != 0.0 or in_move.y != 0.0:
		_braking = false
		if autopilot and (in_move.z != 0.0 or _stick_raw.length() > 0.3):
			autopilot = false
			steer_dir = Vector3.ZERO
			_msg("AUTOPILOT OFF")


# =====================================================================================
# Main loop
# =====================================================================================

func _physics_process(dt: float) -> void:
	_message_t -= dt
	impact = maxf(impact - dt * 2.5, 0.0)
	if capture_hold:
		_update_environment()
		return
	_update_environment()
	if _player_input_active():
		_read_player_input(dt)
	elif not scripted:
		in_move = Vector3.ZERO
		in_stick = Vector2.ZERO
		in_roll = 0.0
		in_boost = false
	if autopilot:
		_update_autopilot(dt)
	elif not scripted:
		steer_dir = Vector3.ZERO
	_update_throttle(dt)
	_update_mode_rules(dt)
	_update_landing(dt)
	boost_t = move_toward(boost_t, 1.0 if in_boost else 0.0, dt * 2.0)
	_update_heat(dt)
	_apply_teleport()


func _update_environment() -> void:
	var p := global_position
	nearest = Universe.get_nearest_body(p)
	body = Universe.get_dominant_body(p)
	if body == null:
		body = nearest
	if body:
		var bp := body.global_position
		up_dir = (p - bp).normalized()
		altitude = _ground_alt(body, p) - GROUND_OFFSET
		var ah: float = body.get_atmosphere_height()
		in_atmosphere = ah > 0.0 and p.distance_to(bp) - body.get_body_radius() < ah
	else:
		up_dir = Vector3.UP
		altitude = INF
		in_atmosphere = false
	surface_dist = INF
	if nearest:
		surface_dist = p.distance_to(nearest.global_position) - nearest.get_body_radius()
	density = Universe.get_atmosphere_density(p)
	speed_cap = _compute_cap()
	_mode_suggest = _suggest_mode()


func _compute_cap() -> float:
	var boost := 1.0 + (boost_mult - 1.0) * boost_t
	var cap := MODE_MAX[mode]
	match mode:
		Mode.HOVER, Mode.ATMOSPHERE:
			cap *= boost
		Mode.SPACE:
			cap = lerpf(5000.0, 800.0, smoothstep(0.0, 0.3, density)) * boost
		Mode.CRUISE:
			cap = clampf(CRUISE_K * _ref_alt(), MODE_MAX[Mode.SPACE], MODE_MAX[Mode.CRUISE])
		Mode.WARP:
			if warp_state == WarpState.ACTIVE:
				cap = clampf(WARP_K * (surface_dist - 2.0 * CRUISE_MIN_ALT), 0.0, MODE_MAX[Mode.WARP])
			else:
				cap = clampf(CRUISE_K * _ref_alt(), MODE_MAX[Mode.SPACE], MODE_MAX[Mode.CRUISE])
	if autopilot and target and is_instance_valid(target) and mode >= Mode.SPACE:
		var d: float = target.global_position.distance_to(global_position) - target.get_body_radius() \
			- safe_orbit_altitude(target)
		var k := WARP_K if mode == Mode.WARP else CRUISE_K * 1.6
		var ap_cap := maxf(k * d, sqrt(2.0 * 60.0 * maxf(d, 0.0)))
		cap = minf(cap, maxf(ap_cap, 30.0))
	return cap


## Altitude used by cruise/warp caps: distance to the closest surface.
func _ref_alt() -> float:
	return minf(surface_dist, altitude) if body else surface_dist


func _cruise_allowed() -> bool:
	return not in_atmosphere and _ref_alt() > CRUISE_MIN_ALT


func _warp_locked() -> bool:
	return surface_dist < WARP_LOCK_DIST


func _suggest_mode() -> int:
	var s := vel.length()
	if body == null:
		return -1
	if altitude < 300.0 and s < 60.0 and mode != Mode.HOVER:
		return Mode.HOVER
	if in_atmosphere and density > 0.02 and mode >= Mode.SPACE and s < 650.0:
		return Mode.ATMOSPHERE
	if not in_atmosphere and mode <= Mode.ATMOSPHERE and altitude > 2000.0:
		return Mode.SPACE
	return -1


func _update_throttle(dt: float) -> void:
	var md: Dictionary = MODES[mode]
	if mode == Mode.HOVER or not flight_assist:
		throttle = move_toward(throttle, in_move.z if in_move.z >= 0.0 else in_move.z * absf(md["rev"]), dt * 4.0)
	elif not autopilot:
		throttle = clampf(throttle + in_move.z * float(md["thr"]) * dt, md["rev"], 1.0)
	if _braking and vel.length() < 0.5:
		_braking = false


func _update_mode_rules(dt: float) -> void:
	if mode == Mode.CRUISE and not _cruise_allowed():
		set_mode(Mode.SPACE, true)
		_msg("CRUISE DISENGAGED")
	if mode == Mode.WARP:
		match warp_state:
			WarpState.SPOOL:
				warp_spool = minf(warp_spool + dt / WARP_SPOOL_TIME, 1.0)
				throttle = 1.0
				if _warp_locked():
					set_mode(Mode.CRUISE if _cruise_allowed() else Mode.SPACE, true)
					_msg("WARP ABORTED: MASS LOCK")
				elif warp_spool >= 1.0:
					warp_state = WarpState.ACTIVE
					warp_engaged.emit()
					_msg("WARP")
			WarpState.ACTIVE:
				if speed_cap < MODE_MAX[Mode.CRUISE] and vel.length() < MODE_MAX[Mode.CRUISE] * 1.05:
					set_mode(Mode.CRUISE if _cruise_allowed() else Mode.SPACE, true)
					_msg("WARP DROP")
	elif warp_state != WarpState.IDLE:
		warp_state = WarpState.IDLE
		warp_spool = 0.0


func _update_landing(dt: float) -> void:
	if landed:
		var wants_off := in_move.y > 0.2 or (throttle > 0.05 and mode != Mode.HOVER) or in_move.z > 0.3 \
			or autopilot or mode >= Mode.CRUISE
		if wants_off and (is_piloted or scripted):
			_takeoff()
		return
	var s := vel.length()
	if gear_contacts >= 3 and s < 0.8 and angular_velocity.length() < 0.15 and in_move.y <= 0.05 \
			and in_move.z <= 0.05:
		_land_timer += dt
	else:
		_land_timer = 0.0
	if _land_timer > 0.5:
		landed = true
		_land_timer = 0.0
		throttle = 0.0
		freeze = true
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		vel = Vector3.ZERO
		if mode != Mode.HOVER:
			set_mode(Mode.HOVER, true)
		landed_changed.emit(true)
		_msg("LANDED · CLAMPS ENGAGED")
	# auto gear retract once flying fast
	if auto_gear and gear_down and gear_contacts == 0 and s > 140.0 \
			and (is_piloted or scripted) and visual and not visual.is_gear_moving():
		set_gear(false)
		_msg("GEAR UP")
	# auto gear deploy for a slow, low descent
	if auto_gear and not gear_down and mode == Mode.HOVER and altitude < 25.0 and s < 20.0 \
			and (is_piloted or scripted):
		set_gear(true)
		_msg("GEAR AUTO-DEPLOY")


func _takeoff() -> void:
	landed = false
	freeze = false
	_land_timer = 0.0
	var v0 := up_dir * 2.5
	linear_velocity = v0
	vel = v0
	landed_changed.emit(false)
	_msg("CLAMPS RELEASED")


func _update_heat(dt: float) -> void:
	var s := vel.length()
	var target_heat := clampf(sqrt(density) * pow(s / 1500.0, 2.0) * 0.8 - 0.1, 0.0, 1.0)
	heat = lerpf(heat, target_heat, 1.0 - exp(-dt * (1.2 if target_heat > heat else 0.45)))
	var target_vapor := clampf((s - 180.0) / 220.0, 0.0, 1.0) * clampf((density - 0.2) / 0.4, 0.0, 1.0) \
		* clampf((900.0 - s) / 200.0, 0.0, 1.0)
	vapor = lerpf(vapor, target_vapor, 1.0 - exp(-dt * 3.0))


func _update_autopilot(_dt: float) -> void:
	if target == null or not is_instance_valid(target):
		autopilot = false
		return
	var to := target.global_position - global_position
	var d := to.length()
	var dsurf: float = d - target.get_body_radius()
	var orbit := safe_orbit_altitude(target)
	var aim := to / maxf(d, 1.0)
	steer_dir = aim
	steer_up = Vector3.ZERO
	if dsurf <= orbit * 1.03:
		autopilot = false
		steer_dir = Vector3.ZERO
		throttle = 0.0
		_braking = true
		if mode > Mode.SPACE:
			set_mode(Mode.SPACE, true)
		_msg("AUTOPILOT: ARRIVED · " + target.get_body_name())
		return
	var fwd := -global_basis.z
	var ang := rad_to_deg(fwd.angle_to(aim))
	var s := vel.length()
	if ang < 4.0:
		throttle = 1.0
		if mode != Mode.WARP and not _warp_locked() and dsurf - orbit > 2.0 * WARP_LOCK_DIST:
			set_mode(Mode.WARP, true)
		elif mode < Mode.CRUISE and _cruise_allowed() and dsurf - orbit > 40000.0:
			set_mode(Mode.CRUISE, true)
		elif mode < Mode.SPACE:
			set_mode(Mode.SPACE, true)
	else:
		# turn first; bleed speed if we would fly off course
		throttle = clampf(1.0 - ang / 30.0, 0.0, 1.0) if s < 2000.0 else 0.0


# =====================================================================================
# Physics
# =====================================================================================

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if capture_hold:
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return
	if _has_pending_xf:
		state.transform = _pending_xf
		_has_pending_xf = false
	var dt := state.step
	var xf := state.transform
	var B := xf.basis.orthonormalized()
	var Bt := B.transposed()
	var pos := xf.origin
	var v: Vector3 = vel if (_teleport or _use_vel_once) else state.linear_velocity
	_use_vel_once = false
	var md: Dictionary = MODES[mode]
	var speed := v.length()
	var g := Universe.get_gravity(pos)
	var lv := Bt * v
	var boost := 1.0 + (boost_mult - 1.0) * boost_t
	var acc_f: float = (float(md["acc"]) + float(md["acc_k"]) * speed) * boost
	var lat: float = float(md["lat"]) + float(md["lat_k"]) * speed
	var wow := gear_contacts > 0

	# --- aerodynamics (simplified): quadratic drag + "weathervane" lift aligning v with the nose
	var a_aero := Vector3.ZERO
	if density > 0.0 and speed > 1.0:
		a_aero = -v * speed * density * drag_k
		var fwd := -B.z
		var v_perp := v - fwd * v.dot(fwd)
		a_aero -= v_perp * density * lift_k * clampf(speed / 150.0, 0.0, 1.0) * (0.25 if flight_assist else 1.0)

	# --- translational control
	var assist := flight_assist or _braking or not (is_piloted or scripted)
	var a_loc := Vector3.ZERO
	if assist:
		var strafe: float = md["strafe"]
		var vt := Vector3(in_move.x * strafe, in_move.y * strafe, -throttle * speed_cap)
		if _braking:
			vt = Vector3.ZERO
		if mode >= Mode.CRUISE:
			vt.x = 0.0
			vt.y = 0.0
		var comp := -g - a_aero
		if wow and in_move.y <= 0.05 and throttle <= 0.05:
			comp = Vector3.ZERO   # weight on wheels: let the gear carry the ship
		a_loc = (vt - lv) / float(md["tau"]) + Bt * comp
	else:
		a_loc = Vector3(in_move.x * lat, in_move.y * lat, -in_move.z * acc_f)
	var back := acc_f * (1.0 if mode >= Mode.CRUISE else 0.6)
	var lat_lim := maxf(lat, 1.0)
	if mode == Mode.HOVER or mode == Mode.ATMOSPHERE:
		lat_lim = maxf(lat, g.length() * 1.6)   # VTOL lift
	a_loc = Vector3(clampf(a_loc.x, -lat_lim, lat_lim), clampf(a_loc.y, -lat_lim, lat_lim),
		clampf(a_loc.z, -acc_f, back))
	thrust_local = a_loc
	thrust_norm = Vector3(a_loc.x / lat_lim, a_loc.y / lat_lim, a_loc.z / (acc_f if a_loc.z < 0.0 else back))
	v += (B * a_loc + g + a_aero) * dt

	# --- ground proximity limiter (assist): never descend faster than we can stop
	if assist and body and altitude < 3000.0 and not _teleport:
		var vdown := -v.dot(up_dir)
		var allowed := sqrt(2.0 * 6.0 * maxf(altitude - 0.3, 0.0)) + 1.2
		if vdown > allowed:
			v += up_dir * (vdown - allowed) * minf(1.0, dt * 6.0)

	# --- speed cap
	speed = v.length()
	var vmax := speed_cap * 1.01
	if speed > vmax:
		var ns := maxf(vmax, speed - (float(md["acc"]) * 1.5 + speed * 2.2) * dt)
		v *= ns / speed

	# --- rotation
	var rate: Vector3 = md["rate"] * (PI / 180.0)
	var st := _shape_stick(in_stick)
	var wt := Vector3(st.y * rate.x, -st.x * rate.y, in_roll * rate.z)
	if steer_dir != Vector3.ZERO:
		wt = _steer_rates(B, steer_dir, steer_up, rate)
	elif assist and body and not landed and (mode == Mode.HOVER or (altitude < 400.0 and speed < 90.0)):
		# auto-level toward local up when hovering / landing (player input overrides)
		var err := Bt * B.y.cross(up_dir)
		wt.x += err.x * 2.2 * (1.0 - absf(st.y))
		wt.z += err.z * 2.2 * (1.0 - absf(in_roll))
	var w := Bt * state.angular_velocity
	var alpha := rate * 4.0
	var dw := wt - w
	dw = Vector3(clampf(dw.x, -alpha.x * dt, alpha.x * dt), clampf(dw.y, -alpha.y * dt, alpha.y * dt),
		clampf(dw.z, -alpha.z * dt, alpha.z * dt))
	if wow:
		dw.x *= 0.1
		dw.z *= 0.1
		dw.y *= 0.4
	ang_accel_local = dw / dt
	w += dw
	if wow:
		w.x *= exp(-3.0 * dt)
		w.z *= exp(-3.0 * dt)
	state.angular_velocity = B * w

	# --- teleport (high speed): body parked, displacement applied by origin shift
	if _teleport:
		state.linear_velocity = Vector3.ZERO
		_disp += v * dt
		_finish_velocity(v, dt)
		return
	state.linear_velocity = v

	# --- landing gear suspension (analytic ground)
	gear_contacts = 0
	if gear_down and body and altitude < 4.0 and visual and not visual.is_gear_moving():
		_suspension(state, B, pos, dt)
	# --- last-resort hull clamp (terrain collision chunk missing / water)
	if body and altitude < 25.0:
		_hull_clamp(state, B)
	_finish_velocity(state.linear_velocity, dt)


func _finish_velocity(v: Vector3, dt: float) -> void:
	accel_world = accel_world.lerp((v - _prev_vel) / dt, 0.2)
	_prev_vel = v
	vel = v


func _suspension(state: PhysicsDirectBodyState3D, B: Basis, pos: Vector3, dt: float) -> void:
	var m := mass
	for f in FEET:
		var r := B * f
		var fw := pos + r
		var h := _ground_alt(body, fw)
		if h >= 0.0:
			continue
		var up := (fw - body.global_position).normalized()
		var pen := -h
		gear_contacts += 1
		var vp := state.linear_velocity + state.angular_velocity.cross(r)
		var vn := vp.dot(up)
		var fn := maxf(gear_stiffness * minf(pen, GEAR_TRAVEL) - gear_damping * vn, 0.0)
		if pen > GEAR_TRAVEL and vn < 0.0:
			# bottomed out: rigid stop
			fn += -vn * m / 3.0 / dt
			impact = maxf(impact, clampf(-vn / 8.0, 0.0, 1.0))
		var jn := up * fn * dt
		# Coulomb friction at the pad (static up to mu*N)
		var vt := vp - up * vn
		var jt := -vt * (m / 3.0)
		var jmax := gear_friction * fn * dt
		if jt.length() > jmax:
			jt = jt.normalized() * jmax
		state.apply_impulse(jn + jt, r)


func _hull_clamp(state: PhysicsDirectBodyState3D, B: Basis) -> void:
	var pos := state.transform.origin
	var worst := 0.0
	for hp in HULL_PROBES:
		var h := _ground_alt(body, pos + B * hp)
		worst = minf(worst, h)
	if worst > -0.25:
		return
	var up := up_dir
	var v := state.linear_velocity
	var vn := v.dot(up)
	if vn < 0.0:
		impact = maxf(impact, clampf(-vn / 15.0, 0.0, 1.0))
		v -= up * vn * 1.25          # small bounce
		v -= (v - up * v.dot(up)) * 0.25
	state.linear_velocity = v
	state.angular_velocity *= 0.8
	var t := state.transform
	t.origin += up * (-worst)
	state.transform = t


## Shapes the virtual-joystick stick: deadzone + expo curve.
func _shape_stick(s: Vector2) -> Vector2:
	var l := s.length()
	if l < stick_deadzone:
		return Vector2.ZERO
	var k := (l - stick_deadzone) / (1.0 - stick_deadzone)
	return s / l * pow(minf(k, 1.0), stick_expo)


## Local angular-velocity target that turns the nose toward `dir` (and roll toward `up`).
func _steer_rates(B: Basis, dir: Vector3, up: Vector3, rate: Vector3) -> Vector3:
	var Bt := B.transposed()
	var fwd := -B.z
	var axis := fwd.cross(dir.normalized())
	var ang := fwd.angle_to(dir.normalized())
	var w := Vector3.ZERO
	if axis.length_squared() > 1e-10:
		w = Bt * (axis.normalized() * ang * 2.5)
	elif ang > 3.0:
		w = Vector3(rate.x, 0, 0)     # exactly backwards: pitch over
	var ref_up := up if up != Vector3.ZERO else up_dir
	if body or up != Vector3.ZERO:
		var u := ref_up - fwd * ref_up.dot(fwd)
		if u.length_squared() > 1e-4:
			var e := Bt * B.y.cross(u.normalized())
			w.z += e.z * 1.5
	return Vector3(clampf(w.x, -rate.x, rate.x), clampf(w.y, -rate.y, rate.y), clampf(w.z, -rate.z, rate.z))


## Ground altitude (terrain or ocean surface, whichever is higher) of a world point.
func _ground_alt(b: Node3D, p: Vector3) -> float:
	var d := p.distance_to(b.global_position)
	var a: float
	if b.has_method("get_altitude_global"):
		a = b.get_altitude_global(p)
	else:
		a = d - b.get_body_radius()
	var orad := _ocean_radius(b)
	if orad > 0.0:
		a = minf(a, d - orad)
	return a


func _ocean_radius(b: Node3D) -> float:
	var id := b.get_instance_id()
	if not _ocean_r.has(id):
		var r := 0.0
		var cfg: Variant = b.get("config")
		if cfg is Object and (cfg as Object).has_method("get_ocean_radius"):
			r = float((cfg as Object).call("get_ocean_radius"))
		_ocean_r[id] = r
	return _ocean_r[id]


## High-speed travel: move by `_disp` and re-centre the floating origin on the ship in the same
## tick (no frame is ever rendered far from the origin). Swept test against every body.
func _apply_teleport() -> void:
	var s := vel.length()
	var want := s > TELEPORT_SPEED and not landed and not freeze
	if want != _teleport:
		if not want:
			_use_vel_once = true
		_teleport = want
	if _disp == Vector3.ZERO:
		return
	var d := _disp
	_disp = Vector3.ZERO
	var p := global_position
	for b in Universe.get_bodies():
		var guard: float = b.get_body_radius() * 1.15 + CRUISE_MIN_ALT
		var c: Vector3 = b.global_position - p
		var t := clampf(c.dot(d) / maxf(d.length_squared(), 1e-9), 0.0, 1.0)
		if (c - d * t).length() < guard and c.length() > guard:
			# would enter the guard sphere: stop at its boundary and drop to space speed
			var dl := d.length()
			var dn := d / dl
			var tc := c.dot(dn)
			var h2 := guard * guard - (c.length_squared() - tc * tc)
			var t_hit := tc - sqrt(maxf(h2, 0.0))
			d = dn * maxf(t_hit - 100.0, 0.0)
			vel = dn * MODE_MAX[Mode.SPACE] * 0.9
			set_mode(Mode.SPACE, true)
			_msg("EMERGENCY DROP")
	global_position = p + d
	if Universe.world_root and get_parent() == Universe.world_root and Universe.focus == self:
		Universe.shift_origin(global_position)


func _msg(t: String) -> void:
	_message = t
	_message_t = 3.0
	hud_message.emit(t)
