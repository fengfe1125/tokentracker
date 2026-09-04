/* Execute the actual renderers with a minimal DOM sink; no npm/browser dependency. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');

function eventTarget() {
  const listeners = new Map();
  return {
    addEventListener(type, fn) {if (!listeners.has(type)) listeners.set(type, new Set()); listeners.get(type).add(fn);},
    removeEventListener(type, fn) {listeners.get(type)?.delete(fn);},
    dispatchEvent(e) {for (const fn of [...(listeners.get(e.type) || [])]) fn(e);},
  };
}

function harness(file, legacy = false, windowProps = {}) {
  const elements = new Map();
  function element(key) {
    if (!elements.has(key)) elements.set(key, {
      innerHTML: '', textContent: '', style: {}, dataset: {}, children: [], value: '',
      classList: {add() {}, remove() {}, toggle() {}, contains() {return false;}},
      querySelector(s) {return element(key + ' ' + s);},
      querySelectorAll() {return [];}, addEventListener() {},
    });
    return elements.get(key);
  }
  const document = {...eventTarget(), querySelector: element, getElementById: element, querySelectorAll: () => [], hidden: false};
  const sandbox = {document, console, Date, setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0,
    requestAnimationFrame: () => 0, cancelAnimationFrame() {}, matchMedia: () => ({matches: true}),
    performance: {now: () => 0}, localStorage: {getItem: () => null, setItem() {}}, location: {hash: ''},
    fetch: async () => ({ok: true, json: async () => ({})}),
    Chart: class {constructor(_, config) {Object.assign(this, config);} update() {} destroy() {}},
  };
  sandbox.window = {...eventTarget(), close() {}, ...windowProps};
  const context = vm.createContext(sandbox);
  let source = fs.readFileSync(path.join(root, file), 'utf8');
  if (legacy) source = source.match(/<script>\s*([\s\S]*?)<\/script>/)[1].replace(/loadAll\(\)\.catch\(e => \{ \$\("status"\)[\s\S]*?\}\);/, '');
  else source = source.slice(0, source.indexOf('(async function boot()'));
  vm.runInContext(source, context, {filename: file});
  return {run: code => vm.runInContext(code, context), element, context};
}

const attack = '\"><img src=x onerror=window.pwned=1><svg onload=window.pwned=2>';
const row = {tool: attack, model: attack, project: attack, session_id: attack, input: 1, output: 2,
  cache_read: 3, cache_write: 4, tokens: 10, events: 1, cost: 1, estimated_tokens: 2, unallocated_tokens: 3};
const quota = {id: attack, name: attack, plan: attack, note: attack, via: attack, source: 'official',
  windows: [{key: attack, label: attack, unit: 'requests', used: attack, limit: attack, pct: 50, resets_at: attack}]};
function assertEscaped(html) {
  assert.ok(!html.includes('<img src=x'), 'untrusted text reached an HTML element');
  assert.ok(!html.includes('"' + '><img'), 'untrusted text escaped an attribute');
  assert.ok(html.includes('&lt;img'), 'hostile text should remain readable as escaped text');
}

async function main() {
  await testWindowDrag();
  const desktop = harness('app/web/app.js');
  desktop.context.row = row; desktop.context.quota = quota;
  desktop.run('renderModels([row]); state.sessRows = [row]; renderSessions(); renderQuotas([quota]);');
  for (const id of ['#modelList', '#sessBody', '#quotaList']) assertEscaped(desktop.element(id).innerHTML);
  desktop.context.fetch = async () => ({ok: true, json: async () => ({...row, models: [row],
    observation_intervals: [{interval_start: 1700000000000, ts: 1700000060000, tokens: 2}]})});
  await desktop.run('openDrawer(row)');
  assertEscaped(desktop.element('#drawerBody').innerHTML);
  assert.ok(desktop.element('#drawerBody').innerHTML.includes('区间内具体发生时间未知'));
  assert.equal(desktop.run('relTime(null)'), '未分配到时间');
  assert.equal(desktop.run('relTime("bad date")'), '未知时间');
  assert.equal(desktop.run('dateTime(null)'), '未分配到时间');
  desktop.run('renderStatCards([row], {...row, sessions: 1, unallocated: {tokens: 3, cost: 1, events: 1}});');
  assert.equal(desktop.run('state.statPrev.tok'), 10, 'total must include all four token categories exactly once');
  assert.ok(desktop.element('#timeQuality').textContent.includes('未分配'));
  // 「亿」单位开关：≥1e8 换单位，关闭时保持 K/M/B
  assert.equal(desktop.run('fmtT(550000000)'), '550.00M');
  assert.equal(desktop.run('state.unitYi = true; fmtT(550000000)'), '5.50亿');
  assert.equal(desktop.run('fmtT(55000000)'), '0.55亿');   // 0.几亿
  assert.equal(desktop.run('fmtT(999999)'), '1000.0K');    // 不足 1M 保持原样
  assert.equal(desktop.run('state.unitYi = false; fmtT(550000000)'), '550.00M');
  // 启动时加载显示偏好：不进设置页也生效（曾因只在 loadSettings 里读而失效）
  desktop.context.fetch = async () => ({ok: true, json: async () => ({settings: {unit_yi: true}})});
  await desktop.run('loadDisplayPrefs()');
  assert.equal(desktop.run('state.unitYi'), true, 'boot 时 unit_yi 必须进入 state');
  // 范围提示：本周=最近 7 天滚动，hint 应写出实际区间消除「本周>本月」疑惑
  desktop.context.fetch = async () => ({ok: true, json: async () => ({
    rows: [], total: {}, bounds: [1757000000000, 1757600000000]})});
  desktop.run('state.range = "week"');
  await desktop.run('loadStats()');
  assert.ok(desktop.element('#rangeHint').textContent.includes('本周'), 'range hint 应标注本周');
  assert.ok(desktop.element('#rangeHint').textContent.includes('–'), 'range hint 应含起止日期');
  assert.equal(desktop.run('state.rangeHintText'), desktop.element('#rangeHint').textContent);
  desktop.context.fetch = async () => ({ok: true, json: async () => ({})});
  desktop.run('drawTrend([{tool: "claude", d: "2026-08-01", ...row, tool: "claude"}]);');
  assert.equal(desktop.run('state.chart.data.datasets[0].data[0]'), 10);
  assert.ok(desktop.element('#sessBody').innerHTML.includes('10'), 'session total is shown');

  // A completed automatic scan refreshes quotas once, without force=1.
  const requests = [];
  desktop.context.fetch = async url => {requests.push(url); return {ok: true, json: async () => url.includes('/scan/status') ? {running: false, last: {done: true, source: 'automatic', results: {}}} : {rows: [], total: {}, entries: []}};};
  desktop.run('state.scanning = true');
  await desktop.run('pollScan()');
  assert.deepEqual(requests.filter(u => u.startsWith('/api/quotas')), ['/api/quotas']);
  requests.length = 0;
  desktop.run('state.scanning = true; state.forceQuotaAfterScan = true');
  await desktop.run('pollScan()');
  assert.deepEqual(requests.filter(u => u.startsWith('/api/quotas')), ['/api/quotas?force=1']);
  requests.length = 0;
  desktop.run('state.scanning = true');
  await desktop.run('pollScan()');
  assert.deepEqual(requests.filter(u => u.startsWith('/api/quotas')), ['/api/quotas']);

  desktop.context.fetch = async url => ({ok:true,json:async()=>url.includes('/scan/status') ?
    {running:false,last:{done:true,results:{hermes:{added:1,counter_resets:1,warning:'无法映射旧历史'}}}} :
    {rows:[],total:{},entries:[]}});
  desktop.run('state.scanning = true');
  await desktop.run('pollScan()');
  assert.ok(desktop.element('#toast').textContent.includes('重置'));
  assert.ok(desktop.element('#toast').textContent.includes('无法映射旧历史'));

  const legacy = harness('web/index.html', true);
  legacy.context.row = row; legacy.context.quota = quota;
  legacy.run('renderModels({rows:[row]}); renderSessions({rows:[row]}); renderQuota({entries:[quota]}); renderDetect({[row.tool]:{installed:true}});');
  for (const id of ['modelTable tbody', 'sessionTable tbody', 'quota', 'toolSel']) assertEscaped(legacy.element(id).innerHTML);
  legacy.run('renderCards({total:{...row,sessions:1,unallocated:{tokens:3,cost:1,events:1}}}); renderDaily({rows:[{...row,tool:"claude",d:"2026-08-01"}],summary:{estimated_tokens:2,unallocated:{tokens:3}}});');
  assert.ok(legacy.element('cards').innerHTML.includes('10'));
  assert.ok(legacy.element('timeQuality').textContent.includes('未分配'));
  assert.equal(legacy.run('dailyChart.data.datasets[0].data[0]'), 10);
  const mixed = {id: 'kimi', name: 'Kimi', source: 'official', note: 'One official window is stale', windows: [
    {key: '5h', label: 'Fresh', source: 'official', stale: false, unit: 'pct', pct: 50},
    {key: '7d', label: 'Stale', source: 'official', stale: true, unit: 'pct', pct: 45},
    {key: 'month', label: 'Local', source: 'local', stale: false, unit: 'tokens', pct: 60,
      used: 60, limit: 100, unallocated: 99},
  ]};
  for (const [page, code, id] of [[desktop, 'renderQuotas([mixed])', '#quotaList'], [legacy, 'renderQuota({entries:[mixed]})', 'quota']]) {
    page.context.mixed = mixed;
    page.run(code);
    const html = page.element(id).innerHTML;
    // 新版把来源状态收敛为圆点（title 说明），旧版是文字徽章；标记与口径注释两版一致
    const staleLabel = page === desktop ? '官方数据过期' : '过期官方';
    for (const expected of [staleLabel, '本地估算', '~45%', '≈60%', '99 Token', '不包含在此窗口']) assert.ok(html.includes(expected), expected);
    assert.ok(!html.includes('~50%'), 'entry.note must not mark a fresh window stale');
  }
  console.log('frontend rendering, token totals, quality labels, scan refresh, and window drag regressions passed');
}

function dragRegion(interactive = false) {
  const captured = new Set();
  const region = {
    closest(selector) {return selector === '.drag' ? region : interactive ? region : null;},
    setPointerCapture(id) {captured.add(id);},
    hasPointerCapture(id) {return captured.has(id);},
    releasePointerCapture(id) {captured.delete(id);},
  };
  return region;
}
function pointer(page, type, target, extra = {}) {
  page.context.document.dispatchEvent({type, target, pointerId: 1, button: 0, buttons: 1,
    isPrimary: true, screenX: 100, screenY: 100, preventDefault() {}, ...extra});
}
async function settle() {for (let i = 0; i < 12; i++) await Promise.resolve();}

async function testWindowDrag() {
  for (const bridgeAtLoad of [true, false]) {
    let reads = 0;
    const moves = [];
    const bridge = {get_main_pos: async () => {reads++; return [10, 20];},
      move_main: async (x, y) => {moves.push([x, y]);}};
    const page = harness('app/web/app.js', false, bridgeAtLoad ? {pywebview: {api: bridge}} : {});
    page.context.window.pywebview = {api: bridge};
    page.context.window.dispatchEvent({type: 'pywebviewready'});
    page.context.window.dispatchEvent({type: 'pywebviewready'});
    const region = dragRegion();
    pointer(page, 'pointerdown', region);
    await settle();
    assert.equal(reads, 1, `drag binds once (bridgeAtLoad=${bridgeAtLoad})`);
    assert.ok(region.hasPointerCapture(1), 'drag keeps receiving events outside the titlebar/window');
    // WKWebView synthetic/native automation can omit the buttons bitmask;
    // captured pointerup/cancel/blur, not that mask, ends a gesture.
    pointer(page, 'pointermove', region, {screenX: 130, screenY: 140, buttons: 0});
    await settle();
    assert.deepEqual(moves.at(-1), [40, 60]);
    pointer(page, 'pointerup', region, {buttons: 0});
    assert.ok(!region.hasPointerCapture(1));
    const count = moves.length;
    pointer(page, 'pointermove', region, {screenX: 200});
    await settle();
    assert.equal(moves.length, count, 'released drag must not keep moving the window');
  }

  for (const ending of ['pointercancel', 'lostpointercapture', 'blur', 'hidden']) {
    const moves = [];
    const bridge = {get_main_pos: async () => [0, 0], move_main: async (...pos) => moves.push(pos)};
    const page = harness('app/web/app.js', false, {pywebview: {api: bridge}});
    const region = dragRegion();
    pointer(page, 'pointerdown', region);
    await settle();
    if (ending === 'blur') page.context.window.dispatchEvent({type: 'blur'});
    else if (ending === 'hidden') {
      page.context.document.hidden = true;
      page.context.document.dispatchEvent({type: 'visibilitychange'});
    } else pointer(page, ending, region);
    pointer(page, 'pointermove', region, {screenX: 200});
    await settle();
    assert.equal(moves.length, 0, ending);
    assert.ok(!region.hasPointerCapture(1), ending);
    // A following gesture works after every cancellation path.
    pointer(page, 'pointerdown', region);
    pointer(page, 'pointermove', region, {screenX: 120});
    await settle();
    assert.deepEqual(moves.at(-1), [20, 0], ending);
  }

  const origins = [], moves = [], releases = [];
  const page = harness('app/web/app.js', false, {pywebview: {api: {
    get_main_pos: () => new Promise(resolve => origins.push(resolve)),
    move_main: (...pos) => {moves.push(pos); return new Promise(resolve => releases.push(resolve));},
  }}});
  const region = dragRegion();
  pointer(page, 'pointerdown', dragRegion(true));
  pointer(page, 'pointerdown', region, {button: 2});
  await settle();
  assert.equal(origins.length, 0, 'interactive controls and non-left buttons do not start dragging');
  pointer(page, 'pointerdown', region);
  await settle();
  pointer(page, 'pointerup', region);
  pointer(page, 'pointerdown', region);
  await settle();
  origins[0]([999, 999]);
  pointer(page, 'pointermove', region, {screenX: 150});
  await settle();
  assert.equal(moves.length, 0, 'late origin from a completed gesture is ignored');
  origins[1]([300, 400]);
  await settle();
  assert.deepEqual(moves, [[350, 400]]);
  pointer(page, 'pointermove', region, {screenX: 160});
  pointer(page, 'pointermove', region, {screenX: 180});
  pointer(page, 'pointerup', region, {pointerId: 2});
  assert.ok(region.hasPointerCapture(1), 'unrelated pointer cannot end the drag');
  assert.equal(moves.length, 1, 'bridge moves are serialised');
  releases[0]();
  await settle();
  assert.deepEqual(moves.at(-1), [380, 400], 'pending moves coalesce to the latest position');
  pointer(page, 'pointerup', region);
  releases[1]();
  await settle();
  assert.equal(moves.length, 2);

  for (const failure of ['origin', 'move']) {
    const broken = harness('app/web/app.js', false, {pywebview: {api: {
      get_main_pos: async () => {if (failure === 'origin') throw Error('offline'); return [0, 0];},
      move_main: async () => {throw Error('closed');},
    }}});
    const target = dragRegion();
    pointer(broken, 'pointerdown', target);
    pointer(broken, 'pointermove', target, {screenX: 140});
    await settle();
    assert.ok(!target.hasPointerCapture(1), `bridge ${failure} failure cancels safely`);
  }
}
main().catch(e => {console.error(e); process.exitCode = 1;});
