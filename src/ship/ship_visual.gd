class_name ShipVisual
extends Node3D
## Visual side of the player ship: instances assets/models/ship.glb (child "Model"), swaps the imported
## placeholder materials for the procedural ship shaders, and animates gear / bay doors / hatch / canopy /
## engines / lights. Pure visuals — no physics. Ship forward is -Z, up is +Y
## (see docs/reports/wave4_ship_v2.md and tools/blender/ship.py).
##
## API: set_thrust(0..1), set_gear(deployed, instant), set_hatch(open, instant), set_canopy(open, instant),
##      get_marker(name) -> Node3D, get_markers(prefix) -> Array[Node3D], is_gear_moving().

signal gear_changed(deployed: bool)
signal hatch_changed(open: bool)

const MATERIALS := {
	"Hull": preload("res://assets/materials/ship/hull.tres"),
	"HullDark": preload("res://assets/materials/ship/hull_dark.tres"),
	"Trim": preload("res://assets/materials/ship/trim.tres"),
	"Glass": preload("res://assets/materials/ship/glass.tres"),
	"Emissive": preload("res://assets/materials/ship/emissive.tres"),
	"EngineInner": preload("res://assets/materials/ship/engine_inner.tres"),
	"Display": preload("res://assets/materials/ship/display.tres"),
	"Lamp": preload("res://assets/materials/ship/lamp.tres"),
}
const PLUME_SHADER := preload("res://shaders/ship_plume.gdshader")
const MARKER_PREFIXES := ["EngineExhaust_", "Thruster_", "NavLight_", "PilotSeat", "PilotEye", "ExitPoint",
	"GroundPoint", "CameraChase", "Flood_", "DeckLight_", "FlankLight_", "CockpitLight"]
const DEFAULT_HATCH_OPEN := -30.0
const DEFAULT_CANOPY_OPEN := 30.0
const NAV_LIGHT_ENERGY := 0.35
## Gear sequence on the 0..1 deploy parameter: doors open first, then the legs telescope out.
const DOOR_END := 0.32
const LEG_START := 0.24

@export var gear_time := 2.6
@export var hatch_time := 2.0
@export var canopy_time := 1.6
@export var nav_lights := true
@export var engine_light_energy := 2.5
@export var plume_length := 7.0
@export var start_gear_deployed := true
@export_group("Lights")
## Landing floodlights under the hull: on while the gear is down.
@export var flood_energy := 7.0
@export var flood_range := 34.0
@export var flood_shadows := true
## Small lamps on the spine shoulders that wash the aft deck / radiators (readability at night).
@export var deck_light_energy := 1.6
@export var cockpit_light_energy := 0.5
## Floodlights/deck lights follow the sun like auto headlights: full on in planet shadow / at night,
## off in daylight (reads the scene's shadowed DirectionalLight3D: colour x energy x elevation).
@export var auto_lights := true

var thrust := 0.0
var gear_deployed := true
var hatch_open := false
var canopy_open := false

var _model: Node3D
var _mats: Dictionary = {}          # slot name -> ShaderMaterial (per-instance duplicates)
var _markers: Dictionary = {}       # name -> Node3D
var _legs: Array[Dictionary] = []   # {node, rest: Vector3, travel: float}
var _doors: Array[Dictionary] = []  # {node, rest: Vector3, slide: Vector3, lift: float}
var _overlay_followers: Array[MeshInstance3D] = []
var _overlay_source: MeshInstance3D
var _hatch: Node3D
var _hatch_angle := deg_to_rad(DEFAULT_HATCH_OPEN)
var _canopy: Node3D
var _canopy_angle := deg_to_rad(DEFAULT_CANOPY_OPEN)
var _gear_t := 1.0                  # 1 = deployed
var _hatch_t := 0.0                 # 1 = open
var _canopy_t := 0.0
var _tweens: Dictionary = {}
var _plumes: Array[Node3D] = []
var _plume_mats: Array[ShaderMaterial] = []
var _engine_lights: Array[OmniLight3D] = []
var _floods: Array[SpotLight3D] = []
var _deck_lights: Array[SpotLight3D] = []
var _sun: DirectionalLight3D
var _night := 1.0                   # 0 = daylight .. 1 = dark (auto_lights)
var _sun_scan_t := 0.0
var _nav: Array[Dictionary] = []    # {light, mesh_mat, color, kind}
var _time := 0.0
var _capture := false


