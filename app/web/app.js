/* TokenTracker 主窗口逻辑：数据全部来自本地 /api，零上传。 */
"use strict";

window.__errs = [];
window.onerror = (m, s, l, c) => window.__errs.push(m + " @" + l + ":" + c);

/* ─────────── 常量与工具 ─────────── */
const TOOL = {
  claude:   { name: "Claude Code", color: "#d97757" },
  codex:    { name: "Codex",       color: "#5b8def" },
  opencode: { name: "opencode",    color: "#34b3a0" },
  dsh:      { name: "DSH",         color: "#b98ae0" },
  hermes:   { name: "Hermes",      color: "#e0a13e" },
  kimi:     { name: "Kimi",        color: "#e06a9a" },
  pi:       { name: "Pi",          color: "#7fb069" },
};
const TOOL_ORDER = ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"];

const $ = (s, el = document) => el.querySelector(s);
const fmtT = n => { n = +n || 0;
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e4) return (n / 1e3).toFixed(1) + "K";
  if (n >= 1e3) return (n / 1e3).toFixed(2) + "K";
  return String(Math.round(n)); };
const fmtCost = n => { n = +n || 0; return "$" + (n >= 1000 ? (n / 1000).toFixed(2) + "K" : n.toFixed(2)); };

const api = () => (window.pywebview && window.pywebview.api) || null;

function toast(msg, ms = 2600) {
  const t = $("#toast"); if (!t) return;
  t.textContent = msg; t.classList.add("show");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), ms);
}

/* ─────────── 状态 ─────────── */
const state = { range: "week", tool: null, chart: null, logScale: false,
                scanning: false, detected: null, sessRows: [],
                sort: { key: "ts", dir: -1 } };

/* ─────────── 数据加载 ─────────── */
async function jget(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + " -> " + r.status);
  return r.json();
}

async function loadStats() {
  const d = await jget("/api/stats?range=" + state.range);
  renderStatCards(d.rows, d.total);
  renderSideTools(d.rows);
}
async function loadToday() {
  const d = await jget("/api/stats?range=day");
  $("#todayCost").textContent = fmtCost((d.total || {}).cost);
}
async function loadDaily() {
  const d = await jget("/api/daily?range=" + state.range);
  drawTrend(d.rows);
}
async function loadQuotas() {
  const d = await jget("/api/quotas");
  renderQuotas(d.entries || []);
}
async function loadModels() {
  const d = await jget("/api/models?range=" + state.range);
  renderModels(d.rows || []);
}
async function loadSessions() {
  const tool = state.tool ? "&tool=" + state.tool : "";
  const d = await jget("/api/sessions?range=" + state.range + "&limit=300" + tool);
  state.sessRows = d.rows || [];
  renderSessions();
}
async function loadDetect() {
  const d = await jget("/api/detect");
  state.detected = d;
}
function stampUpdated() {
  const t = new Date();
  const p = n => String(n).padStart(2, "0");
  $("#updatedAt").textContent = "更新于 " + p(t.getHours()) + ":" + p(t.getMinutes()) + ":" + p(t.getSeconds());
}
async function refreshAll() {
  try {
    await Promise.all([loadStats(), loadToday(), loadDaily(), loadQuotas(), loadModels()]);
    if (!$("#view-sessions").classList.contains("hidden")) await loadSessions();
    stampUpdated();
  } catch (e) { console.warn(e); }
}

/* ─────────── 概览：统计卡 ─────────── */
const ICONS = {
  tok: '<svg viewBox="0 0 24 24"><path d="M13 2 4.5 13.5H11L9.5 22 19 10h-6.5z"/></svg>',
  cost: '<svg viewBox="0 0 24 24"><path d="M12 2v20M17 6.5c0-1.7-2.2-3-5-3s-5 1.3-5 3 1.8 2.6 5 3.2 5 1.5 5 3.3-2.2 3-5 3-5-1.3-5-3"/></svg>',
  sess: '<svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="3.2"/><path d="M5 20c.6-3.4 3.4-5 7-5s6.4 1.6 7 5"/></svg>',
  cache: '<svg viewBox="0 0 24 24"><path d="m12 3 7 4-7 4-7-4 7-4Z"/><path d="m5 12.5 7 4 7-4M5 16.8l7 4 7-4"/></svg>',
};

