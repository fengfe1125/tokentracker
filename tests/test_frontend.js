/* Execute the actual renderers with a minimal DOM sink; no npm/browser dependency. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');

function harness(file, legacy = false) {
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
  const document = {querySelector: element, getElementById: element, querySelectorAll: () => [], addEventListener() {}, hidden: false};
  const sandbox = {document, console, Date, setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0,
    requestAnimationFrame: () => 0, cancelAnimationFrame() {}, matchMedia: () => ({matches: true}),
    performance: {now: () => 0}, localStorage: {getItem: () => null, setItem() {}}, location: {hash: ''},
    fetch: async () => ({ok: true, json: async () => ({})}),
    Chart: class {constructor(_, config) {Object.assign(this, config);} update() {} destroy() {}},
  };
  sandbox.window = {addEventListener() {}, close() {}};
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
    for (const expected of ['过期官方', '本地估算', '~45%', '≈60%', '99 Token', '不包含在此窗口']) assert.ok(html.includes(expected), expected);
    assert.ok(!html.includes('~50%'), 'entry.note must not mark a fresh window stale');
  }
  console.log('frontend rendering, token totals, quality labels, and scan refresh regressions passed');
}
main().catch(e => {console.error(e); process.exitCode = 1;});
