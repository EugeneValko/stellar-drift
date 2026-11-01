class_name ShipFX
extends Node3D
## Visual effects driven by the Ship's flight state (child "FX" of the ship). Builds everything
## in code: engine thrust with spool-up (ShipVisual.set_thrust) + heat shimmer behind the nozzles,
## RCS puffs at Thruster_* markers, re-entry heating (hull overlay + bow shock + plasma wake +
## heat haze + embers + glow light), condensation (transonic vapor cone with a sonic-boom burst,
## wingtip vortex ribbons), space dust streaks, warp tunnel + screen effect + FOV kick + drop-out
## flash/ripple, landing dust (soft lit billows coloured by the ground biome) and sea spray.
## Only marker API of ShipVisual is used (EngineExhaust_*, Thruster_*, NavLight_*): the model may
## change shape. Particle systems that must survive floating-origin shifts use local coordinates;
## world-space ground effects restart on a shift.

const REENTRY_SHADER := preload("res://shaders/ship_reentry.gdshader")
const PLASMA_SHADER := preload("res://shaders/ship_plasma.gdshader")
const VAPOR_SHADER := preload("res://shaders/ship_vapor.gdshader")
const DUST_SHADER := preload("res://shaders/ship_space_dust.gdshader")
const TUNNEL_SHADER := preload("res://shaders/ship_warp_tunnel.gdshader")
const SCREEN_SHADER := preload("res://shaders/ship_warp_screen.gdshader")
const DUST_CLOUD_SHADER := preload("res://shaders/ship_dust_cloud.gdshader")
const HAZE_SHADER := preload("res://shaders/ship_heat_haze.gdshader")
const OVERLAY_PARTS := ["Hull", "Canopy", "GearFront", "GearRearL", "GearRearR", "Hatch"]
const HALF_EXTENTS := Vector3(7.5, 2.0, 10.3)   # ship half size (support function for the shock)

@export var dust_count := 420
@export var dust_box := 90.0
## Max apparent speed for dust motion (above this streaks only lengthen; avoids wrap aliasing).
@export var dust_max_speed := 700.0

var ship: Ship
var vis: ShipVisual

var reentry_mat: ShaderMaterial
var _overlay_meshes: Array[MeshInstance3D] = []
var _overlay_on := false
var _bow: MeshInstance3D
var _bow_mat: ShaderMaterial
var _wake: MeshInstance3D
var _wake_mat: ShaderMaterial
var _heat_light: OmniLight3D
var _embers: GPUParticles3D
var _embers_pm: ParticleProcessMaterial
var _vapor: MeshInstance3D
var _vapor_mat: ShaderMaterial
var _trails: Array[ShipTrail] = []
var _jet_haze: Array[MeshInstance3D] = []
var _jet_haze_mat: ShaderMaterial
var _wake_haze: MeshInstance3D
var _wake_haze_mat: ShaderMaterial
var _billow: GPUParticles3D
var _billow_pm: ParticleProcessMaterial
var _billow_mat: ShaderMaterial
var _skirt: GPUParticles3D
var _skirt_pm: ParticleProcessMaterial
var _skirt_mat: ShaderMaterial
var _spray: GPUParticles3D
var _spray_pm: ParticleProcessMaterial
var _mist: GPUParticles3D
var _mist_pm: ParticleProcessMaterial
var _mist_mat: ShaderMaterial
var _ground_t := 0.0
var _ground_info: Dictionary = {}
var _drop_flash := 0.0
var _ripple := -1.0
## Engine spool 0..1 (start-up after the clamps release, spin-down when landed).
var engine_spool := 0.0
## Total RCS activity (0..~3) for audio.
var rcs_level := 0.0
## Wingtip vortex strength 0..1 (read by audio / debug).
var vortex := 0.0
var _rcs: Array[Dictionary] = []
var _dust: MeshInstance3D
var _dust_mat: ShaderMaterial
var _travel := Vector3.ZERO
var _tunnel: MeshInstance3D
var _tunnel_mat: ShaderMaterial
var _screen: MeshInstance3D
var _screen_mat: ShaderMaterial

var _t := 0.0
var _thrust_s := 0.0
var warp_amount := 0.0
var _flash := 0.0
var _soft_tex: Texture2D
## Overrides for capture stills (negative = automatic).
var force_heat := -1.0
var force_vapor := -1.0
var force_warp := -1.0
var force_thrust := -1.0
var force_dust := -1.0
var force_vortex := -1.0
var force_haze := -1.0
## Capture: ground kind override for the dust ("" = sample the ground).
var force_ground := ""


func _ready() -> void:
	ship = get_parent() as Ship
	vis = ship.get_node_or_null("ShipVisual") as ShipVisual if ship else null
	if ship == null or vis == null:
		push_error("ShipFX: must be a child of Ship with a ShipVisual")
		return
	_soft_tex = _make_soft_texture()
	_build_reentry()
	_build_vapor()
	_build_rcs()
	_build_dust()
	_build_ground_dust()
	_build_haze()
	_build_warp()
	ship.warp_engaged.connect(func() -> void: _flash = 1.0)
	ship.warp_dropped.connect(func() -> void:
		_drop_flash = 1.0
		_ripple = 0.0)
	# world-space dust cannot follow a floating-origin shift: drop the live particles (they would
	# reappear around the ship, which sits at the new origin)
	Universe.origin_shifted.connect(func(_d: Vector3) -> void:
		for gp: GPUParticles3D in [_billow, _skirt, _spray, _mist]:
			var was := gp.emitting
			gp.restart()
			gp.emitting = was)
	if Capture.active:
		_t = 1.3


