extends SceneTree
## Scripted playtest of the real game (scenes/main.tscn), see tools/dev/playtest_runner.gd.
##
##   godot --headless --fixed-fps 60 -s tools/dev/playtest.gd -- [session|soak|extras|all|quick] [soak_sec=180] [seed=1] [from=selene] [pace=1]
##
## The runner references game classes (Ship, GameMode, ...) that use the autoloads; `-s` scripts
## compile before the autoloads exist, so the runner is loaded at runtime from here.

func _initialize() -> void:
	_boot.call_deferred()


func _boot() -> void:
	var runner: Node = (load("res://tools/dev/playtest_runner.gd") as GDScript).new()
	runner.name = "Playtest"
	root.add_child(runner)
