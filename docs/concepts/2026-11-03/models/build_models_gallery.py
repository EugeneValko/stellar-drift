#!/usr/bin/env python3
"""Build an offline source/result catalog from the adjacent jobs.json.

This script reads images and GLBs but never changes them or the job manifest.
Run again whenever jobs.json, validation, previews or downloads change.
No third-party packages needed.
"""
from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import quote, urlparse


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "jobs.json"


def read_validation() -> dict:
    path = ROOT / "validation.json"
    if not path.is_file():
        return {}
    try:
        report = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Validation report unavailable: {error}")
        return {}
    if not isinstance(report, dict) or not isinstance(report.get("jobs"), list):
        return {}
    return report


def checked_lods() -> dict[str, list[dict]]:
    """Publish only the individually accepted exports, including partial batches."""
    report_path = ROOT / "lod_report.json"
    if not report_path.is_file():
        return {}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return {}
    result = {}
    for asset in report.get("assets", []):
        if not isinstance(asset, dict):
            continue
        available = []
        for lod in asset.get("lods", []):
            if lod.get("valid") is not True:
                continue
            checks = lod.get("checks")
            if not isinstance(checks, dict) or not checks or any(value is not True for value in checks.values()):
                continue
            visual_qa = lod.get("visual_qa", {})
            if visual_qa.get("status") != "accepted_distant_only":
                continue
            validation = lod.get("validation", {})
            if validation.get("status") not in {"structurally_checked_visual_review_required", "PASS", "passed"}:
                continue
            if validation.get("errors"):
                continue
            derived = lod.get("derived_mesh_validation", {})
            if derived.get("errors"):
                continue
            level = lod.get("level")
            if level not in {1, 2}:
                continue
            relative = f"lods/{asset.get('id')}_LOD{level}.glb"
            href, exists = local_path(relative)
            exported = lod.get("exported_glb", {})
            path = ROOT / relative
            if not exists or not isinstance(exported.get("path"), str):
                continue
            if Path(exported["path"]).resolve() != path.resolve():
                continue
            if exported.get("file_bytes") != path.stat().st_size:
                continue
            available.append({"level": level, "href": href, "note": "Только для дальнего плана"})
        result[asset.get("id")] = available
    return result


def checked_metrics(job: dict, checked: dict | None) -> dict:
    """Use a matching audited file, never estimates or requested export settings."""
    if not checked or not job["local_available"]:
        return {}
    audit = checked.get("audit")
    if not isinstance(audit, dict) or not isinstance(audit.get("path"), str):
        return {}
    local_file = (ROOT / job["local_file"]).resolve()
    if Path(audit["path"]).resolve() != local_file:
        return {}
    if audit.get("file_bytes") != local_file.stat().st_size:
        return {}
    metrics = {}
    triangle_count = audit.get("scene", {}).get("triangles")
    if isinstance(triangle_count, int) and triangle_count >= 0:
        metrics["triangles"] = triangle_count
    material_count = audit.get("materials", {}).get("count")
    if isinstance(material_count, int) and material_count >= 0:
        metrics["materials"] = material_count
    texture_max_edge = audit.get("textures", {}).get("max_edge")
    if isinstance(texture_max_edge, int) and texture_max_edge > 0:
        metrics["texture_max_edge"] = texture_max_edge
    return metrics


def local_path(value: str | None, *, image: bool = False) -> tuple[str | None, bool]:
    if not value or not isinstance(value, str):
        return None, False
    target = (ROOT / value).resolve()
    allowed_root = ROOT.parent if image else ROOT
    try:
        relative = target.relative_to(allowed_root)
    except ValueError:
        return None, False
    del relative
    # Sources may live in the neighboring imagegen folder; downloads stay in models.
    href = quote(value.replace("\\", "/"), safe="/")
    return href, target.is_file()


