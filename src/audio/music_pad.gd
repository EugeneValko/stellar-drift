class_name MusicPad
extends Node
## Generative ambient music: slow pad chords (one synthesized pad note, transposed by
## pitch_scale), a sub drone in space, and sparse glassy bell notes from the chord's pentatonic
## scale. Chords change every 14–24 s with 6–8 s cross-fades; the mood (space / planet / on foot)
## picks the chord set and timbre. Everything goes to the "Music" bus (reverb + soft low-pass,
## set up by GameAudio). Runs while the tree is paused.

enum Mood { SPACE, PLANET, ON_FOOT }

## Semitone offsets from C3 (the pad sample's pitch). Voicings stay within -7..19.
const CHORDS := {
	Mood.SPACE: [[2, 9, 14, 17], [-2, 5, 9, 14], [-5, 2, 7, 10], [0, 7, 10, 15], [-4, 3, 7, 12]],
	Mood.PLANET: [[0, 7, 11, 14], [2, 6, 9, 14], [-3, 4, 7, 11], [-7, 4, 9, 11], [5, 9, 12, 16]],
	Mood.ON_FOOT: [[0, 7, 14], [-3, 4, 11], [5, 9, 16], [2, 9, 14], [-5, 2, 9]],
}
const PENTA := [0, 2, 4, 7, 9]

var bank: Dictionary
var mood: int = Mood.PLANET
var level := 1.0             ## overall music level (ducking, fade-in)
var running := false

var _voices: Array[Dictionary] = []    # {a, b, cur (0/1), target_db}
var _sub: AudioStreamPlayer
var _bells: Array[AudioStreamPlayer] = []
var _chord_t := 0.0
var _chord_len := 18.0
var _chord_i := 0
var _bell_t := 6.0
var _fade := 7.0
var _rng := RandomNumberGenerator.new()
var _pending_mood := -1
var _chord: Array = []
var _sub_target := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()


func start(sound_bank: Dictionary) -> void:
	bank = sound_bank
	for i in 4:
		var v := {"p": [_player("pad"), _player("pad")], "cur": 0, "amp": [0.0, 0.0], "target": [0.0, 0.0]}
		_voices.append(v)
	_sub = _player("sub")
	for i in 3:
		var b := AudioStreamPlayer.new()
		b.bus = "Music"
		b.stream = bank.get("bell")
		add_child(b)
		_bells.append(b)
	running = true
	_chord_i = _rng.randi() % (CHORDS[mood] as Array).size()
	_next_chord(true)


func set_mood(m: int) -> void:
	if m == mood:
		return
	mood = m
	# change soon (not instantly: a mood flip on every state toggle would be restless)
	_chord_t = maxf(_chord_t, _chord_len - 3.0)


func _player(key: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Music"
	p.stream = bank.get(key)
	p.volume_db = -80.0
	add_child(p)
	return p


func _next_chord(first := false) -> void:
	var set_: Array = CHORDS[mood]
	_chord_i = (_chord_i + 1 + (_rng.randi() % 2 if set_.size() > 2 else 0)) % set_.size()
	_chord = set_[_chord_i]
	_chord_len = _rng.randf_range(14.0, 24.0)
	_fade = 1.5 if first else _rng.randf_range(6.0, 8.0)
	_chord_t = 0.0
	var timbre := "pad_air" if mood == Mood.ON_FOOT else "pad"
	for i in _voices.size():
		var v: Dictionary = _voices[i]
		var nxt := 1 - int(v["cur"])
		var p: AudioStreamPlayer = v["p"][nxt]
		var tg: Array = v["target"]
		if i < _chord.size():
			p.stream = bank.get(timbre if i > 0 else "pad")
			p.pitch_scale = pow(2.0, float(_chord[i]) / 12.0)
			# random start offset: voices never phase-align
			p.play(_rng.randf() * 5.0)
			var base := 0.42 if i == 0 else 0.30
			tg[nxt] = base * _rng.randf_range(0.8, 1.1)
		else:
			tg[nxt] = 0.0
		tg[1 - nxt] = 0.0
		v["cur"] = nxt
	# sub drone: chord root an octave down (sample at C2), only out in space
	var root := int(_chord[0])
	_sub.pitch_scale = pow(2.0, float(posmod(root + 12, 12) - (12 if posmod(root + 12, 12) > 6 else 0)) / 12.0)
	_sub_target = 0.32 if mood == Mood.SPACE else 0.12
	if not _sub.playing:
		_sub.play()


func _bell_note() -> void:
	var free_p: AudioStreamPlayer = null
	for b in _bells:
		if not b.playing:
			free_p = b
			break
	if free_p == null:
		return
	var root := int(_chord[0]) if not _chord.is_empty() else 0
	var deg: int = PENTA[_rng.randi() % PENTA.size()]
	var octave := -12 if _rng.randf() < 0.55 else 0
	# bell sample is C5; keep notes between ~C4 and ~E5
	var st := posmod(root, 12) + deg + octave
	free_p.pitch_scale = pow(2.0, float(st) / 12.0)
	free_p.volume_db = linear_to_db(_rng.randf_range(0.10, 0.22) * level)
	free_p.play()


func _process(dt: float) -> void:
	if not running:
		return
	_chord_t += dt
	if _chord_t >= _chord_len:
		_next_chord()
	_bell_t -= dt
	if _bell_t <= 0.0:
		var dense := 1.0 if mood == Mood.SPACE else (0.7 if mood == Mood.PLANET else 0.5)
		_bell_t = _rng.randf_range(5.0, 15.0) / dense
		if _rng.randf() < 0.85:
			_bell_note()
	var k := clampf(dt / maxf(_fade * 0.5, 0.1), 0.0, 1.0)
	for v: Dictionary in _voices:
		for j in 2:
			var p: AudioStreamPlayer = v["p"][j]
			var a: float = lerpf(float(v["amp"][j]), float(v["target"][j]), k)
			v["amp"][j] = a
			# slow per-voice swell keeps the pad breathing
			var sw := 0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.00021 * (1.0 + j * 0.37) + p.get_instance_id() % 7)
			var lin := a * sw * level
			p.volume_db = linear_to_db(maxf(lin, 1e-5))
			if lin < 1e-4 and p.playing and float(v["target"][j]) == 0.0:
				p.stop()
	var sa := db_to_linear(_sub.volume_db)
	sa = lerpf(sa, _sub_target * level, clampf(dt * 0.25, 0.0, 1.0))
	_sub.volume_db = linear_to_db(maxf(sa, 1e-5))
