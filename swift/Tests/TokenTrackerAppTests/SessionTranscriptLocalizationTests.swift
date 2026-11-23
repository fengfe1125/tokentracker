import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

/// 会话「对话」预览与 Markdown 导出的英文适配：界面文案与导出抬头不能残留中文。
final class SessionTranscriptLocalizationTests: XCTestCase {
    private let keys: [String] = [
        "对话", "查看对话", "导出 Markdown…", "复制为 Markdown", "导出 Markdown",
        "按当前显示选项导出为 Markdown（不受搜索影响）", "工具调用", "思考", "系统注入", "搜索对话",
        "对话记录", "{0} 条提问 · {1} 条回复 · {2} 次工具调用", "匹配 {0} 条", "正在读取本机对话记录…",
        "对话过长，只显示最近的部分（省略了最早的 {0} 条记录）", "回到开头", "跳到末尾",
        "没有包含「{0}」的内容", "已隐藏 {0} 条系统注入、{1} 次工具调用，可在上方打开显示",
        "原始记录里没有可显示的消息", "没有可显示的对话内容", "找不到原始记录文件",
        "原日志可能已被删除或移动；已统计的用量不受影响", "无法读取原始记录",
        "DSH 记录需要系统 zstd（brew install zstd）", "文件可能没有读取权限或正被占用，稍后再试",
        "这个来源没有对话正文", "该记录只包含用量统计，无法还原对话内容",
        "会话 ID", "工作目录", "时间", "模型", "源文件", "导出时间", "用户", "助手",
        "系统 / 上下文注入", "未命名工具", "参数", "结果", "出错", "（未记录结果）",
        "（内容过长，已截断，仅保留前 {0} 个字符）", "（对话过长，省略了最早的 {0} 条记录）",
        "（没有可显示的对话内容）", "已导出到 {0}", "导出失败，文件未保存", "已复制 Markdown 到剪贴板",
        "你", "无结果", "结果（出错）", "收起全文", "展开全文（共 {0} 字）",
        "原文过长，预览只保留前 {0} 个字符",
    ]

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    func testEnglishStringsExistForConversationFeature() {
        for key in keys {
            let english = L10n.render(L10n.Template(stringLiteral: key), language: "en")
            XCTAssertNotEqual(english, key, "缺少英文：\(key)")
            XCTAssertFalse(containsCJK(english), "英文残留中文：\(key) → \(english)")
        }
        XCTAssertEqual(L10n.render(L10n.Template(stringLiteral: "对话"), language: "en"), "Conversation")
    }

    func testEnglishMarkdownExportHasNoChineseChrome() {
        let transcript = SessionTranscript(tool: "codex", sessionID: "s1", sourcePath: "/x", status: .ok, entries: [
            TranscriptEntry(id: 0, kind: .user, text: "Fix the build", timestamp: 0),
            TranscriptEntry(id: 1, kind: .toolCall, text: "{}", toolName: "", callID: "c"),
            TranscriptEntry(id: 2, kind: .assistant, text: "Done"),
        ], droppedEntries: 3)
        let markdown = TranscriptMarkdown.render(
            transcript,
            metadata: .init(title: "Fix", agentName: "Codex", sessionID: "s1", workspace: "/repo", models: ["m"]),
            labels: .english)
        XCTAssertFalse(containsCJK(markdown), markdown)
        XCTAssertTrue(markdown.contains("## 👤 User"))
        XCTAssertTrue(markdown.contains("<code>Unnamed tool</code>"))
        XCTAssertTrue(markdown.contains("the 3 earliest records were omitted"))
    }
}
