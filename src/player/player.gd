class_name Player
extends CharacterBody3D
## On-foot astronaut. Works anywhere on a spherical body: every physics frame the local "up" and
## gravity come from Universe (dominant body), the body is re-aligned smoothly to that up and the
## horizontal velocity is parallel-transported along the sphere, so walking "forward" follows a
## great circle — including the underside of a planet.
##
## Node origin = feet. Children (player.tscn): CollisionShape3D (capsule), Head (pitch) with
## Camera (first person) and TPArm (SpringArm3D) / TPCamera (third person). The astronaut model is
## built from primitives in `_build_model()` on visual layer MODEL_LAYER, which the first-person
## camera does not render (you still see your own shadow).
##
## Input (Controls actions): move_* (WASD), boost (sprint), move_up (jump), camera_toggle (C),
## mouse motion (look) while the mouse is captured. GameMode toggles `set_active()`.
##
## Safety net: if the analytic terrain height (body.get_altitude_global) says the feet are clearly
## below ground (collision for that chunk not streamed in yet), the player is lifted back onto the
## analytic surface and treated as grounded (`rescue_count` counts this; tests watch it).

signal camera_mode_changed(third_person: bool)
signal landed(fall_speed: float)

const MODEL_LAYER := 1 << 19   # visual layer 20: own body, hidden from the first-person camera

@export_group("Movement")
@export var walk_speed := 4.2
@export var sprint_speed := 8.0
@export var accel_ground := 38.0
@export var decel_ground := 30.0
@export var accel_air := 5.0
@export var jump_height := 1.0
## Used when no body is near (deep space): no gravity at all.
@export var fallback_gravity := 0.0
@export var align_rate := 9.0          ## 1/s: how fast the body follows the local up
@export var max_fall_speed := 80.0
## Ledges up to this height are climbed automatically (rocks, terrain LOD seams).
@export var step_height := 0.35
## Still counts as grounded this long after leaving the floor (crests, ledge edges).
@export var coyote_time := 0.12
## Feet this close to the analytic ground while not rising count as grounded (edge contacts).
@export var edge_rest_height := 0.12

@export_group("Look")
@export var mouse_sensitivity := 0.0022
@export var pitch_limit_deg := 86.0
@export var eye_height := 1.62
@export var head_bob := 1.0            ## 0 disables
@export var third_person := false
@export var tp_distance := 3.4
@export var fov := 72.0

@export_group("Safety")
@export var rescue_depth := 0.3        ## m below analytic ground before the safety net lifts us

var input_enabled := true
## Test/scripted input (tools/dev/test_onfoot.gd): when true, `sim_move` etc. replace devices.
var use_sim_input := false
var sim_move := Vector2.ZERO          # x = right, y = back (same as Input.get_vector)
var sim_sprint := false
var sim_jump := false

var rescue_count := 0
var step_count := 0
var step_fail := ""   # debug: why the last step-up attempt failed
var analytic_grounded := false
var current_up := Vector3.UP
var current_gravity := Vector3.ZERO
var altitude := INF                    # above analytic terrain, m (INF if no body)

var _pitch := 0.0
var _bob_phase := 0.0
var _bob_amount := 0.0
var _land_dip := 0.0
var _was_grounded := false
var _air_time := 0.0
var _jumped := false
var _last_vert_speed := 0.0
var _step_side := 0
var _model: Node3D
var _legs: Array[Node3D] = []
var _arms: Array[Node3D] = []
var _dust: Array[CPUParticles3D] = []

@onready var head: Node3D = $Head
@onready var fp_camera: Camera3D = $Head/Camera
@onready var tp_arm: SpringArm3D = $Head/TPArm
@onready var tp_camera: Camera3D = $Head/TPArm/TPCamera


