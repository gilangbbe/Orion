"""Build a single self-contained HTML review page from results/ + the benchmark.

`orion-eval report` -> results/review.html  (double-click to open; no server, works offline)

The page lets you: filter/search questions, read every model's answer side by side against the
ground truth and the auto-grade, spot model disagreements / hallucinations / schema failures,
and record your own 0-2 human scores + notes per (question, model). Human review persists in
the browser (localStorage) and exports to JSON for the rubric's >=20% human spot-check.
"""
from __future__ import annotations

import json
from pathlib import Path


def _load_runs(results_dir: Path) -> list[dict]:
    runs = []
    for meta_path in sorted(results_dir.glob("*/run_meta.json")):
        rd = meta_path.parent
        meta = json.loads(meta_path.read_text())
        ans = {}
        for line in (rd / "answers.jsonl").read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                ans[r["id"]] = r
        grd = {}
        gp = rd / "grades.jsonl"
        if gp.is_file():
            for line in gp.read_text().splitlines():
                if line.strip():
                    r = json.loads(line)
                    grd[r["id"]] = r
        runs.append({"dir": rd.name, "meta": meta, "answers": ans, "grades": grd})
    return runs


def _summary(run: dict) -> dict:
    g = list(run["grades"].values())
    a = list(run["answers"].values())

    def mean(xs):
        xs = [x for x in xs if isinstance(x, (int, float)) and not isinstance(x, bool)]
        return round(sum(xs) / len(xs), 3) if xs else None

    return {
        "n": len(a),
        "composite": mean([x.get("composite") for x in g]),
        "correctness": mean([x.get("correctness") for x in g]),
        "hallucination": mean([x.get("hallucination") for x in g]),
        "evidence_accuracy": mean([x.get("evidence_accuracy") for x in g]),
        "structured_output": mean([x.get("structured_output") for x in g]),
        "schema_valid_pct": round(100 * sum(1 for x in a if x.get("schema_valid")) / max(len(a), 1)),
        "gen_tps": mean([x.get("gen_tps") for x in a]),
        "ttft_seconds": mean([x.get("ttft_seconds") for x in a]),
        "peak_memory_gb": mean([x.get("peak_memory_gb") for x in a]),
        "load_seconds": run["meta"].get("load_seconds"),
    }


def build_report(study_dir: str | Path, out_path: str | Path | None = None) -> str:
    study = Path(study_dir)
    results_dir = study / "results"
    bench_path = study / "benchmark" / "benchmark.resolved.json"
    if not bench_path.is_file():
        bench_path = study / "benchmark" / "benchmark.json"
    bench = json.loads(bench_path.read_text())
    runs = _load_runs(results_dir)
    if not runs:
        raise SystemExit("no results/*/run_meta.json found — run `run` first")

    models = [
        {"id": r["meta"].get("model_id", r["dir"]), "dir": r["dir"],
         "meta": r["meta"], "summary": _summary(r)}
        for r in runs
    ]
    by_dir = {r["dir"]: r for r in runs}

    questions = []
    for q in bench["questions"]:
        row = {k: q.get(k) for k in (
            "id", "category", "difficulty", "question", "developer_explanation",
            "expected_answer", "required_concepts", "relevant_files", "relevant_symbols",
            "evidence", "common_misconceptions", "answerable_from",
            "expected_epistemic_status", "grading_notes", "points")}
        row["answers"] = {}
        for m in models:
            r = by_dir[m["dir"]]
            a = r["answers"].get(q["id"], {})
            g = r["grades"].get(q["id"], {})
            row["answers"][m["id"]] = {
                "answer_obj": a.get("answer_obj"),
                "raw_text": a.get("raw_text", ""),
                "json_method": a.get("json_method"),
                "schema_valid": a.get("schema_valid"),
                "schema_errors": a.get("schema_errors"),
                "context_files": a.get("context_files", []),
                "context_truncated": a.get("context_truncated", False),
                "perf": {k: a.get(k) for k in (
                    "ttft_seconds", "total_seconds", "gen_tps", "gen_tokens",
                    "prompt_tokens", "peak_memory_gb", "finish_reason")},
                "grade": g,
            }
        questions.append(row)

    data = {
        "generated": bench["metadata"].get("authored"),
        "benchmark": {k: bench["metadata"].get(k) for k in (
            "repository", "version", "commit_sha", "language")},
        "judge": runs[0]["meta"].get("judge"),
        "models": models,
        "questions": questions,
    }

    html = _TEMPLATE.replace("/*__DATA__*/", json.dumps(data, ensure_ascii=False))
    out = Path(out_path) if out_path else (results_dir / "review.html")
    out.write_text(html, encoding="utf-8")
    return str(out)


