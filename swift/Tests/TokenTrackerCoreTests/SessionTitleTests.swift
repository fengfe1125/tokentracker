import XCTest
@testable import TokenTrackerCore

final class SessionTitleTests: XCTestCase {
    func testWrappersInterruptsAndHistoryDumpsAreNotTitles() {
        for noise in [
            "<turn_aborted> The user interrupted the previous turn on purpose.",
            "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>",
            "[Request interrupted by user for tool use]",
            "[Workflow harness — user request] The harness relays, verbatim and indented below",
            "[3] tool exec call: text(await run())",
            "[176] assistant: done",
            "<bash-input>cd /tmp</bash-input>",
            "<task-notification> finished",
            "# Files mentioned by the user: ## a.png: /tmp/a.png",
            "   ",
        ] {
            XCTAssertNil(sessionTitle(fromUserText: noise), noise)
        }
    }

    func testAttachmentMarkersAreStrippedAndTheRequestKept() {
        XCTAssertEqual(sessionTitle(fromUserText: "<image name=[Image #1] path=/tmp/a.png> </image> 这张图哪里不对"),
                       "这张图哪里不对")
        XCTAssertEqual(sessionTitle(fromUserText: "[Image: original 1653x2339, displayed at 800x1132] [Image #2] fix the layout"),
                       "fix the layout")
        XCTAssertEqual(sessionTitle(fromUserText: "<pasted_content id=\"591d\"> 请看这段日志"), "请看这段日志")
        XCTAssertEqual(sessionTitle(fromUserText: "# Files mentioned by the user: ## a.png: /tmp/a.png ## My request for Codex:\n  帮我  裁剪 "),
                       "帮我 裁剪")
        // 只有附件、没有文字：不是标题
        XCTAssertNil(sessionTitle(fromUserText: "<image name=[Image #1] path=/tmp/a.png>"))
        // 一个标记后面跟着另一种噪声，仍然不是标题
        XCTAssertNil(sessionTitle(fromUserText: "[Image #1] <turn_aborted> interrupted"))
    }

    func testOrdinaryMessagesAreCollapsedAndCutAt120Characters() {
        XCTAssertEqual(sessionTitle(fromUserText: "  重构\n设置页  "), "重构 设置页")
        // 方括号或井号开头的普通输入不误杀
        XCTAssertEqual(sessionTitle(fromUserText: "[WIP] rename the module"), "[WIP] rename the module")
        XCTAssertEqual(sessionTitle(fromUserText: "# 聊天点歌 实施计划"), "# 聊天点歌 实施计划")
        XCTAssertEqual(sessionTitle(fromUserText: String(repeating: "长", count: 300))?.count, 120)
    }

    func testIncrementalTitleDoesNotReplaceTheFirstMessage() throws {
        let path = NSTemporaryDirectory() + "tt-title-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageStore(path: path)
        func title(_ id: String) throws -> String? {
            try store.conn.queryOne("SELECT title FROM session_meta WHERE tool='claude' AND session_id=?", [id])?
                .string("title")
        }
        try store.setSessionTitle(tool: "claude", sessionID: "s", title: "第一条消息")
        try store.setSessionTitle(tool: "claude", sessionID: "s", title: "继续", onlyIfMissing: true)
        XCTAssertEqual(try title("s"), "第一条消息")
        // 没有标题的会话，增量看到的首条消息可以补上
        try store.setSessionTitle(tool: "claude", sessionID: "new", title: "继续", onlyIfMissing: true)
        XCTAssertEqual(try title("new"), "继续")
        // 全量重扫仍然可以改写
        try store.setSessionTitle(tool: "claude", sessionID: "s", title: "重扫后的首条")
        XCTAssertEqual(try title("s"), "重扫后的首条")
    }

    func testRepairRewritesStoredTitlesOnceAndKeepsUsage() throws {
        let path = NSTemporaryDirectory() + "tt-title-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageStore(path: path)
        try store.putEvent(tool: "codex", srcKey: "e", sessionID: "noise", ts: 1_000, input: 5)
        for (id, title) in [("noise", "<turn_aborted> The user interrupted"),
                            ("image", "<image name=[Image #1] path=/tmp/a.png> 看这张图"),
                            ("fine", "普通标题")] {
            try store.setSessionTitle(tool: "codex", sessionID: id, title: title)
        }
        XCTAssertEqual(try store.repairSessionTitles(), 2)
        let titles = Dictionary(uniqueKeysWithValues: try store.conn
            .query("SELECT session_id,title FROM session_meta").map { ($0.string("session_id"), $0.string("title")) })
        XCTAssertEqual(titles, ["image": "看这张图", "fine": "普通标题"])
        XCTAssertEqual(try store.stats(rangeKey: "all").total.tokens, 5)

        // 只跑一次：之后写入的内容不会被再次清理
        try store.setSessionTitle(tool: "codex", sessionID: "later", title: "<turn_aborted> again")
        XCTAssertEqual(try store.repairSessionTitles(), 0)
        XCTAssertEqual(try store.conn.queryOne("SELECT COUNT(*) n FROM session_meta")?.int("n"), 3)
    }
}
