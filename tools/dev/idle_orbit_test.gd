extends SceneTree
## Idle orbit ("photo mode") check on the real game (scenes/main.tscn, loading screen path):
## landed + piloted + chase view, no input for `idle_orbit_delay` s -> the camera eases onto the
## orbit; any key / mouse button / mouse motion -> back to the chase pose in ~1.1 s;
## cockpit view never orbits.
##
##   godot --headless --fixed-fps 60 -s tools/dev/idle_orbit_test.gd
##
## Game classes use the autoloads, which do not exist yet when a `-s` script compiles, so
## everything here is accessed untyped. Exit code 1 on any failure.

const DT := 1.0 / 60.0

var main: Node
var rig: Node
var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	if not main.get("started"):
		await main.session_started
	var ship: Node = main.get_node("World/Ship")
	rig = ship.get("camera_rig")
	var delay: float = rig.get("idle_orbit_delay")
	print("[orbit] session ready, idle_orbit_delay %.1f s, landed %s" % [delay, ship.get("landed")])

	# 1) no input: not orbiting just before the delay, fully orbiting after delay + 5 s blend
	await _sim(delay - 1.0)
	_check("no orbit before %.0f s idle" % delay, not rig.call("is_orbiting"), "k=%.3f" % _k())
	await _sim(1.5)
	_check("orbit starts after the delay", rig.call("is_orbiting"), "k=%.3f" % _k())
	await _sim(5.5)
	_check("orbit fully blended in ~5 s", _k() > 0.99, "k=%.3f" % _k())
	var cam: Camera3D = root.get_viewport().get_camera_3d()
	var chase: Camera3D = rig.get("chase")
	_check("chase camera renders the orbit", cam == chase, str(cam))
	var p0 := cam.global_position
	await _sim(4.0)
	var moved := cam.global_position.distance_to(p0)
	_check("camera circles (moves)", moved > 1.0 and moved < 20.0, "%.2f m in 4 s" % moved)

	# 2) a key press -> back to chase in ~1.1 s
	await _event_back("key", _key())
	# 3) mouse motion -> back
	await _sim(delay + 6.0)
	_check("orbit resumes after idle again", _k() > 0.99, "k=%.3f" % _k())
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(8, 0)
	await _event_back("mouse motion", mm)
	# 4) mouse button -> back
	await _sim(delay + 6.0)
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	await _event_back("mouse button", mb)

	# 5) cockpit view: never orbits
	rig.call("set_view", 1, false)
	await _sim(delay + 6.0)
	_check("cockpit view never orbits", not rig.call("is_orbiting"), "k=%.3f" % _k())
	rig.call("set_view", 0, false)

	print("RESULT: %s" % ("FAIL" if failed else "PASS"))
	main.queue_free()
	await process_frame
	quit(1 if failed else 0)


func _event_back(what: String, ev: InputEvent) -> void:
	root.push_input(ev)
	await _sim(0.6)
	_check("%s: leaving the orbit" % what, _k() < 0.75, "k=%.3f after 0.6 s" % _k())
	await _sim(0.7)
	_check("%s: back to chase in ~1.1 s" % what, _k() <= 0.001, "k=%.3f after 1.3 s" % _k())
	if ev is InputEventKey or ev is InputEventMouseButton:
		var up := ev.duplicate() as InputEvent
		up.set("pressed", false)
		root.push_input(up)


func _key() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_SCROLLLOCK   # no game binding: only the "any input" path is exercised
	k.physical_keycode = KEY_SCROLLLOCK
	k.pressed = true
	return k


func _k() -> float:
	return rig.get("_orbit_k")


func _sim(sec: float) -> void:
	for i in int(sec / DT):
		await process_frame


func _check(name: String, ok: bool, info: String) -> void:
	print("[orbit] %s  %s  (%s)" % ["PASS" if ok else "FAIL", name, info])
	if not ok:
		failed = true
