@tool
class_name PlanetConfig
extends Resource
## Data-only description of a procedural planet (shape, biomes, flags).
##
## All lengths are metres. Heights are measured from `radius` (the base sphere).
## The height pipeline lives in TerrainGenerator; every knob it uses is here so a
## planet is fully reproducible from (config, seed).
##
## Ocean: the ocean surface is a sphere of radius `radius + sea_level`.
## `sea_level == 0` (or `has_ocean == false`) means the planet has no ocean.

enum PlanetType { ROCKY, EARTHLIKE, ICE, VOLCANIC, MOON }

@export var planet_name := "Planet"
@export var type: PlanetType = PlanetType.ROCKY
@export var radius := 10000.0
@export var seed := 1
## Nominal maximum relief (m). Used by the shader to normalise heights.
@export var height_amplitude := 2000.0

@export_group("Flags")
@export var has_ocean := false
## Ocean surface height above `radius` (m). 0 = no ocean.
@export var sea_level := 0.0
@export var has_atmosphere := false
@export var has_clouds := false

@export_group("Continents")
## Wavelength of the continent noise (m).
@export var continent_scale := 40000.0
@export var continent_octaves := 5
## Added to the continent noise (-1..1). Positive = more land.
@export var continent_bias := 0.0
## Height of inland plains at continent noise == 0.5 (m).
@export var continent_height := 600.0
## Depth of the ocean basins below the coast (m).
@export var ocean_depth := 0.0
## Continent-noise width of the coastal shelf / beach slope.
@export var coast_width := 0.04
## Domain-warp wavelength (m) and strength (m) applied to continents & mountains.
@export var warp_scale := 30000.0
@export var warp_strength := 8000.0

@export_group("Mountains")
@export var mountain_scale := 9000.0
@export var mountain_octaves := 6
@export var mountain_height := 3000.0
## Exponent applied to the ridged noise (>1 = sharper peaks, broader valleys).
@export var mountain_sharpness := 1.6
## Wavelength of the low-frequency mask that decides where ranges are.
@export var mountain_mask_scale := 30000.0
## Mask threshold: lower = more mountains (-1..1).
@export var mountain_coverage := 0.0
## Relative height of the plateau that ranges sit on (0..1 of mountain_height).
@export var mountain_plateau := 0.25
## Erosion-like gullies on mountain flanks (wavelength m, relative amplitude).
@export var gully_scale := 1800.0
@export var gully_strength := 0.25

@export_group("Hills & detail")
@export var hills_scale := 3000.0
@export var hills_height := 150.0
## Mid-frequency roughness (boulders/dunes scale) — wavelength, amplitude.
@export var rough_scale := 160.0
@export var rough_height := 8.0
## Ground micro relief (only generated for fine LOD chunks).
@export var detail_scale := 18.0
@export var detail_height := 0.8

@export_group("Canyons & terraces")
@export var canyon_scale := 0.0          ## 0 = disabled
@export var canyon_depth := 0.0
@export var canyon_width := 0.08          ## in noise units (0..1)
@export var terrace_step := 0.0           ## 0 = disabled
@export var terrace_strength := 0.0       ## 0..1
## Flatten everything below this height (frozen seas / lava plains). Very low = off.
@export var floor_level := -100000.0

@export_group("Volcanoes")
@export var volcano_scale := 0.0          ## cell size (m), 0 = disabled
@export var volcano_height := 0.0
@export var volcano_density := 0.3        ## 0..1 share of cells that get a volcano

@export_group("Craters")
@export var crater_layers := 0
@export var crater_scale := 4000.0        ## cell size of the biggest crater layer (m)
@export var crater_depth := 0.22          ## depth / crater radius
@export var crater_density := 0.7         ## 0..1 share of cells with a crater
## Dark low-lying plains on moons (0..1).
@export var maria_strength := 0.0

@export_group("Climate")
@export var moisture_scale := 25000.0
@export var moisture_bias := 0.0
## Strength of the subtropical dry belt (deserts).
@export var desert_belt := 0.35
## Height above sea level (m) where snow starts at the equator.
@export var snow_line := 4000.0
## How much the snow line drops toward the poles (0..1, 1 = reaches sea at pole).
@export var polar_snow := 0.75
## Width of the beach band around sea level (m).
@export var beach_width := 25.0

@export_group("Palette")
@export var color_seabed := Color(0.16, 0.18, 0.15)
@export var color_sand := Color(0.76, 0.68, 0.5)
@export var color_grass := Color(0.22, 0.38, 0.12)
@export var color_forest := Color(0.08, 0.2, 0.06)
@export var color_dry := Color(0.55, 0.5, 0.3)
@export var color_desert := Color(0.78, 0.6, 0.38)
@export var color_rock := Color(0.38, 0.34, 0.3)
@export var color_rock2 := Color(0.24, 0.22, 0.21)
@export var color_snow := Color(0.92, 0.94, 0.98)
@export var color_lava := Color(1.0, 0.32, 0.05)
@export var lava_intensity := 0.0         ## emission multiplier; 0 = no lava
## Strength of rock strata banding in cliffs (0..1).
@export var strata_strength := 0.3
## Albedo contrast of macro (orbit-scale) variation (0..1).
@export var macro_variation := 0.35

@export_group("Component hints")
## Hints for atmosphere / ocean components (they may use their own configs).
@export var atmosphere_color := Color(0.35, 0.55, 1.0)
@export var atmosphere_height := 0.0
@export var ocean_color := Color(0.02, 0.09, 0.16)


func get_ocean_radius() -> float:
	return radius + sea_level if has_ocean_surface() else 0.0


func has_ocean_surface() -> bool:
	return has_ocean and sea_level != 0.0


## Reference height the biome logic measures from (sea level, or the base radius).
func get_base_level() -> float:
	return sea_level if has_ocean_surface() else 0.0
