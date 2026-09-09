// tests/test_web.js —— 零依赖的 Web 侧回归（Node 22，无 npm install）。
//
// 沿用已退役的 tests/test_frontend.js 的路子：手搓断言、不引框架。
// 最关键的一条是校验器必须对着**与 Swift 测试同一份 golden fixture** 做断言 ——
// 这种跨语言契约检查只有加 Node 步骤才做得到。

'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const ROOT = path.join(__dirname, '..');
const FIXTURE = path.join(ROOT, 'swift/Tests/TokenTrackerCoreTests/Fixtures/public_stats_v1.json');

let passed = 0;
function ok(name, cond, detail) {
    if (cond) { passed++; return; }
    console.error('❌ ' + name + (detail ? '  → ' + detail : ''));
    process.exitCode = 1;
}

function clone(o) { return JSON.parse(JSON.stringify(o)); }

(async function main() {
    const { validatePayload, AGENT_IDS } =
        await import(pathToFileURL(path.join(ROOT, 'web/worker/src/validate.js')).href);

    const golden = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    // fixture 是真实导出，generated_at 会随时间漂出 ±48h 窗口，用它自己的时间当"现在"
    const NOW = Date.parse(golden.generated_at);

    // ---- 1. 必须接受 golden fixture ----
    const base = validatePayload(golden, NOW);
    ok('接受 golden fixture', base.ok, base.error);

    // ---- 2. 必须拒绝的变异 ----
    const mutations = [
        ['未知顶层字段', p => { p.project = '/Users/sakura/secret'; }],
        ['未知嵌套字段', p => { p.totals.hostname = 'sakura-mbp'; }],
        ['constructor 作键', p => { p.totals.constructor = 1; }],
        ['不支持的版本', p => { p.v = 2; }],
        ['缺少顶层字段', p => { delete p.streak; }],
        ['daily 长度与 range.days 不符', p => { p.daily.tokens.pop(); }],
        ['daily 出现负数', p => { p.daily.tokens[0] = -1; }],
        ['daily 出现浮点', p => { p.daily.tokens[0] += 0.5; }],
        ['window_tokens 对不上', p => { p.daily.window_tokens += 1; }],
        ['daily 超过 731 天', p => { p.daily.tokens = new Array(800).fill(0); p.range.days = 800; }],
        ['总量恒等式被破坏', p => { p.totals.tokens_undated += 1; }],
        ['未知 agent id', p => { p.agents[0].id = 'chatgpt'; }],
        ['重复 agent id', p => { p.agents[1].id = p.agents[0].id; }],
        ['agents 超过 16 项', p => { while (p.agents.length <= 17) p.agents.push(clone(p.agents[0])); }],
        ['tz 含换行', p => { p.tz = 'Asia/Shanghai\nX-Injected: 1'; }],
        ['非法日期 2026-13-45', p => { p.peak.day = '2026-13-45'; }],
        ['generated_at 偏离一年', p => { p.generated_at = '2027-09-09T08:00:00Z'; }],
        ['basis 不是 exact', p => { p.longest_burst.basis = 'observed'; }],
        ['成本为负', p => { p.totals.cost_usd = -1; }],
        ['undated_share 越界', p => { p.caveats.undated_share = 1.5; }],
        ['daily.start 与 range.from 不一致', p => { p.daily.start = '2020-01-01'; }],
        ['agents 不是数组', p => { p.agents = { claude: 1 }; }],
        ['snapshot_only_agents 不是数组', p => { p.caveats.snapshot_only_agents = 'opencode'; }],
        ['snapshot_only_agents 含未知工具', p => { p.caveats.snapshot_only_agents = ['chatgpt']; }],
    ];
    for (const [name, mutate] of mutations) {
        const p = clone(golden);
        mutate(p);
        const r = validatePayload(p, NOW);
        ok('拒绝：' + name, r.ok === false, '竟然被接受了');
    }
    // __proto__ 必须经 JSON.parse 构造：直接赋值只会改原型，不产生自有属性
    const protoRaw = JSON.stringify(golden).replace('{"agents"', '{"__proto__":{"x":1},"agents"');
    ok('拒绝：__proto__ 作为自有键',
       validatePayload(JSON.parse(protoRaw), NOW).ok === false);
    ok('  （前提）该键确实是自有属性',
       Object.prototype.hasOwnProperty.call(JSON.parse(protoRaw), '__proto__'));

    // 更多不存在的日期
    for (const bad of ['2026-02-30', '2026-00-10', '2026-13-01', '2025-02-29']) {
        const p = clone(golden); p.peak.day = bad;
        ok('拒绝：不存在的日期 ' + bad, validatePayload(p, NOW).ok === false);
    }
    { const p = clone(golden); p.peak.day = '2028-02-29';
      ok('接受：闰年 2028-02-29', validatePayload(p, NOW).ok); }

    ok('拒绝：载荷是数组', validatePayload([], NOW).ok === false);
    ok('拒绝：载荷是 null', validatePayload(null, NOW).ok === false);
    ok('拒绝：载荷是字符串', validatePayload('{}', NOW).ok === false);

    // ---- 3. 可选键缺席必须被接受（Swift 合成编码器对 nil 是省略键，不是 null）----
    const noOpt = clone(golden);
    delete noOpt.peak; delete noOpt.longest_burst;
    ok('接受：peak / longest_burst 缺席', validatePayload(noOpt, NOW).ok,
       validatePayload(noOpt, NOW).error);
    const nullOpt = clone(golden);
    nullOpt.peak = null;
    ok('拒绝：peak 显式为 null', validatePayload(nullOpt, NOW).ok === false);

    // ---- 4. golden fixture 本身不得含敏感内容 ----
    const raw = fs.readFileSync(FIXTURE, 'utf8');
    for (const needle of ['/Users/', 'session_id', 'project', 'src_key', 'title', '.jsonl']) {
        ok('golden 不含 ' + needle, raw.indexOf(needle) === -1);
    }
    ok('golden 顶层键在白名单内', Object.keys(golden).every(k => [
        'v', 'generated_at', 'tz', 'tz_offset_minutes', 'app_version', 'range', 'totals',
        'daily', 'peak', 'streak', 'longest_burst', 'agents', 'caveats'].includes(k)));
    ok('golden 的 agent id 全部合法',
       golden.agents.every(a => AGENT_IDS.includes(a.id)));

    console.log(process.exitCode ? `\n有断言失败（通过 ${passed} 条）` : `✅ 全部通过，共 ${passed} 条断言`);
})();
