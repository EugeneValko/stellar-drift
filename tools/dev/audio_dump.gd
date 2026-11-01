extends SceneTree
## Dumps the procedural sound bank (Synth.build_bank) as WAV files for offline inspection
## (levels, spectrograms): godot --headless -s tools/dev/audio_dump.gd -- out=/tmp/sd_audio


func _init() -> void:
	var out := "user://audio_dump"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="):
			out = a.substr(4)
	DirAccess.make_dir_recursive_absolute(out)
	var t0 := Time.get_ticks_msec()
	var bank := Synth.build_bank()
	print("[audio_dump] bank built in %d ms" % (Time.get_ticks_msec() - t0))
	for k: String in bank:
		var w: Variant = bank[k]
		if w is AudioStreamWAV:
			var path := out.path_join(k + ".wav")
			(w as AudioStreamWAV).save_to_wav(path)
			print("[audio_dump] %s  %.2f s" % [k, (w as AudioStreamWAV).get_length()])
	quit()
