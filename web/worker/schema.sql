-- tokentracker-stats —— 公开统计的多租户存储。
-- 载荷原样存 TEXT：先校验，再持久化「将要原样吐出去的字节」，
-- 这样载荷 schema 升级不需要改 worker。

CREATE TABLE IF NOT EXISTS handles (
  handle       TEXT PRIMARY KEY,
  token_hash   TEXT NOT NULL,             -- hex(SHA-256(token))，明文永不落库
  created_at   INTEGER NOT NULL,
  last_push_at INTEGER,
  push_count   INTEGER NOT NULL DEFAULT 0,
  disabled     INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS stats (
  handle     TEXT PRIMARY KEY REFERENCES handles(handle),
  payload    TEXT NOT NULL,
  etag       TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  bytes      INTEGER NOT NULL
);

-- 注册限流用。只存加盐哈希后的 IP，绝不存明文。
CREATE TABLE IF NOT EXISTS reg_log (
  ip_hash TEXT NOT NULL,
  day     TEXT NOT NULL,
  n       INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, day)
);
