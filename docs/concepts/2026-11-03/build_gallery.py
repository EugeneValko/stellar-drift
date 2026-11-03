#!/usr/bin/env python3
"""Rebuild the offline concept gallery using the original images beside this file.

Run with any Python 3: python build_gallery.py
Only index.html, concepts.json and brief.txt are written. Image files are never changed.
"""
from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DATE = "2026-11-03"
LABELS = {
    "families": "Семейства",
    "clean": "Чистые формы",
    "shuttles": "Шаттлы",
    "stations": "Станции",
    "aliens": "Чужие",
    "characters": "Персонажи",
    "gear": "Снаряжение",
}


def describe(path: Path) -> dict:
    name = path.stem.lower()
    provider = path.parent.name
    item = {
        "filename": path.relative_to(ROOT).as_posix(),
        "id": path.stem,
        "category": "shuttles",
        "title": path.stem.replace("-", " ").replace("_", " "),
        "source": "Tripo Studio" if provider == "tripo" else "OpenAI image_gen",
        "model": "Не указана",
        "notes": "Поисковый эскиз; дизайн и пропорции не утверждены.",
        "tags": [],
    }
    registry = [
        ("01-kestrel", "H01", "shuttles", "Kestrel · экспедиционный шаттл", "Компактный исследователь с грузовым отсеком и защищенным днищем.", []),
        ("02-mule", "H02", "shuttles", "Mule · сборщик и спасатель", "Двухкорпусный рабочий шаттл с центральной грузовой кассетой.", []),
        ("03-petrel", "H03", "shuttles", "Petrel · дальняя разведка", "Вытянутый исследовательский корпус, лаборатория и походное оборудование.", []),
        ("04-palisade", "S01", "stations", "Palisade · поврежденный ковчег", "Последний человеческий дом: жилые модули, ангар и аварийный сектор.", []),
        ("05_human", "C01", "characters", "Люди · экипаж выживших", "Пилот-исследователь, ремонтный инженер и специалист по спасательным работам.", []),
        ("06_alien", "C02", "characters", "Lacuna · разумные операторы", "Два варианта нечеловеческой анатомии и функционального оснащения.", ["aliens"]),
        ("07_field", "E01", "gear", "Полевой комплект · исследование и ремонт", "Сканер, наручный модуль, наземный прибор, мультитул и ресурсный маяк.", []),
        ("08-lacuna", "A03", "aliens", "Lacuna · перехватчик пространства", "Объемная вариация с открытым центром, массивными рукавами и полевыми ламелями.", ["aliens"]),
        ("09-vela-clean", "H06", "shuttles", "Vela · компактный цельный клин", "Гладкие крупные поверхности и минималистичный силуэт компактного экспедиционного шаттла.", ["clean"]),
        ("10-swift-clean", "H07", "shuttles", "Swift · вытянутый шаттл", "Гладкий минималистичный корпус, вытянутые пропорции и ясная основная форма.", ["clean"]),
        ("11-manta-clean", "H08", "shuttles", "Manta · широкий несущий корпус", "Угловатый баланс крупных панелей и функциональных деталей в широкой низкой компоновке.", ["clean"]),
        ("12-human-clean", "C03", "characters", "Люди · чистая форма", "Крупные цельные элементы скафандра, ясная функция и минимум навесного оборудования.", ["clean"]),
        ("13-alien-clean", "C04", "characters", "Lacuna · чистый силуэт", "Узнаваемая нечеловеческая анатомия, крупные формы и сдержанные функциональные детали.", ["clean", "aliens"]),
        ("14-tools-clean", "E02", "gear", "Полевой комплект · чистые формы", "Понятные исследовательские инструменты, спокойные корпуса и продуманная эргономика.", ["clean"]),
        ("h04-axiom", "H04", "shuttles", "Axiom · человеческий шаттл", "Дополнительные варианты человеческой экспедиционной техники.", []),
        ("h05-cocoon", "H05", "shuttles", "Cocoon · защищенный посадочник", "Компактная компоновка и раскрывающиеся защитные панели.", []),
        ("a01-lacuna", "A01", "aliens", "Lacuna · корабль чужих", "Поиск силуэта, пространственной структуры и материалов чужой технологии.", ["aliens"]),
        ("a02-lamina", "A02", "aliens", "Lamina · корабль чужих", "Альтернативное направление пластинчатой чужой архитектуры.", ["aliens"]),
        ("s02-broken-bridge", "S02", "stations", "Broken Bridge · человеческий ковчег", "Поврежденная корабль-станция: крупный силуэт и обитаемые рабочие сектора.", []),
        ("s03-lacuna-citadel", "S03", "stations", "Lacuna Citadel · станция чужих", "Орбитальная структура, построенная по нечеловеческой пространственной логике.", ["aliens"]),
    ]
    for prefix, concept_id, category, title, notes, tags in registry:
        if name.startswith(prefix):
            item.update(id=concept_id, category=category, title=title, notes=notes, tags=tags)
            break
    if provider == "tripo":
        variants = {
            "h04-": "GPT Image 2.5 · 4K",
            "h05-": "GPT Image 2.5 · 4K",
            "a01-": "Nano Banana Pro · 4K",
            "a02-": "Midjourney v8.2",
            "s02-": "Nano Banana Pro · native",
            "s03-": "Nano Banana Pro · native",
        }
        item["model"] = next((model for prefix, model in variants.items() if name.startswith(prefix)), "Не указана")
        variant = re.search(r"-(\d{2})$", name)
        if variant:
            item["id"] += "-" + variant.group(1)
    else:
        item["model"] = "image_gen · точная модель не указана"
        version = re.search(r"[-_]v(\d+)$", name)
        if version:
            item["id"] += " · v" + version.group(1)
            if item["category"] == "gear":
                item["notes"] += " Уточненная эргономика ручного сканера."
    return item


