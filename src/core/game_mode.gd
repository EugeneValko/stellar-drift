class_name GameMode
extends Node
## Owns the game state SHIP / ON_FOOT / FREECAM (a node in the main scene, not an autoload).
##
## * ON_FOOT: the Player is active (camera, input, Universe focus). Near the ship's hatch
##   (`interact_distance` from ship.get_entry_point() / the ExitPoint marker) the HUD shows
##   "[F] Сесть в корабль"; F fades out, hides the player, calls ship.call("enter_pilot").
##   The hatch (ShipVisual.set_hatch) opens automatically while the player is close.
## * SHIP: the ship's camera is current and Universe focuses the ship. F while ship.can_exit()
##   calls ship.exit_pilot() -> Transform3D and spawns the player there, upright to local up.
## * FREECAM: V toggles a free camera if res://src/core/free_camera.gd exists (instantiated with
##   load(), duck-typed: Camera3D itself or a node with a Camera3D child, optional
##   set_active(bool)). The previous state is restored on V again.
## Esc opens the pause menu (a node in group "pause_menu", see PauseMenu) or, without one,
## toggles mouse capture.
##
## Wiring: set `ship_path` (the Ship), optional `player_path` (otherwise player.tscn is
## instantiated under Universe.world_root), `hud_path` (Hud). See docs/reports/wave2_player_ui.md.

signal state_changed(state: State)

enum State { SHIP, ON_FOOT, FREECAM }

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const FREECAM_SCRIPT := "res://src/core/free_camera.gd"

@export var ship_path: NodePath
@export var player_path: NodePath
@export var hud_path: NodePath
## Optional existing free camera (e.g. Main/World/FreeCamera); otherwise free_camera.gd is
## instantiated on the first V.
@export var free_camera_path: NodePath
@export var start_state: State = State.ON_FOOT
@export var interact_distance := 4.0
@export var hatch_open_distance := 10.0
@export var fade_time := 0.35
@export var capture_mouse := true
## When false the deferred start-up does not run; the scene calls ensure_started() itself
## (main.tscn: after placing the ship; capture presets of the bare system never start it).
@export var auto_start := true

var state: State = State.ON_FOOT
var ship: Node3D
var player: Player
var hud: Hud
var free_camera: Node3D
var busy := false

var _freecam_prev: State = State.ON_FOOT
var _hatch_open := false
var _started := false


func _ready() -> void:
	_start.call_deferred()


func _start(forced := false) -> void:
	if _started or not (auto_start or forced):
		return
	ship = get_node_or_null(ship_path) as Node3D
	if ship == null:
		var ships := get_tree().get_nodes_in_group("player_ship")
		ship = ships[0] as Node3D if not ships.is_empty() else null
	hud = get_node_or_null(hud_path) as Hud
	if free_camera == null and not free_camera_path.is_empty():
		free_camera = get_node_or_null(free_camera_path) as Node3D
	player = get_node_or_null(player_path) as Player
	if player == null:
		player = (load(PLAYER_SCENE) as PackedScene).instantiate() as Player
		var parent: Node = Universe.world_root if Universe.world_root else get_parent()
		parent.add_child(player)
		if ship:
			player.place_at(_exit_transform_guess())
	if ship and ship.has_signal("pilot_exited"):
		ship.connect("pilot_exited", _on_ship_pilot_exited)
	if hud:
		hud.ship = ship
		hud.player = player
	_started = true
	if start_state == State.SHIP and ship:
		_set_player_active(false)
		ship.call("enter_pilot")
		_activate_ship_camera()
		_set_state(State.SHIP)
	else:
		_set_player_active(true)
		_set_state(State.ON_FOOT)
	if capture_mouse and not Capture.active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# ------------------------------------------------------------------ public API

func enter_ship() -> void:
	if busy or state != State.ON_FOOT or ship == null:
		return
	busy = true
	_set_hatch(true)
	if hud:
		hud.clear_prompt()
		await hud.fade_to(1.0, fade_time)
	_set_player_active(false)
	ship.call("enter_pilot")
	_activate_ship_camera()
	_set_state(State.SHIP)
	_set_hatch(false)
	if hud:
		await hud.fade_to(0.0, fade_time * 1.4)
	busy = false


