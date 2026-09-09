// validate.js —— public_stats v1 载荷校验。
//
// 这是隐私的**服务端兜底**：因为它拒绝任何未知字段，将来哪怕客户端出 bug
// 往载荷里塞了绝对路径或会话标题，也只会拿到 400，而不会被发到公网并进 CDN。
//
// 纯函数，无 I/O，Node 可直接 require 来跑测试。
// 只拒绝，不清洗 —— 被拒的发布会反馈给用户，被静默清洗的不会。

'use strict';

var MAX_BYTES = 65536;
var MAX_DAYS = 731;
var MAX_AGENTS = 16;
var AGENT_IDS = ['claude', 'codex', 'opencode', 'dsh', 'hermes', 'kimi', 'pi'];

var RE_DAY = /^\d{4}-\d{2}-\d{2}$/;
var RE_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
var RE_TZ = /^([A-Za-z_]+\/[A-Za-z_+\-]+(\/[A-Za-z_+\-]+)?|UTC)$/;
var RE_VER = /^[0-9]+\.[0-9]+(\.[0-9]+)?$/;

// 形状表：key -> 类型标记。缺一不可，多一个即拒。
var SHAPE = {
    v: 'int', generated_at: 'iso', tz: 'tz', tz_offset_minutes: 'tzoff',
    app_version: 'ver', range: 'obj', totals: 'obj', daily: 'obj',
    peak: 'obj?', streak: 'obj', longest_burst: 'obj?', agents: 'arr', caveats: 'obj'
};
var RANGE_KEYS  = { from: 'day', to: 'day', days: 'count' };
var TOTALS_KEYS = { tokens: 'nat', tokens_dated: 'nat', tokens_undated: 'nat',
                    cost_usd: 'money', cost_usd_undated: 'money', active_days: 'count' };
var DAILY_KEYS  = { start: 'day', tokens: 'natarr', window_tokens: 'nat' };
var PEAK_KEYS   = { day: 'day', tokens: 'nat' };
var STREAK_KEYS = { current: 'count', longest: 'count', as_of: 'day' };
var BURST_KEYS  = { seconds: 'nat', day: 'day', agent: 'agent',
                    gap_minutes: 'count', basis: 'basis' };
var AGENT_KEYS  = { id: 'agent', tokens: 'nat', cost_usd: 'money' };
// 'defer' = 键必须存在、不得是未知键，但值本身在下面单独查（数组类型 checkOne 管不了）
var CAVEAT_KEYS = { undated_share: 'ratio', snapshot_only_agents: 'defer' };

function isNat(v) { return typeof v === 'number' && Number.isSafeInteger(v) && v >= 0; }

// 形状对不代表日期存在：2026-13-45 能过正则。回环一次 Date.UTC 才算数。
function isRealDay(v) {
    if (typeof v !== 'string' || !RE_DAY.test(v)) return false;
    var y = +v.slice(0, 4), m = +v.slice(5, 7), d = +v.slice(8, 10);
    if (m < 1 || m > 12 || d < 1 || d > 31) return false;
    var t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}
function isMoney(v) { return typeof v === 'number' && isFinite(v) && v >= 0 && v <= 1e9; }

// __proto__ / constructor / prototype 作为键一律拒绝，避免原型污染。
function badKey(k) { return k === '__proto__' || k === 'constructor' || k === 'prototype'; }