func _ready() -> void:
	_model = get_node_or_null("Model") as Node3D
	if _model == null:
		push_error("ShipVisual: child 'Model' (ship.glb instance) missing")
		return
	var cap := get_node_or_null("/root/Capture")
	_capture = cap != null and bool(cap.get("active"))
	for k: String in MATERIALS:
		_mats[k] = (MATERIALS[k] as ShaderMaterial).duplicate()
	if _capture:
		for k: String in ["Emissive", "EngineInner", "Display"]:
			(_mats[k] as ShaderMaterial).set_shader_parameter("time_override", 1.3)
	_collect(_model)
	_build_engine_fx()
	_build_nav_lights()
	_build_lights()
	_set_gear_t(1.0 if start_gear_deployed else 0.0)
	gear_deployed = start_gear_deployed
	_set_hatch_t(0.0)
	_set_canopy_t(0.0)
	set_thrust(thrust)


func _collect(node: Node) -> void:
	for c in node.get_children():
		var n3 := c as Node3D
		if n3 == null:
			continue
		var nm := String(n3.name)
		for pre: String in MARKER_PREFIXES:
			if nm.begins_with(pre):
				_markers[nm] = n3
		if nm.begins_with("Gear"):
			_legs.append({"node": n3, "rest": n3.position, "travel": float(_extra(n3, "travel", 2.0))})
		elif nm.begins_with("BayDoor_"):
			var s: Variant = _extra(n3, "slide", [0.0, 0.0, 0.0])
			var sv := Vector3.ZERO
			if s is Array and (s as Array).size() == 3:
				sv = Vector3(float(s[0]), float(s[1]), float(s[2]))
			_doors.append({"node": n3, "rest": n3.position, "slide": sv, "lift": float(_extra(n3, "lift", 0.07))})
		elif nm == "Hatch":
			_hatch = n3
			_hatch_angle = deg_to_rad(float(_extra(n3, "open_deg", DEFAULT_HATCH_OPEN)))
		elif nm == "Canopy":
			_canopy = n3
			_canopy_angle = deg_to_rad(float(_extra(n3, "open_deg", DEFAULT_CANOPY_OPEN)))
		var mi := n3 as MeshInstance3D
		if mi != null and mi.mesh != null:
			_apply_materials(mi)
			if nm == "Hull":
				_overlay_source = mi
			elif nm.begins_with("BayDoor_") or (nm.begins_with("Gear") and nm.contains("_S")):
				_overlay_followers.append(mi)
		_collect(n3)


func _extra(n: Node, key: String, fallback: Variant) -> Variant:
	if n.has_meta("extras"):
		var ex: Variant = n.get_meta("extras")
		if ex is Dictionary and (ex as Dictionary).has(key):
			return ex[key]
	return fallback


func _apply_materials(mi: MeshInstance3D) -> void:
	var mesh := mi.mesh
	for i in mesh.get_surface_count():
		var src := mesh.surface_get_material(i)
		var key := src.resource_name if src != null else ""
		if key == "" and mesh is ArrayMesh:
			key = (mesh as ArrayMesh).surface_get_name(i)
		if _mats.has(key):
			mi.set_surface_override_material(i, _mats[key])
		else:
			push_warning("ShipVisual: unknown material slot '%s' on %s" % [key, mi.name])
	# Separate parts: give the shader their rest offset in ship space so the paint lines up with the hull
	# (and moves with the part when it animates).
	var rest := _model.global_transform.affine_inverse() * mi.global_transform
	mi.set_instance_shader_parameter("part_offset", rest.origin)


