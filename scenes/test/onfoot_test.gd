extends Node3D
## Wave 2D test scene: Selene (R = 10 km) + space sky + sun, the TestShipStub landed on a flat
## spot, the Player next to it, GameMode + HUD + F1 overlay. Playable (walk, F to board/exit,
## C third person, V free camera if present, H HUD, F1 help).
## Capture presets: onfoot_fp, onfoot_tp, hud_ship, help  (use --hud to show the HUD).
## Extra args: --sky_planet=0 (no Terra Nova in the sky), --site=x,y,z (planet-local direction).

const PlanetScene := preload("res://scenes/planets/planet.tscn")
const ATMO_SCENE := preload("res://scenes/planets/atmosphere.tscn")
const SELENE := "res://src/planets/presets/selene.tres"
const TERRA_R := 60000.0
const TERRA_DIST := 400000.0

@onready var world: Node3D = $World
@onready var ship: TestShipStub = $World/Ship
@onready var game_mode: GameMode = $GameMode
@onready var hud: Hud = $Hud
@onready var help: HelpOverlay = $HelpOverlay
@onready var sun: DirectionalLight3D = $Sun
@onready var sky_env: WorldEnvironment = $SpaceBackdrop

var planet: Planet
var site_dir := Vector3.UP
var ship_fwd := Vector3.FORWARD
var terra: Node3D
var terra_ground: PlaceholderBody


func _ready() -> void:
	add_to_group("capture_target")
	Universe.set_world_root(world)
	sky_env.environment = sky_env.environment.duplicate()
	var env := sky_env.environment
	env.ambient_light_energy = 0.35
	env.ambient_light_color = Color(0.5, 0.56, 0.7)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_exposure = 1.05
	planet = PlanetScene.instantiate() as Planet
	planet.name = "Selene"
	planet.config = load(SELENE)
	planet.surface_gravity = 1.62
	planet.auto_focus_camera = true
	world.add_child(planet)
	world.move_child(planet, 0)
	Universe.register_body(planet)
	site_dir = _find_flat_site(_arg_vec("site", Vector3(0.35, 0.82, 0.45)))
	# floating origin: put the landing site at the world origin
	planet.position = -planet.get_surface_point(site_dir)
	var east := Vector3.UP.cross(site_dir).normalized()
	ship_fwd = east.rotated(site_dir, deg_to_rad(25.0))
	ship.land_on(planet, site_dir, ship_fwd)
	_aim_sun(32.0, -55.0)
	if Capture.args.get("sky_planet", "1") != "0":
		_build_sky_planet()
	game_mode.ensure_started()
	# player: a few metres in front-left of the ramp, facing the ship
	_place_player(Vector3(-4.5, 0.0, -9.0), Vector3(0.0, -1.0, -2.0))
	planet.set_focus_global(game_mode.player.global_position)
	planet.terrain.build_until_stable()
	if not Capture.active:
		var p := Capture.get_preset()
		if p != "":
			apply_capture_preset(p)


func _arg_vec(key: String, def: Vector3) -> Vector3:
	if not Capture.args.has(key):
		return def.normalized()
	var a := String(Capture.args[key]).split(",")
	return Vector3(float(a[0]), float(a[1]), float(a[2])).normalized()


## Flattest spot (height range over a 30 m square) among candidates around `base`.
func _find_flat_site(base: Vector3) -> Vector3:
	var R := planet.config.radius
	var t1 := base.cross(Vector3.RIGHT).normalized()
	var t2 := base.cross(t1).normalized()
	var best := base
	var best_score := INF
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 220:
		var off := Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * (3000.0 / R)
		var d := (base + t1 * off.x + t2 * off.y).normalized()
		var a := d.cross(Vector3.RIGHT).normalized()
		var b := d.cross(a).normalized()
		var lo := INF
		var hi := -INF
		for gx in [-15.0, 0.0, 15.0]:
			for gy in [-15.0, 0.0, 15.0]:
				var h := planet.get_height((d + (a * gx + b * gy) / R).normalized())
				lo = minf(lo, h)
				hi = maxf(hi, h)
		var score := hi - lo
		if score < best_score:
			best_score = score
			best = d
	print("[onfoot_test] site %s, height range over 30 m: %.2f m" % [str(best), best_score])
	return best


## Sun at `elev` degrees above the site horizon, `az` degrees from the ship's nose.
func _aim_sun(elev: float, az: float) -> void:
	var up := site_dir
	var horiz := ship_fwd.rotated(up, deg_to_rad(az))
	var to_sun := (horiz * cos(deg_to_rad(elev)) + up * sin(deg_to_rad(elev))).normalized()
	SunGlobals.aim_light(sun, to_sun)
	SunGlobals.sync_from_light(sun)


## Ship-space offset -> world point near the ship, on the ground.
func _ground_near_ship(local: Vector3) -> Vector3:
	var wp := ship.global_transform * Vector3(local.x, 0.0, local.z)
	var d := planet.to_local(wp).normalized()
	return planet.to_global(planet.get_surface_point(d))


func _place_player(local: Vector3, look_local: Vector3) -> void:
	var p := game_mode.player
	var at := _ground_near_ship(local) + site_dir * 0.02
	p.place_at(Transform3D(Basis(), at))
	p.look_at_point(ship.global_transform * look_local)


