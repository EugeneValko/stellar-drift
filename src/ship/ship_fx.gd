class_name ShipFX
extends Node3D
## Visual effects driven by the Ship's flight state (child "FX" of the ship). Builds everything
## in code: engine thrust (ShipVisual.set_thrust), RCS puffs at Thruster_* markers, re-entry
## heating (hull overlay + bow shock + plasma wake + embers + glow light), condensation (vapor
## cone + wingtip trails), space dust streaks, warp tunnel + screen effect + FOV kick, landing dust.
## All particle systems that must survive floating-origin shifts use local coordinates.

const REENTRY_SHADER := preload("res://shaders/ship_reentry.gdshader")
const PLASMA_SHADER := preload("res://shaders/ship_plasma.gdshader")
const VAPOR_SHADER := preload("res://shaders/ship_vapor.gdshader")
const DUST_SHADER := preload("res://shaders/ship_space_dust.gdshader")
const TUNNEL_SHADER := preload("res://shaders/ship_warp_tunnel.gdshader")
const SCREEN_SHADER := preload("res://shaders/ship_warp_screen.gdshader")
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
var _wing_trails: Array[GPUParticles3D] = []
var _rcs: Array[Dictionary] = []
var _dust: MeshInstance3D
var _dust_mat: ShaderMaterial
var _travel := Vector3.ZERO
var _ground_dust: GPUParticles3D
var _ground_pm: ParticleProcessMaterial
var _ground_mat: StandardMaterial3D
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
	_build_warp()
	ship.warp_engaged.connect(func() -> void: _flash = 1.0)
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
		var p := GPUParticles3D.new()
		p.name = "WingVapor"
		p.amount = 140
		p.lifetime = 0.35
		p.local_coords = true
		p.emitting = false
		p.visibility_aabb = AABB(Vector3(-20, -20, -10), Vector3(40, 40, 120))
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, 1)
		pm.spread = 1.5
		pm.initial_velocity_min = 110.0
		pm.initial_velocity_max = 130.0
		pm.gravity = Vector3.ZERO
		pm.scale_min = 0.8
		pm.scale_max = 1.2
		var sc := CurveTexture.new()
		var cv := Curve.new()
		cv.add_point(Vector2(0, 0.4))
		cv.add_point(Vector2(1, 1.6))
		sc.curve = cv
		pm.scale_curve = sc
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 0.32))
		g.set_color(1, Color(1, 1, 1, 0.0))
		var gt := GradientTexture1D.new()
		gt.gradient = g
		pm.color_ramp = gt
		p.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.16, 4.5)
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = _soft_tex
		q.material = mat
		p.draw_pass_1 = q
		p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
		p.position = m.position
		add_child(p)
		_wing_trails.append(p)


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


func _build_ground_dust() -> void:
	_ground_dust = GPUParticles3D.new()
	_ground_dust.name = "GroundDust"
	_ground_dust.amount = 260
	_ground_dust.lifetime = 2.0
	_ground_dust.local_coords = false
	_ground_dust.emitting = false
	_ground_dust.top_level = true
	_ground_dust.visibility_aabb = AABB(Vector3(-60, -10, -60), Vector3(120, 40, 120))
	_ground_pm = ParticleProcessMaterial.new()
	_ground_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	_ground_pm.emission_ring_axis = Vector3(0, 1, 0)
	_ground_pm.emission_ring_radius = 6.0
	_ground_pm.emission_ring_inner_radius = 1.5
	_ground_pm.emission_ring_height = 0.4
	_ground_pm.direction = Vector3(0, 1, 0)
	_ground_pm.spread = 25.0
	_ground_pm.initial_velocity_min = 1.0
	_ground_pm.initial_velocity_max = 4.0
	_ground_pm.radial_velocity_min = 9.0
	_ground_pm.radial_velocity_max = 18.0
	_ground_pm.damping_min = 3.0
	_ground_pm.damping_max = 5.0
	_ground_pm.gravity = Vector3(0, -0.6, 0)
	_ground_pm.scale_min = 0.8
	_ground_pm.scale_max = 1.4
	var sc := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.35))
	cv.add_point(Vector2(1, 1.0))
	sc.curve = cv
	_ground_pm.scale_curve = sc
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.1, Color(1, 1, 1, 0.75))
	g.add_point(0.6, Color(1, 1, 1, 0.35))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	_ground_pm.color_ramp = gt
	_ground_dust.process_material = _ground_pm
	var q := QuadMesh.new()
	q.size = Vector2(6.5, 6.5)
	_ground_mat = StandardMaterial3D.new()
	_ground_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ground_mat.vertex_color_use_as_albedo = true
	_ground_mat.albedo_color = Color(0.62, 0.53, 0.4)
	_ground_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	_ground_mat.albedo_texture = _soft_tex
	_ground_mat.proximity_fade_enabled = true
	_ground_mat.proximity_fade_distance = 4.0
	_ground_mat.roughness = 1.0
	q.material = _ground_mat
	_ground_dust.draw_pass_1 = q
	add_child(_ground_dust)


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
	var t := clampf(-ship.thrust_norm.z, 0.0, 1.0) * lerpf(0.75, 1.0, ship.boost_t)
	if ship.is_piloted or ship.scripted:
		t = maxf(t, 0.06)
	if ship.landed:
		t = 0.0
	if ship.warp_state != Ship.WarpState.IDLE:
		t = maxf(t, 0.5 + 0.5 * ship.warp_spool)
	if force_thrust >= 0.0:
		t = force_thrust
	_thrust_s = lerpf(_thrust_s, t, 1.0 - exp(-dt * (8.0 if t > _thrust_s else 3.0)))
	vis.set_thrust(_thrust_s)


