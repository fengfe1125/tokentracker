using System.Text;
using SQLitePCL;

namespace TokenTracker.Core.Store;

public sealed class SqliteException(string message) : Exception(message);

/// <summary>行值：long / double / string / null（对齐 Python sqlite3.Row 的取值习惯）。</summary>
public sealed class Row(Dictionary<string, object?> values)
{
    public Dictionary<string, object?> Values { get; } = values;

    public object? this[string key] => Values.TryGetValue(key, out var v) ? v : null;

    public long Int(string key) => IntOrNull(key) ?? 0;

    public long? IntOrNull(string key) => this[key] switch
    {
        long l => l,
        double d => (long)d,
        string s => long.TryParse(s, out var n) ? n : null,
        _ => null,
    };

    public double Double(string key) => DoubleOrNull(key) ?? 0;

    public double? DoubleOrNull(string key) => this[key] switch
    {
        double d => d,
        long l => l,
        string s => double.TryParse(s, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : null,
        _ => null,
    };

    public string Str(string key) => this[key] switch
    {
        string s => s,
        long l => l.ToString(System.Globalization.CultureInfo.InvariantCulture),
        double d => Json.PyJson.PyFloatRepr(d),
        _ => "",
    };

    public string? StrOrNull(string key) => this[key] as string;
}

/// <summary>
/// e_sqlite3 的薄封装（移植 Store/SQLite.swift）：参数绑定、行字典、原生 SQL 事务、
/// changes 计数、只读打开、备份 API。连接以 FULLMUTEX 打开，跨线程串行化。
/// </summary>
public sealed class SqliteDb : IDisposable
{
    static SqliteDb() => Batteries_V2.Init();

    readonly sqlite3 _db;
    readonly object _gate = new();

    public string Path { get; }

    /// <summary>timeout=30s 对齐 Python sqlite3.connect(..., timeout=30)。</summary>
    public SqliteDb(string path, bool readOnly = false)
    {
        Path = path;
        var flags = raw.SQLITE_OPEN_FULLMUTEX | (readOnly
            ? raw.SQLITE_OPEN_READONLY
            : raw.SQLITE_OPEN_READWRITE | raw.SQLITE_OPEN_CREATE);
        var rc = raw.sqlite3_open_v2(path, out _db, flags, null);
        if (rc != raw.SQLITE_OK)
        {
            var msg = _db is null ? "open failed" : raw.sqlite3_errmsg(_db).utf8_to_string();
            _db?.Dispose();
            throw new SqliteException($"sqlite open {path}: {msg}");
        }
        raw.sqlite3_busy_timeout(_db, 30_000);
    }

    public static SqliteDb OpenReadOnly(string path) => new(path, readOnly: true);

    public void Dispose()
    {
        lock (_gate)
        {
            _db.Dispose();
        }
    }

    public bool InTransaction
    {
        get
        {
            lock (_gate) return raw.sqlite3_get_autocommit(_db) == 0;
        }
    }

    /// <summary>执行并返回影响行数（对齐 cursor.rowcount / sqlite3_changes）。</summary>
    public int Execute(string sql, params object?[] args)
    {
        lock (_gate)
        {
            return WithStatement(sql, args, stmt =>
            {
                var rc = raw.sqlite3_step(stmt);
                if (rc != raw.SQLITE_DONE && rc != raw.SQLITE_ROW)
                    throw new SqliteException($"step: {LastError()} [{sql}]");
                return raw.sqlite3_changes(_db);
            });
        }
    }

