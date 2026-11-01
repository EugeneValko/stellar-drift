class_name SystemDef
extends RefCounted
## Static description of the star system (prototype: bodies do not move).
##
## System frame: Helios at the origin, ecliptic = XZ plane, +Y = north. Metres.
## Positions are float32 Vector3 constants; the floating origin subtracts them in 64-bit
## (Universe.true_to_local), so their own rounding (~2 m at 3e7 m) never shows.
##
## Layout (see docs/ARCHITECTURE.md): Terra Nova and Aurelion are placed on nearly the same
## line from the star, 6 750 km apart, so the ringed giant hangs in Terra's night / dusk sky
## (gibbous, ~5.1 deg across with rings); Selene orbits 400 km from Terra at quadrature so the
## view from Selene shows a half-lit Terra 17 deg across; Vex sits 900 km from Aurelion just
## above the sunlit side of the rings.

enum Kind { STAR, PLANET, GAS_GIANT }

const KM := 1000.0

## Group = a planet and its moons (scaled space keeps a group's internal ordering exact and
## each group has its own directional light). Group index 0 is reserved for the star.
const GROUPS := ["Helios", "Ignis", "Terra Nova", "Aurelion", "Glacia"]

const STAR := {
	"name": "Helios", "kind": Kind.STAR, "group": 0, "radius": 400.0 * KM,
	"pos": Vector3.ZERO, "temperature": 5900.0, "light_energy": 1.6,
}


## All bodies. Positions in the system frame. "preset": PlanetConfig in src/planets/presets.
## "atmosphere"/"clouds"/"ocean": Dictionaries for the components (null = none); radii are
## filled in by SolarSystem from the PlanetConfig when missing.
static func bodies() -> Array[Dictionary]:
	var terra := _orbit(15000.0 * KM, 0.0, 0.0)
	var aurelion := _orbit(21000.0 * KM, 10.0, 260.0 * KM)
	var out: Array[Dictionary] = []
	out.append(STAR)
	out.append({
		"name": "Ignis", "kind": Kind.PLANET, "group": 1, "preset": "ignis",
		"pos": _orbit(8000.0 * KM, -24.0, -150.0 * KM), "gravity": 6.5,
		"atmosphere": {"preset": "ignis", "ground_offset": -1600.0, "mie_density": 32.0,
			"mie_color": Color(1.0, 0.55, 0.3)},
	})
	out.append({
		"name": "Terra Nova", "kind": Kind.PLANET, "group": 2, "preset": "terra_nova",
		"pos": terra, "gravity": 9.81,
		"atmosphere": {"preset": "terra_nova", "sun_path_scale": 2.8, "mie_density": 0.8},
		"ocean": {},
		"clouds": {"bottom": 1800.0, "top": 4600.0, "coverage": 0.33, "brightness": 2.2,
			"cyclones": 5, "seed": 3.0, "shape_size": 7000.0, "detail_size": 1300.0,
			"stratus": 0.85, "weather_contrast": 2.2},
	})
	out.append({
		"name": "Selene", "kind": Kind.PLANET, "group": 2, "preset": "selene", "parent": "Terra Nova",
		"pos": terra + Vector3(-25.0, 70.0, 393.0).normalized() * 400.0 * KM, "gravity": 1.6,
	})
	out.append({
		"name": "Aurelion", "kind": Kind.GAS_GIANT, "group": 3, "pos": aurelion, "gravity": 22.0,
		"radius": 300.0 * KM, "ring_tilt_deg": AURELION_TILT, "ring_yaw_deg": AURELION_YAW,
		"params": {"rings": {"inner": 390.0 * KM, "outer": 690.0 * KM}, "seed": 2.0},
	})
	out.append({
		"name": "Vex", "kind": Kind.PLANET, "group": 3, "preset": "vex", "parent": "Aurelion",
		"pos": aurelion + _ring_moon_dir(aurelion, 64.0, 6.0) * 900.0 * KM, "gravity": 1.9,
	})
	out.append({
		"name": "Nyx", "kind": Kind.PLANET, "group": 3, "preset": "nyx", "parent": "Aurelion",
		"pos": aurelion + _ring_moon_dir(aurelion, 200.0, -5.0) * 1400.0 * KM, "gravity": 1.2,
	})
	out.append({
		"name": "Glacia", "kind": Kind.PLANET, "group": 4, "preset": "glacia",
		"pos": _orbit(27000.0 * KM, -52.0, 900.0 * KM), "gravity": 8.4,
		"atmosphere": {"preset": "glacia", "ground_offset": 60.0},
		"clouds": {"bottom": 3400.0, "top": 5400.0, "coverage": 0.3, "brightness": 2.0,
			"cyclones": 3, "seed": 11.0, "cirrus_opacity": 0.5, "shape_size": 6000.0,
			"detail_size": 1200.0, "stratus": 0.9, "weather_contrast": 0.9},
	})
	return out


## Point on a circular orbit of radius r at longitude `deg` (from +X toward +Z), height y.
static func _orbit(r: float, deg: float, y: float) -> Vector3:
	var a := deg_to_rad(deg)
	return Vector3(cos(a) * r, y, sin(a) * r)


const AURELION_TILT := 20.0
const AURELION_YAW := -100.0


## Ring-plane normal of Aurelion (GasGiantBody tilts around local X, then we yaw around Y).
static func aurelion_ring_normal() -> Vector3:
	return Basis.from_euler(Vector3(deg_to_rad(AURELION_TILT), deg_to_rad(AURELION_YAW), 0.0)) * Vector3.UP


## Moon direction around Aurelion: the sun direction projected on the ring plane, rotated
## `deg` around the ring normal, lifted `elev_deg` out of the ring plane.
static func _ring_moon_dir(giant: Vector3, deg: float, elev_deg: float) -> Vector3:
	var n := aurelion_ring_normal()
	var s := -giant.normalized()
	var d := (s - n * s.dot(n)).normalized().rotated(n, deg_to_rad(deg))
	return (d * cos(deg_to_rad(elev_deg)) + n * sin(deg_to_rad(elev_deg))).normalized()
