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
    try:
        prices = pricing.load_prices()
        tools = args.tool or ["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"]
        if getattr(args, "reset", False):
            marks = ",".join("?" * len(tools))
            conn.execute(f"DELETE FROM usage_events WHERE tool IN ({marks})", tools)
            conn.execute(f"DELETE FROM scan_state WHERE tool IN ({marks})", tools)
            conn.execute(f"DELETE FROM aggregate_snapshots WHERE tool IN ({marks})", tools)
            conn.commit()
            print(f"已清空 {len(tools)} 个工具的统计和快照，全量重扫；已记录的观测区间与历史时间无法恢复")
            args.full = True
        results = run_all(conn, prices, tools=args.tool, full=args.full)
        repriced = db.reprice(conn, prices)
    finally:
        conn.close()
    for tool, r in results.items():
        if "error" in r:
            print(f"✗ {tool:<10} 出错: {r['error']}")
        elif "skipped" in r:
            print(f"— {tool:<10} {r['skipped']}")
        else:
            print(f"✓ {tool:<10} 新增 {r['added']} 条 / 更新 {r['updated']} 条 / 文件 {r['files']} 个")
        if r.get("counter_resets"):
            print(f"⚠ {tool}: {r['counter_resets']} 个累计计数器重置，已更新基线并保留历史")
        if r.get("warning"):
            print(f"⚠ {tool}: {r['warning']}")
    if repriced:
        print(f"✓ reprice 按价格表回填 {repriced} 条成本")
    return 0


def fmt(n) -> str:
    return f"{n:,}"


def cmd_stats(args) -> int:
    conn = db.connect()
    try:
        rows, total = db.stats(conn, args.range, args.tool)
    finally:
        conn.close()
    print(f"范围: {args.range}   (--range day|week|month|all)")
    hdr = ("工具", "会话", "总Token", "输入", "输出", "缓存读", "缓存写", "成本$")
    widths = [10, 6, 12, 12, 12, 12, 12, 10]
    def line(cells):
        return "  ".join(str(c).rjust(w) for c, w in zip(cells, widths))
    print(line(hdr))
    print("-" * sum(widths) + "--" * 6)
    for r in rows:
        print(line((r["tool"], r["sessions"], fmt(r["tokens"]), fmt(r["input"]), fmt(r["output"]),
                    fmt(r["cache_read"]), fmt(r["cache_write"]),
                    f"{r['cost']:.4f}")))
    print("-" * sum(widths) + "--" * 6)
    print(line(("合计", total["sessions"], fmt(total["tokens"]), fmt(total["input"]), fmt(total["output"]),
                fmt(total["cache_read"]), fmt(total["cache_write"]), f"{total['cost']:.4f}")))
    unallocated = total.get("unallocated") or {}
    if unallocated.get("events"):
        scope = "已计入全部历史，不计入日期范围" if args.range == "all" else "不计入当前范围，保留在全部历史"
        print(f"⚠ 未分配到时间: {fmt(unallocated['tokens'])} Token / ${unallocated['cost']:.4f} / {unallocated['events']} 事件（{scope}）")
    if total.get("estimated_tokens"):
        print(f"≈ 按观测时间估算: {fmt(total['estimated_tokens'])} Token（已计入当前总量）")
    if total["unpriced"]:
        print(f"⚠ 有 {total['unpriced']} 条事件未匹配到价格（已按 token 统计，不计费）。编辑 prices.json 可补价格。")
    return 0


def cmd_quotas(args) -> int:
    from .quotas import compute
    conn = db.connect()
    try:
        data = compute(conn)
    finally:
        conn.close()
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
    serve_blocking(port=args.port, on_ready=webbrowser.open if args.open else None,
                   auto_scan=args.auto_scan, initial_scan=args.scan)
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="tokentracker", description="多 AI 工具 Token 用量统计")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("detect", help="检测各工具数据源")

    ps = sub.add_parser("scan", help="扫描各工具日志并入库")
    ps.add_argument("--tool", action="append", choices=["claude", "codex", "opencode", "dsh", "hermes", "kimi", "pi"])
    ps.add_argument("--full", action="store_true", help="忽略增量游标全量重扫")
    ps.add_argument("--reset", action="store_true", help="显式清空统计和快照后重扫；观测区间与历史时间无法恢复，勿用于日常刷新")

    pt = sub.add_parser("stats", help="查看统计")
    pt.add_argument("--range", default="all", choices=["day", "week", "month", "all"])
    pt.add_argument("--tool")

    pq = sub.add_parser("quotas", help="查看订阅配额进度（官方数据优先，本地估算兜底）")

    psrv = sub.add_parser("serve", help="启动本地仪表盘")
    psrv.add_argument("--port", type=int, default=8765)
    psrv.add_argument("--open", action="store_true", help="自动打开浏览器")
    psrv.add_argument("--scan", action="store_true", help="启动时扫描一次")
    psrv.add_argument("--auto-scan", action="store_true", help="启动时扫描，并每 60 秒增量扫描（默认关闭）")

    args = p.parse_args(argv)
    return {"detect": cmd_detect, "scan": cmd_scan, "stats": cmd_stats,
            "quotas": cmd_quotas, "serve": cmd_serve}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