# =====================================================================================
# Builders
# =====================================================================================

func _make_soft_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.45))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	return t


## Shell of revolution around +Z: apex ring at z=0 to z=length, radius profile r(v), v in 0..1.
static func shell_mesh(length: float, profile: Callable, rings := 24, segs := 48) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in rings + 1:
		var v := float(i) / rings
		var z := v * length
		var r: float = profile.call(v)
		var dv := 0.5 / rings
		var drdz: float = ((profile.call(minf(v + dv, 1.0)) as float) - (profile.call(maxf(v - dv, 0.0)) as float)) \
			/ ((minf(v + dv, 1.0) - maxf(v - dv, 0.0)) * length)
		for j in segs + 1:
			var a := TAU * float(j) / segs
			var c := cos(a)
			var s := sin(a)
			verts.append(Vector3(c * r, s * r, z))
			norms.append(Vector3(c, s, -drdz).normalized())
			uvs.append(Vector2(float(j) / segs, v))
	for i in rings:
		for j in segs:
			var a0 := i * (segs + 1) + j
			var b0 := a0 + segs + 1
			idx.append_array([a0, b0, a0 + 1, a0 + 1, b0, b0 + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _fx_mesh(mesh: Mesh, mat: Material, nm: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.top_level = true
	mi.visible = false
	add_child(mi)
	return mi


func _build_reentry() -> void:
	reentry_mat = ShaderMaterial.new()
	reentry_mat.shader = REENTRY_SHADER
	var model := vis.get_node_or_null("Model")
	if model:
		for c in model.get_children():
			if c is MeshInstance3D and String(c.name) in OVERLAY_PARTS:
				_overlay_meshes.append(c)
	_bow_mat = ShaderMaterial.new()
	_bow_mat.shader = PLASMA_SHADER
	_bow_mat.set_shader_parameter("mode", 0)
	_bow_mat.set_shader_parameter("intensity", 1.1)
	_bow_mat.render_priority = 2
	_bow = _fx_mesh(shell_mesh(26.0, func(v: float) -> float: return 0.3 + 8.0 * pow(v, 0.55), 28, 64),
		_bow_mat, "BowShock")
	_wake_mat = ShaderMaterial.new()
	_wake_mat.shader = PLASMA_SHADER
	_wake_mat.set_shader_parameter("mode", 1)
	_wake_mat.set_shader_parameter("intensity", 0.45)
	_wake_mat.set_shader_parameter("color_a", Color(1.0, 0.5, 0.18))
	_wake_mat.set_shader_parameter("color_b", Color(0.55, 0.2, 0.9))
	_wake_mat.set_shader_parameter("scroll", 10.0)
	_wake_mat.render_priority = 1
	_wake = _fx_mesh(shell_mesh(120.0, func(v: float) -> float: return 2.5 + 6.0 * pow(v, 0.4) * (1.0 - 0.6 * v), 32, 48),
		_wake_mat, "PlasmaWake")
	_heat_light = OmniLight3D.new()
	_heat_light.name = "HeatLight"
	_heat_light.light_color = Color(1.0, 0.5, 0.2)
	_heat_light.omni_range = 30.0
	_heat_light.shadow_enabled = false
	_heat_light.top_level = true
	_heat_light.visible = false
	add_child(_heat_light)
	# embers / plasma sparks streaming aft (ship-local coordinates)
	_embers = GPUParticles3D.new()
	_embers.name = "Embers"
	_embers.amount = 220
	_embers.lifetime = 0.4
	_embers.local_coords = true
	_embers.emitting = false
	_embers.visibility_aabb = AABB(Vector3(-60, -60, -60), Vector3(120, 120, 300))
	_embers_pm = ParticleProcessMaterial.new()
	_embers_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_embers_pm.emission_box_extents = Vector3(6.5, 1.6, 8.0)
	_embers_pm.direction = Vector3(0, 0, 1)
	_embers_pm.spread = 6.0
	_embers_pm.initial_velocity_min = 140.0
	_embers_pm.initial_velocity_max = 320.0
	_embers_pm.gravity = Vector3.ZERO
	_embers_pm.scale_min = 0.5
	_embers_pm.scale_max = 1.2
	var ramp := Gradient.new()
	ramp.set_color(0, Color(3.0, 1.1, 0.35, 1.0))
	ramp.set_color(1, Color(1.2, 0.25, 0.4, 0.0))
	var rt := GradientTexture1D.new()
	rt.gradient = ramp
	_embers_pm.color_ramp = rt
	_embers.process_material = _embers_pm
	var q := QuadMesh.new()
	q.size = Vector2(0.18, 4.0)
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	em.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	em.vertex_color_use_as_albedo = true
	em.albedo_texture = _soft_tex
	q.material = em
	_embers.draw_pass_1 = q
	_embers.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	add_child(_embers)


func _build_vapor() -> void:
	_vapor_mat = ShaderMaterial.new()
	_vapor_mat.shader = VAPOR_SHADER
	_vapor_mat.render_priority = 1
	_vapor = MeshInstance3D.new()
	_vapor.name = "VaporCone"
	_vapor.mesh = shell_mesh(6.5, func(v: float) -> float: return 1.5 + 5.0 * pow(v, 0.8), 12, 64)
	_vapor.material_override = _vapor_mat
	_vapor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vapor.position = Vector3(0, 0.3, -3.2)
	_vapor.visible = false
	add_child(_vapor)
	for nm in ["NavLight_L", "NavLight_R"]:
		var m := vis.get_marker(nm)
		if m == null:
			continue
		var tr := ShipTrail.new()
		tr.name = "Vortex_" + nm.trim_prefix("NavLight_")
		tr.emitter = m
		add_child(tr)
		_trails.append(tr)


func _build_rcs() -> void:
	var inv := ship.global_basis.inverse()
	for m in vis.get_markers("Thruster_"):
		var jet: Vector3 = (inv * m.global_basis) * Vector3(0, 0, -1)
		var arm: Vector3 = ship.to_local(m.global_position)
		var p := GPUParticles3D.new()
		p.name = "RCS_" + String(m.name).trim_prefix("Thruster_")
		p.amount = 24
		p.lifetime = 0.5
		p.local_coords = true
		p.emitting = false
		p.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, -1)
		pm.spread = 9.0
		pm.initial_velocity_min = 16.0
		pm.initial_velocity_max = 26.0
		pm.damping_min = 30.0
		pm.damping_max = 40.0
		pm.gravity = Vector3.ZERO
		pm.scale_min = 0.6
		pm.scale_max = 1.0
		var sc := CurveTexture.new()
		var cv := Curve.new()
		cv.add_point(Vector2(0, 0.25))
		cv.add_point(Vector2(0.3, 1.0))
		cv.add_point(Vector2(1, 1.8))
		sc.curve = cv
		pm.scale_curve = sc
		var g := Gradient.new()
		g.set_color(0, Color(2.5, 2.7, 3.2, 0.9))
		g.set_color(1, Color(0.8, 0.85, 0.95, 0.0))
		g.add_point(0.12, Color(1.0, 1.0, 1.05, 0.55))
		var gt := GradientTexture1D.new()
		gt.gradient = g
		pm.color_ramp = gt
		p.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.9, 0.9)
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.albedo_texture = _soft_tex
		mat.emission_enabled = true
		mat.emission = Color(0.15, 0.17, 0.22)
		q.material = mat
		p.draw_pass_1 = q
		m.add_child(p)
		_rcs.append({"p": p, "jet": jet, "arm": arm, "s": 0.0})


func _build_dust() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in dust_count:
		var b := Vector3(rng.randf(), rng.randf(), rng.randf())
		var k := verts.size()
		for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
			verts.append(b)
			uvs.append(c)
		idx.append_array([k, k + 1, k + 2, k + 2, k + 1, k + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	m.custom_aabb = AABB(Vector3.ONE * -dust_box, Vector3.ONE * dust_box * 2.0)
	_dust_mat = ShaderMaterial.new()
	_dust_mat.shader = DUST_SHADER
	_dust_mat.set_shader_parameter("box", dust_box)
	_dust = _fx_mesh(m, _dust_mat, "SpaceDust")
	_dust.extra_cull_margin = dust_box


## Soft lit billows (GPUParticles3D + ship_dust_cloud shader) for landing dust and sea mist.
func _cloud_particles(nm: String, amount: int, life: float, size: float) -> Array:
	var gp := GPUParticles3D.new()
	gp.name = nm
	gp.amount = amount
	gp.lifetime = life
	gp.local_coords = false
	gp.emitting = false
	gp.top_level = true
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gp.visibility_aabb = AABB(Vector3(-90, -20, -90), Vector3(180, 70, 180))
	gp.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 1, 0)
	pm.emission_ring_radius = 5.0
	pm.emission_ring_inner_radius = 1.0
	pm.emission_ring_height = 0.3
	pm.direction = Vector3(0, 1, 0)
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -12.0
	pm.angular_velocity_max = 12.0
	pm.gravity = Vector3.ZERO
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.12, Color(1, 1, 1, 0.9))
	g.add_point(0.55, Color(1, 1, 1, 0.5))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	var sc := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.3))
	cv.add_point(Vector2(0.4, 0.8))
	cv.add_point(Vector2(1, 1.0))
	sc.curve = cv
	pm.scale_curve = sc
	gp.process_material = pm
	var mat := ShaderMaterial.new()
	mat.shader = DUST_CLOUD_SHADER
	mat.render_priority = 0
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = mat
	gp.draw_pass_1 = q
	add_child(gp)
	return [gp, pm, mat]


