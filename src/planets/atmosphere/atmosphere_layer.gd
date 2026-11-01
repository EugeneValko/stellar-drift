class_name AtmosphereLayer
extends Node3D
## Physically based atmosphere (Rayleigh + Mie + ozone, single scattering + cheap multi-scatter)
## rendered on a back-face proxy sphere; works from space and from inside, stops at scene depth.
##
## Usage (child of the planet node, at the planet centre, unscaled):
##   var atmo := preload("res://scenes/planets/atmosphere.tscn").instantiate()
##   planet.add_child(atmo)
##   atmo.setup({"preset": "terra_nova", "radius": 60000.0})
##
## Parameters (Dictionary or Resource with same property names; all optional):
##   preset            "terra_nova" | "ignis" | "glacia" | "aurelion" (base values)
##   radius            planet radius / sea level, m (density reference)
##   height            atmosphere top above radius, m
##   ground_radius     hard stop sphere for rays (sea level or lowest terrain), m; 0 = off
##   rayleigh_height   Rayleigh scale height, m
##   mie_height        Mie (haze) scale height, m
##   rayleigh_density  multiplier on Earth-equivalent Rayleigh optical depth
##   rayleigh_tint     Vector3/Color per-channel multiplier (tint the sky)
##   mie_density       multiplier on Earth-equivalent haze
##   mie_color         Color tint of Mie scattering (dust)
##   mie_absorb        Vector3/Color absorption relative to Mie scattering (default 0.1)
##   mie_g             Mie anisotropy (0.6 dusty .. 0.85 hazy)
##   ozone_density     multiplier for ozone-like absorption (0 = none)
##   intensity         scattering brightness (PI = physical)
##   multi_scatter     isotropic multiple-scattering approximation strength
##   quality           0 low / 1 medium / 2 high (view samples 8/12/16); or `steps` explicitly
##   render_priority_base  added to the transparent render priorities

const EARTH_RAYLEIGH := Vector3(5.802e-6, 13.558e-6, 33.1e-6)  # at H = 8 km
const EARTH_MIE := 3.996e-6                                      # at H = 1.2 km
const EARTH_OZONE := Vector3(0.650e-6, 1.881e-6, 0.085e-6)

const PRESETS := {
	"terra_nova": {
		"radius": 60000.0, "height": 24000.0, "rayleigh_height": 2600.0, "mie_height": 750.0,
		"rayleigh_density": 1.5, "rayleigh_tint": Vector3(1, 1, 1),
		"mie_density": 1.0, "mie_color": Color(1, 1, 1), "mie_absorb": Vector3(0.1, 0.1, 0.1),
		"mie_g": 0.78, "ozone_density": 1.0, "intensity": PI, "multi_scatter": 0.35,
	},
	"ignis": {  # thin dusty orange-red (Mars-like: dust absorbs blue)
		"radius": 30000.0, "height": 8000.0, "rayleigh_height": 1100.0, "mie_height": 900.0,
		"rayleigh_density": 0.25, "rayleigh_tint": Vector3(1, 1, 1),
		"mie_density": 2.5, "mie_color": Color(1.0, 0.62, 0.38), "mie_absorb": Vector3(0.12, 0.35, 0.7),
		"mie_g": 0.65, "ozone_density": 0.0, "intensity": PI, "multi_scatter": 0.5,
	},
	"glacia": {  # teal / cyan
		"radius": 45000.0, "height": 11000.0, "rayleigh_height": 1400.0, "mie_height": 450.0,
		"rayleigh_density": 1.4, "rayleigh_tint": Vector3(0.45, 1.2, 1.0),
		"mie_density": 0.7, "mie_color": Color(0.85, 1.0, 1.0), "mie_absorb": Vector3(0.1, 0.1, 0.1),
		"mie_g": 0.8, "ozone_density": 0.6, "intensity": PI, "multi_scatter": 0.4,
	},
	"aurelion": {  # gas giant haze: warm, thick high haze
		"radius": 300000.0, "height": 40000.0, "rayleigh_height": 6000.0, "mie_height": 4000.0,
		"rayleigh_density": 0.14, "rayleigh_tint": Vector3(0.8, 0.9, 1.0),
		"mie_density": 0.22, "mie_color": Color(1.0, 0.88, 0.7), "mie_absorb": Vector3(0.05, 0.12, 0.3),
		"mie_g": 0.7, "ozone_density": 0.0, "intensity": PI, "multi_scatter": 0.4,
	},
}