# ------------------------------------------------------------------ engines
func _build_engine_fx() -> void:
	for nm: String in _markers:
		if not nm.begins_with("EngineExhaust_"):
			continue
		var m: Node3D = _markers[nm]
		var r := float(_extra(m, "radius", 0.55))
		var aux := String(_extra(m, "kind", "main")) == "aux"
		for layer in 2:
			var plen := plume_length * (0.55 if aux else 1.0) * (0.45 if layer == 0 else 1.0)
			var cyl := CylinderMesh.new()
			cyl.top_radius = r * (0.8 if layer == 0 else 1.0)
			cyl.bottom_radius = r * (0.15 if layer == 0 else 0.45)
			cyl.height = plen
			cyl.radial_segments = 24
			cyl.rings = 8
			cyl.cap_top = false
			cyl.cap_bottom = false
			var mat := ShaderMaterial.new()
			mat.shader = PLUME_SHADER
			mat.set_shader_parameter("plume_len", plen)
			if layer == 0:
				mat.set_shader_parameter("color_start", Color(0.85, 0.95, 1.0))
				mat.set_shader_parameter("color_end", Color(0.45, 0.65, 1.0))
				mat.set_shader_parameter("intensity", 2.2)
				mat.set_shader_parameter("diamonds", 0.9)
			else:
				mat.set_shader_parameter("intensity", 1.0)
				mat.set_shader_parameter("edge_soft", 2.5)
				mat.set_shader_parameter("diamonds", 0.3)
			if _capture:
				mat.set_shader_parameter("time_override", 1.3)
			var pivot := Node3D.new()
			pivot.name = "Plume%d" % layer
			m.add_child(pivot)
			var mi := MeshInstance3D.new()
			mi.mesh = cyl
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# cylinder axis +Y -> marker -Z (plume direction); top cap (nozzle end) at the marker origin
			mi.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0, -plen * 0.5))
			pivot.add_child(mi)
			_plumes.append(pivot)
			_plume_mats.append(mat)
		var light := OmniLight3D.new()
		light.name = "EngineLight"
		light.light_color = Color(0.55, 0.75, 1.0)
		light.omni_range = 9.0 if not aux else 5.0
		light.omni_attenuation = 1.6
		light.position = Vector3(0, 0, -2.0)
		light.shadow_enabled = false
		m.add_child(light)
		_engine_lights.append(light)


func set_thrust(v: float) -> void:
	thrust = clampf(v, 0.0, 1.0)
	if _mats.is_empty():
		return
	(_mats["EngineInner"] as ShaderMaterial).set_shader_parameter("thrust", thrust)
	for i in _plume_mats.size():
		_plume_mats[i].set_shader_parameter("thrust", thrust)
		_plumes[i].visible = thrust > 0.01
		_plumes[i].scale = Vector3(1.0, 1.0, lerpf(0.5, 1.0, thrust))
	for l in _engine_lights:
		l.light_energy = engine_light_energy * thrust * thrust
		l.visible = thrust > 0.01


# ------------------------------------------------------------------ lights
func _build_lights() -> void:
	for nm: String in _markers:
		var m: Node3D = _markers[nm]
		if nm.begins_with("Flood_"):
			var s := SpotLight3D.new()
			s.name = "Flood"
			s.light_color = Color(1.0, 0.93, 0.82)
			s.spot_range = flood_range
			s.spot_angle = 34.0 if nm.begins_with("Flood_Nose") else 46.0
			s.spot_angle_attenuation = 0.8
			s.spot_attenuation = 1.2
			s.light_energy = flood_energy
			s.light_specular = 0.3
			s.shadow_enabled = flood_shadows and nm.begins_with("Flood_Nose")
			s.shadow_bias = 0.04
			s.position = Vector3(0, 0, -0.05)
			m.add_child(s)
			_floods.append(s)
		elif nm.begins_with("FlankLight_"):
			var f := SpotLight3D.new()
			f.name = "FlankLight"
			f.light_color = Color(1.0, 0.93, 0.85)
			f.spot_range = 13.0
			f.spot_angle = 48.0
			f.spot_angle_attenuation = 1.2
			f.spot_attenuation = 0.9
			f.light_energy = deck_light_energy
			f.light_specular = 0.15
			f.shadow_enabled = false
			m.add_child(f)
			_deck_lights.append(f)
		elif nm.begins_with("DeckLight_"):
			var d := SpotLight3D.new()
			d.name = "DeckLight"
			d.light_color = Color(1.0, 0.9, 0.78)
			d.spot_range = 11.0
			d.spot_angle = 52.0
			d.spot_angle_attenuation = 1.4
			d.spot_attenuation = 1.0
			d.light_energy = deck_light_energy
			d.light_specular = 0.15
			d.shadow_enabled = false
			m.add_child(d)
			_deck_lights.append(d)
		elif nm == "CockpitLight":
			var o := OmniLight3D.new()
			o.name = "CabinLight"
			o.light_color = Color(0.55, 0.8, 1.0)
			o.omni_range = 2.2
			o.omni_attenuation = 1.4
			o.light_energy = cockpit_light_energy
			o.light_specular = 0.05
			o.shadow_enabled = false
			m.add_child(o)


