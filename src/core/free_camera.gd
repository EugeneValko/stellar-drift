class_name FreeCamera
extends Camera3D
## Debug / exploration camera: mouse look, WASD + Space/Ctrl move, Q/E roll, mouse wheel
## changes speed exponentially (1 m/s .. 50 000 km/s), Shift = x5 boost.
## Uses the `Controls` actions. Click captures the mouse, Esc releases it.
## Near surfaces the speed is capped to the altitude (optional) and the camera never goes
## below the ground (noclip off by default).

@export var speed := 200.0
@export var min_speed := 1.0
@export var max_speed := 5.0e7
## Speed multiplier per wheel notch.
@export var wheel_step := 1.25
@export var boost := 5.0
@export var mouse_sensitivity := 0.0025
@export var roll_speed := 1.4
## Cap speed to altitude * factor per second (0 = off). Keeps landings controllable.
@export var altitude_speed_factor := 2.0
@export var min_ground_clearance := 0.6
@export var noclip := false
## Smoothing of the velocity (higher = snappier).
@export var accel := 8.0

var velocity := Vector3.ZERO
var _look := Vector2.ZERO


func _ready() -> void:
	near = 0.1
	# move before SolarSystem (-100) and Star: scaled-space transforms are computed from the
	# camera position of THIS frame (a one-frame lag would drag far bodies along at speed)
	process_priority = -1000


func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = clampf(speed * wheel_step, min_speed, max_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = clampf(speed / wheel_step, min_speed, max_speed)
		elif mb.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look += (event as InputEventMouseMotion).relative
	elif event.is_action_pressed("pause_menu"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(dt: float) -> void:
	if not current or Capture.active:
		return
	# rotation in the camera's own frame (6DOF, no world up)
	var b := global_basis
	if _look != Vector2.ZERO:
		b = b.rotated(b.y, -_look.x * mouse_sensitivity)
		b = b.rotated(b.x, -_look.y * mouse_sensitivity)
		_look = Vector2.ZERO
	var roll := Input.get_axis("roll_right", "roll_left")
	if roll != 0.0:
		b = b.rotated(b.z, roll * roll_speed * dt)
	global_basis = b.orthonormalized()

	var dir := Vector3.ZERO
	dir += -b.z * Input.get_axis("move_back", "move_forward")
	dir += b.x * Input.get_axis("move_left", "move_right")
	dir += b.y * Input.get_axis("move_down", "move_up")
	var s := speed * (boost if Input.is_action_pressed("boost") else 1.0)
	var body := Universe.get_nearest_body(global_position)
	var alt := INF
	if body:
		alt = body.get_altitude_global(global_position)
		if altitude_speed_factor > 0.0:
			s = minf(s, maxf(alt * altitude_speed_factor, 3.0) * (boost if Input.is_action_pressed("boost") else 1.0))
	var want := dir.normalized() * s if dir != Vector3.ZERO else Vector3.ZERO
	velocity = velocity.lerp(want, 1.0 - exp(-accel * dt))
	var step := velocity * dt
	if body and not noclip and alt != INF:
		# don't sink below the ground: remove the downward part when too low
		var up: Vector3 = (global_position - body.global_position).normalized()
		var down := -step.dot(up)
		if down > 0.0 and alt - down < min_ground_clearance:
			step += up * (down - maxf(alt - min_ground_clearance, 0.0))
			velocity -= up * velocity.dot(up) * float(velocity.dot(up) < 0.0)
	global_position += step


## Speed shown by HUDs (m/s).
func get_speed() -> float:
	return velocity.length()