function renderStatCards(rows, total) {
  const t = total || {};
  const cards = [
    { ic: "tok",  k: "Token 总量", v: fmtT((t.input || 0) + (t.output || 0)),
      sub: "输入 " + fmtT(t.input || 0) + " · 输出 " + fmtT(t.output || 0) },
    { ic: "cost", k: "成本估算", v: fmtCost(t.cost),
      sub: (t.unpriced ? "⚠ " + t.unpriced + " 条未计价" : "按 prices.json 计价") , warn: !!t.unpriced},
    { ic: "sess", k: "会话数", v: fmtT(t.sessions), sub: rows.length + " 个工具当前有数据",
      go: "sessions" },
    { ic: "cache", k: "缓存读取", v: fmtT(t.cache_read), sub: "写入 " + fmtT(t.cache_write || 0) },
  ];
  $("#statCards").innerHTML = cards.map(c => `
    <div class="stat-card ${c.go ? "clickable" : ""}" ${c.go ? `data-go="${c.go}" title="点击查看会话记录"` : ""}>
      <div class="ic ${c.ic}">${ICONS[c.ic]}</div>
      <div class="v">${c.v}</div>
      <div class="k">${c.k}</div>
      <div class="sub ${c.warn ? "warn" : ""}">${c.sub}</div>
    </div>`).join("");
  [...$("#statCards").children].forEach(el => {
    if (el.dataset.go) el.onclick = () => switchView(el.dataset.go);
  });
}

/* ─────────── 侧栏：工具数据源（点击 → 会话记录按该工具过滤） ─────────── */
function renderSideTools(rows) {
  const byTool = {}; (rows || []).forEach(r => byTool[r.tool] = r);
  const sorted = TOOL_ORDER.map(t => {
    const r = byTool[t] || null;
    return { tool: t, tok: r ? (r.input + r.output) : 0 };
  }).sort((a, b) => b.tok - a.tok);
  $("#sideTools").innerHTML = sorted.map(s => {
    const meta = TOOL[s.tool] || { name: s.tool, color: "#aaa" };
    const inst = state.detected && state.detected[s.tool] ? state.detected[s.tool].installed : true;
    const label = s.tok > 0 ? fmtT(s.tok) : (inst ? "—" : "未检测到");
    return `<div class="side-tool ${!inst ? "miss" : ""}" data-tool="${s.tool}"
      title="${inst ? "查看 " + meta.name + " 的会话记录" : meta.name + " 未检测到数据源"}">
      <span class="dot" style="background:${meta.color}"></span>
      <span class="name">${meta.name}</span>
      <span class="n">${label}</span></div>`;
  }).join("");
  [...$("#sideTools").children].forEach(el => {
    el.onclick = () => {
      const t = el.dataset.tool;
      if (el.classList.contains("miss")) return;
      setToolFilter(t);
      switchView("sessions");
    };
  });
}

