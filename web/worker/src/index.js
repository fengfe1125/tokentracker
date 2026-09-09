// tokentracker-stats —— 接收本机 TokenTracker 上报的公开统计，并对外提供只读 JSON。
//
// 安全边界：
//   · 写入需 Bearer token，落库只存 SHA-256，比对走常量时间。
//   · PUT 上**刻意不给任何 CORS 头** —— 浏览器因此无法被诱导带 token 发跨站写请求。
//   · 读接口 Access-Control-Allow-Origin: *，但永不带 Allow-Credentials。
//   · 载荷经 validate.js 白名单校验，未知字段一律 400（隐私的服务端兜底）。
//   · 「从未注册」与「已注册未发布」返回完全相同的 404，杜绝 handle 枚举。

import { validatePayload, MAX_BYTES } from './validate.js';

const HANDLE_RE = /^[a-z0-9][a-z0-9-]{1,30}$/;
const RESERVED = new Set(['api', 'admin', 'www', 'new', 'register', 'health', 'healthz',
                          'widget', 'docs', 'embed', 'v1', 'stats', 'me', '_']);
// 服务端下限比客户端的 15 分钟更紧：行为异常的客户端在边缘就被挡住。
const MIN_PUSH_INTERVAL_MS = 10 * 60 * 1000;

const enc = new TextEncoder();

async function sha256Hex(text) {
    const buf = await crypto.subtle.digest('SHA-256', enc.encode(text));
    return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// 常量时间比较：绝不用 === 直接比 hex 字符串。
function safeEqual(a, b) {
    if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

function json(body, status = 200, headers = {}) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { 'content-type': 'application/json; charset=utf-8', ...headers },
    });
}

const NO_STORE = { 'cache-control': 'no-store' };
// 读接口的 CORS：公开数据、无凭据。
const READ_CORS = {
    'access-control-allow-origin': '*',
    'vary': 'origin',
};

function notFound() {
    // 措辞与状态码对「不存在」和「存在但没数据」完全一致
    return json({ error: 'not_found' }, 404, { ...NO_STORE, ...READ_CORS });
}

function bearer(request) {
    const h = request.headers.get('authorization') || '';
    return h.startsWith('Bearer ') ? h.slice(7).trim() : '';
}

async function readStats(request, env, ctx, handle, url) {
    const cache = caches.default;
    const cacheKey = new Request(url.toString(), { method: 'GET' });
    let hit = await cache.match(cacheKey);
    if (!hit) {
        const row = await env.DB.prepare(
            'SELECT s.payload, s.etag, s.updated_at FROM stats s' +
            ' JOIN handles h ON h.handle = s.handle' +
            ' WHERE s.handle = ? AND h.disabled = 0'
        ).bind(handle).first();
        if (!row) return notFound();

        hit = new Response(row.payload, {
            headers: {
                'content-type': 'application/json; charset=utf-8',
                // 发布后全局可见的真实上界是 s-maxage=300，README 里写明了这一点。
                'cache-control': 'public, max-age=60, s-maxage=300, stale-while-revalidate=3600',
                'etag': '"' + row.etag + '"',
                'x-updated-at': String(row.updated_at),
                'x-content-type-options': 'nosniff',
                ...READ_CORS,
            },
        });
        ctx.waitUntil(cache.put(cacheKey, hit.clone()));
    }

    const inm = request.headers.get('if-none-match');
    const etag = hit.headers.get('etag');
    if (inm && etag && inm.split(',').some((t) => t.trim() === etag)) {
        return new Response(null, { status: 304, headers: hit.headers });
    }
    return hit;
}

async function writeStats(request, env, ctx, handle, url) {
    const token = bearer(request);
    if (!token) return json({ error: 'missing_token' }, 401, NO_STORE);

    // 读 body 之前先按 Content-Length 拒；读完再按真实字节数复查
    // （Content-Length 是客户端可控的，不能只信它）。
    const declared = Number(request.headers.get('content-length') || '0');
    if (declared > MAX_BYTES) return json({ error: 'payload_too_large' }, 413, NO_STORE);

    const ct = request.headers.get('content-type') || '';
    if (!ct.includes('application/json')) {
        return json({ error: 'expected_application_json' }, 415, NO_STORE);
    }

    const row = await env.DB.prepare(
        'SELECT token_hash, disabled FROM handles WHERE handle = ?'
    ).bind(handle).first();
    // handle 不存在与被停用返回同一个 404，不泄露哪个 handle 已注册
    if (!row || row.disabled) return notFound();

    const given = await sha256Hex(token);
    if (!safeEqual(given, row.token_hash)) return json({ error: 'bad_token' }, 403, NO_STORE);

    const bytes = await request.arrayBuffer();
    if (bytes.byteLength > MAX_BYTES) return json({ error: 'payload_too_large' }, 413, NO_STORE);

    const text = new TextDecoder().decode(bytes);
    let parsed;
    try { parsed = JSON.parse(text); }
    catch (e) { return json({ error: 'invalid_json' }, 400, NO_STORE); }

    const verdict = validatePayload(parsed);
    if (!verdict.ok) return json({ error: 'invalid_payload', detail: verdict.error }, 400, NO_STORE);

    const now = Date.now();
    const etag = (await sha256Hex(text)).slice(0, 32);

    // 限流与写入放进同一个 batch：CAS 语义，杜绝 read-then-write 竞态。
    const [gate] = await env.DB.batch([
        env.DB.prepare(
            'UPDATE handles SET last_push_at = ?, push_count = push_count + 1' +
            ' WHERE handle = ? AND disabled = 0' +
            ' AND (last_push_at IS NULL OR last_push_at <= ?)'
        ).bind(now, handle, now - MIN_PUSH_INTERVAL_MS),
        env.DB.prepare(
            'INSERT INTO stats (handle, payload, etag, updated_at, bytes) VALUES (?,?,?,?,?)' +
            ' ON CONFLICT(handle) DO UPDATE SET payload=excluded.payload, etag=excluded.etag,' +
            ' updated_at=excluded.updated_at, bytes=excluded.bytes'
        ).bind(handle, text, etag, now, bytes.byteLength),
    ]);

    if (!gate.meta || gate.meta.changes !== 1) {
        const retry = Math.ceil(MIN_PUSH_INTERVAL_MS / 1000);
        return json({ error: 'rate_limited', min_interval_seconds: retry }, 429,
                    { ...NO_STORE, 'retry-after': String(retry) });
    }

    // 只清本 colo；全局可见的上界仍是 s-maxage=300。
    ctx.waitUntil(caches.default.delete(new Request(url.toString(), { method: 'GET' })));
    return json({ ok: true, handle, etag, bytes: bytes.byteLength, updated_at: now }, 200, NO_STORE);
}

