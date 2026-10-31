//
//  TokenTrackerCore.swift
//  TokenTrackerCore
//
//  核心包入口与版本常量。扫描器 / 存储 / 配额 / 调度在 Phase 1+ 填充；
//  本文件先固定公共缝口，保证 App 壳与测试目标有稳定依赖面。
//

import Foundation

public enum TokenTrackerCore {
    /// ~/.tokentracker/usage.db 的 schema 版本。
    public static let schemaVersion = 6

    /// 冻结差分基线 Fixtures/differential/expected.json 的格式版本。
    public static let differentialFormatVersion = 4

    /// 公开统计载荷格式版本。与 differentialFormatVersion 完全独立：
    /// 差分导出含绝对路径与原始 prompt，绝不复用。
    public static let publicStatsFormatVersion = 1

    /// 应用版本，打包脚本写入 Info.plist。
    public static let version = "0.5.7"
}