const SH_SCATTER := preload("res://shaders/atmosphere.gdshader")
const SH_TRANSMIT := preload("res://shaders/atmosphere_transmittance.gdshader")

var params: Dictionary = {}
var uniforms: Dictionary = {}
var mesh_instance: MeshInstance3D
var mat_transmit: ShaderMaterial
var mat_scatter: ShaderMaterial


func setup(cfg: Variant = null) -> void:
	var preset_name: String = LayerParams.get_param(cfg, "preset", "terra_nova")
	params = LayerParams.merged(PRESETS.get(preset_name, PRESETS["terra_nova"]), cfg)
	uniforms = make_uniforms(params)
	if mesh_instance == null:
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = "AtmosphereShell"
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mesh_instance)
		mat_transmit = ShaderMaterial.new()
		mat_transmit.shader = SH_TRANSMIT
		mat_scatter = ShaderMaterial.new()
		mat_scatter.shader = SH_SCATTER
		mat_transmit.next_pass = mat_scatter
		mesh_instance.material_override = mat_transmit
	mesh_instance.mesh = LayerParams.make_proxy_sphere(uniforms["atmo_top_radius"])
	var base: int = int(params.get("render_priority_base", 0))
	mat_transmit.render_priority = LayerParams.PRIO_ATMO_T + base
	mat_scatter.render_priority = LayerParams.PRIO_ATMO_S + base
	LayerParams.apply_uniforms(mat_transmit, uniforms)
	LayerParams.apply_uniforms(mat_scatter, uniforms)


## Converts artist params into the atmo_* shader uniforms (also used by clouds/ocean/terrain
## shaders that #include atmosphere_common.gdshaderinc).
static func make_uniforms(p: Dictionary) -> Dictionary:
	var radius: float = p.get("radius", 60000.0)
	var hr: float = p.get("rayleigh_height", 1600.0)
	var hm: float = p.get("mie_height", 500.0)
	var tint := LayerParams.col3(p.get("rayleigh_tint", Vector3.ONE))
	var ray := EARTH_RAYLEIGH * tint * float(p.get("rayleigh_density", 1.0)) * (8000.0 / hr)
	var mie := LayerParams.col3(p.get("mie_color", Color.WHITE)) * EARTH_MIE \
		* float(p.get("mie_density", 1.0)) * (1200.0 / hm)
	var mie_abs := mie * LayerParams.col3(p.get("mie_absorb", Vector3(0.1, 0.1, 0.1)))
	var oz := EARTH_OZONE * 1.9 * float(p.get("ozone_density", 1.0)) * (8000.0 / hr)
	var q: int = int(p.get("quality", 1))
	var steps: int = int(p.get("steps", [8, 12, 16][clampi(q, 0, 2)]))
	return {
		"atmo_planet_radius": radius,
		"atmo_top_radius": radius + float(p.get("height", 12000.0)),
		"atmo_ground_radius": float(p.get("ground_radius", radius)),
		"atmo_rayleigh_height": hr,
		"atmo_mie_height": hm,
		"atmo_rayleigh": ray,
		"atmo_mie": mie,
		"atmo_mie_absorb": mie_abs,
		"atmo_ozone": oz,
		"atmo_mie_g": float(p.get("mie_g", 0.78)),
		"atmo_intensity": float(p.get("intensity", PI)),
		"atmo_multi_scatter": float(p.get("multi_scatter", 0.35)),
		"atmo_steps": steps,
		"atmo_sun_path_scale": float(p.get("sun_path_scale", 2.2)),
	}


func set_quality(q: int) -> void:
	params["quality"] = q
	params.erase("steps")
	setup(params)


func get_top_radius() -> float:
	return uniforms.get("atmo_top_radius", 0.0)


# --- CPU helpers (same math as the shader) -------------------------------------------------