func _build_ground_dust() -> void:
	# big billows rolling out from under the engines and rising
	var r := _cloud_particles("DustBillow", 280, 4.5, 12.0)
	_billow = r[0]
	_billow_pm = r[1]
	_billow_mat = r[2]
	_billow_pm.spread = 30.0
	_billow_pm.initial_velocity_min = 0.6
	_billow_pm.initial_velocity_max = 2.4
	_billow_pm.radial_velocity_min = 4.0
	_billow_pm.radial_velocity_max = 10.0
	_billow_pm.damping_min = 2.6
	_billow_pm.damping_max = 3.8
	_billow_pm.scale_min = 0.6
	_billow_pm.scale_max = 1.4
	_billow_mat.set_shader_parameter("soft_dist", 3.0)
	_billow_mat.set_shader_parameter("density", 0.42)
	_billow_mat.set_shader_parameter("edge_breakup", 1.1)
	# fast low skirt of fine dust racing outward along the ground
	r = _cloud_particles("DustSkirt", 240, 1.8, 6.0)
	_skirt = r[0]
	_skirt_pm = r[1]
	_skirt_mat = r[2]
	_skirt_pm.emission_ring_radius = 3.5
	_skirt_pm.emission_ring_inner_radius = 0.5
	_skirt_pm.spread = 8.0
	_skirt_pm.initial_velocity_min = 0.2
	_skirt_pm.initial_velocity_max = 0.8
	_skirt_pm.radial_velocity_min = 16.0
	_skirt_pm.radial_velocity_max = 30.0
	_skirt_pm.damping_min = 6.0
	_skirt_pm.damping_max = 9.0
	_skirt_pm.scale_min = 0.6
	_skirt_pm.scale_max = 1.2
	_skirt_mat.set_shader_parameter("soft_dist", 1.0)
	_skirt_mat.set_shader_parameter("density", 0.35)
	_skirt_mat.set_shader_parameter("noise_scale", 2.2)
	# sea: white mist + droplet spray
	r = _cloud_particles("SeaMist", 120, 3.0, 8.0)
	_mist = r[0]
	_mist_pm = r[1]
	_mist_mat = r[2]
	_mist_pm.spread = 35.0
	_mist_pm.initial_velocity_min = 1.0
	_mist_pm.initial_velocity_max = 3.0
	_mist_pm.radial_velocity_min = 8.0
	_mist_pm.radial_velocity_max = 15.0
	_mist_pm.damping_min = 2.5
	_mist_pm.damping_max = 3.5
	_mist_mat.set_shader_parameter("dust_color", Color(0.9, 0.94, 0.98))
	_mist_mat.set_shader_parameter("density", 0.6)
	_mist_mat.set_shader_parameter("backlight", 0.9)
	_spray = GPUParticles3D.new()
	_spray.name = "SeaSpray"
	_spray.amount = 360
	_spray.lifetime = 1.4
	_spray.local_coords = false
	_spray.emitting = false
	_spray.top_level = true
	_spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_spray.visibility_aabb = AABB(Vector3(-60, -10, -60), Vector3(120, 40, 120))
	_spray_pm = ParticleProcessMaterial.new()
	_spray_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	_spray_pm.emission_ring_axis = Vector3(0, 1, 0)
	_spray_pm.emission_ring_radius = 6.0
	_spray_pm.emission_ring_inner_radius = 2.0
	_spray_pm.emission_ring_height = 0.2
	_spray_pm.direction = Vector3(0, 1, 0)
	_spray_pm.spread = 40.0
	_spray_pm.initial_velocity_min = 3.0
	_spray_pm.initial_velocity_max = 8.0
	_spray_pm.radial_velocity_min = 7.0
	_spray_pm.radial_velocity_max = 16.0
	_spray_pm.damping_min = 0.5
	_spray_pm.damping_max = 1.0
	_spray_pm.gravity = Vector3(0, -9.8, 0)
	_spray_pm.scale_min = 0.5
	_spray_pm.scale_max = 1.2
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.85))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	_spray_pm.color_ramp = gt
	_spray.process_material = _spray_pm
	var q := QuadMesh.new()
	q.size = Vector2(0.09, 0.7)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(0.92, 0.96, 1.0)
	m.albedo_texture = _soft_tex
	m.roughness = 0.3
	m.backlight_enabled = true
	m.backlight = Color(0.6, 0.65, 0.7)
	q.material = m
	_spray.draw_pass_1 = q
	_spray.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	add_child(_spray)