func _ready() -> void:
	head.position = Vector3(0, eye_height, 0)
	fp_camera.fov = fov
	tp_camera.fov = fov
	fp_camera.cull_mask &= ~MODEL_LAYER
	tp_arm.spring_length = tp_distance
	tp_arm.add_excluded_object(get_rid())
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.45
	floor_constant_speed = true
	floor_stop_on_slope = true
	floor_block_on_wall = true
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	_build_model()
	_build_dust()
	if not Universe.origin_shifted.is_connected(_on_origin_shifted):
		Universe.origin_shifted.connect(_on_origin_shifted)
	_apply_camera_mode()


# ------------------------------------------------------------------ public API

## Enables/disables input, physics and this player's camera.
func set_active(on: bool) -> void:
	input_enabled = on
	set_physics_process(on)
	visible = on
	if on:
		get_camera().make_current()
	else:
		fp_camera.current = false
		tp_camera.current = false


func get_camera() -> Camera3D:
	return tp_camera if third_person else fp_camera


func set_third_person(on: bool) -> void:
	third_person = on
	_apply_camera_mode()
	camera_mode_changed.emit(on)


## Places the feet at `xform.origin`, upright to the local up, facing xform's -Z (projected).
func place_at(xform: Transform3D) -> void:
	global_position = xform.origin
	var up := Universe.get_up(xform.origin)
	var fwd := -xform.basis.z
	_orient(up, fwd)
	velocity = Vector3.ZERO
	_pitch = 0.0
	head.rotation = Vector3.ZERO
	current_up = up
	up_direction = up


## Turns body (yaw) and head (pitch) to look at a world point.
func look_at_point(world_pos: Vector3) -> void:
	var up := global_basis.y
	var eye := head.global_position
	var d := (world_pos - eye).normalized()
	var flat := d - up * d.dot(up)
	if flat.length() > 1e-4:
		_orient(up, flat)
	_pitch = clampf(asin(clampf(d.dot(up), -1.0, 1.0)), -deg_to_rad(pitch_limit_deg), deg_to_rad(pitch_limit_deg))
	head.rotation = Vector3(_pitch, 0, 0)


func set_pitch_deg(deg: float) -> void:
	_pitch = deg_to_rad(clampf(deg, -pitch_limit_deg, pitch_limit_deg))
	head.rotation = Vector3(_pitch, 0, 0)


## Grounded for control purposes: real floor contact, the analytic safety net, coyote time after
## leaving the floor, or resting on a ledge edge (contact too steep to count as floor, but the feet
## are within a few cm of the ground and not moving up).
func is_grounded() -> bool:
	if is_on_floor() or analytic_grounded:
		return true
	if _jumped:
		return false
	if _air_time < coyote_time:
		return true
	return altitude < edge_rest_height and _last_vert_speed <= 0.5


## Forward direction on the local horizontal plane (unit).
func get_flat_forward() -> Vector3:
	var f := -global_basis.z
	return (f - current_up * f.dot(current_up)).normalized()


func get_horizontal_speed() -> float:
	return (velocity - current_up * velocity.dot(current_up)).length()


## Render-side extrapolation within the physics tick (smooth camera / model on high-refresh
## displays, physics stays at 60 Hz; see ShipCameraRig.render_extrapolation).
@export var render_extrapolation := true
var _model_base := Vector3.ZERO


func _process(_dt: float) -> void:
	var off := Vector3.ZERO
	if render_extrapolation and input_enabled and is_physics_processing():
		var h := Engine.get_physics_interpolation_fraction() / float(Engine.physics_ticks_per_second)
		off = global_basis.inverse() * (velocity * h)
	head.position = Vector3(0, eye_height, 0) + off
	if _model:
		_model.position = _model_base + off


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		var ms := mouse_sensitivity * Controls.mouse_scale
		rotate_yaw(-mm.relative.x * ms)
		_pitch = clampf(_pitch - mm.relative.y * ms,
			-deg_to_rad(pitch_limit_deg), deg_to_rad(pitch_limit_deg))
		head.rotation = Vector3(_pitch, 0, 0)
	elif event.is_action_pressed("camera_toggle") and not event.is_echo():
		set_third_person(not third_person)
		get_viewport().set_input_as_handled()