def collect_families() -> list[dict]:
    """Read one catalog entry per board; the four ships remain on that board."""
    items = []
    for metadata in ("humans.json", "aliens.json"):
        manifest = ROOT / "families" / metadata
        if not manifest.is_file():
            continue
        rows = json.loads(manifest.read_text(encoding="utf-8-sig"))
        if not isinstance(rows, list):
            raise ValueError(f"{manifest}: expected a list of family boards")
        for row in rows:
            roles = row.get("roles4", row.get("roles"))
            if not isinstance(roles, list) or len(roles) != 4:
                raise ValueError(f"{manifest}: {row.get('id')} needs four ordered roles")
            side = row["side"]
            if side not in {"human", "alien"}:
                raise ValueError(f"{manifest}: unsupported side {side!r}")
            path = ROOT / "families" / row["file"]
            if not path.is_file():
                raise FileNotFoundError(path)
            item = {
                "filename": path.relative_to(ROOT).as_posix(),
                "id": row["id"],
                "category": "shuttles" if side == "human" else "aliens",
                "title": row["title_ru"],
                "source": row["source"],
                "model": "image_gen · точная модель не указана" if row["model"] == "not exposed" else row["model"],
                "notes": row["style_ru"],
                "tags": ["families", "clean"],
                "side": side,
                "school": row["school"],
                "roles4": roles,
                "positions": ["TL", "TR", "BL", "BR"],
                "status": "Поисковая школа, не канон; корабли на листе показаны не в общем масштабе.",
            }
            if side == "alien":
                item["tags"].append("aliens")
            prompt = ROOT / "families" / row.get("prompt_file", path.stem + ".prompt.txt")
            if prompt.is_file():
                item["prompt_file"] = prompt.relative_to(ROOT).as_posix()
            items.append(item)
    return sorted(items, key=lambda item: (item["side"] != "human", item["id"]))


