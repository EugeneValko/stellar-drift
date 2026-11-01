class_name HelpOverlay
extends CanvasLayer
## F1 controls overlay: a semi-transparent panel listing Controls.HELP in two columns
## (key caps + Russian descriptions). Toggled by the "help" action (F1).
## On start a small hint "F1 — управление" is shown for a few seconds until the player has opened
## the overlay once (remembered in user://ui_state.cfg). Everything is built in code and scaled
## with the window height (designed at 1080p).

const C_TEXT := Color(0.86, 0.95, 1.0, 0.95)
const C_DIM := Color(0.78, 0.92, 1.0, 0.5)
const C_ACCENT := Color(1.0, 0.76, 0.34, 1.0)
const C_LINE := Color(0.6, 0.9, 1.0, 0.28)
const STATE_FILE := "user://ui_state.cfg"
const TEXT_FONTS := ["Bahnschrift", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans", "sans-serif"]
const MONO_FONTS := ["JetBrains Mono", "Cascadia Mono", "Consolas", "DejaVu Sans Mono", "monospace"]

@export var hint_seconds := 7.0
@export var show_hint_on_start := true

var is_open := false
var _scaler: Control
var _panel_root: Control
var _hint: Control
var _text_font: SystemFont
var _mono: SystemFont
var _tween: Tween


func _ready() -> void:
	layer = 20
	_text_font = SystemFont.new()
	_text_font.font_names = PackedStringArray(TEXT_FONTS)
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(MONO_FONTS)
	_mono.font_weight = 600
	_scaler = Control.new()
	_scaler.name = "Scaler"
	_scaler.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scaler)
	_build_panel()
	_build_hint()
	get_viewport().size_changed.connect(_fit)
	_fit()
	_panel_root.visible = false
	_hint.visible = false
	if show_hint_on_start and not Capture.active and not _seen():
		_show_hint()


func _fit() -> void:
	var vs := get_viewport().get_visible_rect().size
	var k := maxf(vs.y / 1080.0, 0.1)
	_scaler.scale = Vector2(k, k)
	_scaler.position = Vector2.ZERO
	_scaler.size = vs / k


# ------------------------------------------------------------------ API

func toggle() -> void:
	set_open(not is_open)


func set_open(on: bool, instant := false) -> void:
	is_open = on
	if _tween and _tween.is_valid():
		_tween.kill()
	if on:
		_hint.visible = false
		_mark_seen()
		_panel_root.visible = true
		if instant:
			_panel_root.modulate.a = 1.0
		else:
			_panel_root.modulate.a = 0.0
			_tween = create_tween()
			_tween.tween_property(_panel_root, "modulate:a", 1.0, 0.15)
	else:
		if instant:
			_panel_root.visible = false
		else:
			_tween = create_tween()
			_tween.tween_property(_panel_root, "modulate:a", 0.0, 0.12)
			_tween.tween_callback(func() -> void: _panel_root.visible = false)


## Shows the "F1 — управление" hint (fades out after `seconds`; <= 0 keeps it).
func show_hint(seconds := -1.0) -> void:
	_show_hint(hint_seconds if seconds < 0.0 else seconds)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("help") and not event.is_echo():
		toggle()
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ persistence

func _seen() -> bool:
	var cf := ConfigFile.new()
	if cf.load(STATE_FILE) != OK:
		return false
	return bool(cf.get_value("help", "seen", false))


func _mark_seen() -> void:
	if Capture.active:
		return
	var cf := ConfigFile.new()
	cf.load(STATE_FILE)
	cf.set_value("help", "seen", true)
	cf.save(STATE_FILE)


# ------------------------------------------------------------------ building

func _label(text: String, size: int, col: Color, mono := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _mono if mono else _text_font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0.02, 0.04, 0.6))
	l.add_theme_constant_override("outline_size", 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _keycap(text: String) -> Control:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.75, 0.92, 1.0, 0.07)
	sb.border_color = Color(0.75, 0.92, 1.0, 0.45)
	sb.set_border_width_all(1)
	sb.border_width_bottom = 2
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 3
	pc.add_theme_stylebox_override("panel", sb)
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(text, 17, C_TEXT, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pc.add_child(l)
	return pc


## "W / S" -> [W] / [S]; "Tab, 1–5" -> [Tab] [1–5]
func _keys_row(keys: String) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	hb.alignment = BoxContainer.ALIGNMENT_END
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var groups := keys.split(" / ")
	for gi in groups.size():
		if gi > 0:
			hb.add_child(_label("/", 16, C_DIM))
		for part in groups[gi].split(", "):
			hb.add_child(_keycap(part.strip_edges()))
	return hb


func _build_panel() -> void:
	_panel_root = Control.new()
	_panel_root.name = "HelpPanel"
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scaler.add_child(_panel_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.01, 0.02, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.025, 0.045, 0.07, 0.84)
	sb.border_color = C_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 44
	sb.content_margin_right = 44
	sb.content_margin_top = 30
	sb.content_margin_bottom = 28
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 18
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vb)
	# title
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(head)
	var title := _label("УПРАВЛЕНИЕ", 30, C_TEXT)
	title.add_theme_constant_override("outline_size", 0)
	head.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	var sub := _label("STELLAR DRIFT", 14, C_ACCENT)
	sub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(sub)
	var line := ColorRect.new()
	line.color = C_LINE
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(line)
	# two columns
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 56)
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cols)
	var rows: Array = Controls.HELP
	var half := ceili(rows.size() / 2.0)
	for c in 2:
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 18)
		grid.add_theme_constant_override("v_separation", 11)
		grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cols.add_child(grid)
		for i in range(c * half, mini((c + 1) * half, rows.size())):
			var row: Array = rows[i]
			var keys := _keys_row(str(row[0]))
			keys.custom_minimum_size = Vector2(150, 0)
			grid.add_child(keys)
			var desc := _label(str(row[1]), 17, C_TEXT)
			desc.custom_minimum_size = Vector2(330, 0)
			desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			desc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			grid.add_child(desc)
	var line2 := line.duplicate() as ColorRect
	vb.add_child(line2)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(foot)
	foot.add_child(_keycap("F1"))
	foot.add_child(_label("закрыть", 15, C_DIM))
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(sp2)
	foot.add_child(_label("Пешком: F у рампы — сесть в корабль", 15, C_DIM))


func _build_hint() -> void:
	_hint = PanelContainer.new()
	_hint.name = "Hint"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.025, 0.045, 0.07, 0.62)
	sb.border_color = C_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 14
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	_hint.add_theme_stylebox_override("panel", sb)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_child(hb)
	hb.add_child(_keycap("F1"))
	var l := _label("— управление", 17, C_TEXT)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(l)
	_scaler.add_child(_hint)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 36)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hint.grow_vertical = Control.GROW_DIRECTION_END


func _show_hint(seconds := 7.0) -> void:
	_hint.visible = true
	_hint.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(0.6)
	tw.tween_property(_hint, "modulate:a", 1.0, 0.5)
	if seconds > 0.0:
		tw.tween_interval(seconds)
		tw.tween_property(_hint, "modulate:a", 0.0, 1.2)
		tw.tween_callback(func() -> void: _hint.visible = false)
