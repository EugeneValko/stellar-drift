class_name LoadingScreen
extends CanvasLayer
## Loading screen: deep-space backdrop (drawn procedurally: soft nebula glow, twinkling stars, a
## dim planet limb with an atmosphere rim), the title "STELLAR DRIFT", a thin glowing progress
## line with the current stage and percent, rotating tips. Drawn in code, scaled to 1080p.
## API: set_progress(p 0..1, stage), finish(time) (awaitable fade-out, then frees itself).

const C_TEXT := Color(0.86, 0.95, 1.0, 0.95)
const C_DIM := Color(0.78, 0.92, 1.0, 0.5)
const C_ACCENT := Color(1.0, 0.76, 0.34, 1.0)
const C_LINE := Color(0.6, 0.9, 1.0, 0.3)
const TEXT_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans", "sans-serif"]
const MONO_FONTS := ["JetBrains Mono", "Cascadia Mono", "Consolas", "DejaVu Sans Mono", "monospace"]
const TIPS := [
	"Tab или 1–5 — режим скорости: посадка, атмосфера, космос, круиз, варп",
	"T — выбрать цель, R — автопилот: разворот, разгон, остановка на орбите",
	"F рядом с рампой — выйти из корабля или сесть в него",
	"C — вид из кабины. Оставьте корабль на земле на 20 с — камера облетит его",
	"Esc — пауза и настройки звука. F1 — все клавиши",
	"У земли flight assist сам гасит снижение — касание мягкое на любой планете",
]

var progress := 0.0
var shown_progress := 0.0
var stage := ""
var _root: Control
var _font: SystemFont
var _font_thin: SystemFont
var _mono: SystemFont
var _stars: Array = []         # [pos (0..1), size, brightness, phase]
var _t := 0.0
var _s := 1.0
var _tip_i := 0
var _tip_t := 0.0
var _closing := false


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(TEXT_FONTS)
	_font.font_weight = 500
	_font_thin = SystemFont.new()
	_font_thin.font_names = PackedStringArray(TEXT_FONTS)
	_font_thin.font_weight = 300
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(MONO_FONTS)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_root.draw.connect(_draw_screen)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in 340:
		var b := pow(rng.randf(), 3.0)
		_stars.append([Vector2(rng.randf(), rng.randf()), 0.6 + 1.6 * b, 0.25 + 0.75 * b, rng.randf() * TAU])
	_tip_i = rng.randi() % TIPS.size()


func set_progress(p: float, stage_text := "") -> void:
	progress = clampf(maxf(p, progress), 0.0, 1.0)
	if stage_text != "":
		stage = stage_text


## Fades out over `time` and frees the screen (awaitable).
func finish(time := 0.8) -> void:
	_closing = true
	progress = 1.0
	shown_progress = 1.0
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, time).set_trans(Tween.TRANS_SINE)
	await tw.finished
	queue_free()


func _process(dt: float) -> void:
	_t += dt
	shown_progress = move_toward(shown_progress, progress, dt * 0.6) if not _closing else 1.0
	# never lag far behind (the last stage may be very short)
	shown_progress = maxf(shown_progress, progress - 0.12)
	_tip_t += dt
	if _tip_t > 6.0:
		_tip_t = 0.0
		_tip_i = (_tip_i + 1) % TIPS.size()
	_root.queue_redraw()