/* ─────────── 趋势图 ─────────── */
function drawTrend(rows) {
  const byTool = {}; const dates = new Set();
  (rows || []).forEach(r => {
    (byTool[r.tool] = byTool[r.tool] || {})[r.d] = (r.input || 0) + (r.output || 0);
    dates.add(r.d);
  });
  const xs = [...dates].sort();

  const cfg = {
    type: "line",
    data: { labels: xs, datasets: TOOL_ORDER.filter(t => byTool[t]).map(t => ({
      label: TOOL[t].name, data: xs.map(d => byTool[t][d] || null),
      borderColor: TOOL[t].color, backgroundColor: TOOL[t].color,
      borderWidth: 1.8, tension: .3, pointRadius: 0, pointHitRadius: 14, spanGaps: true,
    })) },
    options: {
      responsive: true, maintainAspectRatio: false, interaction: { mode: "index", intersect: false },
      plugins: { legend: { display: false }, tooltip: {
        backgroundColor: "rgba(30,27,23,.92)", padding: 10, cornerRadius: 8,
        displayColors: true, boxWidth: 8, boxHeight: 8, usePointStyle: true,
        callbacks: { label: c => " " + c.dataset.label + "： " + fmtT(c.parsed.y) } } },
      scales: {
        x: { grid: { display: false }, ticks: { color: "#a8a49c", maxTicksLimit: 8, font: { size: 10 } } },
        y: { type: state.logScale ? "logarithmic" : "linear", grid: { color: "#f0efec" },
             border: { display: false },
             ticks: { color: "#a8a49c", font: { size: 10 },
                       callback: v => (+v >= 1000 ? fmtT(v) : v) } },
      },
    },
  };
  if (state.chart) { state.chart.destroy(); }
  state.chart = new Chart($("#trendChart"), cfg);
  buildLegend();
}
function buildLegend() {
  const ds = state.chart ? state.chart.data.datasets : [];
  $("#chartLegend").innerHTML = ds.map(d => `
    <button data-i="${d.index}" class="${d.hidden ? "hidden" : ""}">
      <span class="sw" style="background:${d.borderColor}"></span>${d.label}</button>`).join("");
  [...$("#chartLegend").children].forEach(b => b.onclick = () => {
    const d = state.chart.data.datasets[+b.dataset.i];
    d.hidden = !d.hidden; b.classList.toggle("hidden"); state.chart.update();
  });
}

/* ─────────── 配额 ─────────── */
function renderQuotas(entries) {
  if (!entries.length) { $("#quotaList").innerHTML = '<div class="quota-empty">未配置配额</div>'; return; }
  $("#quotaList").innerHTML = entries.map(e => `
    <div class="quota-item">
      <div class="q-head">
        <span class="q-name">${e.name}</span>
        <span class="q-plan">${e.plan || ""}</span>
        <span class="badge ${e.source === "official" ? "official" : ""}">${e.source === "official" ? "官方" : "本地估算"}</span>
      </div>
      <div class="q-wins">${(e.windows || []).map(w => winRow(w)).join("")}</div>
      ${e.note ? `<div style="font-size:10px;color:var(--red);margin-top:6px">⚠ ${e.note}</div>` : ""}
    </div>`).join("");
}
function winRow(w) {
  const pct = w.pct == null ? null : Math.min(w.pct, 100);
  const cls = pct == null ? "" : (pct < 60 ? "good" : (pct < 85 ? "mid" : "bad"));
  const barCls = pct == null ? "" : (pct < 60 ? "" : (pct < 85 ? "mid" : "bad"));
  const used = w.unit === "usd" ? fmtCost(w.used) : fmtT(w.used);
  const lim = w.unit === "usd" ? fmtCost(w.limit) : fmtT(w.limit);
  const pctTxt = pct == null ? "未设上限" : pct.toFixed(0) + "%";
  const reset = w.resets_at ? countdown(w.resets_at) : "";
  const detail = w.unit === "requests" ? `${w.used} / ${w.limit} 次`
    : (w.used != null && w.limit != null ? `${used} / ${lim}` : "");
  const topRight = w.unit === "usd" ? "" : (w.used != null && w.limit != null ? used + " / " + lim + " " : "");
  return `<div class="q-win" ${detail ? `title="${detail}"` : ""}>
    <div class="w-top"><span>${w.label}</span>
      <span>${topRight}<b class="pct ${cls}">${pctTxt}</b></span></div>
    <div class="q-bar"><i class="${barCls}" style="width:${pct ?? 0}%"></i></div>
    ${reset ? `<div class="reset">${reset} 重置</div>` : ""}
  </div>`;
}
function countdown(iso) {
  const diff = new Date(iso).getTime() - Date.now();
  if (!(diff > 0)) return "";
  const h = Math.floor(diff / 3600e3), m = Math.floor((diff % 3600e3) / 60e3);
  return h > 0 ? h + " 小时 " + m + " 分后" : Math.max(m, 1) + " 分后";
}

