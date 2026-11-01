extends SceneTree
## Authoring tool: (re)writes src/planets/scatter/presets/*.tres from the tables below.
##   godot --headless -s tools/dev/make_scatter_presets.gd
## The .tres files are what the game loads; edit them in the inspector or tune here and regenerate.

const OUT := "res://src/planets/scatter/presets/"
const FLORA := "res://assets/models/flora_terra.glb"
const ROCKS := "res://assets/models/rocks.glb"
const CRYST := "res://assets/models/crystals.glb"

# --- Terra Nova palette ---
const NEEDLES := {"color_a": Color(0.16, 0.32, 0.26), "color_b": Color(0.3, 0.5, 0.36),
	"color_dry": Color(0.52, 0.47, 0.25), "dry_amount": 0.15, "variation": 0.4}
const LEAVES := {"color_a": Color(0.3, 0.44, 0.13), "color_b": Color(0.52, 0.6, 0.18),
	"color_dry": Color(0.74, 0.45, 0.16), "dry_amount": 0.7, "variation": 0.45}
const FRONDS := {"color_a": Color(0.26, 0.47, 0.13), "color_b": Color(0.46, 0.62, 0.2),
	"color_dry": Color(0.62, 0.56, 0.3), "dry_amount": 0.35, "variation": 0.4}


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	_save("terra_nova", _terra())
	_save("ignis", _volcanic(false))
	_save("vex", _volcanic(true))
	_save("glacia", _glacia())
	_save("selene", _moon(false))
	_save("nyx", _moon(true))
	quit()


func _save(n: String, rs: ScatterRuleSet) -> void:
	var err := ResourceSaver.save(rs, OUT + n + ".tres")
	print("[presets] ", n, " -> ", error_string(err), " (", rs.layers.size(), " layers)")


func L(props: Dictionary) -> ScatterLayer:
	var l := ScatterLayer.new()
	for k: String in props:
		if not (k in l):
			push_error("unknown layer property " + k)
		l.set(k, props[k])
	return l


func _far(colors: Dictionary) -> Dictionary:
	return {"far_foliage": colors}


