class_name IntroCard
extends CanvasLayer
## Short cinematic caption after the fade-in: a small amber "STELLAR DRIFT", the place
## ("Terra Nova · система Helios") in thin letter-spaced type with a hairline that draws out,
## fading in and out at the lower third. `play(title, subtitle)` is awaitable.

const TEXT_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans", "sans-serif"]

var title := "Terra Nova · система Helios"
var kicker := "STELLAR DRIFT"
var hold := 3.6
var _t := -1.0
var _root: Control
var _font: SystemFont
var _font_thin: SystemFont
## Capture: freeze at this time (s into the animation).
var freeze_at := -1.0


func _ready() -> void:
	layer = 15
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(TEXT_FONTS)
	_font.font_weight = 600
	_font_thin = SystemFont.new()
	_font_thin.font_names = PackedStringArray(TEXT_FONTS)
	_font_thin.font_weight = 300
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_root.draw.connect(_draw_card)


func play(p_title := "", p_kicker := "") -> void:
	if p_title != "":
		title = p_title
	if p_kicker != "":
		kicker = p_kicker
	_t = 0.0
	while _t >= 0.0 and _t < hold + 3.2:
		await get_tree().process_frame
	_t = -1.0
	_root.queue_redraw()


func _process(dt: float) -> void:
	if freeze_at >= 0.0:
		_t = freeze_at
		_root.queue_redraw()
		return
	if _t >= 0.0:
		_t += dt
		_root.queue_redraw()


func _spaced(text: String, cx: float, y: float, size: int, spacing: float, col: Color, font: Font) -> float:
	var w := 0.0
	for ch in text:
		w += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + spacing
	w -= spacing
	var x := cx - w * 0.5
	for ch in text:
		_root.draw_string_outline(font, Vector2(x, y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(2, int(size * 0.08)),
			Color(0, 0.01, 0.02, col.a * 0.35))
		_root.draw_string(font, Vector2(x, y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
		x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + spacing
	return w


func _draw_card() -> void:
	if _t < 0.0:
		return
	var vs := _root.size
	var s := vs.y / 1080.0
	if vs.y < 100.0:
		return
	var fin := smoothstep(0.0, 1.4, _t)
	var fout := 1.0 - smoothstep(hold + 1.4, hold + 3.0, _t)
	var a := fin * fout
	if a <= 0.001:
		return
	var y := vs.y * 0.70
	var rise := (1.0 - fin) * 10.0 * s
	_spaced(kicker, vs.x * 0.5, y - 46.0 * s + rise, int(14 * s), 8.0 * s, Color(1.0, 0.76, 0.34, a * 0.95), _font)
	var w := _spaced(title, vs.x * 0.5, y + rise, int(40 * s), 5.0 * s, Color(0.9, 0.97, 1.0, a), _font_thin)
	# hairline drawing out from the centre
	var lw := w * 0.5 * smoothstep(0.4, 2.0, _t)
	var ly := y + 22.0 * s + rise
	_root.draw_line(Vector2(vs.x * 0.5 - lw, ly), Vector2(vs.x * 0.5 + lw, ly), Color(0.7, 0.92, 1.0, a * 0.5), 1.0 * s, true)
