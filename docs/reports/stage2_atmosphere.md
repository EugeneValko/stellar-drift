# Этап 2b — атмосфера, облака, океан, газовый гигант, кольца

Агент: rendering (Stage 2b). Ветка `worktree-agent-a4754233eca952b1c`.
Всё процедурно (код + шейдеры), без внешних ассетов. Тестовая сцена: `scenes/test/atmo_test.tscn`.
Скриншоты: `docs/screenshots/s2/atmo/*.png` (1920x1080).

## 1. Компоненты и файлы

| Компонент | Сцена | Скрипт (`class_name`) | Шейдеры |
|---|---|---|---|
| Атмосфера | `scenes/planets/atmosphere.tscn` | `src/planets/atmosphere/atmosphere_layer.gd` (`AtmosphereLayer`) | `shaders/atmosphere.gdshader` (in-scatter, add), `shaders/atmosphere_transmittance.gdshader` (T, mul), `shaders/include/atmosphere_common.gdshaderinc` |
| Облака | `scenes/planets/clouds.tscn` | `src/planets/atmosphere/cloud_layer.gd` (`CloudLayer`) | `shaders/clouds.gdshader`, `shaders/cloud_weather_bake.gdshader`, `shaders/include/clouds_common.gdshaderinc` |
| Океан | `scenes/planets/ocean.tscn` | `src/planets/atmosphere/ocean_layer.gd` (`OceanLayer`) | `shaders/ocean.gdshader` |
| Газовый гигант | `scenes/planets/gas_giant.tscn` | `src/planets/atmosphere/gas_giant.gd` (`GasGiantBody`) | `shaders/gas_giant.gdshader` |
| Кольца | `scenes/planets/rings.tscn` | `src/planets/atmosphere/ring_system.gd` (`RingSystem`) | `shaders/rings.gdshader`, `shaders/include/rings_common.gdshaderinc` |
| Общие | — | `src/core/sun_globals.gd` (`SunGlobals`), `src/planets/atmosphere/layer_params.gd` (`LayerParams`), `src/planets/atmosphere/cloud_noise.gd` (`CloudNoise`) | `shaders/include/sun_globals.gdshaderinc` |
| Только тест | `scenes/test/atmo_test.tscn` | `scenes/test/atmo_test.gd`, `scenes/test/placeholder_body.gd` (`PlaceholderBody`) | `shaders/debug_placeholder_terrain.gdshader`, `shaders/include/debug_terrain_noise.gdshaderinc`, `shaders/debug_space_bg.gdshader` |

`debug_*` — заглушки для теста (рельеф, небо со звёздами); настоящие рельеф и небо делают другие агенты.

## 2. Солнце: глобальные uniform'ы (изменение `project.godot`)

Добавлена секция `[shader_globals]` (единственное изменение общего файла):

| Имя | Тип | Смысл |
|---|---|---|
| `sun_direction` | vec3 | мировое направление **на** солнце (единичное) |
| `sun_color` | color | цвет света звезды без ослабления атмосферой (линейный) |
| `sun_intensity` | float | яркость; белая ламбертова поверхность лицом к солнцу = `sun_color*sun_intensity` (как `light_energy` у `DirectionalLight3D`) |

API: `SunGlobals.set_sun(dir, color, intensity)`, `SunGlobals.sync_from_light(light)` (направление = `+Z` света),
`SunGlobals.aim_light(light, dir)`. Вызывать при изменении положения звезды относительно игрока (раз в кадр — дёшево).
В шейдерах: `#include "res://shaders/include/sun_globals.gdshaderinc"`.

Соглашение по освещению: шейдеры этого этапа сами ослабляют солнце атмосферой попиксельно
(`atmo_sun_transmittance`), поэтому `DirectionalLight3D` должен нести **неослабленный** цвет, если рельеф тоже
делает попиксельное ослабление (как заглушка). Если рельеф использует стандартный свет Godot — можно тонировать
свет на CPU: `atmo.sun_transmittance(cam_pos_local, sun_dir)` (Vector3 RGB) у камеры (корабль, ближний рельеф).

## 3. Как подключить к планете (`setup(params)`)

Все компоненты — `Node3D`, добавляются **дочерними к узлу планеты** (в центре планеты, без масштаба; поворот планеты
учитывается — облака/волны вращаются вместе с ней). `setup()` принимает `Dictionary` или любой `Resource`/`Object`
с одноимёнными свойствами (`LayerParams.get_param/to_dict`), так что `PlanetConfig` можно передавать напрямую,
если имена совпадают, или собрать словарь:

