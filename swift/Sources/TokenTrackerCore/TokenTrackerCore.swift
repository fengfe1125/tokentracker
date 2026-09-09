//
//  TokenTrackerCore.swift
//  TokenTrackerCore
//
//  核心包入口与版本常量。扫描器 / 存储 / 配额 / 调度在 Phase 1+ 填充；
//  本文件先固定公共缝口，保证 App 壳与测试目标有稳定依赖面。
//

import Foundation

public enum TokenTrackerCore {
    /// 与 Python db.SCHEMA_VERSION 对齐；Swift 版复用同一 ~/.tokentracker/usage.db。
    public static let schemaVersion = 3

    /// 差分导出格式版本（tests/differential/export_python.py）。
    public static let differentialFormatVersion = 2

    /// 应用版本（与 Python tokentracker.__version__ 对齐）。
    public static let version = "0.2.6"
}