func _terra() -> ScatterRuleSet:
	var rs := ScatterRuleSet.new()
	rs.max_altitude = 3600.0
	rs.material_params = {
		"needles": NEEDLES.merged({"translucency": 0.6, "sway_amp": 0.012, "flutter_amp": 0.05}),
		"leaves": LEAVES.merged({"translucency": 0.6, "sway_amp": 0.016, "flutter_amp": 0.06}),
		"frond": FRONDS.merged({"translucency": 0.6, "sway_amp": 0.02, "flutter_amp": 0.07}),
		"bark": {"color_a": Color(0.5, 0.42, 0.35), "color_b": Color(0.22, 0.18, 0.15), "sway_amp": 0.012},
		"bark_palm": {"sway_amp": 0.02},
		"rock": {"color_cover": Color(0.3, 0.4, 0.14), "cover_amount": 0.55, "snow_amount": 1.0},
		"glow": {"glow_color": Color(0.25, 0.95, 0.8), "glow_energy": 0.5},
	}
	var trees_common := {"model": FLORA, "cell_size": 128.0, "far_factor": 8, "far_start": 700.0,
		"max_distance": 3000.0, "fade_length": 60.0, "lod_distances": PackedFloat32Array([90.0]),
		"grid_res": 4, "exact_height": true, "shadow_distance": 320.0,
		"collision": 1, "collision_distance": 70.0, "edge_scale": 0.45}
	rs.layers = [
		# --- trees ---
		L(trees_common.merged({"name": "spirepine", "seed": 11, "density": 0.0045,
			"meshes": PackedStringArray(["spirepine_lod0", "spirepine_lod1"]), "far_mesh": "spirepine_lod2",
			"rules": {"forest": Vector3(0.3, 2.0, 0.3), "height": Vector3(60.0, 3200.0, 250.0),
				"slope": Vector3(-1.0, 0.3, 0.1), "snow": Vector3(-1.0, 0.25, 0.2), "beach": Vector3(-1.0, 0.1, 0.2)},
			"cluster_scale": 260.0, "cluster_threshold": -0.15, "cluster_soft": 0.35,
			"scale_range": Vector2(0.65, 1.3), "sink": 0.7, "sway_height": 20.0,
			"collision_size": Vector2(0.45, 9.0), "material_overrides": _far(NEEDLES)})),
		L(trees_common.merged({"name": "parasol", "seed": 23, "density": 0.0024,
			"meshes": PackedStringArray(["parasol_lod0", "parasol_lod1"]), "far_mesh": "parasol_lod2",
			"rules": {"forest": Vector3(0.15, 2.0, 0.3), "height": Vector3(5.0, 1300.0, 200.0),
				"slope": Vector3(-1.0, 0.28, 0.08), "moist": Vector3(0.42, 2.0, 0.12),
				"beach": Vector3(-1.0, 0.1, 0.2)},
			"cluster_scale": 300.0, "cluster_threshold": 0.05, "cluster_soft": 0.4,
			"scale_range": Vector2(0.75, 1.25), "sink": 0.4, "sway_height": 11.0,
			"collision_size": Vector2(0.45, 3.0), "material_overrides": _far(LEAVES)})),
		L(trees_common.merged({"name": "fernpalm", "seed": 37, "density": 0.003,
			"meshes": PackedStringArray(["fernpalm_lod0", "fernpalm_lod1"]), "far_mesh": "fernpalm_lod2",
			"rules": {"height": Vector3(2.0, 420.0, 90.0), "moist": Vector3(0.5, 2.0, 0.12),
				"slope": Vector3(-1.0, 0.25, 0.08), "lat": Vector3(-1.0, 0.5, 0.1),
				"forest": Vector3(0.05, 2.0, 0.2), "beach": Vector3(-1.0, 0.6, 0.3)},
			"cluster_scale": 140.0, "cluster_threshold": 0.1, "cluster_soft": 0.3,
			"scale_range": Vector2(0.75, 1.3), "sink": 0.3, "sway_height": 9.0,
			"collision_size": Vector2(0.3, 4.0), "material_overrides": _far(FRONDS)})),
		# --- shrubs ---
		L({"name": "bush_round", "model": FLORA, "seed": 51, "cell_size": 96.0, "max_distance": 380.0,
			"fade_length": 50.0, "density": 0.02, "grid_res": 8, "exact_height": true,
			"meshes": PackedStringArray(["bush_round_lod0", "bush_round_lod1"]),
			"lod_distances": PackedFloat32Array([70.0]),
			"rules": {"forest": Vector3(0.05, 2.0, 0.3), "height": Vector3(2.0, 2600.0, 120.0),
				"slope": Vector3(-1.0, 0.35, 0.08), "snow": Vector3(-1.0, 0.25, 0.2),
				"rock": Vector3(-1.0, 0.6, 0.2), "beach": Vector3(-1.0, 0.2, 0.2)},
			"cluster_scale": 70.0, "cluster_threshold": -0.1, "cluster_soft": 0.4,
			"scale_range": Vector2(0.6, 1.5), "sink": 0.12, "align_to_normal": 0.3, "sway_height": 1.5,
			"shadow_distance": 90.0,
			"material_overrides": {"leaves": {"color_a": Color(0.27, 0.4, 0.15),
				"color_b": Color(0.52, 0.3, 0.38), "variation": 0.55, "dry_amount": 0.3}}}),
		L({"name": "bush_quill", "model": FLORA, "seed": 57, "cell_size": 96.0, "max_distance": 300.0,
			"fade_length": 40.0, "density": 0.012, "grid_res": 8, "exact_height": true,
			"meshes": PackedStringArray(["bush_quill_lod0"]),
			"rules": {"moist": Vector3(0.18, 0.62, 0.1), "forest": Vector3(-1.0, 0.45, 0.2),
				"height": Vector3(3.0, 2400.0, 100.0), "slope": Vector3(-1.0, 0.4, 0.1),
				"snow": Vector3(-1.0, 0.2, 0.2), "beach": Vector3(-1.0, 0.3, 0.2)},
			"cluster_scale": 50.0, "cluster_threshold": 0.0, "scale_range": Vector2(0.7, 1.4),
			"sink": 0.05, "align_to_normal": 0.4, "sway_height": 1.2, "shadow_distance": 70.0,
			"material_overrides": {"frond": {"color_a": Color(0.4, 0.5, 0.22), "color_b": Color(0.62, 0.62, 0.3),
				"leaflets": 9.0, "duty": 0.7, "slant": 2.4}}}),
		L({"name": "fern", "model": FLORA, "seed": 59, "cell_size": 48.0, "max_distance": 160.0,
			"fade_length": 30.0, "density": 0.09, "grid_res": 6,
			"meshes": PackedStringArray(["fern_lod0"]),
			"rules": {"forest": Vector3(0.35, 2.0, 0.25), "slope": Vector3(-1.0, 0.4, 0.1),
				"height": Vector3(2.0, 2400.0, 100.0)},
			"cluster_scale": 30.0, "cluster_threshold": -0.2, "scale_range": Vector2(0.7, 1.5),
			"sink": 0.03, "align_to_normal": 0.6, "sway_height": 0.8, "cast_shadows": false}),
		# --- ground cover ---
		L({"name": "grass", "model": FLORA, "seed": 61, "cell_size": 20.0, "max_distance": 85.0,
			"fade_length": 20.0, "density": 2.0, "grid_res": 8, "thin_start": 20.0, "thin_keep": 0.25,
			"meshes": PackedStringArray(["grass_lod0", "grass_lod1"]),
			"lod_distances": PackedFloat32Array([16.0]),
			"rules": {"height": Vector3(1.5, 3000.0, 60.0), "slope": Vector3(-1.0, 0.3, 0.07),
				"snow": Vector3(-1.0, 0.2, 0.15), "rock": Vector3(-1.0, 0.45, 0.2),
				"desert": Vector3(-1.0, 0.55, 0.2), "beach": Vector3(-1.0, 0.25, 0.2),
				"forest": Vector3(-1.0, 0.8, 0.3)},
			"cluster_scale": 14.0, "cluster_threshold": -0.45, "cluster_soft": 0.5,
			"scale_range": Vector2(0.7, 1.35), "edge_scale": 0.55, "align_to_normal": 0.7,
			"sway_height": 0.6, "cast_shadows": false}),
		L({"name": "grass_tall", "model": FLORA, "seed": 63, "cell_size": 32.0, "max_distance": 70.0,
			"fade_length": 15.0, "density": 0.35, "grid_res": 8,
			"meshes": PackedStringArray(["grass_tall_lod0"]),
			"rules": {"moist": Vector3(0.4, 2.0, 0.12), "forest": Vector3(-1.0, 0.55, 0.2),
				"height": Vector3(1.5, 2200.0, 60.0), "slope": Vector3(-1.0, 0.25, 0.06),
				"snow": Vector3(-1.0, 0.15, 0.1), "rock": Vector3(-1.0, 0.35, 0.15)},
			"cluster_scale": 22.0, "cluster_threshold": 0.05, "cluster_soft": 0.3,
			"scale_range": Vector2(0.75, 1.25), "align_to_normal": 0.5, "sway_height": 1.1,
			"cast_shadows": false}),
		L({"name": "flowers", "model": FLORA, "seed": 71, "cell_size": 32.0, "max_distance": 55.0,
			"fade_length": 12.0, "density": 0.22, "grid_res": 8,
			"meshes": PackedStringArray(["flower_a_lod0"]),
			"rules": {"moist": Vector3(0.32, 2.0, 0.1), "forest": Vector3(-1.0, 0.5, 0.2),
				"height": Vector3(2.0, 2400.0, 60.0), "slope": Vector3(-1.0, 0.25, 0.06),
				"snow": Vector3(-1.0, 0.1, 0.1), "rock": Vector3(-1.0, 0.3, 0.15)},
			"cluster_scale": 16.0, "cluster_threshold": 0.2, "cluster_soft": 0.25,
			"scale_range": Vector2(0.8, 1.4), "align_to_normal": 0.6, "sway_height": 0.5, "cast_shadows": false}),
		L({"name": "glowbulbs", "model": FLORA, "seed": 81, "cell_size": 32.0, "max_distance": 50.0,
			"fade_length": 12.0, "density": 0.06, "grid_res": 8,
			"meshes": PackedStringArray(["flower_b_lod0"]),
			"rules": {"forest": Vector3(0.25, 2.0, 0.2), "slope": Vector3(-1.0, 0.3, 0.08)},
			"cluster_scale": 20.0, "cluster_threshold": 0.15, "cluster_soft": 0.25,
			"scale_range": Vector2(0.8, 1.5), "align_to_normal": 0.4, "sway_height": 0.7, "cast_shadows": false}),
		# --- rocks ---
		L({"name": "pebbles", "model": ROCKS, "seed": 101, "cell_size": 24.0, "max_distance": 70.0,
			"fade_length": 15.0, "density": 0.05, "grid_res": 6,
			"meshes": PackedStringArray(["pebbles_lod0"]),
			"rules": {"height": Vector3(-5.0, 9000.0, 20.0), "forest": Vector3(-1.0, 0.7, 0.3)},
			"scale_range": Vector2(0.7, 1.6), "align_to_normal": 0.9, "sink": 0.02, "cast_shadows": false}),
		L({"name": "boulders", "model": ROCKS, "seed": 103, "cell_size": 96.0, "max_distance": 450.0,
			"fade_length": 50.0, "density": 0.0035, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["boulder_a_lod0", "boulder_a_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"rules": {"height": Vector3(1.0, 9000.0, 20.0), "slope": Vector3(0.05, 0.9, 0.1)},
			"cluster_scale": 90.0, "cluster_threshold": 0.0, "cluster_soft": 0.4,
			"scale_range": Vector2(0.5, 2.6), "edge_scale": 0.2, "max_tilt_deg": 20.0, "align_to_normal": 0.5,
			"sink": 0.15, "shadow_distance": 160.0, "collision": 2, "collision_size": Vector2(0.7, 0.35),
			"collision_distance": 50.0}),
		L({"name": "boulders_b", "model": ROCKS, "seed": 107, "cell_size": 96.0, "max_distance": 450.0,
			"fade_length": 50.0, "density": 0.004, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["boulder_b_lod0", "boulder_b_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"rules": {"height": Vector3(1.0, 9000.0, 20.0), "rock": Vector3(0.2, 2.0, 0.2)},
			"scale_range": Vector2(0.6, 3.0), "edge_scale": 0.3, "max_tilt_deg": 25.0, "align_to_normal": 0.6,
			"sink": 0.2, "shadow_distance": 160.0, "collision": 2, "collision_size": Vector2(0.7, 0.4),
			"collision_distance": 50.0}),
		L({"name": "slabs", "model": ROCKS, "seed": 109, "cell_size": 96.0, "max_distance": 300.0,
			"fade_length": 40.0, "density": 0.002, "grid_res": 6,
			"meshes": PackedStringArray(["boulder_c_lod0", "boulder_c_lod1"]),
			"lod_distances": PackedFloat32Array([50.0]),
			"rules": {"height": Vector3(1.0, 9000.0, 20.0), "forest": Vector3(-1.0, 0.6, 0.3)},
			"cluster_scale": 120.0, "cluster_threshold": 0.2, "scale_range": Vector2(0.5, 1.8),
			"max_tilt_deg": 10.0, "align_to_normal": 0.85, "sink": 0.1, "shadow_distance": 100.0}),
		L({"name": "rock_clusters", "model": ROCKS, "seed": 113, "cell_size": 128.0, "max_distance": 500.0,
			"fade_length": 60.0, "density": 0.0015, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["rock_cluster_lod0", "rock_cluster_lod1"]),
			"lod_distances": PackedFloat32Array([80.0]),
			"rules": {"height": Vector3(1.0, 9000.0, 20.0), "slope": Vector3(0.1, 1.0, 0.1),
				"rock": Vector3(0.1, 2.0, 0.2)},
			"scale_range": Vector2(0.8, 2.2), "max_tilt_deg": 12.0, "align_to_normal": 0.7, "sink": 0.15,
			"shadow_distance": 180.0, "collision": 3, "collision_distance": 50.0}),
	]
	return rs


func _volcanic(vex: bool) -> ScatterRuleSet:
	var rs := ScatterRuleSet.new()
	rs.max_altitude = 2500.0
	var glow := Color(1.0, 0.85, 0.2) if vex else Color(1.0, 0.32, 0.08)
	rs.material_params = {
		"rock": {"style": 2, "color_cover": Color(0.5, 0.42, 0.2) if vex else Color(0.42, 0.22, 0.12),
			"cover_amount": 0.5, "snow_amount": 0.0, "emission_color": glow, "emission_energy": 0.0},
		"basalt": {"color_a": Color(0.24, 0.21, 0.2), "color_b": Color(0.11, 0.1, 0.1), "cover_amount": 0.35,
			"color_cover": Color(0.4, 0.3, 0.12) if vex else Color(0.35, 0.18, 0.1), "snow_amount": 0.0},
		"crystal": {"color_body": Color(0.35, 0.25, 0.04) if vex else Color(0.3, 0.04, 0.06),
			"color_glow": glow, "color_rim": Color(1.0, 0.95, 0.6) if vex else Color(1.0, 0.6, 0.35),
			"glow_energy": 2.6},
	}
	rs.layers = [
		L({"name": "basalt", "model": ROCKS, "seed": 201, "cell_size": 128.0, "max_distance": 700.0,
			"fade_length": 70.0, "density": 0.0016, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["basalt_a_lod0"]),
			"rules": {"slope": Vector3(-1.0, 0.45, 0.1), "lava": Vector3(-1.0, 0.5, 0.2)},
			"cluster_scale": 260.0, "cluster_threshold": -0.1, "cluster_soft": 0.3,
			"scale_range": Vector2(0.7, 2.2), "max_tilt_deg": 6.0, "align_to_normal": 0.3, "sink": 0.25,
			"shadow_distance": 250.0, "collision": 3, "collision_distance": 60.0}),
		L({"name": "basalt_pavement", "model": ROCKS, "seed": 203, "cell_size": 128.0, "max_distance": 500.0,
			"fade_length": 60.0, "density": 0.0015, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["basalt_b_lod0"]),
			"rules": {"slope": Vector3(-1.0, 0.3, 0.08), "lava": Vector3(-1.0, 0.6, 0.2)},
			"cluster_scale": 260.0, "cluster_threshold": 0.0, "cluster_soft": 0.3,
			"scale_range": Vector2(0.8, 1.8), "align_to_normal": 0.6, "sink": 0.2, "shadow_distance": 200.0}),
		L({"name": "lava_rocks", "model": ROCKS, "seed": 205, "cell_size": 96.0, "max_distance": 450.0,
			"fade_length": 50.0, "density": 0.006, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["volcanic_a_lod0", "volcanic_a_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"rules": {"slope": Vector3(-1.0, 0.9, 0.1)},
			"cluster_scale": 80.0, "cluster_threshold": -0.2, "cluster_soft": 0.4,
			"scale_range": Vector2(0.4, 2.4), "max_tilt_deg": 25.0, "align_to_normal": 0.5, "sink": 0.12,
			"shadow_distance": 160.0, "collision": 2, "collision_size": Vector2(0.7, 0.35), "collision_distance": 50.0,
			"material_overrides": {"rock": {"emission_energy": 1.5}}}),
		L({"name": "lava_spires", "model": ROCKS, "seed": 207, "cell_size": 96.0, "max_distance": 450.0,
			"fade_length": 50.0, "density": 0.0015, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["volcanic_b_lod0", "volcanic_b_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"rules": {"slope": Vector3(-1.0, 0.5, 0.1)},
			"cluster_scale": 120.0, "cluster_threshold": 0.1, "scale_range": Vector2(0.8, 3.0),
			"max_tilt_deg": 12.0, "align_to_normal": 0.2, "sink": 0.3, "shadow_distance": 200.0,
			"collision": 2, "collision_size": Vector2(0.45, 0.6), "collision_distance": 50.0}),
		L({"name": "crystals", "model": CRYST, "seed": 209, "cell_size": 96.0, "max_distance": 600.0,
			"fade_length": 60.0, "density": 0.0035, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["crystal_cluster_a_lod0"]),
			"rules": {"lava": Vector3(0.04, 0.85, 0.12), "slope": Vector3(-1.0, 0.6, 0.1)},
			"cluster_scale": 90.0, "cluster_threshold": -0.1, "scale_range": Vector2(0.6, 2.0),
			"max_tilt_deg": 15.0, "align_to_normal": 0.5, "sink": 0.1, "shadow_distance": 150.0,
			"collision": 2, "collision_size": Vector2(0.6, 0.5), "collision_distance": 40.0}),
		L({"name": "crystals_big", "model": CRYST, "seed": 211, "cell_size": 128.0, "max_distance": 800.0,
			"fade_length": 80.0, "density": 0.0004, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["crystal_cluster_b_lod0"]),
			"rules": {"slope": Vector3(-1.0, 0.5, 0.1), "lava": Vector3(-1.0, 0.7, 0.2)},
			"cluster_scale": 150.0, "cluster_threshold": 0.15, "scale_range": Vector2(0.8, 2.2),
			"max_tilt_deg": 10.0, "align_to_normal": 0.3, "sink": 0.2, "shadow_distance": 250.0,
			"collision": 2, "collision_size": Vector2(0.9, 1.2), "collision_distance": 50.0}),
		L({"name": "pebbles", "model": ROCKS, "seed": 213, "cell_size": 24.0, "max_distance": 70.0,
			"fade_length": 15.0, "density": 0.12, "grid_res": 4, "meshes": PackedStringArray(["pebbles_lod0"]),
			"scale_range": Vector2(0.7, 1.8), "align_to_normal": 0.9, "sink": 0.02, "cast_shadows": false}),
	]
	return rs


