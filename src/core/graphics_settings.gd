class_name GraphicsSettings
extends RefCounted
## User graphics options (Esc -> Графика), saved in user://settings.cfg [graphics]:
##   aa           MSAA 4x / MSAA 2x (default) + FXAA: sharp in motion; or TAA: cheapest
##                (RTX 3060, start meadow: 4x +1.6 ms over 2x, TAA -1 ms), smooths foliage and
##                raymarch grain, softer while moving;
##   sky_quality  clouds / atmosphere / ocean steps (SolarSystem.set_quality): 1 high, 0 medium.
## Captures and benchmarks (--shot / --cam) keep the defaults so frames stay comparable.

enum AA { MSAA_4X, MSAA_2X, TAA }

const SETTINGS_PATH := "user://settings.cfg"

static var aa := AA.MSAA_2X
static var sky_quality := 1
static var _loaded := false


static func load_cfg() -> void:
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	aa = clampi(int(cfg.get_value("graphics", "aa", AA.MSAA_2X)), 0, 2) as AA
	sky_quality = clampi(int(cfg.get_value("graphics", "sky_quality", 1)), 0, 1)


static func save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("graphics", "aa", int(aa))
	cfg.set_value("graphics", "sky_quality", sky_quality)
	cfg.save(SETTINGS_PATH)


## Applies the saved options to the game viewport and the star system.
static func apply(vp: Viewport, system: SolarSystem) -> void:
	if not _loaded:
		load_cfg()
	apply_aa(vp)
	if system and system.quality != sky_quality:
		system.set_quality(sky_quality)


static func apply_aa(vp: Viewport) -> void:
	if aa == AA.TAA:
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.use_taa = true
	else:
		vp.msaa_3d = Viewport.MSAA_4X if aa == AA.MSAA_4X else Viewport.MSAA_2X
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		vp.use_taa = false
