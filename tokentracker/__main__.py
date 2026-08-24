"""CLI 入口：python3 -m tokentracker <scan|stats|detect|serve>"""
from __future__ import annotations

import argparse
import sys
import webbrowser

from . import db, pricing
from .scanners import detect_all, run_all


def cmd_detect(_args) -> int:
    for name, info in detect_all().items():
        mark = "✅" if info["installed"] else "—"
        detail = info.get("detail", "")
        print(f"{mark} {name:<10} {detail}")
    return 0


def cmd_scan(args) -> int:
    conn = db.connect()
    prices = pricing.load_prices()
    tools = args.tool or ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"]
    if getattr(args, "reset", False):
        marks = ",".join("?" * len(tools))
        conn.execute(f"DELETE FROM usage_events WHERE tool IN ({marks})", tools)
        conn.execute(f"DELETE FROM scan_state WHERE tool IN ({marks})", tools)
        conn.commit()
        print(f"已清空 {len(tools)} 个工具的统计，全量重扫")
        args.full = True
    results = run_all(conn, prices, tools=args.tool, full=args.full)
    repriced = db.reprice(conn, prices)
    for tool, r in results.items():
        if "error" in r:
            print(f"✗ {tool:<10} 出错: {r['error']}")
        elif "skipped" in r:
            print(f"— {tool:<10} {r['skipped']}")
        else:
            print(f"✓ {tool:<10} 新增 {r['added']} 条 / 更新 {r['updated']} 条 / 文件 {r['files']} 个")
    if repriced:
        print(f"✓ reprice 按价格表回填 {repriced} 条成本")
    return 0


def fmt(n) -> str:
    return f"{n:,}"


def cmd_stats(args) -> int:
    conn = db.connect()
    rows, total = db.stats(conn, args.range, args.tool)
    print(f"范围: {args.range}   (--range day|week|month|all)")
    hdr = ("工具", "会话", "输入", "输出", "缓存读", "缓存写", "成本$")
    widths = [10, 6, 12, 12, 12, 12, 10]
    def line(cells):
        return "  ".join(str(c).rjust(w) for c, w in zip(cells, widths))
    print(line(hdr))
    print("-" * sum(widths) + "--" * 6)
    for r in rows:
        print(line((r["tool"], r["sessions"], fmt(r["input"]), fmt(r["output"]),
                    fmt(r["cache_read"]), fmt(r["cache_write"]),
                    f"{r['cost']:.4f}" if r["tool"] != "__total__" else f"{r['cost']:.4f}")))
    print("-" * sum(widths) + "--" * 6)
    print(line(("合计", total["sessions"], fmt(total["input"]), fmt(total["output"]),
                fmt(total["cache_read"]), fmt(total["cache_write"]), f"{total['cost']:.4f}")))
    if total["unpriced"]:
        print(f"⚠ 有 {total['unpriced']} 条事件未匹配到价格（已按 token 统计，不计费）。编辑 prices.json 可补价格。")
    return 0


def cmd_quotas(args) -> int:
    from .quotas import compute
    conn = db.connect()
    data = compute(conn)
    for e in data["entries"]:
        tag = "官方" if e["source"] == "official" else "本地估算"
        print(f"{e['name']}  [{tag}]  {e['plan']}")
        for w in e["windows"]:
            pct = w.get("pct")
            bar = "█" * int((pct or 0) // 5) + "░" * (20 - int((pct or 0) // 5))
            if w["source"] == "official":
                if w["unit"] == "requests":
                    print(f"  {w['label']:<9} [{bar}] {w['used']}/{w['limit']} 次  {pct:.1f}%  官方")
                else:
                    print(f"  {w['label']:<9} [{bar}] {pct:.1f}%   官方")
            else:
                used = fmt(w["used"]) if w["unit"] == "tokens" else f"${w['used']:.2f}"
                lim = fmt(w["limit"]) if w["unit"] == "tokens" else f"${w['limit']:.2f}"
                pct_txt = f"{pct:.1f}%" if pct is not None else "未设上限"
                print(f"  {w['label']:<9} [{bar}] {used} / {lim}  {pct_txt}   本地")
        if e.get("note"):
            print(f"  ⚠ {e['note']}")
    return 0


def cmd_serve(args) -> int:
    from .server import serve_blocking
    conn = db.connect()
    if args.scan:
        prices = pricing.load_prices()
        run_all(conn, prices)
        db.reprice(conn, prices)
    conn.close()
    serve_blocking(port=args.port, on_ready=webbrowser.open if args.open else None)
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="tokentracker", description="多 AI 工具 Token 用量统计")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("detect", help="检测各工具数据源")

    ps = sub.add_parser("scan", help="扫描各工具日志并入库")
    ps.add_argument("--tool", action="append", choices=["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"])
    ps.add_argument("--full", action="store_true", help="忽略增量游标全量重扫")
    ps.add_argument("--reset", action="store_true", help="清空统计后全量重扫（改完扫描器/价格表后使用）")

    pt = sub.add_parser("stats", help="查看统计")
    pt.add_argument("--range", default="all", choices=["day", "week", "month", "all"])
    pt.add_argument("--tool")

    pq = sub.add_parser("quotas", help="查看订阅配额进度（官方数据优先，本地估算兜底）")

    psrv = sub.add_parser("serve", help="启动本地仪表盘")
    psrv.add_argument("--port", type=int, default=8765)
    psrv.add_argument("--open", action="store_true", help="自动打开浏览器")
    psrv.add_argument("--scan", action="store_true", help="启动前先扫描一次")

    args = p.parse_args(argv)
    return {"detect": cmd_detect, "scan": cmd_scan, "stats": cmd_stats,
            "quotas": cmd_quotas, "serve": cmd_serve}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())