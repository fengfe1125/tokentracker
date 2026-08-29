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
  go:       { name: "OpenCode Go", color: "#8b7bd8" },
};
const TOOL_ORDER = ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"];

const $ = (s, el = document) => el.querySelector(s);
const fmtT = n => { n = +n || 0;
  if (state.unitYi && n >= 1e8) return (n / 1e8).toFixed(2) + "亿";
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  if (n >= 1e4) return (n / 1e3).toFixed(1) + "K";
  if (n >= 1e3) return (n / 1e3).toFixed(2) + "K";
  return String(Math.round(n)); };
const fmtCost = n => { n = +n || 0; return "$" + (n >= 1000 ? (n / 1000).toFixed(2) + "K" : n.toFixed(2)); };

// All API/log strings are untrusted, including strings inside quoted attributes.
const esc = value => String(value ?? "").replace(/[&<>"']/g,
  c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
const tokensOf = row => Number((row || {}).tokens) || 0;
function qualityLabel(row) {
  const parts = [];
  if (row.unallocated_tokens) parts.push(fmtT(row.unallocated_tokens) + " Token 未分配到时间");
  if (row.estimated_tokens) parts.push(fmtT(row.estimated_tokens) + " Token 按观测时间估算");
  return parts.join(" · ");
}
function qualitySummary(summary, chart = false) {
  const s = summary || {}, u = s.unallocated || {};
  const parts = [];
  if (u.tokens || u.events) parts.push("未分配到时间：" + fmtT(u.tokens) + " Token / " +
    fmtCost(u.cost) + " / " + (Number(u.events) || 0) + " 事件（" +
    (chart ? "不绘入趋势，保留在全部历史" : state.range === "all" ? "已计入全部历史，不计入今天/本周/本月" : "不计入当前范围，保留在全部历史") + "）");
  if (s.estimated_tokens) parts.push("按观测时间估算：" + fmtT(s.estimated_tokens) + " Token（已计入" + (chart ? "趋势" : "当前总量") + "）");
  return parts.join("；");
}

const api = () => (window.pywebview && window.pywebview.api) || null;

function toast(msg, ms = 2600) {
  const t = $("#toast"); if (!t) return;
  t.textContent = msg; t.classList.add("show");
  clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove("show"), ms);
}

/* 数字滚动动画（easeOutCubic，自动打断同元素上一个动画） */
function animateNum(el, to, fmtFn, dur = 700) {
  if (!el) return;
  if (el._raf) cancelAnimationFrame(el._raf);
  const from = el._num || 0;
  el._num = to;
  if (matchMedia("(prefers-reduced-motion: reduce)").matches || from === to) {
    el.textContent = fmtFn(to); return;
  }
  const t0 = performance.now();
  const step = t => {
    const k = Math.min((t - t0) / dur, 1);
    const e = 1 - Math.pow(1 - k, 3);
    el.textContent = fmtFn(from + (to - from) * e);
    if (k < 1) el._raf = requestAnimationFrame(step);
  };
  el._raf = requestAnimationFrame(step);
}

/* ─────────── 状态 ─────────── */
const state = { range: "week", tool: null, chart: null, logScale: false,
                scanning: false, detected: null, sessRows: [],
                unitYi: false,
                sort: { key: "ts", dir: -1 },
                quotaPrev: {}, statPrev: {}, inFlight: 0, forceQuotaAfterScan: false };

/* ─────────── 顶部加载条 ─────────── */
function setLoading(on) {
  state.inFlight = Math.max(0, state.inFlight + (on ? 1 : -1));
  $("#loadbar").classList.toggle("run", state.inFlight > 0);
}

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
  animateNum($("#todayCost"), (d.total || {}).cost || 0, fmtCost, 500);
}
async function loadDaily() {
  const d = await jget("/api/daily?range=" + state.range);
  drawTrend(d.rows);
  $("#trendQuality").textContent = qualitySummary(d.summary, true);
}
async function loadQuotas(force) {
  const d = await jget("/api/quotas" + (force ? "?force=1" : ""));
  renderQuotas(d.entries || []);
}
async function loadModels() {
  const d = await jget("/api/models?range=" + state.range);
  renderModels(d.rows || []);
}
async function loadSessions() {
  const tool = state.tool ? "&tool=" + encodeURIComponent(state.tool) : "";
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
  const r = $(".tl-right");
  r.classList.remove("flash"); void r.offsetWidth; r.classList.add("flash");
}
async function refreshAll(forceQuota = false) {
  setLoading(true);
  try {
    await Promise.all([loadStats(), loadToday(), loadDaily(), loadQuotas(forceQuota), loadModels()]);
    if (!$("#view-sessions").classList.contains("hidden")) await loadSessions();
    stampUpdated();
  } catch (e) { console.warn(e); }
  finally { setLoading(false); }
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
  const tokAll = tokensOf(t);
  $("#timeQuality").textContent = qualitySummary(t);
  const cards = [
    { id: "tok",  ic: "tok",  k: "Token 总量", num: tokAll, fmt: fmtT,
      sub: "输入 " + fmtT(t.input) + " · 输出 " + fmtT(t.output) + " · 缓存读写均计入" },
    { id: "cost", ic: "cost", k: "成本估算", num: t.cost || 0, fmt: fmtCost,
      sub: (t.unpriced ? "⚠ " + t.unpriced + " 条未计价" : "按 prices.json 计价"), warn: !!t.unpriced },
    { id: "sess", ic: "sess", k: "会话数", num: t.sessions || 0, fmt: v => String(Math.round(v)),
      sub: rows.length + " 个工具当前有数据", go: "sessions" },
    { id: "cache", ic: "cache", k: "缓存读取", num: t.cache_read || 0, fmt: fmtT,
      sub: "写入 " + fmtT(t.cache_write || 0) },
  ];
  $("#statCards").innerHTML = cards.map((c, i) => `
    <div class="stat-card ${c.go ? "clickable" : ""}" style="--i:${i}"
      ${c.go ? `data-go="${c.go}" title="点击查看会话记录"` : ""}>
      <div class="ic ${c.ic}">${ICONS[c.ic]}</div>
      <div class="v" data-num="${c.id}">${c.fmt(state.statPrev[c.id] || 0)}</div>
      <div class="k">${c.k}</div>
      <div class="sub ${c.warn ? "warn" : ""}">${esc(c.sub)}</div>
    </div>`).join("");
  [...$("#statCards").children].forEach(el => {
    if (el.dataset.go) el.onclick = () => switchView(el.dataset.go);
  });
  // 数字滚动：从上次值滚到新值
  cards.forEach(c => {
    const el = $(`#statCards .v[data-num="${c.id}"]`);
    if (el) { el._num = state.statPrev[c.id] || 0; animateNum(el, c.num, c.fmt); }
    state.statPrev[c.id] = c.num;
  });
}