/* ─────────── 模型榜 ─────────── */
function renderModels(rows) {
  if (!rows.length) { $("#modelList").innerHTML = '<div class="model-empty">暂无数据</div>'; return; }
  const top = rows.slice(0, 10);
  const max = Math.max(...top.map(r => r.input + r.output), 1);
  $("#modelList").innerHTML = top.map((r, i) => {
    const meta = TOOL[r.tool] || { name: r.tool, color: "#aaa" };
    const tok = (r.input || 0) + (r.output || 0);
    return `<div class="model-row">
      <span class="rank">#${i + 1}</span>
      <span class="m-name" title="${r.model || "(未知模型)"}">${r.model || "(未知模型)"}</span>
      <span class="m-tool"><span class="dot" style="background:${meta.color}"></span>${meta.name}</span>
      <span class="m-tok">${fmtT(r.input)} / ${fmtT(r.output)}</span>
      <span class="m-cost">${r.cost == null ? "—" : fmtCost(r.cost)}</span>
      <div class="m-bar-track"><i style="width:${(tok / max * 100).toFixed(1)}%"></i></div>
    </div>`;
  }).join("");
}

/* ─────────── 会话（可排序、可点开详情） ─────────── */
function sortedRows() {
  const { key, dir } = state.sort;
  const val = r => key === "cost" ? (r.cost || 0)
    : key === "tool" ? (TOOL[r.tool] ? TOOL[r.tool].name : r.tool)
    : (r[key] ?? "");
  return [...state.sessRows].sort((a, b) => {
    const x = val(a), y = val(b);
    if (typeof x === "number" && typeof y === "number") return (x - y) * dir;
    return String(x).localeCompare(String(y)) * dir;
  });
}
function renderSessions() {
  const rows = sortedRows();
  const sub = $("#sessSub");
  sub.textContent = (state.tool && TOOL[state.tool] ? TOOL[state.tool].name + " · " : "全部工具 · ") + rows.length + " 条会话";
  $("#sessEmpty").style.display = rows.length ? "none" : "";
  $("#sessBody").innerHTML = rows.map((r, i) => {
    const meta = TOOL[r.tool] || { name: r.tool, color: "#aaa" };
    return `<tr data-i="${i}" title="点击查看会话详情">
      <td><span class="tool-cell"><span class="dot" style="background:${meta.color}"></span>${meta.name}</span></td>
      <td class="proj" title="${r.project || r.session_id || ""}">${r.project || (r.session_id || "—").slice(0, 26)}</td>
      <td class="model-cell" title="${r.model || ""}">${r.model || "—"}</td>
      <td class="when">${relTime(r.last_seen)}</td>
      <td class="num">${fmtT(r.input)}</td>
      <td class="num">${fmtT(r.output)}</td>
      <td class="num">${fmtT(r.cache_read)}</td>
      <td class="num cost-cell">${r.cost == null ? "—" : fmtCost(r.cost)}</td>
      <td class="num">${r.events}</td>
    </tr>`;
  }).join("");
  [...$("#sessBody").children].forEach(el => {
    el.onclick = () => {
      const r = sortedRows()[+el.dataset.i];
      if (r) openDrawer(r);
    };
  });
  // 表头排序箭头
  document.querySelectorAll("th.sortable").forEach(th => {
    const on = th.dataset.sort === state.sort.key;
    th.innerHTML = th.innerHTML.replace(/<span class="arr">.*?<\/span>/, "");
    if (on) th.innerHTML += `<span class="arr">${state.sort.dir < 0 ? "▼" : "▲"}</span>`;
  });
}
function relTime(s) {
  if (!s) return "—";
  const p = s.split(/[- :]/).map(Number);
  const t = new Date(p[0], p[1] - 1, p[2], p[3] || 0, p[4] || 0, p[5] || 0);
  const diff = Date.now() - t.getTime();
  const m = Math.floor(diff / 60e3);
  if (m < 1) return "刚刚";
  if (m < 60) return m + " 分钟前";
  const h = Math.floor(m / 60);
  if (h < 24) return h + " 小时前";
  const d = Math.floor(h / 24);
  if (d < 7) return d + " 天前";
  return (p[1]) + "/" + p[2];
}

