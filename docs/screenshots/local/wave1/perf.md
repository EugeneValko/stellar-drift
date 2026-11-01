# Wave 1 — local GPU renders and FPS (main @ fae90a2)

Machine: RTX 3060 (driver 32.0.16.1088), Ryzen 7 5700X, 32 GB, Win11, monitor 1920x1080 @ 143 Hz — see `../machine.md`.
All shots are 1920x1080, `--fullscreen`, default warmup 30 frames (planet_test: `--warmup=300`).

## Shots
| scene | presets | dir | wall time (whole run) |
|---|---|---|---|
| space_test | 7 (space_wide … star_grazing) | `space/` | 9.8 s |
| atmo_test | 10 (orbit … gasgiant_from_moon) | `atmo/` | 13.5 s |
| planet_test | 8 (orbit … glacia_low), warmup 300 | `planet/` | 39.3 s |
| ship_test | 5 (ship_hero … ship_landed) | `ship/` | 8.5 s |

~1–1.5 s per shot including startup (planet: ~5 s per shot because of 300 warmup frames).
The project needed one `godot --headless --import` after the pull (shot.ps1 only imports when `.godot/` is missing).

## FPS (1920x1080 fullscreen, MSAA 2x from project settings)
Measured with `--disable-vsync` to see headroom (vsync on caps at 143 here). `--print-fps` once per second,
first 3 samples dropped; "min" = lowest 1-second average (not 1% low frame time). Static camera.

| scene / camera | avg FPS | min FPS | ms/frame |
|---|---|---|---|
| space_test (default) | 219 | 217 | 4.6 |
| ship_test (default) | 241 | 232 | 4.2 |
| planet_test (default) | 146 | 144 | 6.9 |
| planet_test `--cam=low_flight` | 116 | 115 | 8.6 |
| atmo_test (default = orbit) | 79–80 | 77 | 12.6 |
| atmo_test `--cam=orbit` | 74 | 73 | 13.4 |
| atmo_test `--cam=atmo_entry` | 74 | 70 | 13.5 |
| atmo_test `--cam=in_atmo_day` | 75 | 73 | 13.4 |
| atmo_test `--cam=above_clouds` | 95 | 93 | 10.5 |
| atmo_test `--cam=terminator` | 67 | 66 | 15.0 |
| atmo_test `--cam=sunset_ground` | 63 | 57 | 15.9 |
| atmo_test `--cam=ocean_glint` | **57** | **54** | **17.4** |
| atmo_test `--cam=gasgiant_from_moon` | 96 | 95 | 10.5 |

Notes:
- The very first atmo_test default run gave 61 avg; three reruns gave 79–80. Treat ±5 FPS as noise
  (GPU at 1912 MHz, 70 °C, P2 during runs).
- **atmo_test is the bottleneck**: ground-level views with clouds + ocean are at 57–63 FPS on an RTX 3060.
  The target is 60 FPS on an RTX 2060 class card (≈20–25 % slower than a 3060), so `ocean_glint`, `sunset_ground`
  and `terminator` will be ~45–55 FPS there. Clouds/ocean need a perf budget pass.
- planet_test has no atmosphere/clouds, so 116–146 FPS is terrain only; with atmosphere it will be closer to the atmo numbers.

## Videos (Movie Maker, 30 fps fixed, 8 s, libx264 crf 18)
- `star_orbit.mp4` — space_test `--cam=orbit`, camera orbits the star; 240 frames, 5.4 MB, 144 s to write.
- `terra_orbit.mp4` — atmo_test `--cam=orbit`; this preset is a **static** camera, only clouds drift slowly,
  so the clip is almost a still (0.4 MB). A moving orbit preset in atmo_test would make a better clip.

## GPU vs cloud (CPU/lavapipe) comparison
Every shot was compared side by side with the cloud renders in `docs/screenshots/s1`, `s2/atmo`, `s2/terrain`, `s3/ship`.
**No GPU-only bugs**: no missing objects, no black frames, no wrong colours, no NaN/flicker; geometry, lighting,
tonemapping, glow and lens flares match.

Differences that do exist are all **time-dependent animation**, not rendering errors:
- Clouds (atmo_entry, orbit, in_atmo_day, ocean_glint, sunset_ground, terminator) are in different places;
  the big cyclone in the cloud `atmo_entry`/`orbit` shots is rotated out of view on GPU.
  Cause: `clouds_common.gdshaderinc` rotates/drifts by `TIME` (`a = TIME * cloud_rot_speed`, `cloud_wind_vel * TIME`),
  and TIME is wall-clock: 30 warmup frames take ~0.3 s on GPU but tens of seconds on CPU.
- Sunspots on the star (star_close, star_surface) differ in shape/size for the same reason (star shaders run on time).
- Suggestion (code, for the cloud session): make captures deterministic — e.g. capture.gd sets
  `Engine.time_scale`/a `--time=<s>` override for shader TIME and `star.time_scale`, or always run shots under
  `--fixed-fps` — so cloud and local frames are comparable pixel for pixel.

Visual issues seen in **both** renders (not GPU-specific), for the art pass:
- `atmo/above_clouds`: the near cloud layer has hard vertical "walls" and flat-topped blocky shapes.
- `space/star_surface` (GPU): one sunspot is a hard-edged dark polygon rather than a soft umbra/penumbra.
- `atmo/ocean_glint`: ocean far field is grainy/noisy (high-frequency sparkle aliasing).
- planet_test low views (`low_flight`, `surface`, `glacia_low`): ground texture right in front of the camera
  is smeared/stretched; sky is pure black (scene has no atmosphere — expected).
- planet_test run ends with `WARNING: 1370 ObjectDB instances were leaked at exit` (terrain workers not freed on quit).
