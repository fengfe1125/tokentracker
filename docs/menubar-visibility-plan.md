# macOS 26 状态栏排障记录

TokenTracker 使用 AppKit `NSStatusItem` 承载 SwiftUI App 的状态栏入口。

## 已确认问题

1. macOS 26 Tahoe 会通过 StatusKit 控制第三方状态栏项目。首次使用需要用户在
   “系统设置 → 菜单栏”中允许 TokenTracker。
2. `isVisible` 不能可靠反映项目是否被系统门控或隐藏，因此不能作为唯一诊断信号。
3. 对 attributed title 的重复赋值可能使项目消失；当前实现只在内容变化时更新。
4. 标题测量需要保持纯文本标题与 attributed title 一致。

## 当前自愈策略

- 内容不变时不重复写入状态栏按钮；
- 定期轻量重排，处理系统未上报的隐藏状态；
- 能确认项目丢失时重建，并带退避避免频繁抖动；
- 配额圆按整数百分点缓存，避免无意义重绘；
- 系统开启“减少动态效果”时使用静态显示。

实现位于 `swift/Sources/TokenTrackerApp/StatusItemController.swift`。

## 用户排障

先检查“系统设置 → 菜单栏”是否允许 TokenTracker，再退出并重新打开 App。
若授权列表中没有 TokenTracker 或允许后仍不显示，应按 StatusKit/ControlCenter 登记异常处理，
不要把数据扫描成功误认为状态栏已经可见。
