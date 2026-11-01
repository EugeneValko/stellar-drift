class_name TestShipStub
extends Node3D
## TEST-ONLY stand-in for the real Ship (src/ship/ship.gd) implementing the GameMode/HUD contract
## on top of scenes/ship/ship_visual.tscn. Static (no flight model): it can be "landed" on a
## surface or posed in the air with fake HUD numbers for screenshots.
##
## Contract used by GameMode / HUD (the real Ship must provide the same):
##   var is_piloted: bool
##   func enter_pilot() -> void
##   func exit_pilot() -> Transform3D      # where the pilot appears (feet), -Z = facing
##   func can_exit() -> bool
##   signal pilot_entered
##   signal pilot_exited(exit_xform: Transform3D)
##   func get_hud_data() -> Dictionary     # see HUD_KEYS
## Optional (duck-typed, GameMode/HUD use them when present):
##   func get_camera() -> Camera3D         # camera to make current while piloting
##   func get_entry_point() -> Vector3     # world point the player must be near to board (hatch)
##   func get_visual() -> ShipVisual       # hatch/canopy animation
##   hud data extras: "velocity" (Vector3 world), "target_position" (Vector3 world),
##                    "target_radius" (m), "mode_count" (int)

signal pilot_entered
signal pilot_exited(exit_xform: Transform3D)

const VISUAL_SCENE := preload("res://scenes/ship/ship_visual.tscn")
const GROUND_OFFSET := 2.95   # GroundPoint: gear contact plane is 2.95 m below the ship origin
const MODE_NAMES := ["HOVER", "ATMO", "SPACE", "CRUISE", "WARP"]
const MODE_MAX := [50.0, 600.0, 5000.0, 300000.0, 3.0e7]

var is_piloted := false
var landed := true
var third_person := false
## Fake flight state for screenshots / HUD tests. Keys override computed values in get_hud_data().
var fake: Dictionary = {}
var visual: ShipVisual
var cockpit_camera: Camera3D
var chase_camera: Camera3D


func _ready() -> void:
	add_to_group("player_ship")
	visual = VISUAL_SCENE.instantiate() as ShipVisual
	visual.name = "Visual"
	add_child(visual)
	_build_collision()
	cockpit_camera = Camera3D.new()
	cockpit_camera.name = "CockpitCamera"
	cockpit_camera.near = 0.05
	cockpit_camera.far = 500000.0
	cockpit_camera.fov = 75.0
	chase_camera = Camera3D.new()
	chase_camera.name = "ChaseCamera"
	chase_camera.near = 0.1
	chase_camera.far = 1000000.0
	chase_camera.fov = 65.0
	add_child(cockpit_camera)
	add_child(chase_camera)
	_place_cameras.call_deferred()


func _place_cameras() -> void:
	var eye := visual.get_marker("PilotEye")
	cockpit_camera.transform = Transform3D(Basis(), eye.position if eye else Vector3(0, 1.12, -3.8))
	var ch := visual.get_marker("CameraChase")
	chase_camera.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-9.0)), ch.position if ch else Vector3(0, 4.6, 19.0))


## Simple box colliders for the hull (the real ship has its own). Belly at y = -1.35; above the
## ramp opening the collider is raised so the pilot can stand at ExitPoint.
func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "HullCollision"
	add_child(body)
	var boxes := [   # [min, max] in ship space (nose = -Z, ground at y = -2.95)
		[Vector3(-1.7, -1.35, -10.3), Vector3(1.7, 1.6, -4.3)],     # nose + cockpit
		[Vector3(-1.7, -0.85, -4.3), Vector3(1.7, 2.0, -0.1)],      # above the open ramp
		[Vector3(-1.7, -1.35, -0.1), Vector3(1.7, 2.0, 9.9)],       # rear fuselage
		[Vector3(-3.9, -1.2, 2.0), Vector3(-1.7, 0.9, 9.9)],        # nacelles
		[Vector3(1.7, -1.2, 2.0), Vector3(3.9, 0.9, 9.9)],
		[Vector3(-7.45, -0.35, 1.0), Vector3(7.45, 0.3, 8.0)],      # wing
	]
	for b in boxes:
		var lo: Vector3 = b[0]
		var hi: Vector3 = b[1]
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = hi - lo
		cs.shape = sh
		cs.position = (lo + hi) * 0.5
		body.add_child(cs)
	for gx in [[0.0, -6.45], [-2.8, 4.5], [2.8, 4.5]]:   # gear legs
		var cs := CollisionShape3D.new()
		var sh := CylinderShape3D.new()
		sh.radius = 0.3
		sh.height = 1.7
		cs.shape = sh
		cs.position = Vector3(gx[0], -2.1, gx[1])
		body.add_child(cs)


# ------------------------------------------------------------------ contract

func enter_pilot() -> void:
	is_piloted = true
	get_camera().make_current()
	pilot_entered.emit()


func exit_pilot() -> Transform3D:
	is_piloted = false
	cockpit_camera.current = false
	chase_camera.current = false
	var xf := get_exit_transform()
	pilot_exited.emit(xf)
	return xf


func can_exit() -> bool:
	return is_piloted and landed


func get_camera() -> Camera3D:
	return chase_camera if third_person else cockpit_camera


func get_visual() -> ShipVisual:
	return visual


## Hatch / ramp end on the ground (world space).
func get_entry_point() -> Vector3:
	var m := visual.get_marker("ExitPoint") if visual else null
	return m.global_position if m else global_position


func get_exit_transform() -> Transform3D:
	var m := visual.get_marker("ExitPoint") if visual else null
	var p := m.global_position if m else global_position - global_basis.y * GROUND_OFFSET
	# face the ship's forward (-Z), as if walking down the ramp
	return Transform3D(global_basis, p + global_basis.y * 0.05)


func get_hud_data() -> Dictionary:
	var pos := global_position
	var body := Universe.get_dominant_body(pos)
	var d := {
		"speed": 0.0, "vertical_speed": 0.0, "mode": 0, "mode_name": MODE_NAMES[0],
		"mode_max_speed": MODE_MAX[0], "altitude": -1.0, "body_name": "",
		"target_name": "", "target_distance": 0.0, "throttle": 0.0,
		"gear_down": visual.gear_deployed if visual else true, "landed": landed,
		"flight_assist": true, "atmosphere_density": Universe.get_atmosphere_density(pos),
		"heat": 0.0, "autopilot": false, "velocity": Vector3.ZERO,
	}
	if body:
		d["body_name"] = body.get_body_name()
		d["altitude"] = body.get_altitude_global(pos - global_basis.y * GROUND_OFFSET)
	for k in fake:
		d[k] = fake[k]
	return d


# ------------------------------------------------------------------ helpers

## Lands the ship on `planet` along planet-local direction `dir` (gear on the analytic surface),
## nose towards `forward` (projected on the local horizon).
func land_on(planet: Planet, dir: Vector3, forward: Vector3) -> void:
	var up := dir.normalized()
	var p := planet.to_global(planet.get_surface_point(up))
	var f := (forward - up * forward.dot(up)).normalized()
	global_transform = Transform3D(Basis.looking_at(f, up), p + up * GROUND_OFFSET)
	landed = true
	if visual:
		visual.set_gear(true, true)


func _unhandled_input(event: InputEvent) -> void:
	if not is_piloted:
		return
	if event.is_action_pressed("camera_toggle") and not event.is_echo():
		third_person = not third_person
		get_camera().make_current()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("gear_toggle") and not event.is_echo() and visual and not landed:
		visual.set_gear(not visual.gear_deployed)
