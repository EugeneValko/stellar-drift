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
	# wave 4: warm haze, tall strong ozone layer (blue hour, purple twilight), multiple scattering
	# (bright horizon), art-directed low-sun tints (orange glow around the sun, pink sky)
	"terra_nova": {
		"radius": 60000.0, "height": 24000.0, "rayleigh_height": 2600.0, "mie_height": 750.0,
		"rayleigh_density": 1.2, "rayleigh_tint": Vector3(1, 1, 1), "sun_path_window": 7.0,
		"steps_mul": 1.5,   # cloud shadows in the air add variance along the ray
		"mie_density": 3.0, "mie_color": Color(1, 0.9, 0.75), "mie_absorb": Vector3(0.1, 0.1, 0.1),
		"mie_g": 0.8, "ozone_density": 2.0, "ozone_height": 7000.0, "intensity": PI,
		"multi_scatter": 0.0, "ms_strength": 1.4, "ms_lift_deg": 4.5, "sun_path_scale": 2.6,
		"twilight_tint": Vector3(1.32, 0.9, 0.95), "twilight_tint_mie": Vector3(2.1, 0.9, 0.25),
		"emission": Vector3(0.45e-6, 1.0e-6, 0.8e-6),   # faint teal airglow band at night
		"night_light": Vector3(0.018, 0.024, 0.042),    # starlight + airglow + giant-shine (ambient)
	},
	# thin dusty orange-red (Mars-like: dust absorbs blue); wave 4: Mars-like BLUE glow around a
	# low sun (fine dust forward-scatters blue), red volcanic glow of the lower haze at night
	"ignis": {
		"radius": 30000.0, "height": 12000.0, "rayleigh_height": 1400.0, "mie_height": 1600.0,
		"rayleigh_density": 0.12, "rayleigh_tint": Vector3(1, 1, 1),
		"mie_density": 45.0, "mie_color": Color(1.0, 0.6, 0.36), "mie_absorb": Vector3(0.15, 0.45, 0.9),
		"mie_g": 0.6, "ozone_density": 0.0, "intensity": PI, "multi_scatter": 0.3,
		"ms_strength": 0.9, "ms_lift_deg": 6.0, "steps_mul": 1.7,
		"twilight_tint": Vector3(1.15, 0.9, 0.8), "twilight_tint_mie": Vector3(0.55, 0.9, 2.2),
		"emission": Vector3(1.3e-5, 3.6e-6, 0.7e-6),
	},
	# teal / cyan; wave 4: ice-crystal haze (22/46 deg halos), cold multiple scattering
	"glacia": {
		"radius": 45000.0, "height": 11000.0, "rayleigh_height": 1400.0, "mie_height": 450.0,
		"rayleigh_density": 1.4, "rayleigh_tint": Vector3(0.45, 1.2, 1.0),
		"mie_density": 1.4, "mie_color": Color(0.85, 1.0, 1.0), "mie_absorb": Vector3(0.1, 0.1, 0.1),
		"mie_g": 0.8, "ozone_density": 0.6, "intensity": PI, "multi_scatter": 0.0,
		"ms_strength": 1.1, "halo": 1.3,
		"twilight_tint": Vector3(1.05, 1.0, 1.15), "twilight_tint_mie": Vector3(1.35, 1.0, 0.85),
	},
	"aurelion": {  # gas giant haze: warm, thick high haze
		"radius": 300000.0, "height": 40000.0, "rayleigh_height": 6000.0, "mie_height": 4000.0,
		"rayleigh_density": 0.14, "rayleigh_tint": Vector3(0.8, 0.9, 1.0),
		"mie_density": 0.3, "mie_color": Color(1.0, 0.88, 0.7), "mie_absorb": Vector3(0.05, 0.12, 0.3),
		"mie_g": 0.8, "ozone_density": 0.0, "intensity": PI, "multi_scatter": 0.2, "ms_strength": 0.6,
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
	# ozone: Earth-like vertical column x ozone_density, on its own profile when ozone_height > 0
	var hz: float = float(p.get("ozone_height", 0.0))
	var oz := EARTH_OZONE * 1.9 * float(p.get("ozone_density", 1.0)) * (8000.0 / (hz if hz > 0.0 else hr))
	var q: int = int(p.get("quality", 1))
	# steps_mul: dense, hazy atmospheres need more view samples (jitter grain otherwise)
	var steps: int = int(p.get("steps", roundi([8, 12, 16][clampi(q, 0, 2)] * float(p.get("steps_mul", 1.0)))))
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
		"atmo_sun_path_window": float(p.get("sun_path_window", 3.0)),
		"atmo_ozone_height": hz,
		"atmo_ms_strength": float(p.get("ms_strength", 0.0)),
		"atmo_ms_lift": deg_to_rad(float(p.get("ms_lift_deg", 4.0))),
		"atmo_ms_path": float(p.get("ms_path", 0.55)),
		"atmo_ground_albedo": LayerParams.col3(p.get("ground_albedo", Vector3(0.12, 0.13, 0.12))),
		"atmo_twilight_tint": LayerParams.col3(p.get("twilight_tint", Vector3.ONE)),
		"atmo_twilight_tint_mie": LayerParams.col3(p.get("twilight_tint_mie", Vector3.ONE)),
		"atmo_sky_gain": float(p.get("sky_gain", 1.0)),
		"atmo_halo": float(p.get("halo", 0.0)),
		"atmo_emission": LayerParams.col3(p.get("emission", Vector3.ZERO)),
		"atmo_night_light": LayerParams.col3(p.get("night_light", Vector3.ZERO)),
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
	var hz: float = u.get("atmo_ozone_height", 0.0)
	var co := minf(_chapman(u, r, mus, hz), 1e9) if hz > 0.0 else cr
	var kk := 1.0 + (float(u["atmo_sun_path_scale"]) - 1.0) \
		* (1.0 - clampf(mus * float(u.get("atmo_sun_path_window", 3.0)), 0.0, 1.0))
	var od: Vector3 = (u["atmo_rayleigh"] * cr + u["atmo_ozone"] * co + (u["atmo_mie"] + u["atmo_mie_absorb"]) * cm) * kk
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
	var oz: Vector3 = u["atmo_ozone"]
	var hz: float = u.get("atmo_ozone_height", 0.0)
	var ext_m: Vector3 = mie + u["atmo_mie_absorb"]
	# multiple scattering (same approximation as atmo_ms_source in the shader, no lift)
	var ms_k: float = u.get("atmo_ms_strength", 0.0)
	var tau_col: Vector3 = ray * float(u["atmo_rayleigh_height"]) + mie * float(u["atmo_mie_height"])
	var col_sky := (Vector3.ONE - Vector3(exp(-tau_col.x), exp(-tau_col.y), exp(-tau_col.z))) * 2.0
	var msr := Vector3.ZERO
	var msm := Vector3.ZERO
	for i in steps:
		var q := p + dir * (t0 + (i + 0.5) * ds)
		var h := q.length() - float(u["atmo_planet_radius"])
		var dr := exp(-h / float(u["atmo_rayleigh_height"]))
		var dm := exp(-h / float(u["atmo_mie_height"]))
		var dz := exp(-h / hz) if hz > 0.0 else dr
		var ext := ray * dr + oz * dz + ext_m * dm
		var here := od + ext * (0.5 * ds)
		od += ext * ds
		var ts := sun_transmittance(q, l)
		var tv := Vector3(exp(-here.x), exp(-here.y), exp(-here.z))
		var tr := tv * ts
		# art-directed low-sun tints (same as atmo_low_sun() in the shader)
		var lo := 1.0 - smoothstep(-0.02, 0.2, q.dot(l) / q.length())
		sr += tr * Vector3.ONE.lerp(u.get("atmo_twilight_tint", Vector3.ONE), lo) * dr * ds
		sm += tr * Vector3.ONE.lerp(u.get("atmo_twilight_tint_mie", Vector3.ONE), lo) * dm * ds
		if ms_k > 0.0:
			var mp: float = u.get("atmo_ms_path", 0.55)
			var src := tv * col_sky * Vector3(pow(ts.x, mp), pow(ts.y, mp), pow(ts.z, mp))
			msr += src * dr * ds
			msm += src * dm * ds
	var mu := dir.dot(l)
	var pr := 0.0596831 * (1.0 + mu * mu)
	var g: float = u["atmo_mie_g"]
	var pm := 0.1193662 * (1.0 - g * g) * (1.0 + mu * mu) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5))
	var ms: float = u["atmo_multi_scatter"] * 0.0795775
	var e := Vector3(sun_col.r, sun_col.g, sun_col.b) * sun_int * float(u["atmo_intensity"]) \
		* float(u.get("atmo_sky_gain", 1.0))
	return e * (sr * ray * (pr + ms) + sm * mie * (pm + ms) + (msr * ray + msm * mie) * (ms_k * 0.0795775))