/* ─────────── 会话详情抽屉 ─────────── */
function closeDrawer() {
  $("#drawer").classList.remove("show");
  $("#drawerMask").classList.remove("show");
}
async function openDrawer(r) {
  const meta = TOOL[r.tool] || { name: r.tool };
  $("#dTitle").textContent = r.project || r.session_id || "会话详情";
  $("#dSub").textContent = meta.name + " · " + (r.last_seen || "");
  $("#drawerBody").innerHTML = '<div class="drawer-loading">加载中…</div>';
  $("#drawer").classList.add("show");
  $("#drawerMask").classList.add("show");
  let d;
  try {
    d = await jget("/api/session_detail?tool=" + encodeURIComponent(r.tool) +
                   "&session_id=" + encodeURIComponent(r.session_id));
  } catch (e) {
    $("#drawerBody").innerHTML = '<div class="drawer-loading">加载失败</div>';
    return;
  }
  const proj = (d.project || "").trim();
  const tokens = (d.tokens != null) ? d.tokens : null;
  $("#drawerBody").innerHTML = `
    <div class="d-cards">
      <div class="d-stat"><div class="v">${tokens == null ? "—" : fmtT(tokens)}</div><div class="k">Token（输入+输出）</div></div>
      <div class="d-stat"><div class="v">${fmtCost(d.cost)}</div><div class="k">成本估算</div></div>
      <div class="d-stat"><div class="v">${d.events ?? "—"}</div><div class="k">事件数</div></div>
      <div class="d-stat"><div class="v">${(d.models || []).length}</div><div class="k">模型数</div></div>
    </div>
    ${proj ? `<button class="d-open-btn" id="dOpenFinder">
      <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
      在 Finder 中打开项目</button>` : ""}
    <div class="d-sec">按模型分解</div>
    ${(d.models || []).map(m => `
      <div class="d-model">
        <span class="m-name" title="${m.model || "(未知模型)"}">${m.model || "(未知模型)"}</span>
        <span class="m-cost">${fmtCost(m.cost)}</span>
        <span class="m-io">入 ${fmtT(m.input)} · 出 ${fmtT(m.output)} · 缓存读 ${fmtT(m.cache_read)} · 缓存写 ${fmtT(m.cache_write)} · ${m.events} 事件</span>
      </div>`).join("") || '<div class="drawer-loading">无明细数据</div>'}
  `;
  const btn = $("#dOpenFinder");
  if (btn) btn.onclick = async () => {
    const a = api();
    const ok = a ? await a.open_in_finder(proj) : false;
    toast(ok ? "已在 Finder 中打开" : "路径不存在：" + proj);
  };
}

/* ─────────── 过滤 chips ─────────── */
function buildFilterChips() {
  const tools = state.detected ? TOOL_ORDER.filter(t => state.detected[t] && state.detected[t].installed) : [];
  const html = ['<button data-tool="" class="on">全部</button>']
    .concat(tools.map(t => `<button data-tool="${t}">${TOOL[t].name}</button>`)).join("");
  $("#toolFilter").innerHTML = html;
  [...$("#toolFilter").children].forEach(b => b.onclick = () => setToolFilter(b.dataset.tool || null));
}
function setToolFilter(tool) {
  state.tool = tool || null;
  [...$("#toolFilter").children].forEach(x =>
    x.classList.toggle("on", (x.dataset.tool || null) === state.tool));
  if (!$("#view-sessions").classList.contains("hidden")) loadSessions();
}