    public List<Row> Query(string sql, params object?[] args)
    {
        lock (_gate)
        {
            return WithStatement(sql, args, stmt =>
            {
                var rows = new List<Row>();
                var count = raw.sqlite3_column_count(stmt);
                var names = new string[count];
                for (var i = 0; i < count; i++) names[i] = raw.sqlite3_column_name(stmt, i).utf8_to_string();
                while (true)
                {
                    var rc = raw.sqlite3_step(stmt);
                    if (rc == raw.SQLITE_DONE) break;
                    if (rc != raw.SQLITE_ROW) throw new SqliteException($"step: {LastError()} [{sql}]");
                    var values = new Dictionary<string, object?>(count);
                    for (var i = 0; i < count; i++)
                    {
                        values[names[i]] = raw.sqlite3_column_type(stmt, i) switch
                        {
                            raw.SQLITE_INTEGER => raw.sqlite3_column_int64(stmt, i),
                            raw.SQLITE_FLOAT => raw.sqlite3_column_double(stmt, i),
                            raw.SQLITE_TEXT => raw.sqlite3_column_text(stmt, i).utf8_to_string(),
                            raw.SQLITE_BLOB => Encoding.UTF8.GetString(raw.sqlite3_column_blob(stmt, i)),
                            _ => null,
                        };
                    }
                    rows.Add(new Row(values));
                }
                return rows;
            });
        }
    }

    public Row? QueryOne(string sql, params object?[] args) => Query(sql, args).FirstOrDefault();

    public long ScalarInt(string sql, params object?[] args)
    {
        var row = QueryOne(sql, args);
        if (row is null || row.Values.Count == 0) return 0;
        return row.Values.First().Value switch
        {
            long l => l,
            double d => (long)d,
            string s => long.TryParse(s, out var n) ? n : 0,
            _ => 0,
        };
    }

    /// <summary>Python conn.commit()：无事务时是 no-op。</summary>
    public void Commit()
    {
        if (InTransaction) Execute("COMMIT");
    }

    public void Rollback()
    {
        if (InTransaction) Execute("ROLLBACK");
    }

    public void BeginImmediate() => Execute("BEGIN IMMEDIATE");

    /// <summary>sqlite3_backup API（对齐 Python conn.backup）。</summary>
    public void BackupTo(SqliteDb destination)
    {
        lock (_gate)
        {
            using var backup = raw.sqlite3_backup_init(destination._db, "main", _db, "main");
            if (backup is null) throw new SqliteException($"backup init: {destination.LastError()}");
            var rc = raw.sqlite3_backup_step(backup, -1);
            while (rc is raw.SQLITE_OK or raw.SQLITE_BUSY or raw.SQLITE_LOCKED)
            {
                if (rc != raw.SQLITE_OK) Thread.Sleep(50);
                rc = raw.sqlite3_backup_step(backup, -1);
            }
            raw.sqlite3_backup_finish(backup);
            if (rc != raw.SQLITE_DONE) throw new SqliteException($"backup step failed: {rc}");
        }
    }

    public string LastError() => raw.sqlite3_errmsg(_db).utf8_to_string();

    T WithStatement<T>(string sql, object?[] args, Func<sqlite3_stmt, T> body)
    {
        var rc = raw.sqlite3_prepare_v2(_db, sql, out var stmt);
        if (rc != raw.SQLITE_OK || stmt is null)
        {
            stmt?.Dispose();
            throw new SqliteException($"prepare: {LastError()} [{sql}]");
        }
        using (stmt)
        {
            for (var index = 0; index < args.Length; index++)
            {
                var i = index + 1;
                var bindRc = args[index] switch
                {
                    null => raw.sqlite3_bind_null(stmt, i),
                    long l => raw.sqlite3_bind_int64(stmt, i, l),
                    int n => raw.sqlite3_bind_int64(stmt, i, n),
                    bool b => raw.sqlite3_bind_int64(stmt, i, b ? 1 : 0),
                    double d => raw.sqlite3_bind_double(stmt, i, d),
                    string s => raw.sqlite3_bind_text(stmt, i, s),
                    var other => throw new SqliteException($"unsupported bind type: {other.GetType()}"),
                };
                if (bindRc != raw.SQLITE_OK) throw new SqliteException($"bind {i}: {LastError()} [{sql}]");
            }
            return body(stmt);
        }
    }
}