func rotate_yaw(angle: float) -> void:
	global_basis = (Basis(global_basis.y, angle) * global_basis).orthonormalized()


func _read_move() -> Vector2:
	if use_sim_input:
		return sim_move.limit_length(1.0)
	if not input_enabled:
		return Vector2.ZERO
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func _read_sprint() -> bool:
	if use_sim_input:
		return sim_sprint
	return input_enabled and Input.is_action_pressed("boost")


func _read_jump() -> bool:
	if use_sim_input:
		var j := sim_jump
		sim_jump = false
		return j
	return input_enabled and Input.is_action_just_pressed("move_up")


# ------------------------------------------------------------------ physics

func _physics_process(dt: float) -> void:
	var pos := global_position
	var target_up := Universe.get_up(pos)
	var g := Universe.get_gravity(pos)
	if g == Vector3.ZERO and fallback_gravity > 0.0:
		g = -target_up * fallback_gravity
	current_gravity = g

	# 1) Re-align to the local up (smooth; snaps faster when far off, e.g. after a teleport).
	var prev_up := current_up
	var cur_up := global_basis.y
	var ang := cur_up.angle_to(target_up)
	if ang > 1e-5:
		var k := 1.0 - exp(-align_rate * dt * (1.0 + ang * 4.0))
		_rotate_body(cur_up, target_up, ang * k)
	current_up = target_up
	up_direction = target_up
	# Parallel-transport velocity with the change of the up vector (keeps "forward" on a great circle).
	var dang := prev_up.angle_to(target_up)
	if dang > 1e-7 and dang < 0.5:
		velocity = Basis(prev_up.cross(target_up).normalized(), dang) * velocity

	# 2) Horizontal control.
	var up := target_up
	var v_vert := up * velocity.dot(up)
	var v_h := velocity - v_vert
	var mv := _read_move()
	var fwd := -global_basis.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up)
	var speed := sprint_speed if _read_sprint() else walk_speed
	var wish := (right * mv.x - fwd * mv.y) * speed
	var grounded := is_grounded()
	if grounded:
		var rate := accel_ground if wish.length_squared() > 0.01 else decel_ground
		v_h = v_h.move_toward(wish, rate * dt)
	else:
		var dv := (wish - v_h)
		if wish.length_squared() < 0.01:
			dv = Vector3.ZERO
		v_h += dv.limit_length(accel_air * dt)

	# 3) Gravity and jump.
	var gmag := g.length()
	if grounded:
		if _read_jump() and gmag > 0.01:
			v_vert = up * sqrt(2.0 * gmag * jump_height)
			grounded = false
			analytic_grounded = false
			_jumped = true
		elif is_on_floor() or analytic_grounded:
			# On the floor the slope is handled by move_and_slide + snapping; never keep an
			# upward component (walking up a crest would otherwise launch us), just press down
			# with one frame of gravity so floor contact stays continuous on a curved surface.
			v_vert = g * dt
		else:
			# coyote / ledge edge: full control, but keep falling naturally
			if v_vert.dot(up) > 0.0:
				v_vert = Vector3.ZERO
			v_vert += g * dt
	else:
		v_vert += g * dt
		if v_vert.dot(up) < -max_fall_speed:
			v_vert = -up * max_fall_speed
	velocity = v_h + v_vert
	_last_vert_speed = velocity.dot(up)
	floor_snap_length = 0.45 + clampf(v_h.length() * 0.06, 0.0, 0.6)
	var pre_slide := global_position
	move_and_slide()
	if grounded and is_on_wall() and wish.length_squared() > 0.01:
		if _try_step_up(pre_slide, v_h * dt, up):
			velocity = v_h

	# 4) Analytic ground safety net.
	analytic_grounded = false
	var body := Universe.get_dominant_body(global_position)
	altitude = INF
	if body != null and body.has_method("get_altitude_global"):
		altitude = float(body.get_altitude_global(global_position))
		if not is_on_floor() and altitude < 0.02:
			if altitude < -rescue_depth:
				rescue_count += 1
				global_position += up * (-altitude)
				altitude = 0.0
			if velocity.dot(up) <= 0.0:
				velocity -= up * velocity.dot(up)
				analytic_grounded = altitude < 0.05

	# 5) Feedback: landing dip, head bob, limbs, dust.
	if is_on_floor() or analytic_grounded:
		_air_time = 0.0
		_jumped = false
	else:
		_air_time += dt
	var now_grounded := is_grounded()
	if now_grounded and not _was_grounded:
		var fall := -_last_vert_speed
		_land_dip = clampf(fall * 0.025, 0.0, 0.12)
		landed.emit(fall)
	_was_grounded = now_grounded
	_update_feedback(dt, now_grounded)