/* ─────────── 侧栏：工具数据源（点击 → 会话记录按该工具过滤） ─────────── */
function renderSideTools(rows) {
  const byTool = Object.create(null); (rows || []).forEach(r => byTool[r.tool] = r);
  const sorted = TOOL_ORDER.map(t => {
    const r = byTool[t] || null;
    return { tool: t, tok: tokensOf(r) };
  }).sort((a, b) => b.tok - a.tok);
  $("#sideTools").innerHTML = sorted.map((s, i) => {
    const meta = TOOL[s.tool] || { name: s.tool, color: "#aaa" };
    const inst = state.detected && state.detected[s.tool] ? state.detected[s.tool].installed : true;
    const label = s.tok > 0 ? fmtT(s.tok) : (inst ? "—" : "未检测到");
    return `<div class="side-tool ${!inst ? "miss" : ""} ${s.tok > 0 ? "live" : ""}"
      style="--i:${i}" data-tool="${s.tool}"
      title="${inst ? "查看 " + meta.name + " 的会话记录" : meta.name + " 未检测到数据源"}">
      <span class="dot" style="background:${meta.color}"></span>
      <span class="name">${esc(meta.name)}</span>
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

/* ─────────── 趋势图（原地更新，不再销毁重建，切换无闪烁） ─────────── */
function drawTrend(rows) {
  const byTool = Object.create(null), estimated = Object.create(null); const dates = new Set();
  (rows || []).forEach(r => {
    (byTool[r.tool] = byTool[r.tool] || {})[r.d] = tokensOf(r);
    (estimated[r.tool] = estimated[r.tool] || {})[r.d] = Number(r.estimated_tokens) || 0;
    dates.add(r.d);
  });
  // 今天：x 轴为 0 点到当前小时；其他范围：补齐首尾之间的空缺日期
  let xs;
  if (state.range === "day") {
    const nowH = new Date().getHours();
    xs = Array.from({ length: nowH + 1 }, (_, h) => String(h).padStart(2, "0") + ":00");
  } else {
    xs = [...dates].sort();
    if (xs.length > 1) {
      const full = [];
      const cur = new Date(xs[0] + "T00:00:00");
      const end = new Date(xs[xs.length - 1] + "T00:00:00");
      while (cur <= end) {
        full.push(cur.getFullYear() + "-" + String(cur.getMonth() + 1).padStart(2, "0") + "-" + String(cur.getDate()).padStart(2, "0"));
        cur.setDate(cur.getDate() + 1);
      }
      xs = full;
    }
  }

  // 保留用户手动隐藏的系列
  const prevHidden = {};
  if (state.chart) state.chart.data.datasets.forEach(d => prevHidden[d.label] = !!d.hidden);

  // 圆点策略（按系列）：非空点 ≤2 个时必须显示圆点（否则孤点完全不可见）；
  // 今天（24 小时粒度）显示小圆点；其它范围隐藏
  const datasets = TOOL_ORDER.filter(t => byTool[t]).map(t => {
    const data = xs.map(d => byTool[t][d] ?? null);
    const nonNull = data.filter(v => v != null).length;
    const pts = nonNull <= 2 ? 3.5 : (state.range === "day" ? 1.5 : 0);
    return {
      label: TOOL[t].name, data, estimated: xs.map(d => estimated[t][d] || 0),
      borderColor: TOOL[t].color, backgroundColor: TOOL[t].color,
      borderWidth: 1.8, tension: .35,
      pointRadius: pts, pointHitRadius: 14,
      pointHoverRadius: 4, pointHoverBackgroundColor: TOOL[t].color,
      spanGaps: true, hidden: !!prevHidden[TOOL[t].name],
    };
  });

  // Y 轴：手动切换过就记住（localStorage）；否则极值比悬殊自动用对数，
  // 免得某天尖峰（如 168M）把其它线全部压平到轴上
  const manual = localStorage.getItem("tt.yscale");
  if (manual) {
    state.logScale = manual === "log";
  } else {
    const vals = datasets.flatMap(d => d.data).filter(v => v > 0).sort((a, b) => b - a);
    state.logScale = vals.length > 1 && vals[0] / vals[vals.length - 1] > 30;
  }
  $("#yToggle").textContent = "Y 轴 · " + (state.logScale ? "对数" : "线性");

  if (!state.chart) {
    state.chart = new Chart($("#trendChart"), {
      type: "line",
      data: { labels: xs, datasets },
      options: {
        responsive: true, maintainAspectRatio: false,
        animation: { duration: 700, easing: "easeOutQuart" },
        interaction: { mode: "index", intersect: false },
        plugins: { legend: { display: false }, tooltip: {
          backgroundColor: "rgba(30,27,23,.92)", padding: 10, cornerRadius: 8,
          displayColors: true, boxWidth: 8, boxHeight: 8, usePointStyle: true,
          callbacks: { label: c => " " + c.dataset.label + "： " + fmtT(c.parsed.y) +
            (c.dataset.estimated[c.dataIndex] ? "（含 " + fmtT(c.dataset.estimated[c.dataIndex]) + " 按观测时间估算）" : "") } } },
        scales: {
          x: { grid: { display: false }, ticks: { color: "#a8a49c", maxTicksLimit: 8, font: { size: 10 } } },
          y: { type: state.logScale ? "logarithmic" : "linear", min: state.logScale ? 1 : undefined, grid: { color: "#f0efec" },
               border: { display: false },
               ticks: { color: "#a8a49c", font: { size: 10 },
                         callback: v => (+v >= 1000 ? fmtT(v) : v) } },
        },
      },
    });
  } else {
    state.chart.data.labels = xs;
    state.chart.data.datasets = datasets;
    state.chart.options.scales.y.type = state.logScale ? "logarithmic" : "linear";
    state.chart.options.scales.y.min = state.logScale ? 1 : undefined;
    state.chart.update();
  }
  buildLegend();
}
function buildLegend() {
  const ds = state.chart ? state.chart.data.datasets : [];
  $("#chartLegend").innerHTML = ds.map((d, i) => `
    <button data-i="${i}" class="${d.hidden ? "hidden" : ""}">
      <span class="sw" style="background:${d.borderColor}"></span>${d.label}</button>`).join("");
  [...$("#chartLegend").children].forEach(b => b.onclick = () => {
    const d = state.chart.data.datasets[+b.dataset.i];
    d.hidden = !d.hidden; b.classList.toggle("hidden"); state.chart.update();
  });
}

/* ─────────── 配额（进度条从旧值平滑滚动到新值） ─────────── */
/* 订阅配额：环形健康卡。品牌色圆环 = 最紧窗口，右侧窗口明细行。 */
function quotaUrgency(pct) {
  return pct == null ? "" : (pct < 50 ? "good" : (pct < 80 ? "mid" : "bad"));
}

function renderQuotas(entries) {
  if (!entries.length) { $("#quotaList").innerHTML = '<div class="quota-empty">未配置配额</div>'; return; }
  $("#quotaList").innerHTML = entries.map((e, i) => {
    const brand = (TOOL[e.id] || {}).color || "#a8a49c";
    const wins = e.windows || [];
    const tight = wins.reduce((a, w) => (w.pct != null && (a == null || w.pct > a.pct) ? w : a), null);
    const tpct = tight ? Math.max(0, Math.min(100, +tight.pct || 0)) : null;
    const srcLabel = e.source === "official" ? (tight && tight.stale ? "过期官方" : "官方") : "本地估算";
    const srcCls = e.source === "official" ? (tight && tight.stale ? "stale" : "official") : "local";
    const urg = quotaUrgency(tpct);
    return `
    <div class="quota-item ${urg === "bad" ? "crit" : ""}" style="--i:${i};--brand:${brand};--state:var(--${urg === "bad" ? "red" : urg === "mid" ? "amber" : "green"})">
      <div class="q-ring" data-qring="${esc(e.id)}" data-pct="${tpct ?? 0}"
           title="最紧窗口：${esc(tight ? tight.label + (tpct != null ? " " + tpct + "%" : "") : "无数据")}">
        <svg viewBox="0 0 48 48" aria-hidden="true">
          <circle class="track" cx="24" cy="24" r="20"></circle>
          <circle class="fill" cx="24" cy="24" r="20"></circle>
        </svg>
        <b class="q-pct">${tpct == null ? "—" : tpct + "%"}</b>
      </div>
      <div class="q-body">
        <div class="q-head">
          <span class="q-name">${esc(e.name)}</span>
          <span class="q-plan" title="${esc(e.plan || "")}">${esc(e.plan || "")}</span>
          <span class="q-src ${srcCls}"><i></i>${srcLabel}</span>
        </div>
        <div class="q-wins">${wins.map(w => winRow(e.id, w, w === tight)).join("")}</div>
        ${e.note ? `<div class="q-note">⚠ ${esc(e.note)}</div>` : ""}
      </div>
    </div>`;
  }).join("");
  // 动画：圆环从旧值滚到新值（首次从空环涨起），数字滚动，进度条沿用旧值过渡
  requestAnimationFrame(() => {
    const C = 2 * Math.PI * 20;
    document.querySelectorAll("#quotaList .q-ring").forEach(el => {
      const k = "ring:" + el.dataset.qring, pct = +el.dataset.pct || 0;
      const fill = el.querySelector(".fill");
      fill.style.strokeDasharray = C;
      const prev = state.quotaPrev[k];
      fill.style.transition = "none";
      fill.style.strokeDashoffset = C * (1 - (prev ?? 0) / 100);
      void fill.getBoundingClientRect();
      fill.style.transition = "";
      fill.style.strokeDashoffset = C * (1 - pct / 100);
      state.quotaPrev[k] = pct;
      animateNum(el.querySelector(".q-pct"), pct, v => Math.round(v) + "%");
    });
    document.querySelectorAll("#quotaList .q-bar i").forEach(el => {
      const k = el.dataset.qk, pct = +el.dataset.pct || 0;
      const prev = state.quotaPrev[k];
      if (prev != null && prev !== pct) {
        el.style.transition = "none";
        el.style.width = prev + "%";
        void el.offsetWidth;                      // 强制回流，让 transition 重新生效
        el.style.transition = "";
      }
      el.style.width = pct + "%";
      state.quotaPrev[k] = pct;
    });
  });
}

function winRow(eid, w, tight) {
  const pct = w.pct == null ? null : Math.max(0, Math.min(Number(w.pct) || 0, 100));
  const official = w.source === "official";
  const prefix = official ? (w.stale ? "~" : "") : "≈";
  const cls = quotaUrgency(pct);
  const used = w.unit === "usd" ? fmtCost(w.used) : fmtT(w.used);
  const lim = w.unit === "usd" ? fmtCost(w.limit) : fmtT(w.limit);
  const pctTxt = pct == null ? "未设上限" : prefix + pct.toFixed(0) + "%";
  const unallocated = w.unit === "usd" ? fmtCost(w.unallocated) : fmtT(w.unallocated) + (w.unit === "requests" ? " 次" : " Token");
  const reset = w.resets_at ? countdown(w.resets_at) : "";
  const detail = w.unit === "requests" ? `${w.used} / ${w.limit} 次`
    : (w.used != null && w.limit != null ? `${used} / ${lim}` : "");
  const dotCls = official ? (w.stale ? "stale" : "official") : "local";
  const dotTitle = official ? (w.stale ? "官方数据过期" : "官方") : "本地估算";
  return `<div class="q-win ${tight ? "top" : ""}" ${detail ? `title="${esc(detail)}"` : ""}>
    <i class="w-dot ${dotCls}" title="${dotTitle}"></i>
    <span class="w-label">${esc(w.label)}</span>
    <div class="q-bar"><i class="${cls === "good" ? "" : cls}" data-qk="${esc(eid)}:${esc(w.key)}" data-pct="${pct ?? 0}" style="width:${pct ?? 0}%"></i></div>
    <b class="pct ${cls}">${pctTxt}</b>
    ${reset ? `<span class="reset">${reset} 重置</span>` : ""}
    ${!official && ((Number(w.unallocated) || 0) !== 0) ? `<div class="q-note">未分配用量：${unallocated}（不包含在此窗口）</div>` : ""}
  </div>`;
}
function countdown(ts) {
  const ms = typeof ts === "number" ? ts : new Date(ts).getTime();
  const diff = ms - Date.now();
  if (!(diff > 0)) return "";
  const h = Math.floor(diff / 3600e3), m = Math.floor((diff % 3600e3) / 60e3);
  if (h >= 24) { const d = Math.floor(h / 24); return d + " 天 " + (h % 24) + " 小时后"; }
  return h > 0 ? h + " 小时 " + m + " 分后" : Math.max(m, 1) + " 分后";
}

/* ─────────── 模型榜 ─────────── */
function renderModels(rows) {
  if (!rows.length) { $("#modelList").innerHTML = '<div class="model-empty">暂无数据</div>'; return; }
  const top = rows.slice(0, 10);
  const max = Math.max(...top.map(tokensOf), 1);
  $("#modelList").innerHTML = top.map((r, i) => {
    const meta = TOOL[r.tool] || { name: r.tool, color: "#aaa" };
    const tok = tokensOf(r);
    return `<div class="model-row" style="--i:${i}">
      <span class="rank">#${i + 1}</span>
      <span class="m-name" title="${esc(r.model || "(未知模型)")}">${esc(r.model || "(未知模型)")}</span>
      <span class="m-tool"><span class="dot" style="background:${meta.color}"></span>${esc(meta.name)}</span>
      <span class="m-tok" title="${esc(qualityLabel(r))}">${fmtT(tok)} Token${qualityLabel(r) ? " *" : ""}</span>
      <span class="m-cost">${r.cost == null ? "—" : fmtCost(r.cost)}</span>
      <div class="m-bar-track"><i data-w="${(tok / max * 100).toFixed(1)}" style="width:0%"></i></div>
    </div>`;
  }).join("");
  requestAnimationFrame(() => {
    document.querySelectorAll("#modelList .m-bar-track i").forEach(el => {
      el.style.width = el.dataset.w + "%";
    });
  });
}

/* ─────────── 会话（可排序、可点开详情） ─────────── */
function sortedRows() {
  const { key, dir } = state.sort;
  const val = r => key === "cost" ? (r.cost || 0)
    : key === "tool" ? (TOOL[r.tool] ? TOOL[r.tool].name : r.tool)
    : (r[key] ?? "");
  return [...state.sessRows].sort((a, b) => {
    if (key === "ts" && (a.ts == null || b.ts == null)) {
      return a.ts == null ? (b.ts == null ? 0 : 1) : -1;
    }
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
    return `<tr data-i="${i}" style="--i:${Math.min(i, 14)}" title="点击查看会话详情">
      <td><span class="tool-cell"><span class="dot" style="background:${meta.color}"></span>${esc(meta.name)}</span></td>
      <td class="proj" title="${esc(r.project || r.session_id || "")}">${esc(r.project || (r.session_id || "—").slice(0, 26))}</td>
      <td class="model-cell" title="${esc(r.model || "")}">${esc(r.model || "—")}</td>
      <td class="when" title="${esc(qualityLabel(r))}">${relTime(r.last_seen)}${qualityLabel(r) ? " *" : ""}</td>
      <td class="num">${fmtT(tokensOf(r))}</td>
      <td class="num">${fmtT(r.input)}</td>
      <td class="num">${fmtT(r.output)}</td>
      <td class="num">${fmtT(r.cache_read)}</td>
      <td class="num">${fmtT(r.cache_write)}</td>
      <td class="num cost-cell">${r.cost == null ? "—" : fmtCost(r.cost)}</td>
      <td class="num">${esc(r.events)}</td>
      <td class="act"><button class="row-resume" data-i="${i}" title="在终端继续此会话">▶</button></td>
    </tr>`;
  }).join("");
  [...$("#sessBody").children].forEach(el => {
    el.onclick = () => {
      const r = sortedRows()[+el.dataset.i];
      if (r) openDrawer(r);
    };
  });
  document.querySelectorAll(".row-resume").forEach(btn => btn.onclick = e => {
    e.stopPropagation();
    const r = sortedRows()[+btn.dataset.i];
    if (r) quickResume(r);
  });
  // 表头排序箭头
  document.querySelectorAll("th.sortable").forEach(th => {
    const on = th.dataset.sort === state.sort.key;
    th.innerHTML = th.innerHTML.replace(/<span class="arr">.*?<\/span>/, "");
    if (on) th.innerHTML += `<span class="arr">${state.sort.dir < 0 ? "▼" : "▲"}</span>`;
  });
}
function relTime(s) {
  if (!s) return "未分配到时间";
  const p = String(s).split(/[- :]/).map(Number);
  const t = new Date(p[0], p[1] - 1, p[2], p[3] || 0, p[4] || 0, p[5] || 0);
  if (!Number.isFinite(t.getTime())) return "未知时间";
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
function dateTime(ts) {
  if (ts == null) return "未分配到时间";
  const d = new Date(Number(ts));
  return Number.isFinite(d.getTime()) ? d.toLocaleString("zh-CN") : "未知时间";
}

/* ─────────── 会话详情抽屉 ─────────── */
function closeDrawer() {
  $("#drawer").classList.remove("show");
  $("#drawerMask").classList.remove("show");
}

/* 「继续会话」可用性：命令在服务端生成（浏览器模式也能拿到），打开终端只有桌面桥能做 */
async function resumeInfo(r) {
  try {
    const resp = await fetch("/api/resume?tool=" + encodeURIComponent(r.tool) +
      "&session_id=" + encodeURIComponent(r.session_id || "") +
      "&project=" + encodeURIComponent(r.project || ""));
    return await resp.json();
  } catch (e) { return { ok: false, reason: "服务未就绪", command: "" }; }
}

async function copyResumeCmd(r, cmd) {
  if (!cmd) return;
  try { await navigator.clipboard.writeText(cmd); toast("✓ 命令已复制，到终端粘贴执行"); }
  catch (e) {
    const a = api();
    if (a && typeof a.copy_resume_command === "function") {
      await a.copy_resume_command(r.tool, r.session_id || "", r.project || "");
      toast("✓ 命令已复制，到终端粘贴执行");
    } else toast("复制失败，请手动复制：" + cmd, 6000);
  }
}

/* 行内 ▶：可直接恢复就一键开终端，否则打开抽屉看原因 / 选目录 / 复制命令 */
async function quickResume(r) {
  const bridge = api();
  const canLaunch = !!(bridge && typeof bridge.resume_session === "function");
  const info = await resumeInfo(r);
  if (info.ok && !info.cwd_missing && canLaunch) {
    const res = await bridge.resume_session(r.tool, r.session_id || "", r.project || "", "");
    toast(res.ok ? "✓ 已在终端中恢复会话" : (res.reason || "终端打开失败"), 4000);
  } else if (info.ok && info.command && !canLaunch) {
    copyResumeCmd(r, info.command);   // 浏览器模式降级为复制命令
  } else {
    openDrawer(r);
  }
}

async function setupDrawerResume(r) {
  const resumeBtn = $("#dResume"), copyBtn = $("#dCopyCmd");
  if (!resumeBtn || !copyBtn) return;
  const info = await resumeInfo(r);
  const bridge = api();
  const canLaunch = !!(bridge && typeof bridge.resume_session === "function");
  if (info.ok && info.command) {
    copyBtn.disabled = false;
    copyBtn.title = info.command;
    if (canLaunch) {
      resumeBtn.disabled = false;
      resumeBtn.title = info.command;
      if (info.cwd_missing) resumeBtn.textContent = "▶ 选择目录并继续…";
    } else {
      resumeBtn.title = "直接打开终端仅桌面 App 支持，可用「复制命令」";
    }
  } else {
    resumeBtn.textContent = "▶ " + (info.reason || "不可恢复");
    resumeBtn.title = info.reason || "";
  }
  resumeBtn.onclick = async () => {
    if (resumeBtn.disabled || !canLaunch) return;
    let cwd = "";
    if (info.cwd_missing) {
      cwd = await bridge.pick_resume_directory();
      if (!cwd) return;   // 用户取消
    }
    const res = await bridge.resume_session(r.tool, r.session_id || "", r.project || "", cwd);
    toast(res.ok ? "✓ 已在终端中恢复会话" : (res.reason || "终端打开失败"), 4000);
  };
  copyBtn.onclick = () => copyResumeCmd(r, info.command || "");
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
  const intervals = d.observation_intervals || [];
  const intervalRows = intervals.slice(-20).map(v => `<li>${esc(dateTime(v.interval_start))} → ${esc(dateTime(v.ts))}：${fmtT(tokensOf(v))} Token</li>`).join("");
  const modelRows = (d.models || []).map((m, i) => `
      <div class="d-model" style="--i:${i + 3}">
        <span class="m-name" title="${esc(m.model || "(未知模型)")}">${esc(m.model || "(未知模型)")}</span>
        <span class="m-cost">${fmtCost(m.cost)}</span>
        <span class="m-io">总计 ${fmtT(tokensOf(m))} · 入 ${fmtT(m.input)} · 出 ${fmtT(m.output)} · 缓存读 ${fmtT(m.cache_read)} · 缓存写 ${fmtT(m.cache_write)} · ${esc(m.events)} 事件</span>
      </div>`).join("") || '<div class="drawer-loading">无明细数据</div>';
  $("#drawerBody").innerHTML = `
    <div class="d-cards" style="--i:0">
      <div class="d-stat"><div class="v">${tokens == null ? "—" : fmtT(tokens)}</div><div class="k">Token（含缓存读写）</div></div>
      <div class="d-stat"><div class="v">${fmtCost(d.cost)}</div><div class="k">成本估算</div></div>
      <div class="d-stat"><div class="v">${esc(d.events ?? "—")}</div><div class="k">事件数</div></div>
      <div class="d-stat"><div class="v">${(d.models || []).length}</div><div class="k">模型数</div></div>
    </div>
    <div class="d-actions" style="--i:1">
      <button class="d-open-btn primary" id="dResume" disabled>▶ 继续会话</button>
      <button class="d-open-btn" id="dCopyCmd" disabled title="">复制命令</button>
    </div>
    ${proj ? `<button class="d-open-btn" id="dOpenFinder" style="--i:1">
      <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
      在 Finder 中打开项目</button>` : ""}
    <p class="time-quality">会话全部历史${qualityLabel(d) ? " · " + esc(qualityLabel(d)) : ""}</p>
    ${intervalRows ? `<div class="time-quality">观察区间（最近 ${Math.min(intervals.length, 20)} / ${intervals.length} 个，区间内具体发生时间未知）<ul>${intervalRows}</ul></div>` : ""}
    <div class="d-sec" style="--i:2">按模型分解</div>
    ${modelRows}
  `;
  const btn = $("#dOpenFinder");
  if (btn) btn.onclick = async () => {
    const a = api();
    const ok = a ? await a.open_in_finder(proj) : false;
    toast(ok ? "已在 Finder 中打开" : "路径不存在：" + proj);
  };
  setupDrawerResume(r);
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
  try {
    const response = await fetch("/api/scan", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    if (!response.ok && response.status !== 409) throw new Error("scan request failed");
    // Only a user-initiated accepted scan bypasses the quota cache once.
    state.forceQuotaAfterScan = response.ok;
  }
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
        const warnings = Object.values(r).flatMap(x => [
          x.counter_resets ? x.counter_resets + " 个累计计数器重置，已更新基线" : "", x.warning || ""
        ]).filter(Boolean);
        toast("✓ 扫描完成 · 新增 " + added + " 条事件" +
          (warnings.length ? "；" + warnings.join("；") : ""), warnings.length ? 7000 : 2600);
      }
      const forceQuota = state.forceQuotaAfterScan;
      state.forceQuotaAfterScan = false;
      await refreshAll(forceQuota);
    } else if (!s.running) { setScanning(false); }
  } catch (e) { /* 服务未就绪时忽略 */ }
}

/* ─────────── 设置 ─────────── */
async function loadSettings() {
  try {
    const r = await fetch("/api/settings");
    const d = await r.json();
    const s = d.settings || {};
    const sel = $("#setProvider");
    sel.innerHTML = "";
    for (const p of d.providers || []) {
      const o = document.createElement("option");
      o.value = p.id; o.textContent = "今日用量 + " + p.name;
      sel.appendChild(o);
    }
    const off = document.createElement("option");
    off.value = "off"; off.textContent = "仅今日用量";
    sel.appendChild(off);
    sel.value = s.menubar_provider || "off";
    if (sel.value !== (s.menubar_provider || "off")) sel.value = "off"; // 平台已下架时回退
    const termSel = $("#setTerminal");
    if (termSel) termSel.value = s.terminal_app || "auto";
    state.unitYi = !!s.unit_yi;
    $("#setUnitYi").checked = state.unitYi;
    $("#setCompact").checked = !!s.menubar_compact;
    $("#setRing").checked = s.menubar_ring !== false;
    $("#setLogin").checked = !!s.launch_at_login;
  } catch (e) { /* 服务未就绪时忽略 */ }
  const bridge = api(), loginInput = $("#setLogin"), hint = $("#loginHint");
  if (!bridge || typeof bridge.launch_at_login_supported !== "function") {
    loginInput.disabled = true;
    hint.textContent = "开机自启仅桌面 App 支持";
  } else {
    Promise.resolve(bridge.launch_at_login_supported()).then(ok => {
      loginInput.disabled = !ok;
      hint.textContent = ok ? "" : "开机自启仅打包后的 TokenTracker.app 支持";
    }).catch(() => { loginInput.disabled = true; });
  }
}

async function saveSetting(key, value) {
  try {
    const r = await fetch("/api/settings", { method: "POST",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify({ [key]: value }) });
    if (!r.ok) {
      const d = await r.json().catch(() => ({}));
      toast("保存失败：" + (d.error || r.status));
      loadSettings();   // 回滚到实际值
      return;
    }
    toast("✓ 已保存 · 状态栏 5 秒内生效");
  } catch (e) { toast("保存失败：服务未就绪"); }
}

$("#setProvider").onchange = e => saveSetting("menubar_provider", e.target.value);
$("#setCompact").onchange = e => saveSetting("menubar_compact", e.target.checked);
$("#setRing").onchange = e => saveSetting("menubar_ring", e.target.checked);
$("#setLogin").onchange = e => saveSetting("launch_at_login", e.target.checked);
$("#setTerminal").onchange = e => saveSetting("terminal_app", e.target.value);
$("#setUnitYi").onchange = e => {
  state.unitYi = e.target.checked;
  saveSetting("unit_yi", e.target.checked);
  refreshAll();                                   // 概览/图表即时换单位
  if (!$("#view-sessions").classList.contains("hidden")) renderSessions();
};
$("#openDataDir").onclick = () => {
  const a = api();
  if (a && typeof a.open_data_folder === "function") a.open_data_folder();
  else toast("数据目录：~/.tokentracker");
};
$("#openMenuBarSettings").onclick = () => {
  const a = api();
  if (a && typeof a.open_menubar_settings === "function") a.open_menubar_settings();
  else toast("系统设置 → 菜单栏 → 允许 TokenTracker");
};

/* ─────────── 事件绑定 ─────────── */
function switchView(name) {
  document.querySelectorAll(".nav-item").forEach(b => b.classList.toggle("active", b.dataset.view === name));
  $("#view-overview").classList.toggle("hidden", name !== "overview");
  $("#view-sessions").classList.toggle("hidden", name !== "sessions");
  $("#view-settings").classList.toggle("hidden", name !== "settings");
  if (name === "sessions") loadSessions();
  if (name === "settings") loadSettings();
}
document.querySelectorAll(".nav-item").forEach(b => b.onclick = () => switchView(b.dataset.view));

/* 时间范围 chips：滑动选中块 */
function moveRangeInk() {
  const ink = $("#rangeInk");
  const on = $("#rangeChips button.on");
  if (!ink || !on) return;
  ink.style.width = on.offsetWidth + "px";
  ink.style.transform = "translateX(" + on.offsetLeft + "px)";
  ink.classList.add("on");
}
document.querySelectorAll("#rangeChips button").forEach(b => b.onclick = () => {
  document.querySelectorAll("#rangeChips button").forEach(x => x.classList.remove("on"));
  b.classList.add("on"); state.range = b.dataset.range;
  moveRangeInk();
  refreshAll();
});
window.addEventListener("resize", moveRangeInk);

$("#yToggle").onclick = () => {
  state.logScale = !state.logScale;
  localStorage.setItem("tt.yscale", state.logScale ? "log" : "linear");
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

/* 快捷键：⌘1/⌘2 切视图 · ⌘, 设置 · ⌘R 扫描 · ⌘W 关闭面板 · Esc 关抽屉 */
document.addEventListener("keydown", e => {
  const mod = e.metaKey || e.ctrlKey;
  if (e.key === "Escape") closeDrawer();
  else if (mod && e.key.toLowerCase() === "w") { e.preventDefault(); closeApp(); }
  else if (mod && e.key === "1") { e.preventDefault(); switchView("overview"); }
  else if (mod && e.key === "2") { e.preventDefault(); switchView("sessions"); }
  else if (mod && e.key === ",") { e.preventDefault(); switchView("settings"); }
  else if (mod && e.key.toLowerCase() === "r") { e.preventDefault(); startScan(); }
});

/* 窗口重新聚焦时立刻刷新一次（从别的工具切回来就能看到最新数据） */
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refreshAll();
});

/* ─────────── 窗口控制（关闭 = 隐藏，进程留在状态栏；红绿灯为原生） ─────────── */
function closeApp() { const a = api(); a ? a.hide_main() : window.close(); }

/* 标题栏拖拽：桥接可晚于页面加载，指针捕获负责窗口外释放。 */
function initDrag(getPos, moveWin) {
  let d = null;
  let moving = false;
  function end(e) {
    if (!d || (e?.pointerId != null && e.pointerId !== d.id)) return;
    const old = d;
    d = null;
    if (old.region.hasPointerCapture(old.id)) old.region.releasePointerCapture(old.id);
  }
  function flushMove() {
    if (moving || !d?.origin || !d.delta) return;
    const current = d;
    const [dx, dy] = current.delta;
    current.delta = null;
    moving = true;
    // At most one bridge call in flight; coalesce later pointer positions.
    Promise.resolve().then(() => {
      if (d === current) return moveWin(current.origin[0] + dx, current.origin[1] + dy);
    }).catch(() => { if (d === current) end(); })
      .finally(() => { moving = false; flushMove(); });
  }
  document.addEventListener("pointerdown", e => {
    if (d || e.button !== 0 || e.isPrimary === false) return;
    const region = e.target.closest(".drag");
    if (!region || e.target.closest('button, a, input, select, textarea, [role="button"], [contenteditable], .tl-left')) return;
    const current = { id: e.pointerId, region, sx: e.screenX, sy: e.screenY, origin: null, delta: null };
    d = current;
    try { region.setPointerCapture(e.pointerId); } catch (_) { end(); return; }
    Promise.resolve().then(getPos).then(pos => {
      if (d !== current) return; // A prior gesture's delayed reply cannot initialise a new drag.
      if (!Array.isArray(pos) || pos.length !== 2 || !pos.every(Number.isFinite)) { end(); return; }
      current.origin = pos;
      flushMove();
    }).catch(() => { if (d === current) end(); });
    e.preventDefault();
  });
  document.addEventListener("pointermove", e => {
    if (!d || e.pointerId !== d.id) return;
    d.delta = [e.screenX - d.sx, e.screenY - d.sy];
    flushMove();
  });
  for (const event of ["pointerup", "pointercancel", "lostpointercapture"]) document.addEventListener(event, end);
  window.addEventListener("blur", () => end());
  document.addEventListener("visibilitychange", () => { if (document.hidden) end(); });
}
let dragReady = false;
function setupDrag() {
  const bridge = api();
  if (dragReady || typeof bridge?.get_main_pos !== "function" || typeof bridge?.move_main !== "function") return;
  dragReady = true;
  initDrag(() => bridge.get_main_pos(), (x, y) => bridge.move_main(x, y));
}
window.addEventListener("pywebviewready", setupDrag);
setupDrag();

/* ─────────── 骨架屏 ─────────── */
function showSkeletons() {
  $("#statCards").innerHTML = [0, 1, 2, 3].map(i =>
    `<div class="sk sk-card" style="--i:${i}"></div>`).join("");
  $("#quotaList").innerHTML = '<div class="sk sk-row"></div>'.repeat(4);
  $("#modelList").innerHTML = '<div class="sk sk-row"></div>'.repeat(5);
}

/* ─────────── 启动 ─────────── */
(async function boot() {
  showSkeletons();
  await loadDetect();
  buildFilterChips();
  await refreshAll();
  moveRangeInk();
  const deep = location.hash.slice(1);
  if (["overview", "sessions", "settings"].includes(deep)) switchView(deep);   // 深链直达
  setInterval(pollScan, 4000);      // 扫描状态
  setInterval(refreshAll, 60000);   // 定时刷新（新日志入库后自动跟上）
})();
