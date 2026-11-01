extends Node3D
## Flight test: Terra Nova (terrain + atmosphere + ocean [+ clouds]), star Helios, the flyable Ship.
## Standalone-pilotable (no game-mode manager needed).
##
## Capture presets (tools/shot.sh --cam= / --shots=):
##   chase_space, reentry, low_flight, landed, warp, cockpit, hover
## Scripted demo flights (tools/movie.sh ... --demo=NAME): reentry, landing, warp, hover, orbit
## Other args: --clouds=0/1, --spawn=orbit|ground|space, --hud=1, --sky_face=512
##
## The world root (Universe.world_root) is $World; the ship is its direct child so the
## floating origin keeps it at ~(0,0,0).

const PlanetScene := preload("res://scenes/planets/planet.tscn")
const ShipScene := preload("res://scenes/ship/ship.tscn")
const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")
const OCEAN_SCENE := preload("res://scenes/planets/ocean.tscn")
const CLOUDS_SCENE := preload("res://scenes/planets/clouds.tscn")
const STAR_DIST := 1.5e7   # 15 000 km (Helios)

@export var start_preset := "orbit"

var planet: Planet
var ship: Ship
var cfg: PlanetConfig
var atmo: Node3D
var demo := ""
var demo_t := 0.0
var _demo_state := {}
var _hud: Label
var _site_cache := {}
var _env: Environment

@onready var world: Node3D = $World
@onready var star: Star = $World/Star
@onready var sun_light: DirectionalLight3D = $SunLight


func _ready() -> void:
	add_to_group("capture_target")
	Universe.set_world_root(world)
	var bd := $SpaceBackdrop as WorldEnvironment
	_env = bd.environment.duplicate() as Environment
	bd.environment = _env
	Universe.origin_shifted.connect(func(delta: Vector3) -> void:
		if _demo_state.has("cam_p"):
			_demo_state["cam_p"] -= delta)
	_build_planet()
	ship = ShipScene.instantiate() as Ship
	ship.name = "Ship"
	world.add_child(ship)
	ship.enter_pilot()
	_build_hud()
	demo = String(Capture.args.get("demo", ""))
	if demo != "":
		_start_demo(demo)
	elif Capture.active:
		pass   # Capture applies the presets
	else:
		apply_capture_preset(String(Capture.args.get("spawn", start_preset)))


func _build_planet() -> void:
	cfg = (load("res://src/planets/presets/terra_nova.tres") as PlanetConfig).duplicate()
	# match the gameplay atmosphere (density / heating / cruise lock) to the visual shell (24 km)
	cfg.atmosphere_height = 24000.0
	planet = PlanetScene.instantiate() as Planet
	planet.name = "TerraNova"
	planet.config = cfg
	world.add_child(planet)
	atmo = ATMO_SCENE.instantiate()
	planet.components.add_child(atmo)
	atmo.setup({"preset": "terra_nova", "radius": cfg.radius, "quality": 1})
	var ocean: Node3D = OCEAN_SCENE.instantiate()
	planet.components.add_child(ocean)
	ocean.setup({"radius": cfg.get_ocean_radius(), "atmosphere": atmo, "quality": 1})
	if Capture.args.get("clouds", "1") != "0":
		var clouds: Node3D = CLOUDS_SCENE.instantiate()
		planet.components.add_child(clouds)
		clouds.setup({"radius": cfg.radius, "bottom": 1800.0 + cfg.sea_level, "top": 4300.0 + cfg.sea_level,
			"coverage": 0.36, "brightness": 2.2, "cyclones": 4, "atmosphere": atmo,
			"ocean_radius": cfg.get_ocean_radius(), "quality": 1})
		ocean.set_clouds(clouds)
		clouds.apply_shadow_uniforms(planet.terrain_material)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color(0.75, 0.95, 1.0))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	layer.add_child(_hud)
	_hud.visible = (not Capture.active and not Capture.args.has("demo")) or Capture.args.get("hud", "0") == "1"