_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Orion Task 3 — Answer Review</title>
<style>
  :root{
    --bg:#0f1115; --panel:#171a21; --panel2:#1e222b; --line:#2a2f3a; --fg:#e6e8ec;
    --muted:#9aa3af; --accent:#6ea8fe; --good:#43b581; --warn:#e0a52b;
    --bad:#e5534b; --chip:#2a2f3a;
  }
  @media (prefers-color-scheme: light){
    :root{ --bg:#f6f7f9; --panel:#fff; --panel2:#eef1f5; --line:#d9dee6; --fg:#1c2330;
      --muted:#5b6472; --accent:#2563eb; --good:#1a7f4b; --warn:#a9740c; --bad:#c0392b;
      --chip:#e6eaf0; }
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
  header{padding:10px 14px;border-bottom:1px solid var(--line);display:flex;gap:16px;align-items:baseline;flex-wrap:wrap;position:sticky;top:0;background:var(--bg);z-index:5}
  header h1{font-size:14px;margin:0;font-weight:700}
  header .meta{color:var(--muted);font-size:12px}
  .lead{display:flex;gap:10px;flex-wrap:wrap;margin-left:auto}
  .lead .m{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:4px 8px;font-size:12px}
  .lead .m b{color:var(--accent)}
  main{display:grid;grid-template-columns:340px 1fr;height:calc(100vh - 46px)}
  #list{border-right:1px solid var(--line);overflow:auto;background:var(--panel)}
  #filters{padding:8px 10px;border-bottom:1px solid var(--line);display:flex;flex-direction:column;gap:6px;position:sticky;top:0;background:var(--panel);z-index:2}
  #filters input[type=search]{width:100%;padding:5px 8px;border-radius:6px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}
  #filters .row{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
  #filters label{font-size:11px;color:var(--muted);display:flex;gap:4px;align-items:center;background:var(--chip);padding:2px 6px;border-radius:5px;cursor:pointer}
  .qitem{padding:8px 10px;border-bottom:1px solid var(--line);cursor:pointer;display:flex;flex-direction:column;gap:3px}
  .qitem:hover{background:var(--panel2)}
  .qitem.sel{background:var(--panel2);box-shadow:inset 3px 0 0 var(--accent)}
  .qitem .top{display:flex;gap:6px;align-items:center}
  .qitem .qid{font-weight:700;font-family:ui-monospace,Menlo,monospace}
  .qitem .qtext{color:var(--muted);font-size:12px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
  .chip{font-size:10px;padding:1px 5px;border-radius:4px;background:var(--chip);color:var(--muted);white-space:nowrap}
  .chip.diff-hard{background:#5a2b2b;color:#ffd9d6}
  .chip.diff-medium{background:#5a4a25;color:#ffedcf}
  .chip.diff-easy{background:#22432f;color:#cdf3dc}
  @media (prefers-color-scheme: light){.chip.diff-hard{background:#f6d6d3;color:#7a271f}.chip.diff-medium{background:#f6e9cf;color:#7a5310}.chip.diff-easy{background:#d6f0df;color:#1a5b38}}
  .scorepips{display:flex;gap:3px;margin-top:2px}
  .pip{font-size:10px;font-family:ui-monospace,monospace;padding:0 4px;border-radius:3px;background:var(--chip)}
  .pip b{color:var(--fg)}
  #detail{overflow:auto;padding:16px 20px}
  #detail h2{margin:0 0 4px;font-size:16px}
  .qmeta{color:var(--muted);font-size:12px;margin-bottom:12px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:12px}
  .card h3{margin:0 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
  .kv{margin:4px 0}
  .kv .k{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
  .tags{display:flex;gap:5px;flex-wrap:wrap;margin:3px 0}
  .tag{font-size:11px;padding:2px 7px;border-radius:5px;background:var(--chip)}
  .tag.bad{background:#5a2b2b;color:#ffd9d6}
  @media (prefers-color-scheme: light){.tag.bad{background:#f6d6d3;color:#7a271f}}
  .cols{display:grid;gap:12px}
  .modelcard{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
  .modelcard .name{font-weight:700;font-family:ui-monospace,monospace;font-size:13px}
  .grades{display:flex;gap:6px;flex-wrap:wrap;margin:8px 0}
  .g{font-size:11px;padding:2px 7px;border-radius:5px;background:var(--chip);font-family:ui-monospace,monospace}
  .g.s0{background:#5a2b2b;color:#ffd9d6}
  .g.s1{background:#5a4a25;color:#ffedcf}
  .g.s2{background:#22432f;color:#cdf3dc}
  @media (prefers-color-scheme: light){.g.s0{background:#f6d6d3;color:#7a271f}.g.s1{background:#f6e9cf;color:#7a5310}.g.s2{background:#d6f0df;color:#1a5b38}}
  .ans{white-space:pre-wrap;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;margin:6px 0;font-size:12.5px}
  .rationale{font-style:italic;color:var(--muted);font-size:12px;margin:4px 0}
  details{margin:6px 0}
  summary{cursor:pointer;color:var(--accent);font-size:12px}
  pre{white-space:pre-wrap;font-size:11.5px;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;max-height:340px}
  code{font-family:ui-monospace,Menlo,monospace}
  .perf{color:var(--muted);font-size:11px;margin-top:4px}
  .human{margin-top:10px;border-top:1px dashed var(--line);padding-top:8px}
  .human .axis{display:flex;gap:6px;align-items:center;margin:3px 0;font-size:12px}
  .human .axis span{width:150px;color:var(--muted)}
  .human .axis button{border:1px solid var(--line);background:var(--bg);color:var(--fg);border-radius:5px;width:26px;height:22px;cursor:pointer}
  .human .axis button.on{background:var(--accent);color:#fff;border-color:var(--accent)}
  .human textarea{width:100%;min-height:44px;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px;margin-top:4px}
  .toolbar{display:flex;gap:8px;align-items:center;margin-left:auto}
  .btn{border:1px solid var(--line);background:var(--panel);color:var(--fg);border-radius:6px;padding:4px 10px;cursor:pointer;font-size:12px}
  .btn:hover{border-color:var(--accent)}
  .delta{font-weight:700}
  .delta.big{color:var(--warn)}
  mark{background:var(--warn);color:#000;padding:0 2px;border-radius:3px}
</style>
</head>
<body>
<header>
  <h1>Orion Task 3 · Answer Review</h1>
  <span class="meta" id="hmeta"></span>
  <div class="lead" id="lead"></div>
  <div class="toolbar">
    <button class="btn" id="btnExport">Export my review</button>
    <button class="btn" id="btnClear">Clear my review</button>
  </div>
</header>
<main>
  <div id="list">
    <div id="filters">
      <input type="search" id="q" placeholder="search id / text / concept…">
      <div class="row" id="catFilters"></div>
      <div class="row">
        <label><input type="checkbox" id="fDisagree"> disagreements only</label>
        <label><input type="checkbox" id="fHall"> hallucination &lt; 2</label>
        <label><input type="checkbox" id="fSchema"> schema invalid</label>
        <label><input type="checkbox" id="fUnrev"> not reviewed by me</label>
      </div>
      <div class="row" id="diffFilters"></div>
    </div>
    <div id="qlist"></div>
  </div>
  <div id="detail"><p style="color:var(--muted)">Select a question. Keys: <code>j</code>/<code>k</code> next/prev.</p></div>
</main>
<script>
const DATA = /*__DATA__*/;
const MODELS = DATA.models.map(m=>m.id);
const AXES = ["correctness","completeness","architectural_reasoning","hallucination","evidence_accuracy","structured_output","teaching_quality"];
const LS_KEY = "orion_task3_human_review_v1";
let human = {};
try{ human = JSON.parse(localStorage.getItem(LS_KEY)||"{}"); }catch(e){ human={}; }
const saveHuman = ()=>{ try{ localStorage.setItem(LS_KEY, JSON.stringify(human)); }catch(e){} };

const el = (t,props={},...kids)=>{ const n=document.createElement(t); for(const[k,v]of Object.entries(props)){ if(k==="class")n.className=v; else if(k==="html")n.innerHTML=v; else if(k.startsWith("on"))n.addEventListener(k.slice(2),v); else n.setAttribute(k,v);} for(const c of kids.flat()){ if(c==null)continue; n.append(c.nodeType?c:document.createTextNode(c)); } return n; };
const esc = s => (s==null?"":String(s)).replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const scoreClass = v => v==null?"":"s"+Math.max(0,Math.min(2,Math.round(v)));

// ---------- header / leaderboard
document.getElementById("hmeta").textContent =
  `${DATA.benchmark.repository} ${DATA.benchmark.version} @ ${(DATA.benchmark.commit_sha||"").slice(0,12)} · ${DATA.questions.length} questions · judge: ${DATA.judge||"none"}`;
const lead = document.getElementById("lead");
DATA.models.slice().sort((a,b)=>(b.summary.composite||0)-(a.summary.composite||0)).forEach(m=>{
  lead.append(el("div",{class:"m",html:
    `<b>${esc(m.id)}</b> · comp ${m.summary.composite ?? "—"} · halluc ${m.summary.hallucination ?? "—"} · schema ${m.summary.schema_valid_pct}% · ${m.summary.gen_tps ?? "—"} tok/s · ${m.summary.peak_memory_gb ?? "—"} GB`}));
});

// ---------- filters
const cats = [...new Set(DATA.questions.map(q=>q.category))];
const catState = new Set(cats);
const catBox = document.getElementById("catFilters");
cats.forEach(c=>{
  const cb = el("input",{type:"checkbox",checked:"checked",onchange:e=>{ e.target.checked?catState.add(c):catState.delete(c); render(); }});
  catBox.append(el("label",{},cb,c.replace(/_/g," ")));
});
const diffs=["easy","medium","hard"]; const diffState=new Set(diffs);
const diffBox=document.getElementById("diffFilters");
diffs.forEach(d=>{
  const cb=el("input",{type:"checkbox",checked:"checked",onchange:e=>{ e.target.checked?diffState.add(d):diffState.delete(d); render(); }});
  diffBox.append(el("label",{},cb,d));
});
["q","fDisagree","fHall","fSchema","fUnrev"].forEach(id=>document.getElementById(id).addEventListener("input",render));

function compositeOf(q,mid){ const g=q.answers[mid]?.grade||{}; return g.composite; }
function disagreement(q){
  const vs = MODELS.map(m=>compositeOf(q,m)).filter(v=>v!=null);
  return vs.length>1 ? Math.max(...vs)-Math.min(...vs) : 0;
}
function anyHall(q){ return MODELS.some(m=>{ const h=q.answers[m]?.grade?.hallucination; return h!=null && h<2; }); }
function anySchemaBad(q){ return MODELS.some(m=>q.answers[m]?.schema_valid===false); }
function reviewedAll(q){ return MODELS.every(m=>human[q.id]?.[m]?.done); }

let selected = null;
function passes(q){
  if(!catState.has(q.category)) return false;
  if(!diffState.has(q.difficulty)) return false;
  const term = document.getElementById("q").value.trim().toLowerCase();
  if(term){
    const hay = (q.id+" "+q.question+" "+(q.required_concepts||[]).join(" ")+" "+q.category).toLowerCase();
    if(!hay.includes(term)) return false;
  }
  if(document.getElementById("fDisagree").checked && disagreement(q) < 0.25) return false;
  if(document.getElementById("fHall").checked && !anyHall(q)) return false;
  if(document.getElementById("fSchema").checked && !anySchemaBad(q)) return false;
  if(document.getElementById("fUnrev").checked && reviewedAll(q)) return false;
  return true;
}

function render(){
  const list = document.getElementById("qlist");
  list.innerHTML="";
  const shown = DATA.questions.filter(passes);
  shown.forEach(q=>{
    const pips = el("div",{class:"scorepips"});
    MODELS.forEach(m=>{
      const c = compositeOf(q,m);
      pips.append(el("span",{class:"pip",html:`${esc(m.split("-")[0])} <b>${c==null?"—":c.toFixed(2)}</b>`}));
    });
    const d = disagreement(q);
    const item = el("div",{class:"qitem"+(selected===q.id?" sel":""),onclick:()=>{selected=q.id;render();showDetail(q);}},
      el("div",{class:"top"},
        el("span",{class:"qid"},q.id),
        el("span",{class:"chip diff-"+q.difficulty},q.difficulty),
        el("span",{class:"chip"},q.category.replace(/_/g," ")),
        d>=0.25?el("span",{class:"chip",html:`Δ <span class="delta big">${d.toFixed(2)}</span>`}):null,
        anyHall(q)?el("span",{class:"chip",html:"⚠ halluc"}):null,
        reviewedAll(q)?el("span",{class:"chip",html:"✓ mine"}):null,
      ),
      el("div",{class:"qtext"},q.question),
      pips
    );
    list.append(item);
  });
  if(!list.children.length) list.append(el("div",{class:"qitem"},"no questions match filters"));
}

function humanBlock(q,mid){
  human[q.id] = human[q.id]||{}; human[q.id][mid] = human[q.id][mid]||{scores:{},note:""};
  const rec = human[q.id][mid];
  const wrap = el("div",{class:"human"});
  wrap.append(el("div",{class:"k",html:"<b>My review</b>"}));
  AXES.forEach(ax=>{
    const row = el("div",{class:"axis"}, el("span",{},ax));
    [0,1,2].forEach(v=>{
      const b = el("button",{class:(rec.scores[ax]===v?"on":""),onclick:()=>{
        rec.scores[ax]=(rec.scores[ax]===v?undefined:v); rec.done=Object.keys(rec.scores).some(k=>rec.scores[k]!=null);
        saveHuman(); showDetail(q); render();
      }}, String(v));
      row.append(b);
    });
    wrap.append(row);
  });
  const ta = el("textarea",{placeholder:"notes / where the auto-grade is wrong…",oninput:e=>{rec.note=e.target.value;rec.done=true;saveHuman();}});
  ta.value = rec.note||"";
  wrap.append(ta);
  return wrap;
}

function showDetail(q){
  const d = document.getElementById("detail");
  d.innerHTML="";
  d.append(el("h2",{},q.id+" — "+q.category.replace(/_/g," ")));
  d.append(el("div",{class:"qmeta"},`difficulty ${q.difficulty} · points ${q.points} · answerable_from ${q.answerable_from} · expected epistemic_status ${q.expected_epistemic_status||"—"}`));

  const qc = el("div",{class:"card"});
  qc.append(el("h3",{},"Question"));
  qc.append(el("div",{},q.question));
  if(q.developer_explanation){
    qc.append(el("div",{class:"kv"}, el("div",{class:"k"},"developer explanation under test"), el("div",{},q.developer_explanation)));
  }
  d.append(qc);

  const gt = el("div",{class:"card"});
  gt.append(el("h3",{},"Ground truth"));
  gt.append(el("div",{class:"kv"}, el("div",{class:"k"},"expected answer"), el("div",{},q.expected_answer)));
  gt.append(el("div",{class:"kv"}, el("div",{class:"k"},"required concepts"),
    el("div",{class:"tags"}, (q.required_concepts||[]).map(c=>el("span",{class:"tag"},c)))));
  if((q.common_misconceptions||[]).length)
    gt.append(el("div",{class:"kv"}, el("div",{class:"k"},"common misconceptions (penalise if asserted)"),
      el("div",{class:"tags"}, q.common_misconceptions.map(c=>el("span",{class:"tag bad"},c)))));
  gt.append(el("div",{class:"kv"}, el("div",{class:"k"},"evidence anchors"),
    el("div",{class:"tags"}, (q.evidence||[]).map(e=>el("span",{class:"tag"}, (e.file||"")+(e.symbol?" :: "+e.symbol.split("::").pop():"")+(e.line?" :"+e.line:""))))));
  gt.append(el("details",{}, el("summary",{},"grading notes"), el("div",{class:"rationale"},q.grading_notes||"")));
  d.append(gt);

  const cols = el("div",{class:"cols"});
  cols.style.gridTemplateColumns = MODELS.length>1 ? "repeat("+MODELS.length+",1fr)" : "1fr";
  MODELS.forEach(mid=>{
    const a = q.answers[mid]||{}; const g = a.grade||{}; const o = a.answer_obj;
    const mc = el("div",{class:"modelcard"});
    mc.append(el("div",{class:"name"},mid));
    const gr = el("div",{class:"grades"});
    gr.append(el("span",{class:"g",html:`composite <b>${g.composite==null?"—":g.composite.toFixed(3)}</b>`}));
    AXES.forEach(ax=>{ if(g[ax]!=null) gr.append(el("span",{class:"g "+scoreClass(g[ax])},`${ax.split("_")[0]} ${g[ax]}`)); });
    if(g.epistemic_got!=null) gr.append(el("span",{class:"g"+(g.epistemic_got===g.epistemic_expected?" s2":" s0")},`epis ${g.epistemic_got}→${g.epistemic_expected}`));
    if(g.concept_coverage!=null) gr.append(el("span",{class:"g"},`concepts ${(g.concept_coverage*100|0)}%`));
    if(a.schema_valid===false) gr.append(el("span",{class:"g s0"},`schema BAD (${a.json_method})`));
    if(a.context_truncated) gr.append(el("span",{class:"g s1"},"ctx truncated"));
    mc.append(gr);
    if(g.judge_rationale) mc.append(el("div",{class:"rationale"},"judge: "+g.judge_rationale));
    if(g.fabricated_paths && g.fabricated_paths.length) mc.append(el("div",{class:"rationale",html:`<mark>fabricated paths:</mark> ${esc(g.fabricated_paths.join(", "))}`}));

    if(o){
      mc.append(el("div",{class:"ans"}, o.answer||"(no answer field)"));
      if((o.key_points||[]).length) mc.append(el("div",{class:"kv"}, el("div",{class:"k"},"key points"),
        el("ul",{}, o.key_points.map(k=>el("li",{},k)))));
      if((o.evidence||[]).length) mc.append(el("div",{class:"kv"}, el("div",{class:"k"},"cited evidence"),
        el("div",{class:"tags"}, o.evidence.map(e=>el("span",{class:"tag"}, (e.file||"?")+(e.symbol?" :: "+e.symbol:"") )))));
      if((o.uncertainties||[]).length) mc.append(el("div",{class:"kv"}, el("div",{class:"k"},"uncertainties"),
        el("div",{class:"tags"}, o.uncertainties.map(u=>el("span",{class:"tag"},u)))));
      mc.append(el("div",{class:"perf"},`epistemic_status: ${o.epistemic_status||"—"}`));
    } else {
      mc.append(el("div",{class:"ans"},"(no parseable JSON object)"));
    }
    mc.append(el("details",{}, el("summary",{},"raw completion"), el("pre",{}, a.raw_text||"")));
    mc.append(el("details",{}, el("summary",{},`context files (${(a.context_files||[]).length})`),
      el("pre",{}, (a.context_files||[]).join("\n"))));
    const p = a.perf||{};
    mc.append(el("div",{class:"perf"},
      `ttft ${p.ttft_seconds ?? "—"}s · ${p.gen_tps ?? "—"} tok/s · gen ${p.gen_tokens ?? "—"} tok · prompt ${p.prompt_tokens ?? "—"} tok · peak ${p.peak_memory_gb ?? "—"} GB · ${p.finish_reason ?? ""}`));
    mc.append(humanBlock(q,mid));
    cols.append(mc);
  });
  d.append(cols);
  d.scrollTop = 0;
}

document.getElementById("btnExport").onclick = ()=>{
  const rows=[];
  for(const [qid,perModel] of Object.entries(human)){
    for(const [mid,rec] of Object.entries(perModel)){
      if(!rec.done) continue;
      rows.push({question_id:qid, model:mid, human_scores:rec.scores, note:rec.note||""});
    }
  }
  const blob = new Blob([JSON.stringify({exported:new Date().toISOString(),
    benchmark:DATA.benchmark, judge:DATA.judge, reviews:rows}, null, 2)], {type:"application/json"});
  const u = URL.createObjectURL(blob);
  const a = el("a",{href:u,download:"orion_task3_human_review.json"}); document.body.append(a); a.click(); a.remove(); URL.revokeObjectURL(u);
};
document.getElementById("btnClear").onclick = ()=>{ if(confirm("Clear all your human review notes?")){ human={}; saveHuman(); render(); if(selected) showDetail(DATA.questions.find(q=>q.id===selected)); } };

document.addEventListener("keydown",e=>{
  if(e.target.tagName==="TEXTAREA"||e.target.tagName==="INPUT") return;
  if(e.key!=="j"&&e.key!=="k") return;
  const shown = DATA.questions.filter(passes);
  let i = shown.findIndex(q=>q.id===selected);
  i = e.key==="j" ? Math.min(shown.length-1,i+1) : Math.max(0,i-1);
  if(shown[i]){ selected=shown[i].id; render(); showDetail(shown[i]); document.querySelector(".qitem.sel")?.scrollIntoView({block:"nearest"}); }
});

render();
if(DATA.questions.length){ selected=DATA.questions[0].id; render(); showDetail(DATA.questions[0]); }
</script>
</body>
</html>
"""