func _spaced(text: String, pos: Vector2, size: int, spacing: float, col: Color, font: Font) -> void:
	var w := 0.0
	for ch in text:
		w += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + spacing
	w -= spacing
	var x := pos.x - w * 0.5
	for ch in text:
		_root.draw_string(font, Vector2(x, pos.y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
		x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + spacing


func _draw_screen() -> void:
	var vs := _root.size
	_s = vs.y / 1080.0
	if vs.y < 100.0:
		return
	# backdrop
	_root.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.006, 0.009, 0.018))
	# soft nebula glows (stacked translucent circles)
	for g: Array in [[Vector2(0.72, 0.32), 0.55, Color(0.25, 0.32, 0.6, 0.012)], [Vector2(0.28, 0.6), 0.45, Color(0.45, 0.25, 0.5, 0.01)]]:
		var c: Vector2 = g[0] * vs
		for k in 14:
			var r: float = float(g[1]) * vs.y * (1.0 - k / 14.0)
			_root.draw_circle(c, r, g[2])
	# stars
	for st: Array in _stars:
		var p: Vector2 = st[0] * vs
		var tw := 0.75 + 0.25 * sin(_t * (0.6 + float(st[3]) * 0.3) + float(st[3]))
		var a: float = float(st[2]) * tw
		var r: float = float(st[1]) * _s
		_root.draw_circle(p, r, Color(0.85, 0.92, 1.0, a * 0.9))
		if float(st[2]) > 0.8:
			_root.draw_circle(p, r * 3.0, Color(0.6, 0.75, 1.0, a * 0.06))
	# planet limb: dark disc rising from the bottom with an atmosphere rim
	var pc := Vector2(vs.x * 0.5, vs.y * 1.0 + vs.y * 2.05)
	var pr := vs.y * 2.38
	for k in 16:
		var rr := pr + (16 - k) * 3.2 * _s
		_root.draw_arc(pc, rr, PI * 1.12, PI * 1.88, 160, Color(0.35, 0.6, 1.0, 0.012 + 0.006 * k), 4.0 * _s, true)
	_root.draw_circle(pc, pr, Color(0.008, 0.012, 0.022))
	_root.draw_arc(pc, pr, PI * 1.12, PI * 1.88, 200, Color(0.55, 0.8, 1.0, 0.55), 1.4 * _s, true)
	# title
	var cy := vs.y * 0.42
	var title_size := int(78 * _s)
	_spaced("STELLAR DRIFT", Vector2(vs.x * 0.5, cy), title_size, 18.0 * _s, Color(C_TEXT, 0.95), _font_thin)
	_spaced("СИСТЕМА HELIOS", Vector2(vs.x * 0.5, cy + 44.0 * _s), int(16 * _s), 7.0 * _s, Color(C_ACCENT, 0.9), _font)
	# progress line
	var bw := 560.0 * _s
	var bx := vs.x * 0.5 - bw * 0.5
	var by := cy + 120.0 * _s
	_root.draw_line(Vector2(bx, by), Vector2(bx + bw, by), C_LINE, 1.0 * _s, true)
	var px := bx + bw * shown_progress
	_root.draw_line(Vector2(bx, by), Vector2(px, by), Color(0.8, 0.96, 1.0, 0.95), 2.0 * _s, true)
	for k in 5:
		_root.draw_circle(Vector2(px, by), (2.0 + k * 2.6) * _s, Color(0.6, 0.85, 1.0, 0.07))
	_root.draw_circle(Vector2(px, by), 2.2 * _s, Color(1, 1, 1, 0.95))
	var fs := int(15 * _s)
	_root.draw_string(_font, Vector2(bx, by + 30.0 * _s), stage, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, C_DIM)
	_root.draw_string(_mono, Vector2(bx, by + 30.0 * _s), "%d%%" % roundi(shown_progress * 100.0),
		HORIZONTAL_ALIGNMENT_RIGHT, bw, fs, C_TEXT)
	# tip
	var tip: String = TIPS[_tip_i]
	var ta := clampf(minf(_tip_t / 0.8, (6.0 - _tip_t) / 0.8), 0.0, 1.0)
	var tsz := int(16 * _s)
	var tw2 := _font.get_string_size(tip, HORIZONTAL_ALIGNMENT_LEFT, -1, tsz).x
	_root.draw_string(_font, Vector2(vs.x * 0.5 - tw2 * 0.5, vs.y - 72.0 * _s), tip, HORIZONTAL_ALIGNMENT_LEFT, -1,
		tsz, Color(C_DIM, 0.75 * ta))