def collect() -> list[dict]:
    """Select the newest numbered variant while preserving all original files."""
    newest: dict[str, tuple[int, Path]] = {}
    for folder in ("imagegen", "tripo"):
        for path in sorted((ROOT / folder).glob("*")):
            if path.suffix.lower() not in {".png", ".jpg", ".jpeg", ".webp"}:
                continue
            match = re.match(r"^(.*?)[-_]v(\d+)$", path.stem, re.I)
            base, version = (match.group(1), int(match.group(2))) if match else (path.stem, 1)
            key = folder + "/" + base.lower()
            if key not in newest or version > newest[key][0]:
                newest[key] = version, path
    items = [describe(path) for _, path in newest.values()]
    order = {key: index for index, key in enumerate(LABELS)}
    items.sort(key=lambda item: (0 if "clean" in item["tags"] else 1, order.get(item["category"], 99), item["id"], item["filename"]))
    return collect_families() + items


PAGE = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Stellar Drift — концепты</title>
<style>
:root{--bg:#101318;--panel:#191e25;--edge:#303845;--text:#f0eee8;--muted:#a3adba;--accent:#e8a46b;--max:1680px}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 "Segoe UI",system-ui,sans-serif}button,a{font:inherit}button{cursor:pointer}button,a{touch-action:manipulation}button:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:4px}button{color:inherit}a{color:inherit}.shell{max-width:var(--max);margin:auto;padding:40px 32px 100px}.eyebrow{color:var(--accent);font-size:11px;font-weight:650;letter-spacing:.19em;text-transform:uppercase}.heading{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;margin-top:12px}h1{margin:0;font-size:clamp(30px,4vw,56px);font-weight:550;letter-spacing:-.045em;line-height:1.1}.intro{color:var(--muted);max-width:720px;margin:18px 0 0;font-size:16px}.stats{color:var(--muted);text-align:right;font-size:12px;white-space:nowrap}.stats strong{display:block;color:var(--text);font-size:28px;font-weight:450;line-height:1.2}.navwrap{position:sticky;top:0;z-index:2;background:rgba(16,19,24,.95);backdrop-filter:blur(16px);border-bottom:1px solid var(--edge);margin:30px 0 26px;padding:16px 0;display:flex;gap:16px;align-items:center;justify-content:space-between}.filters{display:flex;gap:7px;flex-wrap:wrap}.filter{border:1px solid transparent;border-radius:24px;background:transparent;padding:8px 13px;color:var(--muted);white-space:nowrap}.filter:hover{background:#232a34;color:var(--text)}.filter[aria-pressed=true]{background:#e3ded3;color:#171a1d}.count{font-size:11px;opacity:.65;margin-left:7px}.hint{font-size:11px;color:var(--muted);text-align:right;max-width:220px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px}.card{background:var(--panel);border:1px solid var(--edge);border-radius:12px;overflow:hidden;transition:border-color .18s,transform .18s}.card:hover{border-color:#687482}.card.selected{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}.picture{display:block;width:100%;aspect-ratio:16/10;border:0;padding:12px;background:#0d1014;overflow:hidden}.picture img{width:100%;height:100%;object-fit:contain;display:block;transition:transform .25s}.picture:hover img{transform:scale(1.012)}.cardinfo{padding:17px 20px 18px}.cardtop{display:flex;gap:14px;justify-content:space-between;align-items:center}.conceptid{font:11px/1.3 ui-monospace,Consolas,monospace;letter-spacing:.06em;color:var(--accent)}.source{font-size:11px;color:var(--muted)}.card h2{font-size:18px;font-weight:550;margin:8px 0 6px;line-height:1.35}.note{font-size:13px;color:var(--muted);margin:0;min-height:38px}.cardbottom{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:14px;border-top:1px solid var(--edge);padding-top:12px}.model{font-size:11px;color:var(--muted)}.select{font-size:12px;display:flex;align-items:center;gap:7px;white-space:nowrap;cursor:pointer}.select input{accent-color:var(--accent);width:15px;height:15px;margin:0}.empty{padding:80px 0;color:var(--muted);text-align:center;grid-column:1/-1}.foot{margin-top:36px;padding-top:18px;border-top:1px solid var(--edge);display:flex;gap:18px;justify-content:space-between;color:var(--muted);font-size:12px}.foot a{text-decoration:none;border-bottom:1px solid #657080}.comparebar{position:fixed;z-index:4;bottom:20px;left:50%;transform:translateX(-50%);width:min(680px,calc(100% - 32px));padding:12px 16px;border:1px solid #655343;border-radius:12px;background:#20252d;box-shadow:0 12px 60px #0009;display:flex;align-items:center;gap:14px}.comparebar[hidden]{display:none}.comparebar .selectiontext{flex:1;font-size:12px}.action{border:1px solid #647080;background:transparent;border-radius:7px;padding:8px 12px;font-size:12px}.primary{background:#e3ded3;border-color:#e3ded3;color:#171a1d}.action:disabled{opacity:.35;cursor:default}.tiny{color:var(--muted);font-size:12px;background:none;border:none;padding:6px}.lightbox{padding:0;max-width:none;max-height:none;width:calc(100vw - 32px);height:calc(100vh - 32px);margin:auto;border:1px solid #47525f;border-radius:12px;background:#101318;color:var(--text);overflow:hidden}.lightbox::backdrop{background:#000d;backdrop-filter:blur(8px)}.lightboxinner{height:100%;display:flex;flex-direction:column}.lbhead{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:15px 20px;border-bottom:1px solid var(--edge);flex-shrink:0}.lbtitle{font-size:15px;font-weight:550;margin:0}.lbsub{color:var(--muted);font-size:11px;margin-top:3px}.lbcontrols{display:flex;align-items:center;gap:9px;white-space:nowrap}.original{font-size:12px;color:var(--muted);text-decoration:none;margin-right:12px}.original:hover{color:var(--text)}.iconbutton{background:#222a34;border:1px solid #3b4654;border-radius:6px;font-size:22px;width:38px;height:36px;line-height:1}.lbmedia{flex:1;min-height:0;display:flex;align-items:stretch;justify-content:center;padding:16px;gap:16px}.lbmedia figure{margin:0;min-width:0;flex:1;display:flex;flex-direction:column;justify-content:center}.lbmedia img{display:block;min-height:0;flex:1;width:100%;object-fit:contain}.lbmedia figcaption{font-size:12px;color:var(--muted);padding:10px 0 0;text-align:center}.lbmedia figcaption a{margin-left:12px;color:var(--text)}.lbnote{padding:10px 20px 16px;color:var(--muted);font-size:12px;flex-shrink:0}.lbmedia.comparing{background:#0b0e12}.live{position:absolute;overflow:hidden;clip-path:inset(50%);width:1px;height:1px}
.direction{display:inline-block;margin:12px 0 0;padding:3px 7px;border:1px solid #66513e;border-radius:4px;color:var(--accent);font-size:10px;letter-spacing:.05em}.direction+.cardtitle{margin-top:7px}
.familyroles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px 14px;margin:14px 0 0;padding:12px 0 0;border-top:1px solid var(--edge);list-style:none;font-size:12px;color:var(--muted)}.familyroles strong{display:inline-block;color:var(--accent);font:10px/1.3 ui-monospace,Consolas,monospace;margin-right:6px}.familystatus{margin:11px 0 0;font-size:11px;color:var(--muted)}
@media(min-width:1400px){.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:800px){.shell{padding:26px 16px 110px}.heading{align-items:flex-start}.stats{padding-top:4px}.intro{font-size:14px}.navwrap{margin-top:24px;padding:12px 0;display:block}.hint{display:none}.filter{padding:7px 11px;font-size:13px}.grid{grid-template-columns:1fr;gap:20px}.cardinfo{padding:14px 16px}.card h2{font-size:17px}.note{min-height:0}.foot{flex-direction:column;gap:8px}.lightbox{width:100vw;height:100dvh;border-radius:0;border:0}.lbhead{padding:12px;gap:8px}.lbtitle{font-size:13px}.lbsub{font-size:10px}.lbcontrols{gap:5px}.original{display:none}.iconbutton{width:32px;height:32px}.lbmedia{padding:8px;gap:8px}.lbmedia.comparing{flex-direction:column}.lbmedia.comparing figure{min-height:0}.lbnote{padding:8px 12px;font-size:11px}.comparebar{gap:9px}.comparebar .selectiontext{font-size:11px}.comparebar .action{padding:8px;font-size:11px}}
@media(prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}
</style>
</head>
<body>
<main class="shell">
  <div class="eyebrow">Stellar Drift / Art exploration / 03.11.2026</div>
  <div class="heading"><h1>Силуэты нового мира</h1><div class="stats"><strong id="total">0</strong>листов и концептов</div></div>
  <p class="intro">Шесть школ, четыре класса в каждой. Чистые силуэты, крупные функциональные формы и свой характер у каждого семейства. Поисковые варианты, не канон.</p>
  <div class="navwrap"><nav class="filters" aria-label="Категории концептов" id="filters"></nav><div class="hint">Нажмите на изображение, чтобы рассмотреть.<br>Отметьте два эскиза для сравнения.</div></div>
  <section class="grid" id="grid" aria-label="Концепты"></section>
  <footer class="foot"><span>Поисковые изображения. Конструкции, пропорции и детали могут меняться.</span><span><a href="models/index.html">3D-пробы</a> · <a href="brief.txt">Короткий бриф</a> · <a href="concepts.json">Каталог</a></span></footer>
</main>
<div class="comparebar" id="comparebar" hidden><span class="selectiontext" id="selectiontext"></span><button class="tiny" id="clear">Сбросить</button><button class="action primary" id="compare" disabled>Сравнить два</button></div>
<dialog class="lightbox" id="lightbox" aria-labelledby="lbtitle"><div class="lightboxinner"><header class="lbhead"><div><h2 class="lbtitle" id="lbtitle"></h2><div class="lbsub" id="lbsub"></div></div><div class="lbcontrols"><a class="original" id="original" target="_blank" rel="noopener">Оригинал ↗</a><button class="iconbutton" id="prev" aria-label="Предыдущий концепт">‹</button><button class="iconbutton" id="next" aria-label="Следующий концепт">›</button><button class="iconbutton" id="close" aria-label="Закрыть">×</button></div></header><div class="lbmedia" id="lbmedia"></div><div class="lbnote" id="lbnote"></div></div></dialog>
<div class="live" role="status" aria-live="polite" id="status"></div>
<script id="concept-data" type="application/json">__DATA__</script>
<script>
'use strict';
const DATA=JSON.parse(document.getElementById('concept-data').textContent),items=DATA.items;
const labels={families:'Семейства',clean:'Чистые формы',all:'Все',shuttles:'Шаттлы',stations:'Станции',aliens:'Чужие',characters:'Персонажи',gear:'Снаряжение'};
const byId=id=>document.getElementById(id),grid=byId('grid'),dialog=byId('lightbox');
let category=items.some(item=>(item.tags||[]).includes('families'))?'families':items.filter(item=>(item.tags||[]).includes('clean')).length>=3?'clean':'all',visible=[],selected=[],current=-1,mode='single';
function node(tag,attrs={},text){const el=document.createElement(tag);for(const[k,v]of Object.entries(attrs)){if(k==='class')el.className=v;else el.setAttribute(k,v);}if(text!==undefined)el.textContent=text;return el;}
function matches(item,filter){return filter==='all'||item.category===filter||(item.tags||[]).includes(filter);}
function imagePath(item){return item.filename.split('/').map(encodeURIComponent).join('/');}
function announce(text){byId('status').textContent=text;}
function renderFilters(){const nav=byId('filters');nav.replaceChildren();for(const[key,label]of Object.entries(labels)){const count=items.filter(item=>matches(item,key)).length;if(key==='families'&&!count)continue;const b=node('button',{class:'filter','aria-pressed':String(category===key)},label);b.append(node('span',{class:'count'},String(count)));b.addEventListener('click',()=>{category=key;renderFilters();renderGrid();});nav.append(b);}}
function familyRoles(item){return(item.roles4||[]).map((role,i)=>item.positions[i]+' · '+role).join('; ');}
function renderGrid(){
  visible=items.map((item,index)=>({item,index})).filter(({item})=>matches(item,category)).map(x=>x.index);
  grid.replaceChildren();
  for(const index of visible){
    const item=items[index],card=node('article',{class:'card'+(selected.includes(index)?' selected':'')});
    const open=node('button',{class:'picture','aria-label':'Рассмотреть: '+item.title});
    open.append(node('img',{src:imagePath(item),alt:item.title+' — '+item.notes,loading:'lazy',decoding:'async'}));
    open.addEventListener('click',()=>showSingle(index));
    const info=node('div',{class:'cardinfo'}),top=node('div',{class:'cardtop'});
    top.append(node('span',{class:'conceptid'},item.id),node('span',{class:'source'},item.source));
    info.append(top);
    if((item.tags||[]).includes('families'))info.append(node('span',{class:'direction'},'Семейство '+(item.side==='human'?'людей':'чужих')+' · '+item.school));
    else if((item.tags||[]).includes('clean'))info.append(node('span',{class:'direction'},'Актуальное направление · Чистые формы'));
    info.append(node('h2',{class:'cardtitle'},item.title),node('p',{class:'note'},item.notes));
    if(item.roles4){const roles=node('ul',{class:'familyroles','aria-label':'Классы кораблей: сверху слева, сверху справа, снизу слева, снизу справа'});item.roles4.forEach((role,i)=>{const li=node('li'),position=node('strong',{},item.positions[i]);li.append(position,document.createTextNode(role));roles.append(li);});info.append(roles,node('p',{class:'familystatus'},item.status));}
    const bottom=node('div',{class:'cardbottom'}),label=node('label',{class:'select'}),check=node('input',{type:'checkbox','aria-label':'Выбрать для сравнения: '+item.id});
    check.checked=selected.includes(index);check.addEventListener('change',()=>toggleSelection(index));
    label.append(check,document.createTextNode('Сравнить'));bottom.append(node('span',{class:'model'},item.model),label);
    info.append(bottom);card.append(open,info);grid.append(card);
  }
  if(!visible.length)grid.append(node('p',{class:'empty'},'В этой категории пока нет изображений.'));
  byId('total').textContent=String(visible.length);
}
function toggleSelection(index){if(selected.includes(index))selected=selected.filter(x=>x!==index);else{if(selected.length===2)selected.shift();selected.push(index);}updateSelection();renderGrid();}
function updateSelection(){byId('comparebar').hidden=selected.length===0;byId('compare').disabled=selected.length!==2;byId('selectiontext').textContent=selected.map(index=>items[index].id).join('  +  ')+(selected.length===1?' · выберите второй эскиз':'');announce('Выбрано для сравнения: '+selected.length);}
function figure(item,caption){const f=node('figure'),img=node('img',{src:imagePath(item),alt:item.title});f.append(img);if(caption){const c=node('figcaption',{},item.id+' · '+item.title),a=node('a',{href:imagePath(item),target:'_blank',rel:'noopener'},'Оригинал ↗');c.append(a);f.append(c);}return f;}
function openDialog(){if(!dialog.open)dialog.showModal();document.body.style.overflow='hidden';}
function showSingle(index){mode='single';current=index;const item=items[index];byId('lbtitle').textContent=item.id+' · '+item.title;const pos=visible.indexOf(index);byId('lbsub').textContent=item.source+' / '+item.model+' · '+(pos+1)+' из '+visible.length;byId('original').hidden=false;byId('original').href=imagePath(item);byId('prev').hidden=byId('next').hidden=visible.length<2;byId('lbmedia').className='lbmedia';byId('lbmedia').replaceChildren(figure(item,false));byId('lbnote').textContent=item.notes+(item.roles4?' · '+familyRoles(item)+' · '+item.status:'')+'  ·  ← → следующий эскиз · Esc закрыть';openDialog();}
function move(delta){if(mode!=='single'||visible.length<2)return;const pos=visible.indexOf(current);showSingle(visible[(pos+delta+visible.length)%visible.length]);}
function showComparison(){if(selected.length!==2)return;mode='compare';byId('lbtitle').textContent='Сравнение концептов';byId('lbsub').textContent='Силуэт · функция · материалы · человеческий масштаб';byId('original').hidden=byId('prev').hidden=byId('next').hidden=true;byId('lbmedia').className='lbmedia comparing';byId('lbmedia').replaceChildren(...selected.map(index=>figure(items[index],true)));byId('lbnote').textContent='Эскизы показаны целиком. Их масштаб в кадре может различаться. Esc — закрыть.';openDialog();}
byId('clear').addEventListener('click',()=>{selected=[];updateSelection();renderGrid();});byId('compare').addEventListener('click',showComparison);byId('prev').addEventListener('click',()=>move(-1));byId('next').addEventListener('click',()=>move(1));byId('close').addEventListener('click',()=>dialog.close());dialog.addEventListener('close',()=>{document.body.style.overflow='';});dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close();});dialog.addEventListener('keydown',event=>{if(event.key==='ArrowLeft'){event.preventDefault();move(-1);}if(event.key==='ArrowRight'){event.preventDefault();move(1);}});renderFilters();renderGrid();
</script>
</body>
</html>
'''


BRIEF = """STELLAR DRIFT — АРТ-РАЗВЕДКА
03 ноября 2026

Эскизы, не канон. Это изображения для выбора художественного направления,
а не готовые игровые модели или утвержденные инженерные чертежи.
__COUNTS__

Уточнение художественного направления
Уточнение пользователя: нужны чистые современные формы, четкий силуэт,
крупные спокойные поверхности и минимум мелких деталей. Это относится
к кораблям, персонажам и инструментам. Инженерные узлы собраны в понятные
функциональные группы; швы и сервисные элементы поддерживают общую форму.
Перегруженные панели и случайная декоративная механика не соответствуют
актуальному направлению.

Исходная история — рабочая завязка для арт-поиска, не утвержденный сценарий
Земля уничтожена чужими после открытия людьми опасной для них технологии.
Поврежденный межзвездный корабль-станция ушел аварийным прыжком в новую
планетную систему. Он стал последним домом выживших. Экспедиционный шаттл
летает к планетам, ищет ресурсы и возвращает детали для ремонта базы.

Человеческая техника
Читаемые обитаемые объемы, продуманный доступ к обслуживанию и сдержанные
рабочие огни. Три школы используют разные пропорции, материалы и палитры:
экспедиционные клинья Meridian, замкнутые промышленные модули Bastion и
асимметричные скоростные корпуса Vesper. Новые листы показывают чистую,
поддерживаемую технику; повреждения и ремонт остаются частью сюжета и
предыдущих поисковых вариантов. Разведка, перевозка и спасение.

Чужие
Нечеловеческая пространственная логика, самостоятельные силуэты, организованная
конструкция и оборудование. Lacuna — поисковое название одного направления.

Гипотеза для обсуждения — не канон
Открытые центры и ламели чужих могут быть аппаратами управления пространством.
Человеческая технология прыжка могла нарушить их транзитную инфраструктуру.
Это возможная связь визуального языка с мотивом нападения, а не утвержденный
сюжетный факт.

Что обсуждать
1. Узнаваемость силуэта спереди, сзади и из камеры погони.
2. Понятную функцию, входы, груз и честный человеческий масштаб.
3. Единство технологий и деталей внутри школы при различии ее классов.
4. Какие идеи сохранить, совместить или отбросить до работы с 3D.

Семейства кораблей — актуальный поиск формы
__FAMILIES__

Предыдущие чистые варианты — «Чистые формы»
H06 Vela — компактный цельный клин на крайне гладкой грани минимализма.
H07 Swift — вытянутый шаттл с такими же гладкими минималистичными поверхностями.
H08 Manta v2 — более угловатый баланс крупных панелей и функциональных деталей.
C03 Люди — крупные цельные элементы скафандра и минимум навески.
C04 Lacuna — ясный нечеловеческий силуэт и спокойные поверхности.
E02 Полевой комплект — чистые формы и понятная функция инструментов.
Это варианты художественного поиска. Названия рабочие; дизайн не утвержден.
Предыдущие изображения сохранены в общем каталоге как история поиска,
а не как выбранные или утвержденные конструкции.

Просмотр
Откройте index.html прямо с диска или через локальный HTTP-сервер.
При наличии семейств первым открывается фильтр «Семейства». Он показывает
по одному листу на школу. Фильтр «Чистые формы» включает и новые семейства,
и предыдущие чистые варианты. «Все» открывает весь каталог изображений.
Клик по изображению открывает крупный просмотр; стрелки перелистывают,
Esc закрывает. Отметьте любые два эскиза, чтобы сравнить их рядом.
Все изображения загружаются из соседних папок, без сетевых библиотек.
Оригиналы не изменяются. При наличии версии v2/v3 в галерее показывается
только новейшая версия соответствующего изображения.
Ссылка «3D-пробы» ведет в отдельный каталог models/index.html.

Источники
OpenAI image_gen и генерация изображений в Tripo Studio.
Точная модель указана только там, где она подтверждена.

Пересборка каталога после добавления изображений
python build_gallery.py
Скрипт обновляет index.html, concepts.json и этот brief.txt.
"""


def main() -> None:
    items = collect()
    families = [item for item in items if "families" in item["tags"]]
    manifest = {"date": DATE, "title": "Stellar Drift — арт-разведка", "status": "Эскизы, не канон", "family_schools": len(families), "family_ship_concepts": sum(len(item["roles4"]) for item in families), "items": items}
    payload = json.dumps(manifest, ensure_ascii=False, indent=2)
    (ROOT / "concepts.json").write_text(payload + "\n", encoding="utf-8")
    # Escape the closing-tag sequence even if future titles contain untrusted text.
    (ROOT / "index.html").write_text(PAGE.replace("__DATA__", payload.replace("</", "<\\/")), encoding="utf-8")
    tripo_count = sum(item["source"] == "Tripo Studio" for item in items)
    imagegen_count = sum(item["source"] == "OpenAI image_gen" for item in items)
    counts = f"Изображений в каталоге: {len(items)}. Tripo Studio: {tripo_count} (бесплатно); ImageGen: {imagegen_count}.\nСемейств: {len(families)}; кораблей на их листах: {sum(len(item['roles4']) for item in families)}."
    family_lines = [
        "Шесть школ, четыре класса в каждой. Чистые силуэты и крупные функциональные формы.",
        "Школы и названия поисковые, не канон. Это шесть листов с 24 вариантами кораблей,",
        "а не 24 отдельных изображения. Корабли на листах показаны не в общем масштабе.",
        "TL — сверху слева; TR — сверху справа; BL — снизу слева; BR — снизу справа.",
        "Назначение классов задано для поиска формы; механизмы и игровые параметры не определены.",
    ]
    for item in families:
        side = "люди" if item["side"] == "human" else "чужие"
        family_title = item["title"] if item["title"].startswith(item["school"]) else f"{item['school']} — {item['title']}"
        family_lines.extend([
            "",
            f"{item['id']} {family_title} ({side})",
            item["notes"],
            "; ".join(f"{position}: {role}" for position, role in zip(item["positions"], item["roles4"])) + ".",
            "Лист: " + item["filename"],
        ])
    (ROOT / "brief.txt").write_text(BRIEF.replace("__COUNTS__", counts).replace("__FAMILIES__", "\n".join(family_lines)), encoding="utf-8")
    print(f"Gallery rebuilt: {len(items)} concepts -> {ROOT / 'index.html'}")
    for key in LABELS:
        count = sum(item["category"] == key or key in item["tags"] for item in items)
        print(f"  {key}: {count}")


if __name__ == "__main__":
    main()