## Climbs small ledges (rocks, terrain LOD seams) up to `step_height`: if the slide was blocked
## by a wall, retry the horizontal motion from `step_height` higher and snap back down.
func _try_step_up(from: Vector3, motion: Vector3, up: Vector3) -> bool:
	var done := global_position - from
	done -= up * done.dot(up)
	var remaining := motion - done
	if remaining.length() < motion.length() * 0.3:
		step_fail = "glancing"
		return false   # mostly moved: glancing wall contact, nothing to climb
	# probe at least a few cm forward so the capsule clears the ledge edge
	var probe := motion.normalized() * maxf(motion.length(), 0.12)
	var lift := up * step_height
	var xf := global_transform
	xf.origin = from
	if test_move(xf, lift):
		step_fail = "headroom"
		return false
	xf.origin += lift
	if test_move(xf, probe):
		step_fail = "wall"
		return false   # still blocked higher up: a real wall
	xf.origin += probe
	# drop back onto the ledge
	var col := KinematicCollision3D.new()
	if not test_move(xf, -lift * 1.5, col):
		step_fail = "no_ground"
		return false   # nothing below (edge of a drop): let normal physics handle it
	xf.origin += col.get_travel()
	var gain := (xf.origin - from).dot(up)
	if col.get_normal().dot(up) < 0.3 or gain > step_height or gain < -0.05:
		step_fail = "bad_landing"
		return false
	global_position = xf.origin
	step_count += 1
	return true


func _rotate_body(from_up: Vector3, to_up: Vector3, angle: float) -> void:
	var axis := from_up.cross(to_up)
	if axis.length_squared() < 1e-12:
		axis = global_basis.x   # exactly opposite: flip over the side axis
	global_basis = (Basis(axis.normalized(), angle) * global_basis).orthonormalized()


func _orient(up: Vector3, fwd: Vector3) -> void:
	var f := fwd - up * fwd.dot(up)
	if f.length_squared() < 1e-6:
		f = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	f = f.normalized()
	var x := f.cross(up).normalized()
	global_basis = Basis(x, up, -f)


func _on_origin_shifted(_delta: Vector3) -> void:
	# Nothing cached in world space except particles (they live in world space and shift with
	# their parent only when local_coords is set); clear them to avoid a visible jump.
	for d in _dust:
		d.restart()
		d.emitting = false


# ------------------------------------------------------------------ cameras / feedback

func _apply_camera_mode() -> void:
	if not is_inside_tree():
		return
	var was_current := fp_camera.current or tp_camera.current
	if _model:
		_model.visible = true
	if was_current or input_enabled:
		get_camera().make_current()