func _build_sky_planet() -> void:
	# Terra Nova hanging in Selene's sky (placeholder ground + real atmosphere shader).
	var dir := (site_dir * 0.55 + ship_fwd * 0.75 + site_dir.cross(ship_fwd) * -0.25).normalized()
	terra = Node3D.new()
	terra.name = "TerraNovaSky"
	world.add_child(terra)
	terra.global_position = planet.global_position + dir * TERRA_DIST
	terra_ground = PlaceholderBody.new()
	terra_ground.radius = TERRA_R
	terra.add_child(terra_ground)
	var atmo := ATMO_SCENE.instantiate()
	terra.add_child(atmo)
	atmo.setup({"preset": "terra_nova", "radius": TERRA_R, "quality": 1})
	LayerParams.apply_uniforms(terra_ground.material, atmo.uniforms)
	terra_ground.focus(terra.to_local(Vector3.ZERO))


func _process(_dt: float) -> void:
	if terra_ground and not Capture.active:
		var cam := get_viewport().get_camera_3d()
		if cam:
			terra_ground.focus(terra.to_local(cam.global_position))


# ------------------------------------------------------------------ capture presets

func apply_capture_preset(preset: String) -> void:
	game_mode.ensure_started()
	var p := game_mode.player
	help.set_open(false, true)
	if preset != "hud_ship":
		_reset_ship()
		if game_mode.state != GameMode.State.ON_FOOT:
			game_mode.force_on_foot()
		game_mode.set_hatch_open(true, true)
		_aim_sun(38.0, 80.0)
	match preset:
		"onfoot_fp":
			p.set_third_person(false)
			# within interact distance of the ramp end, looking up the open ramp
			_place_player(Vector3(-3.3, 0.0, -5.7), Vector3(0.4, -1.3, -1.6))
		"help":
			p.set_third_person(false)
			_place_player(Vector3(-8.0, 0.0, -15.0), Vector3(0.0, -0.8, 0.0))
			help.set_open(true, true)
		"onfoot_tp":
			_place_player(Vector3(-6.5, 0.0, -11.5), Vector3(0.0, -0.8, 1.0))
			p.set_third_person(true)
			p.set_pitch_deg(-4.0)
		"hud_ship":
			_aim_sun(32.0, -55.0)
			_pose_ship_flying()
		_:
			push_warning("onfoot_test: unknown preset " + preset)
			return
	var cam := get_viewport().get_camera_3d()
	if cam:
		if preset == "hud_ship":
			_place_sky_planet(cam, 17.0, 13.0)
		else:
			_place_sky_planet(cam, -24.0, 24.0)
		planet.set_focus_global(cam.global_position)
	if preset == "hud_ship" and terra:
		ship.fake["target_position"] = terra.global_position
		ship.fake["target_radius"] = TERRA_R
		ship.fake["target_distance"] = ship.global_position.distance_to(terra.global_position) - TERRA_R
	planet.terrain.build_until_stable()
	print("[onfoot_test] preset %s: state=%s hatch_dist=%.1f m" % [preset, game_mode.get_state_name(), game_mode.distance_to_hatch()])


## Moves the sky planet to `yaw`/`pitch` degrees off the camera's view direction (screenshots).
func _place_sky_planet(cam: Camera3D, yaw: float, pitch: float) -> void:
	if terra == null:
		return
	var b := cam.global_basis
	var y := deg_to_rad(yaw)
	var pt := deg_to_rad(pitch)
	var dir := (b * Vector3(sin(y) * cos(pt), sin(pt), -cos(y) * cos(pt))).normalized()
	terra.global_position = cam.global_position + dir * TERRA_DIST
	terra_ground.focus(terra.to_local(cam.global_position))


func _reset_ship() -> void:
	ship.fake = {}
	ship.third_person = false
	ship.land_on(planet, site_dir, ship_fwd)
	ship.get_visual().set_thrust(0.0)
	ship._place_cameras()


func _pose_ship_flying() -> void:
	var up := site_dir
	var alt := 1350.0
	var fwd := ship_fwd.rotated(up, deg_to_rad(-30.0))
	var ground := planet.to_global(planet.get_surface_point(up))
	var pitch_basis := Basis.looking_at(fwd, up)
	pitch_basis = pitch_basis.rotated(pitch_basis.x, deg_to_rad(-7.0)) * Basis(Vector3.FORWARD, deg_to_rad(-9.0))
	ship.global_transform = Transform3D(pitch_basis, ground + up * alt)
	ship.landed = false
	ship.get_visual().set_gear(false, true)
	ship.get_visual().set_thrust(0.62)
	var vel := (fwd * 1843.0 + up * -42.0)
	ship.third_person = true
	ship.fake = {
		"speed": vel.length(), "vertical_speed": -42.0, "mode": 2, "mode_name": "Space",
		"mode_max_speed": 5000.0, "throttle": 0.62, "gear_down": false, "landed": false,
		"flight_assist": true, "autopilot": true, "heat": 0.0, "atmosphere_density": 0.0,
		"velocity": vel, "target_name": "Terra Nova",
	}
	if game_mode.state != GameMode.State.SHIP:
		game_mode.force_ship()
	# chase camera a bit to the side for a nicer composition
	ship.chase_camera.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-10.0), deg_to_rad(-16.0), 0.0)),
		Vector3(-6.5, 5.0, 19.5))
	ship.chase_camera.make_current()