func _process(_dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if _env:
		var a := smoothstep(0.0, 0.25, ship.density)
		_env.ambient_light_color = Color(0.11, 0.12, 0.16).lerp(Color(0.42, 0.55, 0.75), a)
		_env.ambient_light_energy = lerpf(0.12, 0.55, a)
		# daylight inside the atmosphere outshines the stars (test-scene stand-in for exposure)
		var sky := _env.sky.sky_material as ShaderMaterial if _env.sky else null
		if sky:
			var k := smoothstep(0.0, 0.12, ship.density)
			sky.set_shader_parameter("sky_energy", lerpf(1.0, 0.04, k))
			sky.set_shader_parameter("star_brightness", lerpf(1.35, 0.0, k))
		_env.tonemap_exposure = lerpf(1.0, 1.45, a)
	if cam and star:
		var d := (star.global_position - cam.global_position).normalized()
		SunGlobals.set_sun(d, star.light_color, star.light_energy)
	if _hud.visible:
		var h := ship.get_hud_data()
		_hud.text = "%s  %s  %.0f m/s (cap %.0f)  thr %.2f\nalt %.0f m  vs %.1f  ρ %.3f  heat %.2f\nbody %s  target %s %.0f km\nFA %s  gear %s  landed %s  AP %s  %s" % [
			h["mode_name"], "BOOST" if h["boost"] else "", h["speed"], h["mode_max_speed"], h["throttle"],
			h["altitude"], h["vertical_speed"], h["atmosphere_density"], h["heat"],
			h["body_name"], h["target_name"], h["target_distance"] / 1000.0,
			h["flight_assist"], h["gear_down"], h["landed"], h["autopilot"], h["message"]]


func _physics_process(dt: float) -> void:
	if demo != "":
		demo_t += dt
		_drive_demo(dt)


# =====================================================================================
# Placement helpers
# =====================================================================================

## Ground (terrain or ocean) height above the radius along planet-local dir.
func ground_h(d: Vector3) -> float:
	return maxf(planet.get_height(d), cfg.sea_level if cfg.has_ocean_surface() else -1e9)


## Puts the star so that at surface dir `d` the sun is `elev` deg above the horizon, `az` deg
## around from `fwd` (0 = straight ahead).
func set_sun_at(d: Vector3, fwd: Vector3, elev: float, az: float) -> void:
	var up := d.normalized()
	var f := (fwd - up * fwd.dot(up)).normalized()
	var h := f.rotated(up, deg_to_rad(az))
	var from := (h * cos(deg_to_rad(elev)) + up * sin(deg_to_rad(elev))).normalized()
	star.global_position = planet.global_position + from * STAR_DIST


## Places the ship at planet-local direction `d`, `alt` m above ground, nose along `fwd`
## (projected on the tangent plane, pitched by `pitch_deg`), with velocity `v` (world).
func place_ship(d: Vector3, alt: float, fwd: Vector3, pitch_deg := 0.0, v := Vector3.ZERO, mode := Ship.Mode.SPACE) -> void:
	d = d.normalized()
	var f := (fwd - d * fwd.dot(d)).normalized()
	var right := f.cross(d).normalized()
	f = f.rotated(right, deg_to_rad(pitch_deg))
	var up := right.cross(f).normalized()
	var p := planet.global_position + d * (cfg.radius + ground_h(d) + alt + Ship.GROUND_OFFSET)
	_teleport_ship(Transform3D(Basis(right, up, -f), p), v)
	ship.set_mode(mode, true)
	if alt > 60.0:
		ship.set_gear(false, true)


func _teleport_ship(xf: Transform3D, v: Vector3, frozen := false) -> void:
	ship.landed = false
	ship.throttle = 0.0
	ship.teleport(xf, v, frozen or ship.capture_hold)
	Universe.shift_origin(ship.global_position)
	ship._update_environment()
	if ship.camera_rig:
		ship.camera_rig.activate()


func set_ship_velocity(v: Vector3) -> void:
	ship.vel = v
	ship._prev_vel = v
	if not ship.freeze:
		ship.linear_velocity = v
		ship._use_vel_once = true


## Lands the ship on the ground at `d` (feet fitted to the terrain), clamps engaged.
func land_ship(d: Vector3, fwd: Vector3) -> void:
	d = d.normalized()
	var f := (fwd - d * fwd.dot(d)).normalized()
	var right := f.cross(d).normalized()
	var B := Basis(right, d, -f)
	var c := planet.global_position + d * (cfg.radius + ground_h(d) + Ship.GROUND_OFFSET)
	# fit the plane through the ground points under the three feet
	var pts: Array[Vector3] = []
	for foot in Ship.FEET:
		var fw := c + B * foot
		var dir := (fw - planet.global_position).normalized()
		pts.append(planet.global_position + dir * (cfg.radius + ground_h(dir)))
	var n := (pts[1] - pts[0]).cross(pts[2] - pts[0]).normalized()
	if n.dot(d) < 0.0:
		n = -n
	var f2 := (f - n * f.dot(n)).normalized()
	var r2 := f2.cross(n).normalized()
	var B2 := Basis(r2, n, -f2)
	var foot_c := (pts[0] + pts[1] + pts[2]) / 3.0
	var foot_avg := (Ship.FEET[0] + Ship.FEET[1] + Ship.FEET[2]) / 3.0
	var sag := 0.12
	var pos := foot_c - B2 * foot_avg - n * sag
	_teleport_ship(Transform3D(B2, pos), Vector3.ZERO, true)
	ship.set_mode(Ship.Mode.HOVER, true)
	ship.set_gear(true, true)
	ship.landed = true


func build_terrain() -> void:
	planet.set_focus_global(ship.global_position)
	planet.terrain.build_until_stable()


# --- site search (deterministic) ---

func _fib_dir(i: int, n: int) -> Vector3:
	var ga := PI * (3.0 - sqrt(5.0))
	var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
	var r := sqrt(1.0 - y * y)
	return Vector3(cos(ga * i) * r, y, sin(ga * i) * r)


## Highest green mountain (|lat| < 0.6).
func find_peak() -> Vector3:
	if _site_cache.has("peak"):
		return _site_cache["peak"]
	var best := Vector3.UP
	var best_h := -1e9
	for i in 4000:
		var d := _fib_dir(i, 4000)
		if absf(d.y) > 0.6:
			continue
		if planet.terrain.generator.moisture(d) < 0.55:
			continue
		var h := planet.get_height(d)
		if h > best_h:
			best_h = h
			best = d
	_site_cache["peak"] = best
	return best


## Flat dry ground 3–9 km from `site` (scenic landing pad with the mountain in view).
func find_flat_near(site: Vector3) -> Vector3:
	if _site_cache.has("flat"):
		return _site_cache["flat"]
	var t1 := site.cross(Vector3.UP).normalized()
	var t2 := site.cross(t1)
	var best := site
	var best_s := -1e9
	for ring in 6:
		var dist := 7000.0 + ring * 1500.0
		for k in 32:
			var a := TAU * k / 32.0
			var d := (site + (t1 * cos(a) + t2 * sin(a)) * (dist / cfg.radius)).normalized()
			var h := planet.get_height(d) - cfg.sea_level
			if h < 60.0:
				continue
			var e := 12.0 / cfg.radius
			var dh := absf(planet.get_height((d + t1 * e).normalized()) - planet.get_height((d - t1 * e).normalized())) \
				+ absf(planet.get_height((d + t2 * e).normalized()) - planet.get_height((d - t2 * e).normalized()))
			var s := -dh * 4.0 - absf(h - 400.0) * 0.004 - dist * 0.0002
			if s > best_s:
				best_s = s
				best = d
	_site_cache["flat"] = best
	return best


## Heading for the pad shots: facing away from the peak (peak behind the ship), turned a bit.
func pad_heading(site: Vector3, peak: Vector3) -> Vector3:
	return (-tangent_toward(site, peak)).rotated(site, deg_to_rad(28.0))


func tangent_toward(from_d: Vector3, to_d: Vector3) -> Vector3:
	var t := to_d - from_d * to_d.dot(from_d)
	if t.length_squared() < 1e-12:
		t = from_d.cross(Vector3.RIGHT)
	return t.normalized()


func offset_dir(d: Vector3, toward: Vector3, meters: float) -> Vector3:
	return (d + tangent_toward(d, toward) * (meters / cfg.radius)).normalized()


# =====================================================================================
# Capture presets
# =====================================================================================

func apply_capture_preset(preset: String) -> void:
	var fx := ship.get_node("FX") as ShipFX
	fx.force_heat = -1.0
	fx.force_vapor = -1.0
	fx.force_warp = -1.0
	fx.force_thrust = -1.0
	fx.force_dust = -1.0
	var rig := ship.camera_rig as ShipCameraRig
	rig.view_override = Callable()
	rig.set_view(ShipCameraRig.View.CHASE)
	ship.capture_hold = Capture.active
	ship.visual.set_hatch(false, true)
	var peak := find_peak()
	match preset:
		"orbit", "chase_space":
			var d := offset_dir(peak, Vector3.UP, -600000.0 * 0.2)
			var fwd := tangent_toward(d, peak)
			set_sun_at(d, fwd, 30.0, 110.0)
			place_ship(d, 30000.0, fwd, -6.0, Vector3.ZERO, Ship.Mode.SPACE)
			set_ship_velocity(-ship.global_basis.z * 2400.0)
			fx.force_thrust = 0.75
			rig.view_override = _orbit_cam.bind(Vector3(9.0, 7.0, 23.0), Vector3(0, -5.0, -14.0))
		"reentry":
			var d := offset_dir(peak, Vector3.UP, -95000.0)
			var fwd := tangent_toward(d, peak)
			set_sun_at(d, fwd, 28.0, 35.0)
			place_ship(d, 17000.0, fwd, -10.0, Vector3.ZERO, Ship.Mode.SPACE)
			set_ship_velocity(-ship.global_basis.z * 4300.0)
			fx.force_heat = 0.95
			fx.force_thrust = 0.6
			rig.view_override = _orbit_cam.bind(Vector3(-26.0, 9.0, -22.0), Vector3(0, -1.0, 2.0))
		"low_flight":
			var d := offset_dir(peak, Vector3.UP, -14000.0)
			var fwd := tangent_toward(d, peak)
			set_sun_at(d, fwd, 20.0, 150.0)
			place_ship(d, 260.0, fwd, 2.0, Vector3.ZERO, Ship.Mode.ATMOSPHERE)
			set_ship_velocity(-ship.global_basis.z * 430.0)
			fx.force_vapor = 0.7
			fx.force_thrust = 1.0
			rig.view_override = _orbit_cam.bind(Vector3(7.0, 3.2, 22.0), Vector3(0, 0.0, -10.0))
		"cockpit":
			var d := offset_dir(peak, Vector3.UP, -9000.0)
			var fwd := tangent_toward(d, peak)
			set_sun_at(d, fwd, 26.0, 140.0)
			place_ship(d, 700.0, fwd, -3.0, Vector3.ZERO, Ship.Mode.ATMOSPHERE)
			set_ship_velocity(-ship.global_basis.z * 250.0)
			rig.set_view(ShipCameraRig.View.COCKPIT)
		"landed":
			var d := find_flat_near(peak)
			var fwd := pad_heading(d, peak)
			set_sun_at(d, fwd, 38.0, 60.0)
			land_ship(d, fwd)
			ship.visual.set_hatch(true, true)
			rig.view_override = _orbit_cam.bind(Vector3(-16.0, 1.2, -19.0), Vector3(0, -0.8, 0.0))
		"hover":
			var d := find_flat_near(peak)
			var fwd := pad_heading(d, peak)
			set_sun_at(d, fwd, 26.0, 70.0)
			place_ship(d, 7.0, fwd, 0.0, Vector3.ZERO, Ship.Mode.HOVER)
			ship.set_gear(true, true)
			ship.thrust_norm = Vector3(0, 0.45, -0.1)
			rig.view_override = _orbit_cam.bind(Vector3(-20.0, 2.0, 18.0), Vector3(0, -2.0, 0.0))
		"warp":
			var d := offset_dir(peak, Vector3.UP, -60000.0)
			var fwd := -d
			set_sun_at(d, d.cross(Vector3.UP), 0.0, 0.0)
			# 9000 km out, nose on the planet
			var p := planet.global_position + d * 9.0e6
			var right := fwd.cross(Vector3.UP).normalized()
			_teleport_ship(Transform3D(Basis(right, right.cross(fwd), -fwd), p), Vector3.ZERO)
			ship.mode = Ship.Mode.WARP
			ship.warp_state = Ship.WarpState.ACTIVE
			set_ship_velocity(fwd * 2.0e7)
			fx.force_warp = 1.0
			fx.force_thrust = 1.0
		_:
			push_warning("flight_test: unknown preset " + preset)
			return
	if Capture.args.has("cam_off"):
		var o: PackedFloat64Array = String(Capture.args["cam_off"]).split_floats(",")
		var l: PackedFloat64Array = String(Capture.args.get("cam_look", "0,0,0")).split_floats(",")
		rig.view_override = _orbit_cam.bind(Vector3(o[0], o[1], o[2]), Vector3(l[0], l[1], l[2]))
	if preset != "warp":
		build_terrain()
	ship._update_environment()
	if Capture.args.has("probe"):
		var B := ship.global_basis
		for i in 9:
			var q := ship.global_position + B * Vector3(-16.0 * i / 8.0, -2.95, -19.0 * i / 8.0)
			print("  probe %d ground alt %.2f" % [i, ship._ground_alt(planet, q)])
	if rig.view_override.is_valid():
		var cx: Transform3D = rig.view_override.call(rig)
		print("[flight_test] sun in camera space: ", cx.basis.inverse() * (star.global_position - cx.origin).normalized())
	if Capture.args.has("probe"):
		print("  preset end: planet=%s by=%s" % [str(planet.global_position), str(ship.global_basis.y)])
	print("[flight_test] preset %s alt=%.0f m speed=%.0f up·local=%.3f" % [preset, ship.altitude,
		ship.vel.length(), ship.global_basis.y.normalized().dot(ship.up_dir)])


## Camera at a fixed ship-local offset looking at a ship-local point (shot framing).
func _orbit_cam(_rig: ShipCameraRig, offset: Vector3, look: Vector3) -> Transform3D:
	var B := ship.global_basis.orthonormalized()
	var p := ship.global_position + B * offset
	var t := ship.global_position + B * look
	# keep the camera above the ground
	var ga := ship._ground_alt(planet, p)
	if ga < 1.6:
		p += ship.up_dir * (1.6 - ga)
	return Transform3D(Basis.looking_at(t - p, B.y), p)


# =====================================================================================
# Demo flights (deterministic: fixed-fps movie + scripted inputs)
# =====================================================================================

func _start_demo(name_: String) -> void:
	ship.scripted = true
	ship.capture_hold = false
	var rig := ship.camera_rig as ShipCameraRig
	var peak := find_peak()
	match name_:
		"reentry":
			var d := offset_dir(peak, Vector3.UP, -125000.0)
			var fwd := tangent_toward(d, peak)
			set_sun_at(d, fwd, 20.0, 115.0)
			place_ship(d, 15500.0, fwd, -16.0, Vector3.ZERO, Ship.Mode.SPACE)
			var v := -ship.global_basis.z * 4600.0
			set_ship_velocity(v)
			ship.heat = 0.6
			ship.throttle = 0.95
			_demo_state["fwd"] = fwd
			rig.view_override = _demo_reentry_cam
		"landing":
			var site := find_flat_near(peak)
			var fwd := pad_heading(site, peak)
			set_sun_at(site, fwd, 26.0, 70.0)
			var start := offset_dir(site, fwd, -170.0)
			place_ship(start, 85.0, fwd, 0.0, Vector3.ZERO, Ship.Mode.HOVER)
			var v := -ship.global_basis.z * 38.0
			set_ship_velocity(v)
			ship.set_gear(false, true)
			_demo_state["site"] = site
			rig.view_override = _demo_landing_cam
		"hover":
			var site := find_flat_near(peak)
			var fwd := pad_heading(site, peak)
			set_sun_at(site, fwd, 26.0, 70.0)
			place_ship(site, 6.0, fwd, 0.0, Vector3.ZERO, Ship.Mode.HOVER)
			ship.set_gear(true, true)
			rig.view_override = _orbit_cam.bind(Vector3(-20.0, 3.0, 20.0), Vector3(0, -1.5, 0.0))
		"warp":
			var d := offset_dir(peak, Vector3.UP, -40000.0)
			var fwd := -d
			set_sun_at(d, d.cross(Vector3.UP), 10.0, 0.0)
			var p := planet.global_position + d * float(Capture.args.get("warp_dist", "12.0e6"))
			var right := fwd.cross(Vector3.UP).normalized()
			_teleport_ship(Transform3D(Basis(right, right.cross(fwd), -fwd), p), Vector3.ZERO)
			ship.set_mode(Ship.Mode.SPACE, true)
		"autopilot":
			# 3000 km out, pointing away from the planet: R must turn, warp/cruise and stop in orbit
			var d := offset_dir(peak, Vector3.UP, -30000.0)
			var p := planet.global_position + d * 3.0e6
			var right := d.cross(Vector3.UP).normalized()
			_teleport_ship(Transform3D(Basis(right, right.cross(d), -d), p), Vector3.ZERO)
			ship.set_mode(Ship.Mode.SPACE, true)
			ship.target = planet
			ship.toggle_autopilot()
		"takeoff":
			var site := find_flat_near(peak)
			land_ship(site, pad_heading(site, peak))
		"orbit":
			apply_capture_preset("chase_space")
			ship.capture_hold = false
			ship.freeze = false
			set_ship_velocity(ship.vel)
			ship.throttle = 0.5
		_:
			push_warning("flight_test: unknown demo " + name_)
	if name_ != "warp" and name_ != "autopilot":
		build_terrain()
	print("[flight_test] demo %s" % name_)


func _drive_demo(_dt: float) -> void:
	var t := demo_t
	ship.in_move = Vector3.ZERO
	ship.in_stick = Vector2.ZERO
	ship.in_roll = 0.0
	match demo:
		"reentry":
			# hold a shallow flight path, nose slightly above the velocity vector
			var up := ship.up_dir
			var fwd: Vector3 = _demo_state["fwd"]
			fwd = (fwd - up * fwd.dot(up)).normalized()
			var pitch := lerpf(-16.0, -10.0, clampf(t / 8.0, 0.0, 1.0))
			var right := fwd.cross(up).normalized()
			ship.steer_dir = fwd.rotated(right, deg_to_rad(pitch))
			ship.steer_up = up.rotated(fwd, deg_to_rad(12.0 * sin(t * 0.6)))
			ship.throttle = 0.95
		"landing":
			var site: Vector3 = _demo_state["site"]
			ship.steer_dir = Vector3.ZERO
			if t > 0.4 and not ship.gear_down:
				ship.set_gear(true)
			ship.in_move.z = clampf(0.85 - t * 0.2, 0.0, 1.0)
			ship.in_move.y = -0.95 if ship.altitude > 4.0 else (-0.25 if not ship.landed and ship.altitude > 0.3 else 0.0)
			ship.in_stick.x = 0.05 * sin(t * 0.7)
			var _unused := site
		"hover":
			ship.in_stick.x = 0.16
			ship.in_move.y = 0.12 * sin(t * 1.3)
			ship.in_move.x = 0.15 * sin(t * 0.7)
		"warp":
			if t > 0.3 and ship.mode != Ship.Mode.WARP and ship.warp_state == Ship.WarpState.IDLE and not _demo_state.has("warped"):
				ship.set_mode(Ship.Mode.WARP)
				_demo_state["warped"] = true
			ship.throttle = 1.0
			ship.steer_dir = (planet.global_position - ship.global_position).normalized()
		"takeoff":
			# lift off, climb, gear up, accelerate, switch modes up to cruise (should be refused low)
			if t < 3.0:
				ship.in_move.y = 1.0
			elif t < 3.1:
				ship.set_gear(false)
				ship.set_mode(Ship.Mode.ATMOSPHERE)
				ship.throttle = 1.0
			elif t < 8.0:
				ship.steer_dir = (-ship.global_basis.z + ship.up_dir * 0.8).normalized()
			elif t < 8.1:
				ship.set_mode(Ship.Mode.CRUISE)   # refused: atmosphere
				ship.set_mode(Ship.Mode.SPACE)
			else:
				ship.steer_dir = ship.up_dir
				ship.throttle = 1.0
		"orbit":
			ship.in_stick = Vector2(0.12 * sin(t * 0.5), 0.05)
			ship.in_roll = 0.2 * sin(t * 0.4)
	if int(t * 60.0) % 30 == 0:
		var h := ship.get_hud_data()
		print("[demo %s t=%.1f] %s v=%.0f alt=%.0f ρ=%.3f heat=%.2f thr=%.2f warp=%d %s" % [demo, t, h["mode_name"],
			h["speed"], h["altitude"], h["atmosphere_density"], h["heat"], h["throttle"], h["warp_state"], h["message"]])


func _demo_reentry_cam(rig: ShipCameraRig) -> Transform3D:
	var k := clampf(demo_t / 7.0, 0.0, 1.0)
	var off := Vector3(-28.0, 8.0, -24.0).lerp(Vector3(-32.0, 6.0, 4.0), k * k * (3.0 - 2.0 * k))
	return _orbit_cam(rig, off, Vector3(0, -1.0, 4.0))


func _demo_landing_cam(rig: ShipCameraRig) -> Transform3D:
	# world-stable camera: starts trailing, then holds near the pad while the ship settles
	var B := ship.global_basis.orthonormalized()
	var up := ship.up_dir
	var fwd := -B.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	var right := fwd.cross(up).normalized()
	var off := -fwd * 26.0 + right * -14.0 + up * 5.0
	var p := ship.global_position + off
	if not _demo_state.has("cam_p"):
		_demo_state["cam_p"] = p
	var cp: Vector3 = _demo_state["cam_p"]
	cp = cp.lerp(p, 0.06)
	# never below the terrain
	var ga := ship._ground_alt(planet, cp)
	if ga < 2.0:
		cp += up * (2.0 - ga)
	_demo_state["cam_p"] = cp
	var t := ship.global_position + up * -1.0
	return Transform3D(Basis.looking_at(t - cp, up), cp)