func _glacia() -> ScatterRuleSet:
	var rs := ScatterRuleSet.new()
	rs.max_altitude = 3000.0
	rs.material_params = {
		"rock": {"color_cover": Color(0.85, 0.9, 0.97), "cover_amount": 0.0, "snow_amount": 1.4},
		"ice": {"color_body": Color(0.3, 0.55, 0.75), "color_rim": Color(0.78, 0.92, 1.0),
			"color_glow": Color(0.35, 0.7, 1.0), "glow_energy": 0.5},
	}
	rs.layers = [
		L({"name": "ice_shards", "model": CRYST, "seed": 301, "cell_size": 128.0, "max_distance": 900.0,
			"fade_length": 80.0, "density": 0.0018, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["ice_shard_a_lod0"]),
			"rules": {"slope": Vector3(-1.0, 0.45, 0.1)},
			"cluster_scale": 220.0, "cluster_threshold": -0.05, "cluster_soft": 0.3,
			"scale_range": Vector2(0.6, 2.4), "max_tilt_deg": 14.0, "align_to_normal": 0.3, "sink": 0.4,
			"shadow_distance": 300.0, "collision": 2, "collision_size": Vector2(0.8, 1.0), "collision_distance": 50.0}),
		L({"name": "ice_field", "model": CRYST, "seed": 303, "cell_size": 96.0, "max_distance": 500.0,
			"fade_length": 60.0, "density": 0.004, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["ice_shard_b_lod0"]),
			"rules": {"slope": Vector3(-1.0, 0.3, 0.08)},
			"cluster_scale": 100.0, "cluster_threshold": 0.0, "scale_range": Vector2(0.6, 1.8),
			"max_tilt_deg": 10.0, "align_to_normal": 0.6, "sink": 0.15, "shadow_distance": 150.0}),
		L({"name": "snow_boulders", "model": ROCKS, "seed": 305, "cell_size": 96.0, "max_distance": 450.0,
			"fade_length": 50.0, "density": 0.004, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["boulder_b_lod0", "boulder_b_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"cluster_scale": 120.0, "cluster_threshold": -0.2, "scale_range": Vector2(0.5, 2.8),
			"max_tilt_deg": 20.0, "align_to_normal": 0.5, "sink": 0.2, "shadow_distance": 160.0,
			"collision": 2, "collision_size": Vector2(0.7, 0.4), "collision_distance": 50.0}),
		L({"name": "snow_slabs", "model": ROCKS, "seed": 307, "cell_size": 96.0, "max_distance": 300.0,
			"fade_length": 40.0, "density": 0.003, "grid_res": 6,
			"meshes": PackedStringArray(["boulder_c_lod0", "boulder_c_lod1"]),
			"lod_distances": PackedFloat32Array([50.0]),
			"scale_range": Vector2(0.5, 2.0), "max_tilt_deg": 12.0, "align_to_normal": 0.8, "sink": 0.12,
			"shadow_distance": 100.0}),
		L({"name": "pebbles", "model": ROCKS, "seed": 309, "cell_size": 24.0, "max_distance": 60.0,
			"fade_length": 15.0, "density": 0.04, "grid_res": 4, "meshes": PackedStringArray(["pebbles_lod0"]),
			"rules": {"snow": Vector3(-1.0, 0.7, 0.2)},
			"scale_range": Vector2(0.7, 1.5), "align_to_normal": 0.9, "sink": 0.03, "cast_shadows": false}),
	]
	return rs


