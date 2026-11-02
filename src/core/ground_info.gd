class_name GroundInfo
extends RefCounted
## What the ground is made of at a point: surface kind (footstep sound) and loose-material colour
## (landing dust / footstep puffs), from the planet's biome logic (ScatterBiome, same rules as the
## terrain shader) and its PlanetConfig palette. Cached per position (cheap to call per footstep
## or a few times per second).

## Footstep kinds: "sand", "grass", "rock", "snow", "water".
static var _biomes: Dictionary = {}     # planet instance id -> ScatterBiome
static var _cache_key := Vector3(INF, INF, INF)
static var _cache_body := 0
static var _cache: Dictionary = {}


static func _biome(p: Planet) -> ScatterBiome:
	var id := p.get_instance_id()
	if not _biomes.has(id):
		var b: ScatterBiome = null
		if p.terrain and p.terrain.generator and p.config:
			b = ScatterBiome.new(p.terrain.generator, p.config)
		_biomes[id] = b
	return _biomes[id]


## {"kind": String, "color": Color (linear-ish albedo of the dust), "water": bool,
##  "air": bool (body has an atmosphere)}
static func sample(body: Node3D, world_pos: Vector3) -> Dictionary:
	var out := {"kind": "rock", "color": Color(0.5, 0.47, 0.42), "water": false, "air": false}
	if body == null or not (body is Planet):
		return out
	var p := body as Planet
	var local := world_pos - p.global_position
	var key := (local / 6.0).round()
	if key == _cache_key and _cache_body == p.get_instance_id():
		return _cache
	var cfg := p.config
	out["air"] = cfg.has_atmosphere
	var d := local.normalized()
	# sea
	var orad := cfg.get_ocean_radius() if cfg.has_method("get_ocean_radius") else 0.0
	if orad > 0.0 and p.get_body_radius() + p.get_height(d) < orad - 0.2:
		out["kind"] = "water"
		out["water"] = true
		out["color"] = Color(0.86, 0.91, 0.96)
		_store(key, p, out)
		return out
	var b := _biome(p)
	var w := {"sand": 0.0, "grass": 0.0, "rock": 0.0, "snow": 0.0}
	var col := cfg.color_dry
	if b:
		var e := b.evaluate(d)
		var snow := maxf(float(e["snow"]), float(e["ice"]))
		var rock := float(e["rock"])
		var sand := maxf(float(e["beach"]), float(e["desert"]))
		var veg := clampf(float(e["moist"]) * 1.4, 0.0, 1.0) * (1.0 if cfg.has_atmosphere else 0.0)
		w["snow"] = snow
		w["rock"] = rock * (1.0 - snow)
		w["sand"] = sand * (1.0 - snow) * (1.0 - rock) + (0.0 if cfg.has_atmosphere else 0.6)
		w["grass"] = veg * (1.0 - snow) * (1.0 - rock) * (1.0 - sand)
		# loose material colour: soil under grass is the dry tone, sand/desert, rock dust, snow
		var tot := 0.0
		var c := Color(0, 0, 0)
		for k: String in w:
			var kc: Color = cfg.color_dry
			match k:
				"sand":
					kc = cfg.color_sand.lerp(cfg.color_desert, float(e["desert"]))
				"rock":
					kc = cfg.color_rock.lerp(cfg.color_rock2, 0.3)
				"snow":
					kc = cfg.color_snow
				"grass":
					kc = cfg.color_dry.lerp(cfg.color_sand, 0.25)
			var ww: float = w[k] + 0.02
			c += kc * ww
			tot += ww
		col = c / tot
	var best := "rock"
	var bw := -1.0
	for k: String in w:
		if float(w[k]) > bw:
			bw = w[k]
			best = k
	out["kind"] = best
	out["color"] = col
	_store(key, p, out)
	return out


static func _store(key: Vector3, p: Planet, out: Dictionary) -> void:
	_cache_key = key
	_cache_body = p.get_instance_id()
	_cache = out