func _update_floods() -> void:
	var dark := _night if auto_lights else 1.0
	var on := smoothstep(LEG_START, 0.6, _gear_t) * dark
	for s in _floods:
		s.light_energy = flood_energy * on
		s.visible = on > 0.01
	for d in _deck_lights:
		d.light_energy = deck_light_energy * (0.25 + 0.75 * dark)
	if _mats.has("Lamp"):
		(_mats["Lamp"] as ShaderMaterial).set_shader_parameter("lit", 0.2 + 0.8 * maxf(on, dark * 0.6))


## Daylight estimate at the ship from the scene's main (shadowed) directional light.
func _update_daylight(delta: float) -> void:
	if not auto_lights:
		return
	_sun_scan_t -= delta
	if (_sun == null or not is_instance_valid(_sun)) and _sun_scan_t <= 0.0:
		_sun_scan_t = 1.0
		_sun = null
		var best := -1.0
		for n in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
			var l := n as DirectionalLight3D
			var score := l.light_energy + (10.0 if l.shadow_enabled else 0.0)
			if score > best:
				best = score
				_sun = l
	var day := 0.0
	if _sun and _sun.is_visible_in_tree():
		var c := _sun.light_color
		var lum := (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) * _sun.light_energy
		var elev := _sun.global_basis.z.normalized().dot(global_basis.y.normalized())
		day = lum * clampf(elev * 2.5 + 0.35, 0.0, 1.0)
	var target := 1.0 - smoothstep(0.08, 0.4, day)
	# airless bodies / space: shadowed sides are pitch black even in daylight -> keep the lights on
	var env := get_viewport().find_world_3d().environment if get_viewport() else null
	if env and env.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR:
		var a := env.ambient_light_color
		var amb := (0.2126 * a.r + 0.7152 * a.g + 0.0722 * a.b) * env.ambient_light_energy
		target = maxf(target, 1.0 - smoothstep(0.09, 0.2, amb))
	var k := 1.0 if _capture else 1.0 - exp(-delta * 1.5)
	if absf(target - _night) > 0.002:
		_night = lerpf(_night, target, k)
		_update_floods()


# ------------------------------------------------------------------ nav lights
func _build_nav_lights() -> void:
	var defs := {
		"NavLight_L": [Color(1.0, 0.08, 0.05), "steady", Vector3(-0.35, 0.0, 0.0)],
		"NavLight_R": [Color(0.1, 1.0, 0.25), "steady", Vector3(0.35, 0.0, 0.0)],
		"NavLight_Top": [Color(1.0, 0.95, 0.9), "strobe", Vector3(0.0, 0.35, 0.0)],
		"NavLight_Tail": [Color(1.0, 0.97, 0.92), "steady", Vector3(0.0, 0.0, 0.4)],
		"NavLight_Belly": [Color(1.0, 0.1, 0.04), "beacon", Vector3(0.0, -0.35, 0.0)],
	}
	for nm: String in defs:
		if not _markers.has(nm):
			continue
		var m: Node3D = _markers[nm]
		var col: Color = defs[nm][0]
		var sph := SphereMesh.new()
		sph.radius = 0.055
		sph.height = 0.11
		sph.radial_segments = 12
		sph.rings = 6
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		var mi := MeshInstance3D.new()
		mi.mesh = sph
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.add_child(mi)
		var light := OmniLight3D.new()
		light.light_color = col
		light.omni_range = 2.5
		light.light_energy = NAV_LIGHT_ENERGY
		light.shadow_enabled = false
		light.position = defs[nm][2]  # keep the point light off the hull (avoids a blown-out hot spot)
		m.add_child(light)
		_nav.append({"light": light, "mat": mat, "color": col, "kind": defs[nm][1], "mesh": mi})
	_update_nav(0.0)


