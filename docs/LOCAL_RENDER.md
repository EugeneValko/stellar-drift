# Локальный рендер на Windows (реальная видеокарта)

Облачная сессия рендерит на CPU (~25 с/кадр). Сессия Claude Code на ПК пользователя (Remote Control)
рендерит на GPU за доли секунды и может снимать видео и мерить FPS. Обмен — через git.

## Однократная настройка (делает локальная сессия)
1. Godot 4.7.2 stable (Windows, x86_64, standard — не .NET):
   https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip
   Распаковать, например, в `C:\Tools\Godot\`, путь к `Godot_v4.7.2-stable_win64.exe` записать в `tools/.godot_path.txt`
   (файл в .gitignore) или в переменную окружения `GODOT`.
2. (опционально) ffmpeg на PATH — для mp4 (`winget install ffmpeg`).
3. Проверка: `powershell -ExecutionPolicy Bypass -File tools/shot.ps1 scenes/main.tscn docs/screenshots/local/test.png`

## Рабочий цикл
1. `git pull` (или `git fetch origin <branch>` + `git checkout <branch>` для веток агентов).
2. Снять: `tools/shot.ps1 <scene> --shots=<presets> --outdir=docs/screenshots/local/<этап>/` и/или `tools/movie.ps1 ...`.
3. Замер: `tools/fps_bench.ps1 <scene> 20` → записать в `docs/screenshots/local/<этап>/perf.md` (GPU, разрешение, FPS).
4. `git add docs/screenshots/local && git commit -m "Local GPU renders: <что>" && git push`.
   Пушить только в `docs/screenshots/local/` (и perf-заметки) — код не менять, этим занимается облачная сессия.
