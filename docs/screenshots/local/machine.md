# Local render machine (user's PC)

| | |
|---|---|
| OS | Windows 11 Pro 10.0.26300 |
| GPU | NVIDIA GeForce RTX 3060 (driver 32.0.16.1088) |
| CPU | AMD Ryzen 7 5700X, 8C/16T |
| RAM | 32 GB |
| Monitor | 1920x1080 (work area 1920x1032, taskbar 48 px) |
| Godot | 4.7.2.stable.official.ed1daf0bf, `C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe` |
| ffmpeg | on PATH (`C:\ffmpeg\bin`, build N-124567, 2026-05-21) |

## Timings — `scenes/main.tscn`, 1920x1080, one shot (30 warmup frames)
- First `--import` of the project: 4.0 s.
- First shot (cold shader cache): 7.5 s wall, whole process.
- Repeat shots (warm): 1.7–1.9 s wall, whole process (startup + warmup + save).

## Known issue: `tools/shot.ps1` gives 1920x1061, not 1080
The monitor is exactly 1920x1080, so Godot shrinks a windowed 1920x1080 window to fit the work area
(the taskbar takes 48 px). `--window-borderless` does not help; `--fullscreen` does: it gives 1920x1080.
`test.png` was rendered with:
`Godot --path . --resolution 1920x1080 --fullscreen scenes/main.tscn -- --shot=<abs path>`
Suggested fix (code, for the cloud session): add `--fullscreen` to `shot.ps1` (and `fps_bench.ps1`),
or render to an offscreen SubViewport of the requested size in `capture.gd`.

The `.exe` (non-console) build detaches from PowerShell, so its output is lost; use `_console.exe`
in `tools/.godot_path.txt`.