function checkOne(kind, v, path) {
    switch (kind) {
    case 'int':   return Number.isSafeInteger(v) ? null : path + ' 必须是整数';
    case 'nat':   return isNat(v) ? null : path + ' 必须是非负安全整数';
    case 'count': return isNat(v) && v <= 100000 ? null : path + ' 越界';
    case 'money': return isMoney(v) ? null : path + ' 必须是 0..1e9 的数字';
    case 'ratio': return typeof v === 'number' && isFinite(v) && v >= 0 && v <= 1
                      ? null : path + ' 必须是 0..1 的比例';
    case 'day':   return isRealDay(v) ? null : path + ' 必须是真实存在的 YYYY-MM-DD 日期';
    case 'iso':   return typeof v === 'string' && RE_ISO.test(v) ? null : path + ' 必须是 ISO-8601 Z';
    case 'tz':    return typeof v === 'string' && v.length <= 64 && RE_TZ.test(v)
                      ? null : path + ' 时区名非法';
    case 'tzoff': return Number.isSafeInteger(v) && v >= -840 && v <= 840 ? null : path + ' 越界';
    case 'ver':   return typeof v === 'string' && v.length <= 16 && RE_VER.test(v)
                      ? null : path + ' 版本号非法';
    case 'agent': return typeof v === 'string' && AGENT_IDS.indexOf(v) >= 0
                      ? null : path + ' 不是已知的 CLI 工具';
    case 'basis': return v === 'exact' ? null : path + ' 只接受 "exact"';
    case 'defer': return null;
    default:      return path + ' 内部类型错误 ' + kind;
    }
}

// 严格对象：键集必须与 spec 完全一致，多一个少一个都拒。
function checkObj(o, spec, path) {
    if (o === null || typeof o !== 'object' || Array.isArray(o)) return path + ' 必须是对象';
    var keys = Object.keys(o), i, k;
    for (i = 0; i < keys.length; i++) {
        k = keys[i];
        if (badKey(k)) return path + ' 含被禁止的键 ' + k;
        if (!Object.prototype.hasOwnProperty.call(spec, k)) return path + ' 含未知字段 ' + k;
    }
    var want = Object.keys(spec);
    for (i = 0; i < want.length; i++) {
        if (!Object.prototype.hasOwnProperty.call(o, want[i])) return path + ' 缺少字段 ' + want[i];
        var err = checkOne(spec[want[i]], o[want[i]], path + '.' + want[i]);
        if (err) return err;
    }
    return null;
}

