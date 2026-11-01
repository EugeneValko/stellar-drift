@tool
class_name ScatterRuleSet
extends Resource
## Per-planet scatter configuration (src/planets/scatter/presets/<planet>.tres).
## Authoring helper: tools/dev/make_scatter_presets.gd regenerates the presets from code.

@export var layers: Array[ScatterLayer] = []
## Material slot parameters: { slot_name: { shader_param: value } } (slots: bark, bark_palm, needles,
## leaves, frond, grass, flower, glow, far_foliage, rock, basalt, crystal, ice). Ground palette values
## (grass/dry/rock/snow colours) are filled from the PlanetConfig automatically unless set here.
@export var material_params: Dictionary = {}
@export var wind_dir := Vector3(1.0, 0.0, 0.35)
@export var wind_strength := 1.0
@export var wind_speed := 1.0
## No scatter above this altitude (m above the terrain under the focus).
@export var max_altitude := 3500.0