## Heat shimmer: a refracting cone behind every engine nozzle + a shell along the re-entry wake.
func _build_haze() -> void:
	_jet_haze_mat = ShaderMaterial.new()
	_jet_haze_mat.shader = HAZE_SHADER
	_jet_haze_mat.render_priority = -2
	_jet_haze_mat.set_shader_parameter("flow_axis", Vector3(0, -1, 0))
	_jet_haze_mat.set_shader_parameter("v_end", 0.85)
	_jet_haze_mat.set_shader_parameter("freq", 1.4)
	_jet_haze_mat.set_shader_parameter("scroll", 9.0)
	for m in vis.get_markers("EngineExhaust_"):
		var r := 0.55
		if m.has_meta("extras") and m.get_meta("extras") is Dictionary:
			r = float((m.get_meta("extras") as Dictionary).get("radius", 0.55))
		var plen := 16.0
		var cyl := CylinderMesh.new()
		cyl.top_radius = r * 1.05
		cyl.bottom_radius = r * 3.6
		cyl.height = plen
		cyl.radial_segments = 16
		cyl.rings = 4
		cyl.cap_top = false
		cyl.cap_bottom = false
		var mi := MeshInstance3D.new()
		mi.name = "JetHaze"
		mi.mesh = cyl
		mi.material_override = _jet_haze_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		# cylinder +Y -> marker -Z (plume direction), nozzle end at the marker (as the plumes)
		mi.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0, 0, -plen * 0.5 - 0.3))
		mi.visible = false
		m.add_child(mi)
		_jet_haze.append(mi)
	_wake_haze_mat = ShaderMaterial.new()
	_wake_haze_mat.shader = HAZE_SHADER
	_wake_haze_mat.render_priority = -2
	_wake_haze_mat.set_shader_parameter("flow_axis", Vector3(0, 0, 1))
	_wake_haze_mat.set_shader_parameter("v_start", 0.02)
	_wake_haze_mat.set_shader_parameter("v_end", 0.9)
	_wake_haze_mat.set_shader_parameter("freq", 0.35)
	_wake_haze_mat.set_shader_parameter("scroll", 40.0)
	_wake_haze_mat.set_shader_parameter("max_offset", 0.02)
	_wake_haze_mat.set_shader_parameter("tint", Color(1.0, 0.75, 0.55))
	_wake_haze = _fx_mesh(shell_mesh(70.0, func(v: float) -> float: return 3.0 + 9.0 * pow(v, 0.5), 16, 32),
		_wake_haze_mat, "WakeHaze")