func exit_ship() -> void:
	if busy or state != State.SHIP or ship == null:
		return
	if ship.has_method("can_exit") and not bool(ship.call("can_exit")):
		if hud:
			hud.flash_message("Сначала посадите корабль")
		return
	if _over_water():
		if hud:
			hud.flash_message("Под кораблём вода — выйти нельзя")
		return
	busy = true
	_set_hatch(true)
	if hud:
		await hud.fade_to(1.0, fade_time)
	var xf: Transform3D = ship.call("exit_pilot")
	_spawn_player(xf)
	if hud:
		await hud.fade_to(0.0, fade_time * 1.4)
	busy = false


func toggle_freecam() -> void:
	if busy:
		return
	if state == State.FREECAM:
		_leave_freecam()
		return
	if not ResourceLoader.exists(FREECAM_SCRIPT):
		if hud:
			hud.flash_message("Свободная камера недоступна")
		return
	if free_camera == null or not is_instance_valid(free_camera):
		var scr := load(FREECAM_SCRIPT) as Script
		if scr == null:
			return
		var inst: Object = scr.new()
		if not (inst is Node3D):
			push_warning("GameMode: free_camera.gd is not a Node3D")
			if inst is Node:
				(inst as Node).queue_free()
			return
		free_camera = inst as Node3D
		free_camera.name = "FreeCamera"
		var parent: Node = Universe.world_root if Universe.world_root else get_parent()
		parent.add_child(free_camera)
	var cur := get_viewport().get_camera_3d()
	if cur:
		free_camera.global_transform = cur.global_transform
	_freecam_prev = state
	_set_inputs(false)
	free_camera.process_mode = Node.PROCESS_MODE_INHERIT
	if free_camera.has_method("set_active"):
		free_camera.call("set_active", true)
	var cam := _find_camera(free_camera)
	if cam:
		cam.make_current()
	Universe.set_focus(free_camera)
	_set_state(State.FREECAM)


## Runs the deferred start-up now (scenes that position things in their own _ready).
func ensure_started() -> void:
	_start(true)


## Instant switch to ON_FOOT without fades (loading, capture presets, tests).
func force_on_foot() -> void:
	ensure_started()
	if state == State.SHIP and ship:
		_spawn_player(ship.call("exit_pilot"))
	else:
		_set_player_active(true)
		_set_state(State.ON_FOOT)


## Instant switch to SHIP without fades.
func force_ship() -> void:
	ensure_started()
	if state == State.SHIP or ship == null:
		return
	_set_player_active(false)
	ship.call("enter_pilot")
	_activate_ship_camera()
	_set_state(State.SHIP)


## Opens/closes the hatch through GameMode's bookkeeping (instant for captures).
func set_hatch_open(open: bool, instant := false) -> void:
	var v := _visual()
	if v and v.has_method("set_hatch"):
		v.call("set_hatch", open, instant)
	_hatch_open = open


func get_state_name() -> String:
	return ["SHIP", "ON_FOOT", "FREECAM"][state]


## Distance from the player to the boarding point (INF if unknown).
func distance_to_hatch() -> float:
	if player == null or ship == null:
		return INF
	return player.global_position.distance_to(_entry_point())


# ------------------------------------------------------------------ internals

func _set_state(s: State) -> void:
	state = s
	if hud:
		match s:
			State.SHIP:
				hud.set_mode(Hud.Mode.SHIP)
			State.ON_FOOT:
				hud.set_mode(Hud.Mode.ON_FOOT)
			State.FREECAM:
				hud.set_mode(Hud.Mode.NONE)
				hud.clear_prompt()
	state_changed.emit(s)


func _set_player_active(on: bool) -> void:
	if player == null:
		return
	player.set_active(on)
	player.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	if on:
		Universe.set_focus(player)


func _activate_ship_camera() -> void:
	Universe.set_focus(ship)
	var cam: Camera3D = null
	if ship.has_method("get_camera"):
		cam = ship.call("get_camera") as Camera3D
	if cam == null:
		cam = _find_camera(ship)
	if cam:
		cam.make_current()


func _spawn_player(xf: Transform3D) -> void:
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.place_at(xf)
	_set_player_active(true)
	_set_state(State.ON_FOOT)


