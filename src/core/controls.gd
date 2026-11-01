extends Node
## Controls (autoload): registers all input actions in code (single source of truth, no
## project.godot conflicts). Help text for F1 is generated from HELP below.

const KEYS := {
	# shared movement (ship thrust axes / on-foot movement)
	"move_forward": [KEY_W], "move_back": [KEY_S],
	"move_left": [KEY_A], "move_right": [KEY_D],
	"move_up": [KEY_SPACE], "move_down": [KEY_CTRL],
	"roll_left": [KEY_Q], "roll_right": [KEY_E],
	"boost": [KEY_SHIFT],
	# ship
	"speed_mode_next": [KEY_TAB],
	"mode_1": [KEY_1], "mode_2": [KEY_2], "mode_3": [KEY_3], "mode_4": [KEY_4], "mode_5": [KEY_5],
	"ship_stop": [KEY_X],
	"gear_toggle": [KEY_G],
	"target_next": [KEY_T],
	"autopilot": [KEY_R],
	"flight_assist_toggle": [KEY_Z],
	# common
	"interact": [KEY_F],
	"camera_toggle": [KEY_C],
	"freecam_toggle": [KEY_V],
	"help": [KEY_F1],
	"hud_toggle": [KEY_H],
	"screenshot": [KEY_F12],
	"pause_menu": [KEY_ESCAPE],
}

## Displayed by the F1 overlay. Keep in sync with gameplay code.
const HELP := [
	["Мышь", "Тангаж / рыскание (корабль), обзор (пешком)"],
	["W / S", "Тяга вперёд / назад · идти"],
	["A / D", "Смещение влево / вправо"],
	["Space / Ctrl", "Вверх / вниз · прыжок"],
	["Q / E", "Крен"],
	["Shift", "Форсаж · бег"],
	["Tab, 1–5", "Режим скорости: посадка / атмосфера / космос / круиз / варп"],
	["X", "Полная остановка"],
	["G", "Шасси"],
	["T", "Следующая цель"],
	["R", "Автопилот к цели"],
	["Z", "Flight assist вкл/выкл"],
	["F", "Выйти из корабля / сесть"],
	["C", "Камера: кабина / сзади"],
	["V", "Свободная камера (колесо — скорость)"],
	["H", "Скрыть HUD"],
	["F12", "Скриншот"],
	["Esc", "Курсор мыши: показать / захватить"],
	["F1", "Эта подсказка"],
]


func _enter_tree() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