func _build_warp() -> void:
	_tunnel_mat = ShaderMaterial.new()
	_tunnel_mat.shader = TUNNEL_SHADER
	_tunnel_mat.render_priority = 10
	var cyl := CylinderMesh.new()
	cyl.top_radius = 26.0
	cyl.bottom_radius = 26.0
	cyl.height = 4000.0
	cyl.radial_segments = 64
	cyl.rings = 16
	cyl.cap_top = false
	cyl.cap_bottom = false
	_tunnel_mat.set_shader_parameter("length_m", cyl.height)
	_tunnel = _fx_mesh(cyl, _tunnel_mat, "WarpTunnel")
	_tunnel.extra_cull_margin = 4000.0
	_screen_mat = ShaderMaterial.new()
	_screen_mat.shader = SCREEN_SHADER
	_screen_mat.render_priority = 127
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_screen = _fx_mesh(quad, _screen_mat, "WarpScreen")
	_screen.extra_cull_margin = 16384.0


# =====================================================================================
# Update
# =====================================================================================

func _process(dt: float) -> void:
	if ship == null or vis == null:
		return
	if not Capture.active:
		_t += dt
	else:
		_t += dt * 0.0 + 1.0 / 60.0
	var v := ship.vel
	var speed := v.length()
	var vdir := v / speed if speed > 0.5 else -ship.global_basis.z
	var B := ship.global_basis.orthonormalized()
	var cam := get_viewport().get_camera_3d()
	_update_engine(dt)
	_update_rcs(dt)
	_update_reentry(dt, vdir, speed, B)
	_update_vapor(dt, vdir, speed, B)
	_update_dust(dt, cam, speed)
	_update_ground_dust(dt)
	_update_warp(dt, cam, vdir, speed)
	if Capture.args.has("fx_hide"):
		for n in String(Capture.args["fx_hide"]).split(","):
			var node := get_node_or_null(n) as Node3D
			if node:
				node.visible = false


func _update_engine(dt: float) -> void:
	# spool: engines wind up over ~1.5 s after the clamps release, wind down when landed
	var running := (ship.is_piloted or ship.scripted) and not ship.landed
	var spool_t := 1.0 if running else 0.0
	engine_spool = move_toward(engine_spool, spool_t, dt * (0.75 if spool_t > engine_spool else 0.3))
	if ship.capture_hold:
		engine_spool = 0.0 if ship.landed else 1.0
	var sp := engine_spool * engine_spool * (3.0 - 2.0 * engine_spool)
	var t := clampf(-ship.thrust_norm.z, 0.0, 1.0) * lerpf(0.75, 1.0, ship.boost_t)
	# VTOL lift shows in the main engines too (hover / take-off)
	if ship.mode == Ship.Mode.HOVER:
		t = maxf(t, clampf(ship.thrust_norm.y, 0.0, 1.0) * 0.45)
	t = maxf(t, 0.06) * (0.2 + 0.8 * sp)
	if not running and not ship.capture_hold:
		t = 0.06 * sp
	if ship.warp_state != Ship.WarpState.IDLE:
		t = maxf(t, 0.5 + 0.5 * ship.warp_spool)
	if force_thrust >= 0.0:
		t = force_thrust
	_thrust_s = lerpf(_thrust_s, t, 1.0 - exp(-dt * (8.0 if t > _thrust_s else 3.0)))
	vis.set_thrust(_thrust_s)
	# heat shimmer behind the nozzles: strong in air, faint in vacuum
	var air := clampf(ship.density * 4.0, 0.0, 1.0)
	var hz := _thrust_s * (0.35 + 0.65 * air)
	if force_haze >= 0.0:
		hz = force_haze
	var on := hz > 0.02
	for mi in _jet_haze:
		mi.visible = on
	if on:
		_jet_haze_mat.set_shader_parameter("strength", clampf(hz * 1.4, 0.0, 1.6))
		_jet_haze_mat.set_shader_parameter("time_s", _t)