function validatePayload(p, nowMs) {
    var now = nowMs === undefined ? Date.now() : nowMs;
    if (p === null || typeof p !== 'object' || Array.isArray(p)) return { ok: false, error: '载荷必须是对象' };

    var keys = Object.keys(p), i, k, err;
    for (i = 0; i < keys.length; i++) {
        k = keys[i];
        if (badKey(k)) return { ok: false, error: '含被禁止的键 ' + k };
        if (!Object.prototype.hasOwnProperty.call(SHAPE, k)) return { ok: false, error: '含未知顶层字段 ' + k };
    }
    var want = Object.keys(SHAPE);
    for (i = 0; i < want.length; i++) {
        var optional = SHAPE[want[i]].slice(-1) === '?';
        if (!Object.prototype.hasOwnProperty.call(p, want[i])) {
            if (optional) continue;
            return { ok: false, error: '缺少顶层字段 ' + want[i] };
        }
    }

    if (p.v !== 1) return { ok: false, error: '不支持的格式版本 v=' + p.v };
    err = checkOne('iso', p.generated_at, 'generated_at')
       || checkOne('tz', p.tz, 'tz')
       || checkOne('tzoff', p.tz_offset_minutes, 'tz_offset_minutes')
       || checkOne('ver', p.app_version, 'app_version');
    if (err) return { ok: false, error: err };

    var gen = Date.parse(p.generated_at);
    if (!isFinite(gen)) return { ok: false, error: 'generated_at 无法解析' };
    if (Math.abs(gen - now) > 48 * 3600 * 1000) {
        return { ok: false, error: 'generated_at 偏离当前时间超过 48 小时' };
    }

    err = checkObj(p.range, RANGE_KEYS, 'range')
       || checkObj(p.totals, TOTALS_KEYS, 'totals')
       || checkObj(p.streak, STREAK_KEYS, 'streak')
       || checkObj(p.caveats, CAVEAT_KEYS, 'caveats');
    if (err) return { ok: false, error: err };

    // daily.tokens 单独查：checkObj 不认识数组元素
    if (p.daily === null || typeof p.daily !== 'object' || Array.isArray(p.daily)) {
        return { ok: false, error: 'daily 必须是对象' };
    }
    var dkeys = Object.keys(p.daily);
    for (i = 0; i < dkeys.length; i++) {
        if (badKey(dkeys[i])) return { ok: false, error: 'daily 含被禁止的键' };
        if (!Object.prototype.hasOwnProperty.call(DAILY_KEYS, dkeys[i])) {
            return { ok: false, error: 'daily 含未知字段 ' + dkeys[i] };
        }
    }
    if (dkeys.length !== 3) return { ok: false, error: 'daily 字段不全' };
    err = checkOne('day', p.daily.start, 'daily.start')
       || checkOne('nat', p.daily.window_tokens, 'daily.window_tokens');
    if (err) return { ok: false, error: err };
    if (!Array.isArray(p.daily.tokens)) return { ok: false, error: 'daily.tokens 必须是数组' };
    if (p.daily.tokens.length > MAX_DAYS) return { ok: false, error: 'daily.tokens 超过 ' + MAX_DAYS + ' 天' };
    var sum = 0;
    for (i = 0; i < p.daily.tokens.length; i++) {
        if (!isNat(p.daily.tokens[i])) return { ok: false, error: 'daily.tokens[' + i + '] 不是非负安全整数' };
        sum += p.daily.tokens[i];
    }
    if (p.daily.tokens.length !== p.range.days) {
        return { ok: false, error: 'daily.tokens 长度 ' + p.daily.tokens.length + ' 与 range.days ' + p.range.days + ' 不一致' };
    }
    if (sum !== p.daily.window_tokens) {
        return { ok: false, error: 'daily.tokens 之和 ' + sum + ' 与 window_tokens ' + p.daily.window_tokens + ' 不一致' };
    }
    if (p.daily.start !== p.range.from) return { ok: false, error: 'daily.start 与 range.from 不一致' };
    if (p.range.from > p.range.to) return { ok: false, error: 'range.from 晚于 range.to' };

    // 总量恒等式：这条不成立，公开页面就会出现无法解释的缺口
    if (p.totals.tokens_dated + p.totals.tokens_undated !== p.totals.tokens) {
        return { ok: false, error: 'totals: dated + undated 不等于 tokens' };
    }

    if (Object.prototype.hasOwnProperty.call(p, 'peak')) {
        err = checkObj(p.peak, PEAK_KEYS, 'peak');
        if (err) return { ok: false, error: err };
    }
    if (Object.prototype.hasOwnProperty.call(p, 'longest_burst')) {
        err = checkObj(p.longest_burst, BURST_KEYS, 'longest_burst');
        if (err) return { ok: false, error: err };
    }

    if (!Array.isArray(p.agents)) return { ok: false, error: 'agents 必须是数组' };
    if (p.agents.length > MAX_AGENTS) return { ok: false, error: 'agents 超过 ' + MAX_AGENTS + ' 项' };
    var seen = {};
    for (i = 0; i < p.agents.length; i++) {
        err = checkObj(p.agents[i], AGENT_KEYS, 'agents[' + i + ']');
        if (err) return { ok: false, error: err };
        if (seen[p.agents[i].id]) return { ok: false, error: 'agents 出现重复 id ' + p.agents[i].id };
        seen[p.agents[i].id] = 1;
    }

    if (!Array.isArray(p.caveats.snapshot_only_agents)) {
        return { ok: false, error: 'caveats.snapshot_only_agents 必须是数组' };
    }
    if (p.caveats.snapshot_only_agents.length > AGENT_IDS.length) {
        return { ok: false, error: 'caveats.snapshot_only_agents 过长' };
    }
    for (i = 0; i < p.caveats.snapshot_only_agents.length; i++) {
        err = checkOne('agent', p.caveats.snapshot_only_agents[i], 'caveats.snapshot_only_agents[' + i + ']');
        if (err) return { ok: false, error: err };
    }
    return { ok: true };
}

export { validatePayload, MAX_BYTES, MAX_DAYS, AGENT_IDS };
