@tool
class_name ScatterLayer
extends Resource
## One kind of scattered object (a tree species, grass, a rock type...) and its placement rules.
##
## Placement is deterministic per cell of an equi-angular cube-sphere grid (cell edge ~ `cell_size`).
## A cell's instances depend only on (planet seed, layer seed, cell) so they are identical whichever
## patch (near ring or far ring) asks for them.
##
## Biome rules: `rules` maps an attribute name (see ScatterBiome.ATTRS: height, slope, moist, forest,
## snow, rock, desert, beach, lava, ice, lat) to Vector3(min, max, soft). The probability of a candidate
## is `density` x the product of the soft range weights (x the cluster noise, if enabled).
## height = metres above sea level (or above the base radius on planets without ocean); slope = 1 - cos.

@export var name := "layer"
@export var enabled := true
@export_file("*.glb") var model := "res://assets/models/flora_terra.glb"
## Near-ring meshes by node name in `model`, finest first; switched per patch by `lod_distances`.
@export var meshes: PackedStringArray = []
## Patch distance (m) at which meshes[i] switches to meshes[i + 1].
@export var lod_distances: PackedFloat32Array = []
## Optional far-ring mesh (low hull). Empty = no far ring.
@export var far_mesh := ""
## Far patches are far_factor x far_factor near cells.
@export var far_factor := 8
## Distance (m) where the near ring hands over to the far ring (dithered cross-fade over fade_length).
@export var far_start := 800.0

@export_group("Grid")
@export var cell_size := 64.0
@export var max_distance := 400.0
@export var fade_length := 40.0
## Height grid resolution per cell (quads per side); instance heights are interpolated from it.
@export var grid_res := 8
## Sample the exact height for every instance (trees / big rocks; slower).
@export var exact_height := false
## Distance thinning: from thin_start to max_distance only `thin_keep` of the instances stay.
@export var thin_start := -1.0
@export var thin_keep := 1.0

@export_group("Placement")
@export var density := 0.01            ## instances per m^2 at full biome weight
@export var rules: Dictionary = {}
@export var cluster_scale := 0.0       ## m; 0 = no clustering noise
@export var cluster_threshold := 0.0   ## noise (-1..1) above which the layer grows
@export var cluster_soft := 0.2
@export var seed := 0
@export var scale_range := Vector2(0.8, 1.2)
## Instances at biome edges (low weight) are up to this fraction smaller.
@export var edge_scale := 0.35
@export var max_tilt_deg := 0.0
## 0 = vertical (sphere up), 1 = follow the terrain normal.
@export var align_to_normal := 0.0
## Pushed into the ground by sink * scale (m).
@export var sink := 0.0
## Extra random height (Y) scale: +-fraction (trees / grass of different heights).
@export var height_jitter := 0.0
## Flora: encode the alien canopy region (ScatterBiome alien_b / alien_c) into INSTANCE_CUSTOM.w
## (= snow + 2 * region); flora shaders tint with region_tint_b / region_tint_c.
@export var tint_regions := false

@export_group("Rendering")
@export var cast_shadows := true
@export var shadow_distance := 250.0
## Nominal height of the mesh (m), drives wind sway amplitude.
@export var sway_height := 1.0
## Per-layer material tweaks: { slot_name: { param: value } } on top of the planet's slot materials.
@export var material_overrides: Dictionary = {}

@export_group("Collision")
## 0 = none, 1 = capsule (trunks), 2 = sphere (boulders), 3 = convex hull of the last near mesh.
@export var collision := 0
## Capsule: (radius, height); sphere: (radius, centre height). Metres at scale 1.
@export var collision_size := Vector2(0.4, 6.0)
@export var collision_distance := 60.0