func _update_rcs(dt: float) -> void:
	var md: Dictionary = Ship.MODES[ship.mode]
	var alpha: Vector3 = (md["rate"] as Vector3) * (PI / 180.0 * 4.0)
	var aa := ship.ang_accel_local
	aa = Vector3(clampf(aa.x / alpha.x, -1, 1), clampf(aa.y / alpha.y, -1, 1), clampf(aa.z / alpha.z, -1, 1))
	var lin := Vector3(ship.thrust_norm.x, ship.thrust_norm.y, 0.0)
	var active := (ship.is_piloted or ship.scripted) and not ship.landed and not ship.capture_hold
	var total := 0.0
	for r: Dictionary in _rcs:
		var push: Vector3 = -(r["jet"] as Vector3)
		var li := maxf(push.dot(lin), 0.0)
		var td: Vector3 = (r["arm"] as Vector3).cross(push)
		var ai := 0.0
		if td.length_squared() > 1e-6:
			ai = maxf(td.normalized().dot(aa), 0.0)
		var target := clampf(li * 1.1 + ai * 1.3, 0.0, 1.0) if active else 0.0
		var s: float = r["s"]
		s = lerpf(s, target, 1.0 - exp(-dt * (25.0 if target > s else 6.0)))
		r["s"] = s
		total += s
		var p: GPUParticles3D = r["p"]
		p.emitting = s > 0.06
		p.amount_ratio = clampf(s, 0.05, 1.0)
	rcs_level = total


func _update_reentry(_dt: float, vdir: Vector3, speed: float, B: Basis) -> void:
	var h := ship.heat if force_heat < 0.0 else force_heat
	var on := h > 0.01
	if on != _overlay_on:
		_overlay_on = on
		for mi in _overlay_meshes:
			mi.material_overlay = reentry_mat if on else null
	_bow.visible = on
	_wake.visible = on
	_wake_haze.visible = on
	_heat_light.visible = on
	_embers.emitting = h > 0.12
	if not on:
		return
	var vl := B.transposed() * vdir
	reentry_mat.set_shader_parameter("heat", h)
	reentry_mat.set_shader_parameter("flow_dir", vl)
	reentry_mat.set_shader_parameter("time_s", _t)
	# shock apex just ahead of the hull along the velocity (ellipsoid support distance)
	var support := (HALF_EXTENTS * vl).length()
	var sp := ship.global_position
	var basis := Basis.looking_at(vdir, B.y if absf(vdir.dot(B.y)) < 0.95 else B.x)
	_bow.global_transform = Transform3D(basis, sp + vdir * (support + 2.2))
	_bow.scale = Vector3.ONE * lerpf(0.9, 1.05, h)
	_bow_mat.set_shader_parameter("amount", smoothstep(0.0, 0.6, h))
	_bow_mat.set_shader_parameter("time_s", _t)
	_wake.global_transform = Transform3D(basis, sp + vdir * (support * 0.4))
	_wake.scale = Vector3(1.0, 1.0, lerpf(0.35, 1.0, h))
	_wake_mat.set_shader_parameter("amount", smoothstep(0.1, 0.9, h))
	_wake_mat.set_shader_parameter("time_s", _t)
	_wake_haze.global_transform = Transform3D(basis, sp + vdir * (support * 0.2))
	_wake_haze_mat.set_shader_parameter("strength", smoothstep(0.05, 0.7, h) * 1.2)
	_wake_haze_mat.set_shader_parameter("time_s", _t)
	_heat_light.global_position = sp + vdir * (support + 1.0)
	_heat_light.light_energy = h * h * 9.0
	_embers_pm.direction = -vl
	_embers.amount_ratio = clampf(h * 1.2, 0.1, 1.0)
	_embers_pm.initial_velocity_min = clampf(speed * 0.04, 60.0, 200.0)
	_embers_pm.initial_velocity_max = clampf(speed * 0.09, 120.0, 400.0)


func _update_vapor(dt: float, _vdir: Vector3, speed: float, _B: Basis) -> void:
	var vp := ship.vapor if force_vapor < 0.0 else force_vapor
	_vapor.visible = vp > 0.01
	if _vapor.visible:
		_vapor_mat.set_shader_parameter("amount", vp)
		_vapor_mat.set_shader_parameter("time_s", _t)
		# the boom burst: the shock ring balloons out and thins
		var b := ship.boom_t
		_vapor.scale = Vector3.ONE * (1.0 + ((1.0 - b) * 0.6 if b > 0.0 else 0.0))
	# wingtip vortices: humid air + lift (hard turns / pulling g) + the transonic cone
	var w := ship.angular_velocity.length() if not ship.capture_hold else 0.0
	var load_k := clampf(w * speed / 200.0, 0.0, 1.0) + clampf(absf(ship.thrust_norm.y) * speed / 400.0, 0.0, 0.5)
	var wet := clampf((ship.density - 0.12) / 0.3, 0.0, 1.0)
	var target := clampf(maxf(vp * 0.8, load_k * wet * clampf((speed - 60.0) / 120.0, 0.0, 1.0)), 0.0, 1.0)
	if force_vortex >= 0.0:
		target = force_vortex
	vortex = lerpf(vortex, target, 1.0 - exp(-dt * 6.0))
	if force_vortex >= 0.0:
		vortex = force_vortex
	for tr in _trails:
		tr.intensity = vortex
		tr.synthetic = ship.capture_hold
		tr.synthetic_vel = ship.vel