func _leave_freecam() -> void:
	if free_camera and is_instance_valid(free_camera):
		if free_camera.has_method("set_active"):
			free_camera.call("set_active", false)
		free_camera.process_mode = Node.PROCESS_MODE_DISABLED
		var cam := _find_camera(free_camera)
		if cam:
			cam.current = false
	_set_inputs(true)
	if _freecam_prev == State.SHIP:
		_activate_ship_camera()
		_set_state(State.SHIP)
	else:
		_set_player_active(true)
		_set_state(State.ON_FOOT)


## Enables/disables gameplay input of the player and (if it supports it) the ship.
func _set_inputs(on: bool) -> void:
	if player:
		player.input_enabled = on and _freecam_prev == State.ON_FOOT
		if not on:
			player.process_mode = Node.PROCESS_MODE_DISABLED   # frozen while flying the free camera
		elif _freecam_prev == State.ON_FOOT:
			player.process_mode = Node.PROCESS_MODE_INHERIT
	if ship:
		if "input_enabled" in ship:
			ship.set("input_enabled", on)
		elif ship.has_method("set_input_enabled"):
			ship.call("set_input_enabled", on)


func _find_camera(n: Node) -> Camera3D:
	if n is Camera3D:
		return n as Camera3D
	for c in n.find_children("*", "Camera3D", true, false):
		return c as Camera3D
	return null


func _visual() -> Node:
	if ship == null:
		return null
	if ship.has_method("get_visual"):
		return ship.call("get_visual")
	for c in ship.find_children("*", "ShipVisual", true, false):
		return c
	return null


func _entry_point() -> Vector3:
	if ship.has_method("get_entry_point"):
		return ship.call("get_entry_point")
	var v := _visual()
	if v and v.has_method("get_marker"):
		var m: Node3D = v.call("get_marker", "ExitPoint")
		if m:
			return m.global_position
	return ship.global_position


func _exit_transform_guess() -> Transform3D:
	var p := _entry_point()
	return Transform3D(ship.global_basis, p + ship.global_basis.y * 0.05)


func _set_hatch(open: bool) -> void:
	if open == _hatch_open:
		return
	var v := _visual()
	if v and v.has_method("set_hatch"):
		v.call("set_hatch", open)
	_hatch_open = open


func _over_water() -> bool:
	return ship != null and ship.has_method("is_over_water") and bool(ship.call("is_over_water"))


## The node that carries the gameplay (floating-origin focus outside the free camera).
func get_gameplay_body() -> Node3D:
	if state == State.FREECAM:
		return ship if _freecam_prev == State.SHIP else player
	return ship if state == State.SHIP else player


func _on_ship_pilot_exited(xf: Transform3D) -> void:
	# The ship ejected the pilot by itself (not through exit_ship()).
	if state == State.SHIP and not busy:
		_spawn_player(xf)


func _process(_dt: float) -> void:
	if not _started or hud == null:
		return
	match state:
		State.ON_FOOT:
			var d := distance_to_hatch()
			var piloted := bool(ship.get("is_piloted")) if ship else false
			if ship and not piloted and not busy:
				_set_hatch(d < hatch_open_distance)
				hud.set_prompt("Сесть в корабль" if d < interact_distance else "")
			else:
				hud.clear_prompt()
		State.SHIP:
			if not busy and ship.has_method("can_exit") and bool(ship.call("can_exit")) and not _over_water():
				hud.set_prompt("Выйти из корабля")
			else:
				hud.clear_prompt()


func _unhandled_input(event: InputEvent) -> void:
	if not _started or event.is_echo():
		return
	if event.is_action_pressed("interact"):
		if state == State.ON_FOOT and distance_to_hatch() < interact_distance:
			enter_ship()
			get_viewport().set_input_as_handled()
		elif state == State.SHIP:
			exit_ship()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("freecam_toggle"):
		toggle_freecam()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause_menu"):
		# Esc: the pause menu (group "pause_menu") if the scene has one, else toggle the cursor
		var menus := get_tree().get_nodes_in_group("pause_menu")
		if not menus.is_empty() and bool(menus[0].get("enabled")):
			menus[0].call("set_open", true)
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
				else Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()   # the free camera / ship must not toggle it back
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and capture_mouse and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not Capture.active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