func _update_feedback(dt: float, grounded: bool) -> void:
	var hs := get_horizontal_speed()
	var moving := grounded and hs > 0.5
	_bob_amount = move_toward(_bob_amount, clampf(hs / sprint_speed, 0.0, 1.0) if moving else 0.0, dt * 3.0)
	var prev_phase := _bob_phase
	if moving:
		_bob_phase += dt * (5.2 + hs * 0.55)
	_land_dip = move_toward(_land_dip, 0.0, dt * 0.35)
	var bob := head_bob * _bob_amount
	fp_camera.position = Vector3(sin(_bob_phase) * 0.028 * bob,
		absf(cos(_bob_phase)) * 0.045 * bob - _land_dip, 0)
	fp_camera.rotation = Vector3(0, 0, sin(_bob_phase) * 0.006 * bob)
	# limbs swing with the step phase
	var swing := sin(_bob_phase) * 0.55 * clampf(_bob_amount * 1.8, 0.0, 1.0)
	if not grounded:
		swing = 0.25
	for i in _legs.size():
		_legs[i].rotation.x = swing * (1.0 if i == 0 else -1.0)
	for i in _arms.size():
		_arms[i].rotation.x = -swing * 0.7 * (1.0 if i == 0 else -1.0)
	# footstep puff each half cycle
	if moving and floor(prev_phase / PI) != floor(_bob_phase / PI) and not _dust.is_empty():
		_step_side = 1 - _step_side
		var d := _dust[_step_side]
		d.global_transform = Transform3D(global_basis, global_position + global_basis.x * (0.14 if _step_side == 1 else -0.14))
		d.restart()


func _build_dust() -> void:
	for i in 2:
		var p := CPUParticles3D.new()
		p.name = "Dust%d" % i
		p.top_level = true
		p.local_coords = false
		p.one_shot = true
		p.emitting = false
		p.amount = 10
		p.lifetime = 1.4
		p.explosiveness = 0.9
		p.direction = Vector3(0, 1, 0)
		p.spread = 70.0
		p.initial_velocity_min = 0.15
		p.initial_velocity_max = 0.5
		p.gravity = Vector3(0, -0.3, 0)
		p.damping_min = 0.6
		p.damping_max = 1.2
		p.scale_amount_min = 0.5
		p.scale_amount_max = 1.2
		var curve := Curve.new()
		curve.add_point(Vector2(0, 0.3))
		curve.add_point(Vector2(0.3, 1.0))
		curve.add_point(Vector2(1, 1.4))
		p.scale_amount_curve = curve
		var grad := Gradient.new()
		grad.set_color(0, Color(0.55, 0.53, 0.5, 0.22))
		grad.set_color(1, Color(0.55, 0.53, 0.5, 0.0))
		p.color_ramp = grad
		var q := QuadMesh.new()
		q.size = Vector2(0.18, 0.18)
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _soft_dot()
		q.material = m
		p.mesh = q
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_dust.append(p)


static func _soft_dot() -> GradientTexture2D:
	var t := GradientTexture2D.new()
	t.width = 32
	t.height = 32
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	t.gradient = g
	return t


# ------------------------------------------------------------------ astronaut model (primitives)