func _update_dust(dt: float, cam: Camera3D, speed: float) -> void:
	if cam == null:
		_dust.visible = false
		return
	var amt := (1.0 - smoothstep(0.0, 0.004, ship.density)) * smoothstep(3.0, 40.0, speed) \
		* (1.0 - clampf(warp_amount * 2.0, 0.0, 1.0))
	if force_dust >= 0.0:
		amt = force_dust
	_dust.visible = amt > 0.01
	var v := ship.vel
	var va := v.limit_length(dust_max_speed)
	if not ship.capture_hold:
		_travel = (_travel + va * dt)
		_travel = Vector3(fposmod(_travel.x, dust_box), fposmod(_travel.y, dust_box), fposmod(_travel.z, dust_box))
	if not _dust.visible:
		return
	_dust.global_transform = Transform3D(Basis.IDENTITY, cam.global_position)
	# streak length grows with log(speed) beyond the apparent cap
	var stretch := 1.0 + clampf(log(maxf(speed, 1.0) / dust_max_speed), 0.0, 6.0) * 0.35
	_dust_mat.set_shader_parameter("travel", _travel)
	_dust_mat.set_shader_parameter("vel_app", va * stretch)
	_dust_mat.set_shader_parameter("amount", amt)


func _ground_off() -> void:
	for gp: GPUParticles3D in [_billow, _skirt, _spray, _mist]:
		gp.emitting = false


## Landing dust / sea spray under the engines: strength from height and lift thrust; colour and
## kind (dust vs water) from the ground under the ship (GroundInfo, sampled ~4x per second).
func _update_ground_dust(dt: float) -> void:
	var b := ship.body
	if b == null or not (b is Planet):
		_ground_off()
		return
	var alt := ship.altitude
	var lift := clampf(absf(ship.thrust_norm.y) * 1.6 + clampf(-ship.thrust_norm.z, 0.0, 1.0) * 0.4, 0.3, 1.0)
	# the exhaust reaches the ground below ~45 m
	var k := clampf(1.0 - alt / 45.0, 0.0, 1.0)
	k = k * k * (3.0 - 2.0 * k) * lift * (0.35 + 0.65 * engine_spool)
	if not (ship.is_piloted or ship.scripted) or alt < -1.0 or (ship.landed and not ship.capture_hold):
		k = 0.0
	if force_dust >= 0.0:
		k = force_dust
	if k <= 0.02:
		_ground_off()
		return
	var up := ship.up_dir
	var gp_pos := ship.global_position - up * (alt + Ship.GROUND_OFFSET)
	_ground_t -= dt
	if _ground_t <= 0.0 or _ground_info.is_empty():
		_ground_t = 0.25
		_ground_info = GroundInfo.sample(b, gp_pos)
		if force_ground != "":
			_ground_info = _ground_info.duplicate()
			_ground_info["kind"] = force_ground
			_ground_info["water"] = force_ground == "water"
	var water: bool = bool(_ground_info.get("water", false))
	var kind := String(_ground_info.get("kind", "sand"))
	var fwd := ship.global_basis.z
	fwd = fwd - up * fwd.dot(up)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else up.cross(Vector3.RIGHT).normalized()
	var xf := Transform3D(Basis(up.cross(fwd).normalized(), up, fwd), gp_pos + up * 0.4)
	# how much loose material: lots on sand/regolith, some on rock/soil, little on grass
	var loose: float = {"sand": 1.0, "rock": 0.65, "grass": 0.45, "snow": 0.8}.get(kind, 0.8)
	var dust_k := 0.0 if water else k * loose
	var sea_k := k if water else 0.0
	var air := clampf(ship.density * 3.0, 0.0, 1.0)
	_billow.emitting = dust_k > 0.03
	_skirt.emitting = dust_k > 0.05
	_mist.emitting = sea_k > 0.03
	_spray.emitting = sea_k > 0.06
	if dust_k > 0.03:
		var col: Color = _ground_info.get("color", Color(0.7, 0.62, 0.5))
		# loose dust is lighter than the surface albedo, a touch desaturated
		var lum := col.get_luminance()
		var dc := col.lerp(Color(lum, lum, lum), 0.45).lerp(Color(0.78, 0.74, 0.68), 0.3) * 1.1
		if kind == "snow":
			dc = Color(0.95, 0.97, 1.0)
		for m: ShaderMaterial in [_billow_mat, _skirt_mat]:
			m.set_shader_parameter("dust_color", Color(dc.r, dc.g, dc.b))
		_billow.global_transform = xf
		_skirt.global_transform = xf
		_billow.amount_ratio = clampf(dust_k, 0.05, 1.0)
		_skirt.amount_ratio = clampf(dust_k, 0.05, 1.0)
		_billow_pm.radial_velocity_min = lerpf(3.0, 6.0, dust_k)
		_billow_pm.radial_velocity_max = lerpf(6.0, 12.0, dust_k)
		# airless: the dust flies far and falls ballistically, no rising billows
		_billow_pm.gravity = -up * lerpf(1.2, -0.35, air)
		_billow_pm.damping_min = lerpf(0.4, 2.2, air)
		_billow_pm.damping_max = lerpf(0.8, 3.4, air)
		_skirt_pm.gravity = -up * lerpf(0.8, 0.0, air)
	if sea_k > 0.03:
		_mist.global_transform = xf
		_spray.global_transform = xf
		_mist.amount_ratio = clampf(sea_k, 0.05, 1.0)
		_spray.amount_ratio = clampf(sea_k, 0.05, 1.0)
		_mist_pm.gravity = up * 0.3
		_spray_pm.gravity = -up * 9.8