/* ─────────── 扫描 ─────────── */
async function startScan() {
  if (state.scanning) return;
  try { await fetch("/api/scan", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" }); }
  catch (e) { toast("扫描请求失败：无法连接本地服务"); return; }
  setScanning(true);
}
function setScanning(on) {
  state.scanning = on;
  $("#scanBtn").classList.toggle("scanning", on);
  $("#scanBtn span").textContent = on ? "扫描中…" : "扫描日志";
  $("#liveDot").classList.toggle("busy", on);
}
async function pollScan() {
  try {
    const s = await jget("/api/scan/status");
    if (s.running) { setScanning(true); return; }
    if (state.scanning && s.last && s.last.done) {
      setScanning(false);
      if (s.last.error) toast("扫描出错：" + s.last.error, 4200);
      else {
        const r = s.last.results || {};
        const added = Object.values(r).reduce((a, x) => a + (x.added || 0), 0);
        toast("✓ 扫描完成 · 新增 " + added + " 条事件");
      }
      refreshAll(); loadSessions();
    } else if (!s.running) { setScanning(false); }
  } catch (e) { /* 服务未就绪时忽略 */ }
}

/* ─────────── 事件绑定 ─────────── */
function switchView(name) {
  document.querySelectorAll(".nav-item").forEach(b => b.classList.toggle("active", b.dataset.view === name));
  $("#view-overview").classList.toggle("hidden", name !== "overview");
  $("#view-sessions").classList.toggle("hidden", name !== "sessions");
  if (name === "sessions") loadSessions();
}
document.querySelectorAll(".nav-item").forEach(b => b.onclick = () => switchView(b.dataset.view));
[...$("#rangeChips").children].forEach(b => b.onclick = () => {
  [...$("#rangeChips").children].forEach(x => x.classList.remove("on"));
  b.classList.add("on"); state.range = b.dataset.range;
  refreshAll(); if (!$("#view-sessions").classList.contains("hidden")) loadSessions();
});
$("#yToggle").onclick = () => {
  state.logScale = !state.logScale;
  $("#yToggle").textContent = "Y 轴 · " + (state.logScale ? "对数" : "线性");
  loadDaily();
};
$("#scanBtn").onclick = startScan;

/* 表头排序 */
document.querySelectorAll("th.sortable").forEach(th => th.onclick = () => {
  const key = th.dataset.sort;
  if (state.sort.key === key) state.sort.dir *= -1;
  else state.sort = { key, dir: key === "ts" || key === "cost" ? -1 : 1 };
  renderSessions();
});

/* 抽屉 */
$("#drawerClose").onclick = closeDrawer;
$("#drawerMask").onclick = closeDrawer;

/* 快捷键：⌘1/⌘2 切视图 · ⌘R 扫描 · ⌘W 关闭面板 · Esc 关抽屉 */
document.addEventListener("keydown", e => {
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape") closeDrawer();
  else if (mod && e.key.toLowerCase() === "w") { e.preventDefault(); closeApp(); }
  else if (mod && e.key === "1") { e.preventDefault(); switchView("overview"); }
  else if (mod && e.key === "2") { e.preventDefault(); switchView("sessions"); }
  else if (mod && e.key.toLowerCase() === "r") { e.preventDefault(); startScan(); }
});

/* ─────────── 窗口控制（关闭 = 隐藏，进程留在状态栏；红绿灯为原生） ─────────── */
function closeApp() { const a = api(); a ? a.hide_main() : window.close(); }

/* 标题栏拖拽（JS 驱动 window.move，WebKit 无 -webkit-app-region） */
function initDrag(getPos, moveWin) {
  let d = null;
  document.addEventListener("mousedown", e => {
    if (!e.target.closest(".drag")) return;
    d = { sx: e.screenX, sy: e.screenY, ox: null, oy: null };
    getPos().then(([x, y]) => { if (d) { d.ox = x; d.oy = y; } });
    e.preventDefault();
  });
  document.addEventListener("mousemove", e => {
    if (!d || d.ox == null) return;
    moveWin(d.ox + e.screenX - d.sx, d.oy + e.screenY - d.sy);
  });
  document.addEventListener("mouseup", () => { d = null; });
}
if (api()) initDrag(() => api().get_main_pos(), (x, y) => api().move_main(x, y));

/* ─────────── 骨架屏 ─────────── */
function showSkeletons() {
  $("#statCards").innerHTML = '<div class="sk sk-card"></div>'.repeat(4);
  $("#quotaList").innerHTML = '<div class="sk sk-row"></div>'.repeat(4);
  $("#modelList").innerHTML = '<div class="sk sk-row"></div>'.repeat(5);
}

/* ─────────── 启动 ─────────── */
(async function boot() {
  showSkeletons();
  await loadDetect();
  buildFilterChips();
  await refreshAll();
  if (location.hash === "#sessions") switchView("sessions");   // 深链直达
  setInterval(pollScan, 4000);      // 扫描状态
  setInterval(refreshAll, 60000);   // 定时刷新（新日志入库后自动跟上）
})();
