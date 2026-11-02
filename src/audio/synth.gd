class_name Synth
extends RefCounted
## Procedural sound synthesis: every sound of the game is built in code at start-up as an
## AudioStreamWAV (mono, 16-bit PCM) — no audio files. Pure functions (no scene tree), so the
## whole bank is generated on a worker thread during the loading screen (`build_bank()`).
##
## Building blocks: seamless noise loops (white / pink / brown, cross-faded seam), tonal loops
## whose partials are integer multiples of 1/length (so the loop is seamless), RBJ biquad filters
## (static and swept), envelopes. Levels are normalised to a peak so the mixer gains in
## GameAudio are meaningful (0 dB = full-scale).

const RATE := 32000
const MUSIC_RATE := 22050

enum F { LP, HP, BP }


# =====================================================================================
# Primitives
# =====================================================================================

static func to_wav(x: PackedFloat32Array, rate := RATE, loop := false) -> AudioStreamWAV:
	var n := x.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, clampi(int(x[i] * 32767.0), -32768, 32767))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w


static func zeros(n: int) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	x.fill(0.0)
	return x


static func white(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	for i in n:
		x[i] = rng.randf() * 2.0 - 1.0
	return x


## Paul Kellet's economy pink filter.
static func pink(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	for i in n:
		var w := rng.randf() * 2.0 - 1.0
		b0 = 0.99765 * b0 + w * 0.0990460
		b1 = 0.96300 * b1 + w * 0.2965164
		b2 = 0.57000 * b2 + w * 1.0526913
		x[i] = (b0 + b1 + b2 + w * 0.1848) * 0.2
	return x


## Leaky-integrated white noise (deep rumble).
static func brown(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	var b := 0.0
	for i in n:
		b = (b + 0.02 * (rng.randf() * 2.0 - 1.0)) / 1.02
		x[i] = b * 3.5
	return x


## RBJ biquad, static coefficients.
static func biquad(x: PackedFloat32Array, kind: int, f0: float, q: float, rate := RATE) -> PackedFloat32Array:
	return biquad_sweep(x, kind, f0, f0, q, rate)


## RBJ biquad with the centre frequency gliding exponentially from f_a to f_b (coefficients
## refreshed every 32 samples).
static func biquad_sweep(x: PackedFloat32Array, kind: int, f_a: float, f_b: float, q: float, rate := RATE) -> PackedFloat32Array:
	var n := x.size()
	var y := PackedFloat32Array()
	y.resize(n)
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var b0 := 0.0
	var b1 := 0.0
	var b2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var lr := log(f_b / f_a)
	for i in n:
		if i % 32 == 0:
			var f := f_a * exp(lr * float(i) / float(maxi(n - 1, 1)))
			f = clampf(f, 10.0, rate * 0.45)
			var w0 := TAU * f / rate
			var cw := cos(w0)
			var alpha := sin(w0) / (2.0 * q)
			var a0 := 1.0 + alpha
			match kind:
				F.LP:
					b0 = (1.0 - cw) * 0.5
					b1 = 1.0 - cw
					b2 = b0
				F.HP:
					b0 = (1.0 + cw) * 0.5
					b1 = -(1.0 + cw)
					b2 = b0
				_:
					b0 = alpha
					b1 = 0.0
					b2 = -alpha
			a1 = -2.0 * cw / a0
			a2 = (1.0 - alpha) / a0
			b0 /= a0
			b1 /= a0
			b2 /= a0
		var xi := x[i]
		var yi := b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = xi
		y2 = y1
		y1 = yi
		y[i] = yi
	return y


## Makes a loop of `n` samples out of `n + fade` samples: the tail is cross-faded (equal power)
## into the head, so the seam is inaudible.
static func loopify(x: PackedFloat32Array, fade: int) -> PackedFloat32Array:
	var n := x.size() - fade
	var y := x.slice(0, n)
	for i in fade:
		var t := float(i) / float(fade)
		y[i] = x[i] * sqrt(t) + x[n + i] * sqrt(1.0 - t)
	return y


static func normalize(x: PackedFloat32Array, peak := 0.9) -> PackedFloat32Array:
	# remove DC first (filtered noise drifts), then scale to the peak
	var mean := 0.0
	for v in x:
		mean += v
	mean /= maxf(float(x.size()), 1.0)
	if absf(mean) > 1e-5:
		for i in x.size():
			x[i] -= mean
	var m := 0.0
	for v in x:
		m = maxf(m, absf(v))
	if m > 1e-9:
		var k := peak / m
		for i in x.size():
			x[i] *= k
	return x


static func mix_into(dst: PackedFloat32Array, src: PackedFloat32Array, gain := 1.0, offset := 0) -> void:
	for i in src.size():
		var j := i + offset
		if j >= 0 and j < dst.size():
			dst[j] += src[i] * gain


## Attack / exponential-decay envelope (seconds), applied in place.
static func env_ad(x: PackedFloat32Array, attack: float, decay: float, rate := RATE) -> PackedFloat32Array:
	var na := maxi(int(attack * rate), 1)
	for i in x.size():
		var t := float(i) / rate
		var e := (float(i) / na) if i < na else exp(-(t - attack) / maxf(decay, 1e-4))
		x[i] *= e
	return x


## Fade in / out (seconds) at both ends (removes clicks from one-shots).
static func fade_ends(x: PackedFloat32Array, fin: float, fout: float, rate := RATE) -> PackedFloat32Array:
	var n := x.size()
	var a := maxi(int(fin * rate), 1)
	var b := maxi(int(fout * rate), 1)
	for i in mini(a, n):
		x[i] *= float(i) / a
	for i in mini(b, n):
		x[n - 1 - i] *= float(i) / b
	return x


## Sine with exponential frequency glide and amplitude envelope callable(t) -> amp.
static func glide(dur: float, f_a: float, f_b: float, amp: Callable, rate := RATE, harmonics := 1) -> PackedFloat32Array:
	var n := int(dur * rate)
	var x := PackedFloat32Array()
	x.resize(n)
	var ph := 0.0
	var lr := log(f_b / f_a)
	for i in n:
		var t := float(i) / rate
		var f := f_a * exp(lr * t / dur)
		ph += TAU * f / rate
		var s := 0.0
		for h in harmonics:
			s += sin(ph * (h + 1)) / float(h + 1)
		x[i] = s * float(amp.call(t))
	return x


## Seamless tonal loop: `partials` = [[freq, amp], ...]; frequencies are snapped to integer
## cycles per loop. Optional slow amplitude wobble per partial (breathing timbre).
static func tone_loop(dur: float, partials: Array, wobble := 0.0, rate := RATE) -> PackedFloat32Array:
	var n := int(dur * rate)
	var x := zeros(n)
	var k := 0
	for p: Array in partials:
		var cyc := maxf(roundf(float(p[0]) * dur), 1.0)
		var w := TAU * cyc / n
		var a := float(p[1])
		var ph0 := float(k) * 1.7
		# wobble: 1 or 2 cycles per loop (keeps it seamless)
		var wm := TAU * float(1 + (k % 2)) / n
		for i in n:
			var amp := a * (1.0 + wobble * sin(wm * i + ph0 * 2.3))
			x[i] += sin(w * i + ph0) * amp
		k += 1
	return x


# =====================================================================================
# The sound bank
# =====================================================================================

## Builds every sound. Returns {name: AudioStreamWAV}; footsteps as "step_<surface>_<i>".
static func build_bank() -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var b := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 1977
	var R := RATE
	# --- noise beds (loops)
	b["noise_white"] = to_wav(normalize(loopify(white(R * 2 + 4000, rng), 4000), 0.7), R, true)
	b["noise_pink"] = to_wav(normalize(loopify(pink(R * 2 + 4000, rng), 4000), 0.8), R, true)
	b["noise_brown"] = to_wav(normalize(loopify(biquad(brown(R * 3 + 6000, rng), F.LP, 240.0, 0.7), 6000), 0.85), R, true)
	# --- engine: low harmonic hum (50 Hz base, beating partials), turbine whine
	var hum := []
	for h in range(1, 13):
		hum.append([50.0 * h, 1.0 / pow(h, 1.25) * (1.25 if h % 2 == 1 else 0.8)])
	hum.append([51.0, 0.35])
	hum.append([99.0, 0.25])
	hum.append([151.0, 0.15])
	var hx := tone_loop(1.0, hum, 0.25)
	mix_into(hx, normalize(biquad(loopify(brown(R + 2000, rng), 2000), F.LP, 180.0, 0.7), 0.5))
	b["engine_hum"] = to_wav(normalize(hx, 0.8), R, true)
	b["turbine"] = to_wav(normalize(tone_loop(1.0, [[880.0, 1.0], [1321.0, 0.5], [1763.0, 0.35],
		[2642.0, 0.18], [441.0, 0.3]], 0.3), 0.7), R, true)
	# --- RCS: hiss loop + puff one-shot
	b["rcs_hiss"] = to_wav(normalize(loopify(biquad(white(R + 2000, rng), F.BP, 2600.0, 0.6), 2000), 0.7), R, true)
	var puff := biquad(white(int(0.22 * R), rng), F.BP, 1900.0, 0.8)
	b["rcs_puff"] = to_wav(normalize(env_ad(puff, 0.006, 0.05), 0.85), R)
	# --- re-entry crackle (sparse decaying impulses, low-passed) loop
	var cr := zeros(R * 2 + 3000)
	var i := 0
	while i < cr.size() - 800:
		var amp := rng.randf_range(0.2, 1.0)
		var len_s := rng.randi_range(80, 600)
		for j in len_s:
			cr[i + j] += (rng.randf() * 2.0 - 1.0) * amp * exp(-float(j) / (len_s * 0.25))
		i += rng.randi_range(120, 1400)
	b["crackle"] = to_wav(normalize(loopify(biquad(cr, F.LP, 2400.0, 0.7), 3000), 0.8), R, true)
	# --- warp
	b["warp_spool"] = to_wav(_warp_spool(rng), R)
	b["warp_whoosh"] = to_wav(_warp_whoosh(rng), R)
	b["warp_loop"] = to_wav(normalize(_warp_loop(rng), 0.8), R, true)
	b["warp_drop"] = to_wav(_boom(rng, 2.6, 62.0, 28.0, 0.5), R)
	# --- atmosphere events
	b["sonic_boom"] = to_wav(_sonic_boom(rng), R)
	# --- mechanics
	b["thump"] = to_wav(_thump(rng), R)
	b["clunk"] = to_wav(_clunk(rng, 1.0), R)
	b["gear_motor"] = to_wav(_servo(rng, 2.4, 170.0, 0.3), R)
	b["hatch_servo"] = to_wav(_servo(rng, 2.0, 105.0, 0.8), R)
	b["cockpit_hum"] = to_wav(normalize(_cockpit_hum(rng), 0.6), R, true)
	# --- on foot
	for surf in ["sand", "grass", "rock", "snow"]:
		for k in 4:
			b["step_%s_%d" % [surf, k]] = to_wav(_step(rng, surf), R)
	b["land_foot"] = to_wav(_land_thud(rng), R)
	b["breath"] = to_wav(normalize(_breath(rng), 0.6), R, true)
	# --- UI
	b["ui_click"] = to_wav(_blip(1650.0, 0.05, 0.012, 0.6), R)
	b["ui_hover"] = to_wav(_blip(1180.0, 0.035, 0.008, 0.35), R)
	b["ui_back"] = to_wav(_blip(900.0, 0.06, 0.016, 0.5), R)
	b["hud_mode"] = to_wav(_two_tone(880.0, 1318.5, 0.07), R)
	b["hud_warn"] = to_wav(_two_tone(740.0, 523.3, 0.11), R)
	# --- music material (22.05 kHz)
	b["pad"] = to_wav(normalize(_pad(), 0.8), MUSIC_RATE, true)
	b["pad_air"] = to_wav(normalize(_pad_air(rng), 0.8), MUSIC_RATE, true)
	b["sub"] = to_wav(normalize(tone_loop(4.0, [[65.4, 1.0], [130.8, 0.18], [98.0, 0.12]], 0.15, MUSIC_RATE), 0.8),
		MUSIC_RATE, true)
	b["bell"] = to_wav(_bell(), MUSIC_RATE)
	b["_build_ms"] = Time.get_ticks_msec() - t0
	return b


# =====================================================================================
# Individual sounds
# =====================================================================================

static func _warp_spool(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 2.3
	var R := RATE
	# rising, beating tone stack + noise swell, ends on a "lift"
	var x := glide(dur, 48.0, 210.0, func(t: float) -> float:
		return pow(t / dur, 1.6) * (1.0 - smoothstep(dur - 0.08, dur, t)), R, 6)
	var x2 := glide(dur, 48.7, 213.0, func(t: float) -> float:
		return pow(t / dur, 1.6) * 0.7 * (1.0 - smoothstep(dur - 0.08, dur, t)), R, 3)
	mix_into(x, x2)
	var hi := glide(dur, 600.0, 2400.0, func(t: float) -> float:
		return pow(t / dur, 3.0) * 0.18, R, 2)
	mix_into(x, hi)
	var nz := biquad_sweep(white(int(dur * R), rng), F.BP, 300.0, 3500.0, 1.2)
	for i in nz.size():
		nz[i] *= pow(float(i) / nz.size(), 2.2) * 0.6
	mix_into(x, nz)
	return normalize(fade_ends(x, 0.02, 0.03), 0.85)


static func _warp_whoosh(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 2.4
	var R := RATE
	var n := int(dur * R)
	var nz := biquad_sweep(pink(n, rng), F.BP, 4200.0, 160.0, 0.9)
	for i in n:
		var t := float(i) / R
		nz[i] *= (1.0 - exp(-t / 0.03)) * exp(-t / 0.8)
	var low := glide(dur, 90.0, 32.0, func(t: float) -> float: return exp(-t / 0.6) * minf(t / 0.02, 1.0), R, 2)
	mix_into(nz, low, 1.4)
	return normalize(fade_ends(nz, 0.002, 0.2), 0.9)


static func _warp_loop(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 4.0
	var x := tone_loop(dur, [[40.0, 1.0], [60.0, 0.6], [80.25, 0.5], [120.0, 0.25], [160.5, 0.2],
		[480.0, 0.05], [721.0, 0.04], [962.25, 0.03]], 0.45)
	var nz := loopify(biquad(pink(int(dur * RATE) + 4000, rng), F.LP, 900.0, 0.7), 4000)
	mix_into(x, normalize(nz, 0.35))
	return x


static func _boom(rng: RandomNumberGenerator, dur: float, f_a: float, f_b: float, noise := 0.5) -> PackedFloat32Array:
	var R := RATE
	var x := glide(dur, f_a, f_b, func(t: float) -> float: return exp(-t / (dur * 0.28)) * minf(t / 0.004, 1.0), R, 3)
	var nz := biquad(white(int(dur * R), rng), F.LP, 420.0, 0.8)
	for i in nz.size():
		var t := float(i) / R
		nz[i] *= exp(-t / 0.35) * noise * 2.0
	mix_into(x, nz)
	return normalize(fade_ends(x, 0.002, 0.15), 0.95)


## Two sharp pressure jumps (N-wave) ~0.11 s apart + low rumble tail.
static func _sonic_boom(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var R := RATE
	var n := int(1.8 * R)
	var x := zeros(n)
	for k in 2:
		var o := int((0.02 + 0.11 * k) * R)
		var nw := int(0.012 * R)
		for j in nw * 6:
			var t := float(j) / nw
			var v := (1.0 - t * 0.5) if t < 2.0 else 0.0
			if j < nw * 6 and o + j < n:
				x[o + j] += v * exp(-float(j) / (nw * 3.0)) * (1.0 if k == 0 else -0.85)
	x = biquad(x, F.LP, 1400.0, 0.7)
	var rum := biquad(brown(n, rng), F.LP, 160.0, 0.7)
	for i in n:
		rum[i] *= exp(-float(i) / R / 0.6) * minf(float(i) / (0.05 * R), 1.0)
	mix_into(x, normalize(rum, 0.6))
	return normalize(fade_ends(x, 0.001, 0.2), 0.95)


static func _thump(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var R := RATE
	var x := glide(0.6, 78.0, 38.0, func(t: float) -> float: return exp(-t / 0.12) * minf(t / 0.003, 1.0), R, 2)
	var nz := biquad(white(int(0.6 * R), rng), F.LP, 300.0, 0.7)
	env_ad(nz, 0.002, 0.06)
	mix_into(x, nz, 0.8)
	# suspension creak: resonant metallic tail
	var cr := biquad(white(int(0.6 * R), rng), F.BP, 740.0, 18.0)
	env_ad(cr, 0.02, 0.18)
	mix_into(x, normalize(cr, 0.12), 1.0, int(0.03 * R))
	return normalize(fade_ends(x, 0.001, 0.08), 0.9)


static func _clunk(rng: RandomNumberGenerator, size := 1.0) -> PackedFloat32Array:
	var R := RATE
	var n := int(0.4 * R)
	var x := zeros(n)
	for f: float in [310.0 / size, 870.0 / size, 1530.0 / size]:
		var r := biquad(white(n, rng), F.BP, f, 14.0)
		env_ad(r, 0.001, 0.05 if f > 1000.0 else 0.09)
		mix_into(x, normalize(r, 0.5))
	var hit := white(int(0.01 * R), rng)
	env_ad(hit, 0.0005, 0.003)
	mix_into(x, hit, 0.7)
	var low := glide(0.3, 120.0, 70.0, func(t: float) -> float: return exp(-t / 0.05), R)
	mix_into(x, low, 0.8)
	return normalize(fade_ends(x, 0.0005, 0.05), 0.85)


## Electric servo / hydraulic actuator: whine with slight vibrato and load wobble, soft ends,
## and a lock clunk at the end.
static func _servo(rng: RandomNumberGenerator, dur: float, f0: float, hiss: float) -> PackedFloat32Array:
	var R := RATE
	var n := int(dur * R)
	var x := zeros(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / R
		var ramp := smoothstep(0.0, 0.25, t) * (1.0 - smoothstep(dur - 0.3, dur - 0.05, t))
		var f := f0 * (0.85 + 0.15 * ramp) * (1.0 + 0.012 * sin(t * TAU * 6.0))
		ph += TAU * f / R
		var s := sin(ph) + 0.5 * sin(2.0 * ph) + 0.33 * sin(3.0 * ph) + 0.25 * sin(4.0 * ph) \
			+ 0.2 * sin(5.0 * ph) + 0.12 * sin(7.0 * ph) + 0.08 * sin(9.0 * ph)
		x[i] = s * ramp * 0.35
	var hs := biquad(pink(n, rng), F.BP, 1800.0, 0.9)
	for i in n:
		var t := float(i) / R
		hs[i] *= smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(dur - 0.35, dur - 0.05, t)) * 0.25 * hiss
	mix_into(x, hs)
	var out := zeros(n + int(0.35 * R))
	mix_into(out, x)
	mix_into(out, _clunk(rng, 1.2), 0.9, n - int(0.06 * R))
	return normalize(fade_ends(out, 0.01, 0.05), 0.85)


static func _cockpit_hum(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var dur := 2.0
	var x := tone_loop(dur, [[60.0, 0.5], [120.0, 1.0], [180.0, 0.3], [240.0, 0.2], [400.5, 0.05]], 0.1)
	var air := loopify(biquad(pink(int(dur * RATE) + 3000, rng), F.LP, 1500.0, 0.6), 3000)
	mix_into(x, normalize(air, 0.6))
	return x


static func _step(rng: RandomNumberGenerator, surf: String) -> PackedFloat32Array:
	var R := RATE
	var n := int(0.32 * R)
	var x := zeros(n)
	var var_k := rng.randf_range(0.85, 1.15)
	match surf:
		"sand":
			var a := biquad(white(n, rng), F.LP, 1300.0 * var_k, 0.7)
			env_ad(a, 0.012, 0.07)
			mix_into(x, normalize(a, 0.8))
			var g := _grains(rng, n, 30, 0.004, 3500.0)
			env_ad(g, 0.01, 0.09)
			mix_into(x, g, 0.25)
		"grass":
			var a := biquad(white(n, rng), F.BP, 3800.0 * var_k, 0.7)
			env_ad(a, 0.025, 0.09)
			mix_into(x, normalize(a, 0.6))
			var th := biquad(white(n, rng), F.LP, 260.0, 0.7)
			env_ad(th, 0.004, 0.04)
			mix_into(x, normalize(th, 0.7))
		"rock":
			var th := glide(0.2, 150.0 * var_k, 90.0, func(t: float) -> float: return exp(-t / 0.03), R)
			mix_into(x, th, 0.9)
			var cl := biquad(white(int(0.02 * R), rng), F.HP, 2500.0, 0.7)
			env_ad(cl, 0.0005, 0.006)
			mix_into(x, normalize(cl, 0.7))
			var g := _grains(rng, n, 12, 0.003, 2200.0)
			env_ad(g, 0.005, 0.05)
			mix_into(x, g, 0.4, int(0.01 * R))
		_:   # snow: dense crunch
			var g := _grains(rng, n, 90, 0.006, 2200.0 * var_k)
			for i in n:
				var t := float(i) / R
				g[i] *= smoothstep(0.0, 0.03, t) * exp(-maxf(t - 0.04, 0.0) / 0.06)
			mix_into(x, normalize(g, 0.8))
			var th := biquad(white(n, rng), F.LP, 400.0, 0.7)
			env_ad(th, 0.006, 0.05)
			mix_into(x, normalize(th, 0.4))
	return normalize(fade_ends(x, 0.001, 0.05), 0.85)


## Granular crackle: `count` tiny band-passed clicks spread over n samples.
static func _grains(rng: RandomNumberGenerator, n: int, count: int, grain_s: float, f: float) -> PackedFloat32Array:
	var x := zeros(n)
	var g := int(grain_s * RATE)
	for k in count:
		var o := rng.randi_range(0, maxi(n - g - 1, 0))
		var a := rng.randf_range(0.3, 1.0)
		for j in g:
			x[o + j] += (rng.randf() * 2.0 - 1.0) * a * (1.0 - float(j) / g)
	return biquad(x, F.BP, f, 0.9)


static func _land_thud(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var R := RATE
	var x := glide(0.35, 110.0, 55.0, func(t: float) -> float: return exp(-t / 0.06) * minf(t / 0.003, 1.0), R, 2)
	var nz := biquad(white(int(0.35 * R), rng), F.LP, 900.0, 0.7)
	env_ad(nz, 0.003, 0.05)
	mix_into(x, nz, 0.5)
	return normalize(fade_ends(x, 0.001, 0.05), 0.85)


## Helmet breathing loop (4.8 s): inhale, pause, exhale, pause. Band-passed noise with a
## faint helmet resonance.
static func _breath(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var R := RATE
	var dur := 4.8
	var n := int(dur * R)
	var inh := biquad(pink(n, rng), F.BP, 1100.0, 0.9)
	var exh := biquad(pink(n, rng), F.BP, 650.0, 0.8)
	var x := zeros(n)
	for i in n:
		var t := float(i) / R
		var a_in := smoothstep(0.1, 0.9, t) * (1.0 - smoothstep(1.2, 1.7, t))
		var a_ex := smoothstep(2.2, 2.6, t) * (1.0 - smoothstep(3.0, 4.0, t))
		x[i] = inh[i] * a_in * 0.6 + exh[i] * a_ex
	var res := biquad(x, F.BP, 420.0, 4.0)
	mix_into(x, res, 0.6)
	return x


static func _blip(f: float, dur: float, decay: float, amp: float) -> PackedFloat32Array:
	var x := glide(dur, f, f * 0.92, func(t: float) -> float: return exp(-t / decay) * minf(t / 0.0015, 1.0), RATE, 2)
	return normalize(fade_ends(x, 0.0005, 0.01), amp)


static func _two_tone(f1: float, f2: float, step: float) -> PackedFloat32Array:
	var a := glide(step * 1.6, f1, f1, func(t: float) -> float: return exp(-t / (step * 0.6)) * minf(t / 0.002, 1.0), RATE, 2)
	var b := glide(step * 2.6, f2, f2, func(t: float) -> float: return exp(-t / step) * minf(t / 0.002, 1.0), RATE, 2)
	var x := zeros(int(step * 4.0 * RATE))
	mix_into(x, a)
	mix_into(x, b, 0.8, int(step * RATE))
	return normalize(fade_ends(x, 0.0005, 0.02), 0.5)


## Warm pad note (C3, 6 s seamless loop): harmonic stack, each partial a slightly detuned
## pair/triplet (slow chorus beating), upper partials breathe.
static func _pad() -> PackedFloat32Array:
	var f0 := 130.8128
	var parts := []
	var amps := [1.0, 0.55, 0.32, 0.2, 0.12, 0.07]
	for h in amps.size():
		var f := f0 * (h + 1)
		var a: float = amps[h]
		parts.append([f, a])
		parts.append([f + 0.34 * (h + 1), a * 0.7])
		if h < 3:
			parts.append([f - 0.5 * (h + 1), a * 0.5])
	return tone_loop(6.0, parts, 0.35, MUSIC_RATE)


## Airy pad (choir-ish): pure fifths + octave with band-passed breath noise, 6 s loop.
static func _pad_air(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var f0 := 130.8128
	var x := tone_loop(6.0, [[f0 * 2.0, 0.6], [f0 * 2.0 + 0.5, 0.4], [f0 * 3.0, 0.35], [f0 * 3.0 - 0.33, 0.25],
		[f0 * 4.0, 0.2], [f0, 0.3]], 0.5, MUSIC_RATE)
	var n := x.size()
	var nz := loopify(biquad(white(n + 6000, rng), F.BP, f0 * 4.0, 3.0, MUSIC_RATE), 6000)
	mix_into(x, normalize(nz, 0.25))
	return x


## Soft bell / glass tone (C5, inharmonic partials, 5 s decay).
static func _bell() -> PackedFloat32Array:
	var R := MUSIC_RATE
	var dur := 5.0
	var n := int(dur * R)
	var x := zeros(n)
	var f0 := 523.25
	var parts := [[1.0, 1.0, 2.2], [2.0, 0.35, 1.4], [2.76, 0.25, 1.0], [5.4, 0.08, 0.5], [8.93, 0.03, 0.3]]
	for p: Array in parts:
		var w := TAU * f0 * float(p[0]) / R
		var a := float(p[1])
		var d := float(p[2])
		for i in n:
			var t := float(i) / R
			x[i] += sin(w * i) * a * exp(-t / d) * minf(t / 0.01, 1.0)
	return normalize(fade_ends(x, 0.002, 0.3, R), 0.8)