func _update_warp(dt: float, cam: Camera3D, vdir: Vector3, speed: float) -> void:
	var target := 0.0
	match ship.warp_state:
		Ship.WarpState.SPOOL:
			target = 0.3 * ship.warp_spool
		Ship.WarpState.ACTIVE:
			target = clampf(0.45 + 0.55 * speed / 3.0e6, 0.45, 1.0)
	if ship.warp_state == Ship.WarpState.IDLE and speed > 50000.0:
		target = clampf((speed - 50000.0) / 250000.0, 0.0, 0.3)   # faint streaks in fast cruise
	if force_warp >= 0.0:
		target = force_warp
	warp_amount = lerpf(warp_amount, target, 1.0 - exp(-dt * (2.0 if target > warp_amount else 1.2)))
	_flash = maxf(_flash - dt * 2.2, 0.0)
	if not Capture.active:
		_drop_flash = maxf(_drop_flash - dt * 1.6, 0.0)
		if _ripple >= 0.0:
			_ripple += dt / 1.1
			if _ripple >= 1.0:
				_ripple = -1.0
	var rig := ship.camera_rig as ShipCameraRig
	if rig:
		var spool_kick := -4.0 * ship.warp_spool if ship.warp_state == Ship.WarpState.SPOOL else 0.0
		# drop-out: the view "snaps back" (FOV punch below normal, recovering)
		var drop_kick := -9.0 * _drop_flash * _drop_flash
		var warp_on := ship.warp_state == Ship.WarpState.ACTIVE or force_warp >= 0.0
		rig.fov_kick = spool_kick + 24.0 * warp_amount * (1.0 if warp_on else 0.4) + 10.0 * _flash + drop_kick
		rig.shake_extra = (0.06 * ship.warp_spool if ship.warp_state == Ship.WarpState.SPOOL else 0.0) \
			+ _flash * 0.25 + warp_amount * 0.01
	var flash_all := maxf(_flash, _drop_flash * 0.8)
	var on := warp_amount > 0.01 and cam != null
	_tunnel.visible = on
	_screen.visible = cam != null and ((on and warp_amount > 0.08) or flash_all > 0.01 or _ripple >= 0.0)
	if cam == null or (not on and flash_all <= 0.01 and _ripple < 0.0):
		return
	var dir := vdir if speed > 100.0 else -ship.global_basis.z
	var up := ship.global_basis.y
	if absf(dir.dot(up)) > 0.95:
		up = ship.global_basis.x
	var x := dir.cross(up).normalized()
	var z := x.cross(dir).normalized()
	_tunnel.global_transform = Transform3D(Basis(x, dir, z), cam.global_position + dir * 600.0)
	_tunnel_mat.set_shader_parameter("amount", warp_amount)
	_tunnel_mat.set_shader_parameter("time_s", _t)
	_tunnel_mat.set_shader_parameter("speed", 0.6 + 2.4 * warp_amount)
	_screen.global_position = cam.global_position - cam.global_basis.z * 1.0
	var center := Vector2(0.5, 0.5)
	var ahead := cam.global_position + dir * 10000.0
	if not cam.is_position_behind(ahead):
		center = cam.unproject_position(ahead) / get_viewport().get_visible_rect().size
	_screen_mat.set_shader_parameter("center", center)
	_screen_mat.set_shader_parameter("amount", warp_amount)
	_screen_mat.set_shader_parameter("flash", _flash * 0.6 + _drop_flash * _drop_flash * 0.9)
	_screen_mat.set_shader_parameter("ripple", _ripple)


func clear_dropout() -> void:
	_drop_flash = 0.0
	_ripple = -1.0


## Capture: pre-simulates the ground dust / spray so a still shows developed clouds.
func prewarm_ground(sec: float) -> void:
	for gp: GPUParticles3D in [_billow, _skirt, _spray, _mist]:
		gp.preprocess = sec
		gp.restart()


## Capture helper: freeze a warp drop-out at progress `t` (0..1) for a still.
func preview_dropout(t: float) -> void:
	_drop_flash = clampf(1.0 - t * 1.6, 0.0, 1.0)
	_ripple = clampf(t, 0.0, 0.99)