func _mat(col: Color, rough := 0.65, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _part(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	mi.layers = MODEL_LAYER
	parent.add_child(mi)
	return mi


func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 20
	c.rings = 6
	return c


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 28
	s.rings = 14
	return s


func _box(sz: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = sz
	return b


func _cyl(r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = 20
	return c


func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	add_child(_model)
	var suit := _mat(Color(0.86, 0.86, 0.83), 0.72)
	var suit_dark := _mat(Color(0.22, 0.23, 0.25), 0.55, 0.3)
	var accent := _mat(Color(0.95, 0.42, 0.08), 0.5)
	var metal := _mat(Color(0.62, 0.64, 0.67), 0.32, 0.9)
	var visor := _mat(Color(0.95, 0.68, 0.28), 0.06, 1.0)
	visor.clearcoat_enabled = true
	visor.clearcoat = 1.0
	visor.clearcoat_roughness = 0.02
	var glow := _mat(Color(0.3, 0.9, 1.0), 0.4)
	glow.emission_enabled = true
	glow.emission = Color(0.3, 0.9, 1.0)
	glow.emission_energy_multiplier = 3.0

	# torso
	_part(_model, _capsule(0.24, 0.78), suit, Vector3(0, 1.22, 0), Vector3.ZERO, Vector3(1.0, 1.0, 0.8))
	_part(_model, _cyl(0.245, 0.09), suit_dark, Vector3(0, 0.93, 0), Vector3.ZERO, Vector3(1.0, 1.0, 0.82))   # belt
	_part(_model, _box(Vector3(0.2, 0.13, 0.05)), suit_dark, Vector3(0, 1.3, -0.2))          # chest unit
	_part(_model, _box(Vector3(0.05, 0.03, 0.01)), glow, Vector3(-0.05, 1.32, -0.226))
	_part(_model, _box(Vector3(0.04, 0.03, 0.01)), accent, Vector3(0.05, 1.32, -0.226))
	_part(_model, _box(Vector3(0.5, 0.035, 0.36)), accent, Vector3(0, 1.48, 0))               # shoulder stripe
	# collar ring + helmet
	_part(_model, _cyl(0.17, 0.06), metal, Vector3(0, 1.58, 0))
	_part(_model, _sphere(0.19), suit, Vector3(0, 1.74, 0.01))
	_part(_model, _sphere(0.16), visor, Vector3(0, 1.745, -0.06), Vector3.ZERO, Vector3(1.0, 0.82, 0.9))
	_part(_model, _box(Vector3(0.03, 0.03, 0.03)), glow, Vector3(0.15, 1.84, -0.07))          # helmet lamp
	# backpack (life support)
	_part(_model, _box(Vector3(0.42, 0.56, 0.2)), suit, Vector3(0, 1.25, 0.27))
	_part(_model, _box(Vector3(0.36, 0.08, 0.21)), suit_dark, Vector3(0, 1.0, 0.275))
	for sx in [-0.13, 0.13]:
		_part(_model, _cyl(0.05, 0.5), metal, Vector3(sx, 1.27, 0.39))                           # tanks
	_part(_model, _box(Vector3(0.025, 0.2, 0.01)), glow, Vector3(0, 1.32, 0.375))
	_part(_model, _box(Vector3(0.43, 0.035, 0.205)), accent, Vector3(0, 1.48, 0.27))
	# arms (pivot at shoulder)
	for side in [-1.0, 1.0]:
		var sh := Node3D.new()
		sh.position = Vector3(0.3 * side, 1.45, 0)
		_model.add_child(sh)
		_part(sh, _capsule(0.085, 0.42), suit, Vector3(0.02 * side, -0.18, 0), Vector3(0, 0, 0.08 * side))
		_part(sh, _capsule(0.08, 0.38), suit, Vector3(0.05 * side, -0.5, -0.03))
		_part(sh, _cyl(0.085, 0.05), accent, Vector3(0.05 * side, -0.4, -0.02))
		_part(sh, _sphere(0.07), suit_dark, Vector3(0.05 * side, -0.72, -0.03))                  # glove
		_arms.append(sh)
	# legs (pivot at hip)
	for side in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(0.12 * side, 0.92, 0)
		_model.add_child(hip)
		_part(hip, _capsule(0.1, 0.5), suit, Vector3(0, -0.22, 0))
		_part(hip, _capsule(0.092, 0.46), suit, Vector3(0, -0.6, 0.0))
		_part(hip, _cyl(0.1, 0.05), accent, Vector3(0, -0.44, 0))
		_part(hip, _box(Vector3(0.15, 0.1, 0.28)), suit_dark, Vector3(0, -0.87, -0.04))          # boot
		_legs.append(hip)
	for mi in _model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