def build() -> None:
    if not MANIFEST.is_file():
        raise SystemExit(f"Missing manifest: {MANIFEST}")
    data = json.loads(MANIFEST.read_text(encoding="utf-8-sig"))
    if not isinstance(data.get("jobs"), list):
        raise SystemExit("jobs.json must contain a jobs array")
    validation = read_validation()
    checked_jobs = {job.get("id"): job for job in validation.get("jobs", []) if isinstance(job, dict)}
    lod_files = checked_lods()
    data["validation_available"] = bool(validation)
    data["validation_generated_utc"] = validation.get("generated_utc")
    ids: set[str] = set()
    for job in data["jobs"]:
        if job.get("id") in ids:
            raise SystemExit(f"Duplicate job ID: {job.get('id')}")
        ids.add(job.get("id"))
        job["input_href"], job["input_available"] = local_path(job.get("input"), image=True)
        job["local_href"], job["local_available"] = local_path(job.get("local_file"))
        render_href, render_available = local_path(f"previews/{job['id']}.png")
        job["preview_href"] = render_href if render_available else job["input_href"]
        job["preview_available"] = render_available or job["input_available"]
        job["preview_kind"] = "Рендер GLB" if render_available else "Исходное изображение"
        job["rear_href"] = None
        if job.get("id") in {"CH01", "CH02"}:
            rear_href, rear_available = local_path(f"previews/{job['id']}-rear.png")
            if rear_available:
                job["rear_href"] = rear_href
        job["lods"] = lod_files.get(job.get("id"), [])
        job["metrics"] = checked_metrics(job, checked_jobs.get(job.get("id")))
        url = job.get("url")
        if not isinstance(url, str) or urlparse(url).scheme not in {"https", "http"}:
            job["url"] = None
        if job.get("id") in {"CH01", "CH02"}:
            job["source_note"] = "T-поза · без рюкзака · рюкзак отдельным объектом"
        elif job.get("id") in {"BP01", "BP02"}:
            job["source_note"] = "Отдельный модуль жизнеобеспечения"
        else:
            job["source_note"] = "Один объект на исходном изображении"
    payload = json.dumps(data, ensure_ascii=False, indent=2).replace("</", "<\\/")
    (ROOT / "index.html").write_text(PAGE.replace("__JOBS__", payload), encoding="utf-8")
    (ROOT / "README.txt").write_text(README, encoding="utf-8")
    available = sum(bool(job["local_available"]) for job in data["jobs"])
    renders = sum(job["preview_kind"] == "Рендер GLB" for job in data["jobs"])
    lods = sum(len(job["lods"]) for job in data["jobs"])
    inspected = sum(bool(job["metrics"]) for job in data["jobs"])
    print(f"Model catalog rebuilt: {len(data['jobs'])} jobs; {available} GLBs; {renders} renders; "
          f"{lods} LOD files; {inspected} audited files -> {ROOT / 'index.html'}")