async function rotateToken(request, env, handle) {
    const token = bearer(request);
    if (!token) return json({ error: 'missing_token' }, 401, NO_STORE);
    const row = await env.DB.prepare(
        'SELECT token_hash, disabled FROM handles WHERE handle = ?'
    ).bind(handle).first();
    if (!row || row.disabled) return notFound();
    if (!safeEqual(await sha256Hex(token), row.token_hash)) {
        return json({ error: 'bad_token' }, 403, NO_STORE);
    }
    const fresh = newToken();
    await env.DB.prepare('UPDATE handles SET token_hash = ? WHERE handle = ?')
        .bind(await sha256Hex(fresh), handle).run();
    // 只在这一次返回明文，之后无从取回
    return json({ ok: true, handle, token: fresh }, 200, NO_STORE);
}

function newToken() {
    const raw = crypto.getRandomValues(new Uint8Array(32));
    return btoa(String.fromCharCode(...raw))
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function adminCreate(request, env) {
    const admin = bearer(request);
    if (!env.ADMIN_TOKEN || !safeEqual(admin, env.ADMIN_TOKEN)) {
        return json({ error: 'forbidden' }, 403, NO_STORE);
    }
    let body;
    try { body = await request.json(); } catch (e) { return json({ error: 'invalid_json' }, 400, NO_STORE); }
    const handle = String(body && body.handle || '');
    if (!HANDLE_RE.test(handle) || RESERVED.has(handle)) {
        return json({ error: 'invalid_handle' }, 400, NO_STORE);
    }
    const cap = Number(env.MAX_HANDLES || '200');
    const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM handles').first();
    if (count && count.n >= cap) return json({ error: 'capacity_reached' }, 503, NO_STORE);

    const token = newToken();
    try {
        await env.DB.prepare(
            'INSERT INTO handles (handle, token_hash, created_at) VALUES (?,?,?)'
        ).bind(handle, await sha256Hex(token), Date.now()).run();
    } catch (e) {
        return json({ error: 'handle_taken' }, 409, NO_STORE);
    }
    return json({ ok: true, handle, token, note: 'token 只此一次可见' }, 201, NO_STORE);
}

async function adminDelete(request, env, ctx, handle, url) {
    const admin = bearer(request);
    if (!env.ADMIN_TOKEN || !safeEqual(admin, env.ADMIN_TOKEN)) {
        return json({ error: 'forbidden' }, 403, NO_STORE);
    }
    await env.DB.batch([
        env.DB.prepare('DELETE FROM stats WHERE handle = ?').bind(handle),
        env.DB.prepare('DELETE FROM handles WHERE handle = ?').bind(handle),
    ]);
    ctx.waitUntil(caches.default.delete(new Request(url.toString(), { method: 'GET' })));
    return json({ ok: true, handle, deleted: true }, 200, NO_STORE);
}

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const path = url.pathname.replace(/\/+$/, '') || '/';
        const method = request.method.toUpperCase();

        if (method === 'OPTIONS') {
            // 只给读接口放行；写接口刻意不进这个分支，浏览器发不出跨站 PUT。
            const statsGet = /^\/v1\/stats\/[^/]+$/.test(path);
            if (!statsGet) return new Response(null, { status: 405, headers: NO_STORE });
            return new Response(null, {
                status: 204,
                headers: {
                    ...READ_CORS,
                    'access-control-allow-methods': 'GET, OPTIONS',
                    'access-control-allow-headers': 'content-type, if-none-match',
                    'access-control-max-age': '86400',
                },
            });
        }

        if (path === '/healthz' && method === 'GET') {
            return json({ ok: true, service: 'tokentracker-stats', payload_version: 1 },
                        200, NO_STORE);
        }

        if (path === '/v1/handles' && method === 'POST') return adminCreate(request, env);

        const m = path.match(/^\/v1\/stats\/([^/]+)(\/rotate)?$/);
        if (m) {
            const handle = m[1].toLowerCase();
            if (!HANDLE_RE.test(handle) || RESERVED.has(handle)) return notFound();
            if (m[2]) {
                return method === 'POST' ? rotateToken(request, env, handle)
                                         : json({ error: 'method_not_allowed' }, 405, NO_STORE);
            }
            if (method === 'GET')    return readStats(request, env, ctx, handle, url);
            if (method === 'PUT')    return writeStats(request, env, ctx, handle, url);
            if (method === 'DELETE') return adminDelete(request, env, ctx, handle, url);
            return json({ error: 'method_not_allowed' }, 405, NO_STORE);
        }

        return json({ error: 'not_found' }, 404, NO_STORE);
    },
};