static func _chapman(u: Dictionary, r: float, mu: float, h: float) -> float:
	var x := r / h
	var big_x: float = u["atmo_planet_radius"] / h
	var c := sqrt(1.5707963 * x)
	if mu >= 0.0:
		return h * exp(big_x - x) / (mu + 1.0 / c)
	var s := sqrt(maxf(1.0 - mu * mu, 0.0))
	var x0 := x * s
	var c0 := sqrt(1.5707963 * x0)
	return h * (2.0 * c0 * exp(minf(big_x - x0, 80.0)) - exp(big_x - x) / (-mu + 1.0 / c))


## Sunlight transmittance (RGB as Vector3) at planet-local point `p` for sun direction `l`.
## Use it to tint a DirectionalLight3D near the camera (sunset light on ship/terrain).
func sun_transmittance(p: Vector3, l: Vector3) -> Vector3:
	var u := uniforms
	var r := p.length()
	var mus := p.dot(l) / r
	var cr := minf(_chapman(u, r, mus, u["atmo_rayleigh_height"]), 1e9)
	var cm := minf(_chapman(u, r, mus, u["atmo_mie_height"]), 1e9)
	var kk := 1.0 + (float(u["atmo_sun_path_scale"]) - 1.0) * (1.0 - clampf(mus * 3.0, 0.0, 1.0))
	var od: Vector3 = ((u["atmo_rayleigh"] + u["atmo_ozone"]) * cr + (u["atmo_mie"] + u["atmo_mie_absorb"]) * cm) * kk
	var sh := 1.0
	if mus < 0.0:
		var d := r * sqrt(1.0 - mus * mus)
		var w: float = u["atmo_rayleigh_height"] * 0.6
		sh = smoothstep(u["atmo_planet_radius"] - w, u["atmo_planet_radius"] + w, d)
	return Vector3(exp(-od.x), exp(-od.y), exp(-od.z)) * sh


## Rough sky ambient color (radiance) at planet-local point p: single scattering toward zenith.
func sky_radiance(p: Vector3, dir: Vector3, l: Vector3, sun_col: Color, sun_int: float, steps: int = 16) -> Vector3:
	var u := uniforms
	var top: float = u["atmo_top_radius"]
	var b := p.dot(dir)
	var cc := p.length_squared() - top * top
	var disc := b * b - cc
	if disc <= 0.0:
		return Vector3.ZERO
	var t1 := -b + sqrt(disc)
	if t1 <= 0.0:
		return Vector3.ZERO
	var t0 := maxf(-b - sqrt(disc), 0.0)
	var ds := (t1 - t0) / steps
	var od := Vector3.ZERO
	var sr := Vector3.ZERO
	var sm := Vector3.ZERO
	var ray: Vector3 = u["atmo_rayleigh"]
	var mie: Vector3 = u["atmo_mie"]
	var ext_r: Vector3 = ray + u["atmo_ozone"]
	var ext_m: Vector3 = mie + u["atmo_mie_absorb"]
	for i in steps:
		var q := p + dir * (t0 + (i + 0.5) * ds)
		var h := q.length() - float(u["atmo_planet_radius"])
		var dr := exp(-h / float(u["atmo_rayleigh_height"]))
		var dm := exp(-h / float(u["atmo_mie_height"]))
		var here := od + (ext_r * dr + ext_m * dm) * (0.5 * ds)
		od += (ext_r * dr + ext_m * dm) * ds
		var ts := sun_transmittance(q, l)
		var tr := Vector3(exp(-here.x), exp(-here.y), exp(-here.z)) * ts
		sr += tr * dr * ds
		sm += tr * dm * ds
	var mu := dir.dot(l)
	var pr := 0.0596831 * (1.0 + mu * mu)
	var g: float = u["atmo_mie_g"]
	var pm := 0.1193662 * (1.0 - g * g) * (1.0 + mu * mu) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5))
	var ms: float = u["atmo_multi_scatter"] * 0.0795775
	var e := Vector3(sun_col.r, sun_col.g, sun_col.b) * sun_int * float(u["atmo_intensity"])
	return e * (sr * ray * (pr + ms) + sm * mie * (pm + ms))