PAGE = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Stellar Drift — пробные 3D-модели</title>
<style>
:root{--bg:#11151a;--panel:#1b222a;--edge:#333e49;--text:#eeeae1;--muted:#a6b1bc;--accent:#e6a976;--green:#a0ccb1;--blue:#9bc8e9;--red:#e9a4a4}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}a{color:inherit}button{font:inherit;cursor:pointer}a:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:4px}.shell{max-width:1560px;padding:30px 30px 60px;margin:auto}.back{color:var(--muted);font-size:12px;text-decoration:none}.back:hover{color:var(--text)}.eyebrow{color:var(--accent);font-size:11px;font-weight:600;letter-spacing:.15em;text-transform:uppercase;margin:25px 0 10px}h1{font-size:clamp(29px,3.8vw,48px);font-weight:550;letter-spacing:-.035em;line-height:1.15;margin:0}.intro{color:var(--muted);font-size:15px;max-width:780px;margin:16px 0}.meta{display:flex;gap:8px;flex-wrap:wrap;margin:19px 0 24px}.pill{font-size:12px;color:var(--muted);padding:5px 10px;border:1px solid var(--edge);border-radius:20px}.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:26px}.stat{padding:14px 17px;border:1px solid var(--edge);border-radius:8px;background:var(--panel);font-size:12px;color:var(--muted)}.stat strong{display:block;color:var(--text);font-size:27px;font-weight:500;line-height:1.3}.filters{display:flex;flex-wrap:wrap;gap:7px;position:sticky;top:0;padding:14px 0;background:rgba(17,21,26,.96);backdrop-filter:blur(12px);z-index:2;border-bottom:1px solid var(--edge);margin-bottom:28px}.filter{padding:7px 13px;border:1px solid transparent;background:none;color:var(--muted);border-radius:20px;font-size:13px}.filter:hover{background:#252e37;color:var(--text)}.filter[aria-pressed=true]{background:var(--text);color:var(--bg)}.filter span{font-size:11px;opacity:.65;margin-left:7px}.section{margin-bottom:34px}.sectionhead{display:flex;align-items:baseline;justify-content:space-between;gap:20px;margin-bottom:14px}.section h2{font-size:22px;font-weight:500;letter-spacing:-.02em;margin:0}.sectiondesc{color:var(--muted);font-size:12px}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px}.card{border:1px solid var(--edge);border-radius:10px;overflow:hidden;background:var(--panel)}.preview{display:block;position:relative;width:100%;aspect-ratio:16/10;background:#111519;padding:10px;text-decoration:none}.preview img{display:block;object-fit:contain;width:100%;height:100%}.previewbadge{position:absolute;left:16px;top:14px;font-size:10px;letter-spacing:.04em;background:#161b24de;color:#d5dce3;padding:3px 7px;border:1px solid #46505c;border-radius:4px}.missing{height:100%;display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:12px}.info{padding:15px 17px 17px}.row{display:flex;align-items:center;justify-content:space-between;gap:10px}.id{font:11px ui-monospace,Consolas,monospace;color:var(--accent);letter-spacing:.06em}.status{font-size:10px;padding:3px 7px;border-radius:4px;border:1px solid #49525f;color:var(--muted)}.status.generating{color:var(--accent);border-color:#71573c}.status.completed{color:var(--green);border-color:#476553}.status.downloaded{color:var(--blue);border-color:#405f78}.status.failed{color:var(--red);border-color:#775050}.info h3{font-size:18px;font-weight:550;margin:10px 0 8px;line-height:1.35}.source-note{font-size:12px;color:var(--muted);min-height:36px;margin:0 0 14px}.links{display:flex;gap:8px;flex-wrap:wrap;padding-top:12px;border-top:1px solid var(--edge)}.link{font-size:12px;text-decoration:none;padding:7px 10px;border:1px solid #586574;border-radius:6px;display:inline-block}.link:hover{border-color:var(--text);color:#fff}.link.glb{border-color:#69859b;color:#c0dcf0}.link.unavailable{border-color:#35404b;color:#737f8a}.qa{padding:12px 0 0;color:var(--muted);font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere}.qa:empty{display:none}.foot{border-top:1px solid var(--edge);padding-top:18px;display:flex;gap:20px;justify-content:space-between;color:var(--muted);font-size:12px}.foot a{text-decoration:none}.foot a:hover{color:var(--text)}.empty{padding:60px 0;text-align:center;color:var(--muted)}
.model-label{font-size:11px;color:var(--green);margin-bottom:7px}.metrics{display:flex;flex-wrap:wrap;gap:10px 20px;margin:0 0 16px;padding:10px 0;border-top:1px solid var(--edge)}.metrics div{min-width:70px}.metrics dt{font-size:10px;color:var(--muted)}.metrics dd{font-size:13px;font-weight:550;margin:2px 0 0;font-variant-numeric:tabular-nums}
.rig-demo{display:grid;grid-template-columns:minmax(0,540px) minmax(240px,1fr);gap:24px;align-items:center;padding:18px;margin:0 0 24px;border:1px solid var(--edge);border-radius:10px;background:var(--panel)}.rig-demo video{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#0c1014;border-radius:6px}.rig-demo h2{font-size:23px;font-weight:550;letter-spacing:-.02em;margin:7px 0 10px}.rig-demo p{max-width:550px;color:var(--muted);font-size:13px;margin:0 0 17px}.rig-demo .links{border:0;padding:0}.rig-demo .id{color:var(--green)}
@media(max-width:800px){.rig-demo{grid-template-columns:1fr;gap:16px}.rig-demo video{max-height:350px}.rig-demo h2{font-size:21px}}
@media(max-width:1100px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:680px){.shell{padding:22px 16px 40px}.grid{grid-template-columns:1fr}.stats{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.stat{padding:12px}.sectionhead{display:block}.sectiondesc{margin-top:5px}.filters{margin-bottom:24px}.filter{font-size:12px;padding:7px 10px}.foot{flex-direction:column;gap:7px}.source-note{min-height:0}}
</style>
</head>
<body>
<main class="shell">
  <a href="../index.html" class="back">← Галерея концептов</a>
  <div class="eyebrow">Stellar Drift / Пробная 3D-генерация</div>
  <h1>Оптимизированные пробные модели</h1>
  <p class="intro">Базовые модели — статические эскизы. Для CH01 ниже представлена отдельная проба рига и анимации. Превью «Рендер GLB» показывают сохранённые модели; исходные референсы доступны отдельно.</p>
  <div class="meta" id="meta"></div>
  <div class="stats" id="stats"></div>
  <section class="rig-demo" aria-labelledby="rig-demo-title">
    <video controls playsinline preload="none" poster="rigged/CH01/poster.png" src="rigged/CH01/CH01_walk_wave.mp4" aria-label="CH01: ходьба, остановка и приветствие"><a href="rigged/CH01/CH01_walk_wave.mp4">Открыть демонстрацию MP4</a></video>
    <div>
      <span class="id">CH01 / Анимационная проба</span>
      <h2 id="rig-demo-title">Ходьба и приветствие</h2>
      <p>Четыре цикла ходьбы, плавная остановка и взмах рукой. Отдельный редактируемый риг и клипы Walk_Cycle, Wave и Demo.</p>
      <div class="links">
        <a class="link" href="rigged/CH01/CH01_rig_animations.blend" download>Blender · риг и анимации ↓</a>
        <a class="link glb" href="rigged/CH01/CH01_rigged_animated.glb" download>Анимированный GLB ↓</a>
        <a class="link" href="rigged/CH01/README.txt" target="_blank" rel="noopener">Описание и проверка</a>
      </div>
    </div>
  </section>
  <nav class="filters" id="filters" aria-label="Категории моделей"></nav>
  <div id="sections"></div>
  <footer class="foot"><span>Опубликованные LOD — только для дальнего плана. Статусы и ссылки обновляются при пересборке.</span><span><a href="README.txt">Как пользоваться</a> · <a href="jobs.json">Задания и результаты</a></span></footer>
</main>
<script id="jobs-data" type="application/json">__JOBS__</script>
<script>
'use strict';
const data=JSON.parse(document.getElementById('jobs-data').textContent),jobs=data.jobs;
const groups={characters:{title:'Персонажи',note:'Люди в T-позе без рюкзаков; инопланетянин отдельно.'},backpacks:{title:'Рюкзаки',note:'Самостоятельные модули жизнеобеспечения.'},ships:{title:'Корабли',note:'Проба объемной формы по выбранным изображениям.'},tools:{title:'Инструменты',note:'Каждый прибор — отдельный объект.'}};
const statuses={queued:'В очереди',generating:'Генерируется',completed:'Готово в Tripo',downloaded:'GLB сохранен',failed:'Ошибка'};
const el=id=>document.getElementById(id);
let selected='all';
function node(tag,attrs={},text){const n=document.createElement(tag);for(const[k,v]of Object.entries(attrs)){if(k==='class')n.className=v;else n.setAttribute(k,v);}if(text!==undefined)n.textContent=text;return n;}
function link(href,text,extra={}){return node('a',{href,class:'link',...extra},text);}
function renderMeta(){const meta=el('meta'),exportTextures=[...new Set(jobs.map(j=>j.export_texture).filter(Boolean))].sort();let texture=data.texture;if(/^8\s*K$/i.test(texture||''))texture=exportTextures.length?'Экспорт: '+exportTextures.join(' / '):null;const totalCredits=data.totalcredits_spent??data.credits_spent,spent=totalCredits?totalCredits+' кредитов всего':data.credits_per_job?data.credits_per_job+' кредитов / генерация':null;for(const text of [data.provider,data.model,texture,spent,data.date])if(text)meta.append(node('span',{class:'pill'},text));const stats=[['Заданий',jobs.length],['Генерируется',jobs.filter(j=>j.status==='generating').length],['Готово в Tripo',jobs.filter(j=>['completed','downloaded'].includes(j.status)).length],['GLB сохранены',jobs.filter(j=>j.local_available).length]];for(const[label,count]of stats){const s=node('div',{class:'stat'});s.append(node('strong',{},String(count)),document.createTextNode(label));el('stats').append(s);}}
function renderFilters(){const nav=el('filters');nav.replaceChildren();const options={all:'Все',...Object.fromEntries(Object.entries(groups).map(([key,value])=>[key,value.title]))};for(const[key,title]of Object.entries(options)){const count=key==='all'?jobs.length:jobs.filter(j=>j.category===key).length;const b=node('button',{class:'filter','aria-pressed':String(selected===key)},title);b.append(node('span',{},String(count)));b.addEventListener('click',()=>{selected=key;renderFilters();renderSections();});nav.append(b);}}
function card(job){
  const c=node('article',{class:'card'});let preview;
  if(job.preview_available){preview=node('a',{class:'preview',href:job.preview_href,target:'_blank',rel:'noopener','aria-label':'Открыть '+job.preview_kind+': '+job.title});preview.append(node('img',{src:job.preview_href,alt:job.preview_kind+' '+job.id+' — '+job.title,loading:'lazy',decoding:'async'}));}
  else{preview=node('div',{class:'preview'});preview.append(node('div',{class:'missing'},'Превью пока недоступно'));}
  preview.append(node('span',{class:'previewbadge'},job.preview_kind));c.append(preview);
  const info=node('div',{class:'info'}),row=node('div',{class:'row'});
  row.append(node('span',{class:'id'},job.id||'—'),node('span',{class:'status '+(Object.hasOwn(statuses,job.status)?job.status:'queued')},statuses[job.status]||'Статус не указан'));
  info.append(row,node('h3',{},job.title||job.id));
  if(job.optimization?.status==='completed'&&job.local_available)info.append(node('div',{class:'model-label'},'Оптимизированная пробная модель'));
  info.append(node('p',{class:'source-note'},job.source_note));
  const metrics=job.metrics||{},facts=[];
  if(Number.isInteger(metrics.triangles))facts.push(['Треугольники',metrics.triangles.toLocaleString('ru-RU')]);
  if(Number.isInteger(metrics.materials))facts.push(['Материалы',String(metrics.materials)]);
  if(Number.isInteger(metrics.texture_max_edge))facts.push(['Макс. сторона текстуры',metrics.texture_max_edge.toLocaleString('ru-RU')+' px']);
  if(facts.length){const list=node('dl',{class:'metrics'});for(const[label,value]of facts){const item=node('div');item.append(node('dt',{},label),node('dd',{},value));list.append(item);}info.append(list);}
  const links=node('div',{class:'links'});
  if(job.url)links.append(link(job.url,'Открыть в Tripo ↗',{target:'_blank',rel:'noopener'}));
  if(job.local_available)links.append(link(job.local_href,'Скачать GLB ↓',{class:'link glb',download:''}));else links.append(node('span',{class:'link unavailable','aria-disabled':'true'},'GLB пока не сохранен'));
  if(job.input_available)links.append(link(job.input_href,'Исходный референс',{target:'_blank',rel:'noopener'}));else links.append(node('span',{class:'link unavailable','aria-disabled':'true'},'Исходный референс недоступен'));
  if(job.rear_href)links.append(link(job.rear_href,'Вид сзади',{target:'_blank',rel:'noopener'}));
  for(const lod of job.lods||[])links.append(link(lod.href,'LOD '+lod.level+' GLB ↓',{class:'link glb',download:'',title:lod.note}));
  info.append(links);let qa='';if(typeof job.qa==='string')qa=job.qa;else if(job.qa)qa=JSON.stringify(job.qa,null,2);if(qa)info.append(node('div',{class:'qa'},qa));c.append(info);return c;
}
function renderSections(){const target=el('sections');target.replaceChildren();let count=0;for(const[key,group]of Object.entries(groups)){if(selected!=='all'&&selected!==key)continue;const entries=jobs.filter(j=>j.category===key);if(!entries.length)continue;count+=entries.length;const section=node('section',{class:'section'}),head=node('div',{class:'sectionhead'}),grid=node('div',{class:'grid'});head.append(node('h2',{},group.title),node('span',{class:'sectiondesc'},group.note));grid.append(...entries.map(card));section.append(head,grid);target.append(section);}const unknown=selected==='all'?jobs.filter(j=>!Object.hasOwn(groups,j.category)):[];if(unknown.length){count+=unknown.length;const section=node('section',{class:'section'}),grid=node('div',{class:'grid'});section.append(node('h2',{},'Другие задания'));grid.append(...unknown.map(card));section.append(grid);target.append(section);}if(!count)target.append(node('p',{class:'empty'},'В этой категории пока нет заданий.'));}
renderMeta();renderFilters();renderSections();
</script>
</body>
</html>
'''


README = """STELLAR DRIFT — ПРОБНЫЕ 3D-МОДЕЛИ

Откройте index.html прямо с диска или через локальный HTTP-сервер.
Каталог не использует CDN, внешние библиотеки, fetch или локальный 3D-просмотрщик.

Если существует previews/ID.png, карточка показывает его с меткой «Рендер GLB».
Иначе используется исходное изображение с соответствующей меткой.
Клик по превью открывает изображение. «Исходный референс» доступен отдельно.
Для CH01 и CH02 ссылка «Вид сзади» появляется при наличии previews/ID-rear.png.
«Открыть в Tripo» ведет к заданию. «Скачать GLB» появляется после сохранения
файла в локальную папку models.
Рюкзаки выделены в отдельный раздел. Люди подготовлены в T-позе без рюкзаков.

Параметры на карточках читаются только из audit в validation.json: число
треугольников активной сцены, число материалов и максимальная сторона текстуры
в пикселях. Путь и размер проверенного файла должны совпадать с текущим GLB.
Запрошенный бюджет полигонов и разрешение экспорта не выдаются за измерения.
Если проверка еще не выполнена, численные параметры не показываются.

Ссылки на lods/ID_LOD1.glb и lods/ID_LOD2.glb показываются по каждой модели
отдельно: valid должен быть true, visual_qa.status — accepted_distant_only,
все флаги checks — true, а структурные проверки не должны содержать ошибок.
Пакет с отклоненными
вариантами не блокирует прошедшие проверку файлы. Наличие, путь и размер
каждого GLB также проверяются при сборке каталога.
Принятые LOD предназначены только для дальнего плана. Переключение в игре
еще не настроено; структурная и визуальная проверки не заменяют испытание в движке.

Итоговые затраты берутся из totalcredits_spent или credits_spent в jobs.json
и включают ретопологию, если она учтена в этой сумме.

Задания, настройки генерации, статусы, ссылки и замечания находятся в jobs.json.
Статусы: queued, generating, completed, downloaded, failed.
local_file — путь к GLB относительно этой папки, например downloads/CH01.glb.
Не указывайте в manifest пароли, API-ключи или временные подписанные download URL.

После изменения jobs.json, validation.json, lod_report.json, превью или GLB
пересоберите каталог:
python build_models_gallery.py

Скрипт обновляет только index.html и этот README.txt. Он читает локальные
manifest и отчеты, проверяет наличие исходников и результатов, а затем
встраивает снимок данных в HTML. Изображения, модели и отчеты не изменяются.

Генерации пока эскизы. Игровой импорт еще не проводился.
Риг/анимация и физический масштаб ещё не настроены.
"""


if __name__ == "__main__":
    build()