```gdscript
var atmo: AtmosphereLayer = preload("res://scenes/planets/atmosphere.tscn").instantiate()
planet.add_child(atmo)
atmo.setup({"preset": "terra_nova", "radius": cfg.radius, "quality": 1})

var ocean: OceanLayer = preload("res://scenes/planets/ocean.tscn").instantiate()
planet.add_child(ocean)
ocean.setup({"radius": cfg.radius + cfg.sea_level, "atmosphere": atmo, "quality": 1})

var clouds: CloudLayer = preload("res://scenes/planets/clouds.tscn").instantiate()
planet.add_child(clouds)
clouds.setup({"radius": cfg.radius, "bottom": 1800.0, "top": 4300.0, "coverage": 0.4,
	"brightness": 2.2, "atmosphere": atmo, "ocean_radius": cfg.radius + cfg.sea_level, "quality": 1})
ocean.set_clouds(clouds)                         # тени облаков на воде
clouds.apply_shadow_uniforms(terrain_material)   # тени облаков на рельефе (см. §6)

var gg: GasGiantBody = preload("res://scenes/planets/gas_giant.tscn").instantiate()
system.add_child(gg)
gg.setup({"radius": 300000.0, "rings": true, "ring_tilt_deg": 16.0, "quality": 1})
```