func _moon(dark: bool) -> ScatterRuleSet:
	var rs := ScatterRuleSet.new()
	rs.max_altitude = 2500.0
	rs.material_params = {
		"rock": {"color_cover": Color(0.2, 0.19, 0.18) if dark else Color(0.5, 0.49, 0.47),
			"cover_amount": 0.7, "snow_amount": 0.0, "normal_strength": 1.3},
	}
	rs.layers = [
		L({"name": "regolith_boulders", "model": ROCKS, "seed": 401, "cell_size": 96.0, "max_distance": 500.0,
			"fade_length": 60.0, "density": 0.004, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["boulder_b_lod0", "boulder_b_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"cluster_scale": 150.0, "cluster_threshold": -0.2, "cluster_soft": 0.4,
			"scale_range": Vector2(0.4, 3.2), "edge_scale": 0.3, "max_tilt_deg": 25.0, "align_to_normal": 0.6,
			"sink": 0.25, "shadow_distance": 200.0, "collision": 2, "collision_size": Vector2(0.7, 0.4),
			"collision_distance": 50.0}),
		L({"name": "round_boulders", "model": ROCKS, "seed": 403, "cell_size": 96.0, "max_distance": 400.0,
			"fade_length": 50.0, "density": 0.0025, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["boulder_a_lod0", "boulder_a_lod1"]),
			"lod_distances": PackedFloat32Array([60.0]),
			"rules": {"slope": Vector3(0.04, 1.0, 0.06)},
			"scale_range": Vector2(0.5, 2.5), "max_tilt_deg": 20.0, "align_to_normal": 0.5, "sink": 0.2,
			"shadow_distance": 160.0, "collision": 2, "collision_size": Vector2(0.7, 0.35), "collision_distance": 50.0}),
		L({"name": "rock_clusters", "model": ROCKS, "seed": 405, "cell_size": 128.0, "max_distance": 500.0,
			"fade_length": 60.0, "density": 0.0012, "grid_res": 6, "exact_height": true,
			"meshes": PackedStringArray(["rock_cluster_lod0", "rock_cluster_lod1"]),
			"lod_distances": PackedFloat32Array([80.0]),
			"rules": {"rock": Vector3(0.05, 2.0, 0.2)},
			"scale_range": Vector2(0.8, 2.4), "max_tilt_deg": 12.0, "align_to_normal": 0.7, "sink": 0.15,
			"shadow_distance": 180.0, "collision": 3, "collision_distance": 50.0}),
		L({"name": "pebbles", "model": ROCKS, "seed": 407, "cell_size": 24.0, "max_distance": 70.0,
			"fade_length": 15.0, "density": 0.14, "grid_res": 4, "meshes": PackedStringArray(["pebbles_lod0"]),
			"scale_range": Vector2(0.7, 1.8), "align_to_normal": 0.9, "sink": 0.02, "cast_shadows": false}),
	]
	return rs