func _update_nav(t: float) -> void:
	for d: Dictionary in _nav:
		var on := 1.0
		if not nav_lights:
			on = 0.0
		elif _capture:
			on = 1.0
		elif d["kind"] == "strobe":
			var ph := fmod(t, 1.4)
			on = 1.0 if (ph < 0.06 or (ph > 0.16 and ph < 0.22)) else 0.0
		elif d["kind"] == "beacon":
			on = pow(0.5 + 0.5 * sin(t * TAU * 0.8), 6.0)
		else:
			on = 0.35 + 0.65 * (0.5 + 0.5 * signf(sin(t * TAU * 0.5)))
		var c: Color = d["color"]
		(d["mat"] as StandardMaterial3D).albedo_color = c * (0.15 + 5.0 * on)
		(d["light"] as OmniLight3D).light_energy = NAV_LIGHT_ENERGY * on
		(d["mesh"] as MeshInstance3D).visible = nav_lights


func _process(delta: float) -> void:
	_time += delta
	_update_daylight(delta)
	if not _nav.is_empty():
		_update_nav(_time)
	# separate meshes (bay doors, leg stages) follow the hull's FX overlay (re-entry heating, ShipFX)
	if _overlay_source:
		var ov := _overlay_source.material_overlay
		for mi in _overlay_followers:
			if mi.material_overlay != ov:
				mi.material_overlay = ov


# ------------------------------------------------------------------ gear / hatch / canopy
func set_gear(deployed: bool, instant := false) -> void:
	gear_deployed = deployed
	_animate("gear", _set_gear_t, _gear_t, 1.0 if deployed else 0.0, gear_time, instant)
	gear_changed.emit(deployed)


func set_hatch(open: bool, instant := false) -> void:
	hatch_open = open
	_animate("hatch", _set_hatch_t, _hatch_t, 1.0 if open else 0.0, hatch_time, instant)
	hatch_changed.emit(open)


func set_canopy(open: bool, instant := false) -> void:
	canopy_open = open
	_animate("canopy", _set_canopy_t, _canopy_t, 1.0 if open else 0.0, canopy_time, instant)


func is_gear_moving() -> bool:
	return _tweens.has("gear") and (_tweens["gear"] as Tween).is_running()


func _animate(key: String, setter: Callable, from: float, to: float, dur: float, instant: bool) -> void:
	if _tweens.has(key):
		(_tweens[key] as Tween).kill()
		_tweens.erase(key)
	if instant or not is_inside_tree():
		setter.call(to)
		return
	var tw := create_tween()
	tw.tween_method(setter, from, to, dur * absf(to - from)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tweens[key] = tw


func _set_gear_t(t: float) -> void:
	_gear_t = t
	# bay doors: lift into the skin, then slide under it
	var dl := smoothstep(0.0, 0.07, t)
	var ds := smoothstep(0.05, DOOR_END, t)
	for d: Dictionary in _doors:
		var n: Node3D = d["node"]
		n.position = (d["rest"] as Vector3) + Vector3(0.0, float(d["lift"]) * dl, 0.0) + (d["slide"] as Vector3) * ds
		n.visible = ds < 0.999   # fully hidden inside the hull when open
	# telescoping legs: every stage extends proportionally (rest pose = deployed)
	var k := smoothstep(LEG_START, 1.0, t)
	for l: Dictionary in _legs:
		var n: Node3D = l["node"]
		n.position = (l["rest"] as Vector3) + Vector3(0.0, float(l["travel"]) * (1.0 - k), 0.0)
		n.visible = k > 0.001
	_update_floods()


func _set_hatch_t(t: float) -> void:
	_hatch_t = t
	if _hatch:
		_hatch.rotation = Vector3(_hatch_angle * t, 0.0, 0.0)


func _set_canopy_t(t: float) -> void:
	_canopy_t = t
	if _canopy:
		_canopy.rotation = Vector3(_canopy_angle * t, 0.0, 0.0)


# ------------------------------------------------------------------ markers
func get_marker(marker_name: String) -> Node3D:
	return _markers.get(marker_name, null)


func get_markers(prefix: String) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for k: String in _markers:
		if k.begins_with(prefix):
			out.append(_markers[k])
	return out