### AtmosphereLayer — параметры
`preset` (`terra_nova` | `ignis` | `glacia` | `aurelion`), `radius`, `height` (верх над радиусом), `ground_radius`
(жёсткая сфера-ограничитель луча: уровень моря / минимальный рельеф; 0 — выкл.), `rayleigh_height`, `mie_height`,
`rayleigh_density` (множитель к земной оптической толщине, нормирован на высоту шкалы), `rayleigh_tint`,
`mie_density`, `mie_color`, `mie_absorb`, `mie_g`, `ozone_density`, `intensity` (π = физично), `multi_scatter`,
`sun_path_scale` (художественное удлинение «закатных» путей света, по умолчанию 2.2), `quality` 0/1/2 → 8/12/16
шагов или явно `steps`, `render_priority_base`.
CPU-хелперы: `sun_transmittance(p_local, l)`, `sky_radiance(p_local, dir, l, col, inten)`, `make_uniforms(params)`
(готовые `atmo_*` uniform'ы для любых шейдеров с `atmosphere_common.gdshaderinc`), `uniforms`.

Пресеты: Terra Nova — голубое небо (H_R 2.6 км, верх 24 км); Ignis — тонкая пыльная оранжево-красная (Mie-пыль
поглощает синий); Glacia — бирюзовая/циан (тинт Рэлея); Aurelion — тёплая дымка газового гиганта.

### CloudLayer — параметры
`radius`, `bottom`/`top` (высоты слоя, м), `coverage` 0..1, `density` (экстинкция 1/м), `seed`, `cyclones`,
`cyclone_strength`, `shape_size`/`detail_size` (м на тайл шума), `rot_speed` (дрейф погоды, рад/с),
`wind_vel` (Vector3 м/с — эволюция форм), `brightness`, `ambient`, `albedo`, `atmosphere`, `ocean_radius`,
`shadow_strength`, `quality` 0/1/2 → макс. шагов 32/56/96, шагов к солнцу 3/4/5, `weather_resolution` (2048),
`render_priority_base`. Методы: `rebake()` (пересчитать карту погоды), `get_shadow_uniforms()`,
`apply_shadow_uniforms(mat)`, `set_quality(q)`.

### OceanLayer — параметры
`radius` (уровень моря), `atmosphere`, `clouds`, `scatter_color`, `shallow_tint`, `absorption` (1/м по каналам),
`turbidity`, `wave_length`, `wave_min`, `steepness`, `base_roughness`, `time_scale`, `foam_depth`, `foam_amount`,
`refraction`, `sun_spec`, `quality` 0/1/2 → волн 12/20/28, шагов неба в отражении 4/5/6. `set_atmosphere()`,
`set_clouds()`.

### GasGiantBody / RingSystem
GG: `radius`, `seed`, `band_scale`, `turbulence`, `flow_speed`, `brightness`, цвета `col_zone/col_belt/col_mid/
col_polar/col_accent/storm_color`, `storm_dir` (локальный вектор), `storm_size` (Vector2, рад), `quality`
(октавы 5/6/8), `atmosphere` (true/false/Dictionary для AtmosphereLayer), `rings` (true/false/Dictionary для
RingSystem), `ring_tilt_deg`, `ring_shadow`.
Rings: `planet_radius`, `inner`, `outer`, `opacity`, `seed`, `brightness`, `forward_scatter`, `color_a/b/c`, `segments`.

## 4. Как это работает

**Общая техника слоёв (атмосфера, облака, океан)**: прокси-сфера чуть больше аналитической, рисуются **задние грани**
(`cull_front`) с `depth_test_disabled` → покрывает диск планеты снаружи и весь экран изнутри; в фрагменте луч
пересекается аналитически (устойчивая форма ray/sphere через точку наибольшего сближения — точность float32 на
масштабах до ~1e6 м), расстояние до непрозрачной сцены берётся из depth texture (reverse-Z) → луч останавливается
на рельефе. Все вычисления — в системе «центр планеты, относительно камеры» (`CAMERA_POSITION_WORLD -
NODE_POSITION_WORLD`), совместимо с floating origin.

**Атмосфера**: однократное рассеяние Рэлей + Ми (Cornette-Shanks) + озоноподобное поглощение, оптическая толщина
к солнцу — аналитическая аппроксимация функции Чепмена (с тождеством для лучей ниже горизонта) → нет вложенного
марша, 1 exp-пара на шаг. Дешёвый изотропный член многократного рассеяния. Два прохода: `blend_mul` (хроматическое
пропускание — краснеет солнечный диск и дальние горы) + `blend_add` (in-scatter). Квадратичное распределение
шагов изнутри атмосферы (больше выборок у камеры → aerial perspective). Мягкая тень планеты в объёме (полоса
терминатора, «пояс Венеры»). `sun_path_scale` удлиняет только скользящие пути света — компенсирует сжатую систему
(R=60 км), чтобы закаты были красными без «молочного» дневного неба.

**Облака**: погода (покрытие + тип/высота облаков) — fbm + domain warp + широтная циркуляция (ITCZ, сухие
субтропики, штормовые средние широты) + 5–7 циклонов (закрутка домена с кориолисовым знаком, «глаз»), один раз
запекается на GPU в equirect-текстуру 2048x1024 RGBA16F (SubViewport); выборка бикубическая (иначе bilinear-изломы
вытягиваются по вертикали в «шторы»). Форма — 3D-шум (Perlin fbm + инвертированный Worley, 128³/64³ из
`FastNoiseLite`), плоское основание, куполообразные верхушки, эрозия деталями. Свет: 3–5 шагов к солнцу,
многооктавная аппроксимация многократного рассеяния, двухлепестковый HG (серебряная кайма / просвет),
powder-эффект, небесный ambient сверху и отражённый снизу, цвет солнца из атмосферы (розовые/оранжевые закаты),
aerial perspective между камерой и облаком. Анимация: дрейф погоды вокруг оси + ветер форм (через `TIME`).
Тени облаков — функция `cloud_shadow_m()` в include.

**Океан**: аналитическая сфера на уровне моря (идеальная кривизна на любой дистанции, без LOD-меша).
Нормали — сумма 3D-плоских волн на целочисленной решётке (поле тайлится с периодом 4096 м → якорь у камеры без
скачков и без потери точности) + 2 октавы 3D-шума «ряби»; волны, меньшие пикселя, переходят в шероховатость
(дисперсия наклонов) + Toksvig-поправка по производным нормали → корректный размер блика с орбиты и без
мерцания вблизи. Френель с отражением неба из модели атмосферы, GGX-блик солнца (цвет солнца через атмосферу →
оранжевая дорожка на закате), тело воды, мелководье по depth texture (поглощение по каналам: бирюза над песком,
преломление из screen texture), пена у берега (Worley), тени облаков.

**Газовый гигант**: полосы = сумма синусоид широты, возмущённая анизотропным (растянутым по долготе)
domain-warped simplex-fbm; адвекция чередующимися зональными струями с двухфазным смешиванием (сдвиг не
накапливается); большой овальный вихрь (закрутка домена + цвет/воротник) и цепочка белых овалов; мягкий терминатор
с покраснением, потемнение к краю, тень колец на планете, «кольцесвет» на ночной стороне; ободок/дымка — отдельный
`AtmosphereLayer` (пресет `aurelion`).
**Кольца**: плоское кольцо (annulus), радиальный профиль (C/B/A-кольца, щель Кассини, щель Энке, тонкое F),
полосовые ringlets 4 масштабов с band-limiting по `fwidth` (нет муара), цветовые полосы, оптическая толщина
зависит от угла зрения, освещённая сторона vs. просвет (forward scattering при взгляде на солнце сквозь кольца),
мягкая тень планеты.

## 5. Производительность и ручки качества

Цель — 60 FPS на RTX 2060 в 1080p. Оценка по шагам (GPU не доступен — только CPU-lavapipe, где 1080p кадр со всем
включённым ~5–10 с, это не показатель):

| Слой | Стоимость на пиксель | Ручки |
|---|---|---|
| Атмосфера | 2 прохода × 8/12/16 шагов, ~2 exp + sqrt на шаг, без вложенного марша | `quality`, `steps` |
| Облака | до 32/56/96 шагов (адаптивно: `len/80 м`, ранний выход при T<0.01, пропуск пустых областей по погоде), к солнцу 3/4/5 шагов (1 tap погоды) | `quality`, `steps`, `light_steps`, `cloud_max_distance`, `cloud_detail_distance` |
| Океан | 12/20/28 волн + 2 октавы шума + небо 4/5/6 шагов | `quality`, `waves`, `sky_steps` |
| ГГ | fbm 5/6/8 октав × 2 фазы потока (непрозрачный) | `quality` |
| Кольца | дешёво (1D шумы) | — |

Рекомендации: на средних настройках (`quality=1`) ожидаемо ~1–3 мс атмосфера+океан и 3–6 мс облака в самом
тяжёлом ракурсе (весь экран в облаках). Если облака дороже бюджета: `quality=0`, уменьшить `cloud_max_distance`,
включить TAA/FSR2 и `cloud_temporal_jitter=true` (шум шагов усредняется по кадрам); следующий шаг — рендер облаков
в половинном разрешении через `CompositorEffect` (не сделано).

## 6. Интеграция с рельефом (для агента terrain)
- Aerial perspective и туман на дальних горах **уже работают автоматически** (атмосфера читает depth).
- Цвет солнца на поверхности: в шейдере рельефа `#include "res://shaders/include/atmosphere_common.gdshaderinc"`,
  выставить uniform'ы `atmo.uniforms` (`LayerParams.apply_uniforms(mat, atmo.uniforms)`), умножать прямой свет на
  `atmo_sun_transmittance(p_rel, sun_direction)`; ambient — `atmo_sky_ambient(p_rel)`. Пример — `light()` в
  `shaders/debug_placeholder_terrain.gdshader`.
- Тени облаков: `#include "res://shaders/include/clouds_common.gdshaderinc"`,
  `clouds.apply_shadow_uniforms(mat)`, множитель `cloud_shadow_m(mat3(MODEL_MATRIX), p_rel, sun_direction)`.

## 7. Тестовая сцена и пресеты
`tools/shot.sh scenes/test/atmo_test.tscn --shots=orbit,terminator,atmo_entry,above_clouds,in_atmo_day,sunset_ground,ocean_glint,gasgiant,rings,gasgiant_from_moon --outdir=docs/screenshots/s2/atmo`

Отладочные аргументы: `--atmo_preset=ignis|glacia`, `--no_clouds`, `--no_atmo`, `--cu_<uniform>=v` (облака),
`--ou_` (океан), `--au_` (атмосфера), `--tu_` (рельеф), `--ou_ocean_debug=1..4`, `--cu_cloud_debug=1` (карта
погоды), `--orbit_yaw`, `--term_alt`, `--term_ang`, `--tonemap=N`, `--near`, `--far`.

Пресеты ГГ используют «floating origin» вручную: для `gasgiant_from_moon` система сдвинута так, что луна в начале
координат (точность float32 у камеры).

## 8. Известные проблемы и ограничения
- **near/far камеры**: при `near=0.5, far=2e7` Godot 4.7 сыплет `create_frustum_points` (rendering_light_culler) и
  ломает отсечение — объекты пропадают. Использовать отношение far/near ≲ 4e6 (в тесте near=1, far=4e6).
  Для дальних тел — импосторы/scaled space (см. ARCHITECTURE).
- Порядок прозрачных слоёв задаётся `render_priority` (океан −10, атмосфера −9/−8, облака −7, кольца −6).
  Если две планеты с атмосферами перекрываются на экране, порядок может быть неверным — менеджер планет должен
  сдвигать `render_priority_base` по дальности.
- Облака не пишут глубину: прочие прозрачные объекты (частицы, стекло кабины) за облаком рисуются поверх него.
- Под водой (камера ниже уровня моря) океан не рисуется (нужен отдельный эффект).
- Облака не отражаются в океане (только небо); от орбиты блик океана есть, но маскируется облаками.
- Карта погоды статична (вращается целиком); эволюция — `rebake()` раз в N секунд (стоит ~1 кадр на GPU).
- `TIME` в Godot сбрасывается раз в час (`time_rollover_secs`) — скачок фазы волн/дрейфа облаков.
- Облака с орбиты местами выглядят «попкорном» (много одинаковых кучевых); нужно больше слоистых полей/цирруса.
- Шум шагов облаков (статический джиттер) заметен как «зерно» вблизи; лечится TAA + `cloud_temporal_jitter`.
- Масштаб: при R=60 км и реалистичной высоте шкалы атмосфера тонкая; выбраны H_R=2.6 км, верх 24 км, облака
  1.8–4.3 км (горы рельефа могут протыкать облака — так и задумано).
- Тест-рельеф и звёздное небо — заглушки (полярная сетка вокруг камеры, не для геймплея).