func _update_rcs(dt: float) -> void:
	var md: Dictionary = Ship.MODES[ship.mode]
	var alpha: Vector3 = (md["rate"] as Vector3) * (PI / 180.0 * 4.0)
	var aa := ship.ang_accel_local
	aa = Vector3(clampf(aa.x / alpha.x, -1, 1), clampf(aa.y / alpha.y, -1, 1), clampf(aa.z / alpha.z, -1, 1))
	var lin := Vector3(ship.thrust_norm.x, ship.thrust_norm.y, 0.0)
	var active := (ship.is_piloted or ship.scripted) and not ship.landed and not ship.capture_hold
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
		var p: GPUParticles3D = r["p"]
		p.emitting = s > 0.06
		p.amount_ratio = clampf(s, 0.05, 1.0)


func _update_reentry(dt: float, vdir: Vector3, speed: float, B: Basis) -> void:
	var h := ship.heat if force_heat < 0.0 else force_heat
	var on := h > 0.01
	if on != _overlay_on:
		_overlay_on = on
		for mi in _overlay_meshes:
			mi.material_overlay = reentry_mat if on else null
	_bow.visible = on
	_wake.visible = on
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
	_heat_light.global_position = sp + vdir * (support + 1.0)
	_heat_light.light_energy = h * h * 9.0
	_embers_pm.direction = -vl
	_embers.amount_ratio = clampf(h * 1.2, 0.1, 1.0)
	_embers_pm.initial_velocity_min = clampf(speed * 0.04, 60.0, 200.0)
	_embers_pm.initial_velocity_max = clampf(speed * 0.09, 120.0, 400.0)


func _update_vapor(_dt: float, vdir: Vector3, speed: float, B: Basis) -> void:
	var vp := ship.vapor if force_vapor < 0.0 else force_vapor
	_vapor.visible = vp > 0.01
	if _vapor.visible:
		_vapor_mat.set_shader_parameter("amount", vp)
		_vapor_mat.set_shader_parameter("time_s", _t)
	# wingtip trails also appear in hard turns in moderately dense air
	var w := ship.angular_velocity.length() if not ship.capture_hold else 0.0
	var turn := clampf(w * speed / 250.0, 0.0, 1.0) * clampf((ship.density - 0.15) / 0.3, 0.0, 1.0) \
		* clampf(speed / 120.0, 0.0, 1.0)
	var wt := maxf(vp, turn)
	var vl := B.transposed() * vdir
	for p in _wing_trails:
		p.emitting = wt > 0.05
		p.amount_ratio = clampf(wt, 0.05, 1.0)
		var pm := p.process_material as ParticleProcessMaterial
		pm.direction = -vl
		pm.initial_velocity_min = clampf(speed * 0.25, 30.0, 140.0)
		pm.initial_velocity_max = pm.initial_velocity_min * 1.15


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


func _update_ground_dust(dt: float) -> void:
	var b := ship.body
	if b == null:
		_ground_dust.emitting = false
		return
	var alt := ship.altitude
	var lift := clampf(absf(ship.thrust_norm.y) * 1.6 + clampf(-ship.thrust_norm.z, 0.0, 1.0) * 0.4, 0.25, 1.0)
	var k := clampf(1.0 - alt / 40.0, 0.0, 1.0) * lift
	if ship.landed or not (ship.is_piloted or ship.scripted) or alt < -1.0:
		k = 0.0
	_ground_dust.emitting = k > 0.04
	if not _ground_dust.emitting:
		return
	_ground_dust.amount_ratio = clampf(k, 0.05, 1.0)
	var up := ship.up_dir
	var gp := ship.global_position - up * (alt + Ship.GROUND_OFFSET)
	var fwd := ship.global_basis.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	_ground_dust.global_transform = Transform3D(Basis(up.cross(fwd).normalized(), up, fwd), gp)
	_ground_pm.gravity = -up * 0.6
	var water := false
	var cfg: Variant = b.get("config")
	if cfg is Object and (cfg as Object).has_method("get_ocean_radius"):
		var orad := float((cfg as Object).call("get_ocean_radius"))
		if orad > 0.0 and b.has_method("get_altitude_global"):
			water = ship.global_position.distance_to(b.global_position) - orad < b.get_altitude_global(ship.global_position) + 0.1
	_ground_mat.albedo_color = Color(0.85, 0.9, 0.95) if water else Color(0.78, 0.7, 0.55)
	_ground_pm.radial_velocity_min = lerpf(6.0, 12.0, k)
	_ground_pm.radial_velocity_max = lerpf(12.0, 22.0, k)


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
	var rig := ship.camera_rig as ShipCameraRig
	if rig:
		var spool_kick := -4.0 * ship.warp_spool if ship.warp_state == Ship.WarpState.SPOOL else 0.0
		rig.fov_kick = spool_kick + 24.0 * warp_amount * (1.0 if ship.warp_state == Ship.WarpState.ACTIVE or force_warp >= 0.0 else 0.4) + 10.0 * _flash
		rig.shake_extra = (0.06 * ship.warp_spool if ship.warp_state == Ship.WarpState.SPOOL else 0.0) + _flash * 0.25 \
			+ warp_amount * 0.01
	var on := warp_amount > 0.01 and cam != null
	_tunnel.visible = on
	_screen.visible = (on and warp_amount > 0.08) or _flash > 0.01
	if not on and _flash <= 0.01:
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
	_screen_mat.set_shader_parameter("flash", _flash * 0.6)
