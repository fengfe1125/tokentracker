//
//  PortsTests.swift
//  TokenTrackerCoreTests
//
//  端口：lsof / ps 输出解析、项目匹配、启动命令识别、结束进程的拒绝规则。
//  全部用注入的执行器和临时目录，不扫描真实端口、不向真实进程发信号。
//

import XCTest
@testable import TokenTrackerCore

final class PortScannerTests: XCTestCase {
    private let listeners = """
    p667
    cControlCenter
    u501
    Ltester
    f9
    n*:7000
    f10
    n*:7000
    f11
    n*:5000
    p4100
    cnode
    u501
    Ltester
    f20
    n127.0.0.1:3000
    f21
    n[::1]:3000
    p4200
    cnode
    u501
    Ltester
    f20
    n*:3000
    p9000
    cidle
    u0
    Lroot
    """
    private let cwds = "p667\nfcwd\nn/\np4100\nfcwd\nn/Users/tester/code/web\np4200\nfcwd\nn/Users/tester/code/web\n"
    private let processes = """
      667   03-01:36:12 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
     4100      02:16:20 /opt/homebrew/bin/node
     4200         58:24 /Users/tester/Library/Application Support/x/node helper
    """

    func testParsesListenersAndMergesAddressFamilies() {
        let parsed = PortScanner.parseListeners(listeners)
        XCTAssertEqual(parsed.map(\.pid), [667, 4100, 4200])   // 没有监听端口的进程不计
        XCTAssertEqual(parsed[0].ports, [5000, 7000])
        XCTAssertEqual(parsed[1].ports, [3000])
        XCTAssertEqual(parsed[1].command, "node")
        XCTAssertEqual(parsed[0].uid, 501)
    }

    func testParsesCwdProcessesAndElapsed() {
        XCTAssertEqual(PortScanner.parseCwd(cwds)[4100], "/Users/tester/code/web")
        let info = PortScanner.parseProcesses(processes)
        XCTAssertEqual(info[4200]?.command, "/Users/tester/Library/Application Support/x/node helper")
        XCTAssertEqual(info[4200]?.uptime, 58 * 60 + 24)
        XCTAssertEqual(PortScanner.parseElapsed("02:16:20"), 2 * 3600 + 16 * 60 + 20)
        XCTAssertEqual(PortScanner.parseElapsed("03-01:36:12"), 3 * 86_400 + 3600 + 36 * 60 + 12)
        XCTAssertNil(PortScanner.parseElapsed("garbage"))
    }

    func testScanCombinesCommandsAndSharesPortAcrossProcesses() {
        let listeners = listeners, cwds = cwds, processes = processes
        let scanner = PortScanner { argv in
            if argv.contains("-sTCP:LISTEN") { return listeners }
            if argv.contains("cwd") {
                XCTAssertEqual(argv.last, "667,4100,4200")
                return cwds
            }
            return processes
        }
        let ports = scanner.scan()
        XCTAssertEqual(ports.map(\.port), [3000, 5000, 7000])
        XCTAssertEqual(ports[0].pids, [4100, 4200])
        XCTAssertEqual(ports[0].cwd, "/Users/tester/code/web")
        XCTAssertEqual(ports[0].executable, "/opt/homebrew/bin/node")
        XCTAssertEqual(ports[1].uptime, 3 * 86_400 + 3600 + 36 * 60 + 12)
    }

    func testEmptyOutputMeansNoPortsAndNoFurtherCommands() {
        let calls = StateBox(0)
        let scanner = PortScanner { _ in calls.value += 1; return "" }
        XCTAssertTrue(scanner.scan().isEmpty)
        XCTAssertEqual(calls.value, 1)
    }
}

final class PortMatcherTests: XCTestCase {
    private let directories = [
        ProjectDirectory(path: "/Users/tester/code", projectID: "directory:/Users/tester/code", name: "code"),
        ProjectDirectory(path: "/Users/tester/code/web", projectID: "git:/Users/tester/code/web/.git", name: "web"),
        ProjectDirectory(path: "/Users/tester", projectID: "directory:/Users/tester", name: "home"),
        ProjectDirectory(path: "/", projectID: "directory:/", name: "root"),
    ]

    func testLongestPrefixWinsAndHomeAndRootNeverMatch() {
        let home = "/Users/tester"
        XCTAssertEqual(PortMatcher.match(cwd: "/Users/tester/code/web/apps/api", directories: directories, home: home)?.name, "web")
        XCTAssertEqual(PortMatcher.match(cwd: "/Users/tester/code", directories: directories, home: home)?.name, "code")
        // 同名前缀但不是子目录
        XCTAssertEqual(PortMatcher.match(cwd: "/Users/tester/code/website", directories: directories, home: home)?.name, "code")
        XCTAssertNil(PortMatcher.match(cwd: "/Users/tester/Downloads", directories: directories, home: home))
        XCTAssertNil(PortMatcher.match(cwd: "/", directories: directories, home: home))
        XCTAssertNil(PortMatcher.match(cwd: nil, directories: directories, home: home))
    }

    func testApplyFillsProjectAndRootResolution() {
        let port = ListeningPort(port: 3000, pids: [1], process: "node", uid: 501, user: "t",
                                 cwd: "/Users/tester/code/web")
        let matched = PortMatcher.apply([port], directories: directories, home: "/Users/tester")
        XCTAssertEqual(matched[0].projectName, "web")
        XCTAssertEqual(PortMatcher.root(projectID: "git:/Users/tester/code/web/.git", directories: directories),
                       "/Users/tester/code/web")
        XCTAssertEqual(PortMatcher.root(projectID: "directory:/Users/tester/code", directories: directories),
                       "/Users/tester/code")
        let manual = [ProjectDirectory(path: "/a/b/c", projectID: "manual", name: "m"),
                      ProjectDirectory(path: "/a/b", projectID: "manual", name: "m")]
        XCTAssertEqual(PortMatcher.root(projectID: "manual", directories: manual), "/a/b")
    }

    func testStoreListsRecordedDirectories() throws {
        let tmp = try TempDir()
        let store = try tmp.store()
        let project = tmp.path("demo")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try store.recordProjectPath(tool: "claude", srcKey: "k1", path: project)
        try store.conn.commit()
        let listed = try store.projectDirectories()
        let resolved = URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(listed.first { $0.path == resolved }?.name, "demo")
    }
}

final class StartCommandDetectorTests: XCTestCase {
    private func project(_ files: [String: String]) throws -> (TempDir, String) {
        let tmp = try TempDir()
        for (name, body) in files { try body.write(toFile: tmp.path(name), atomically: true, encoding: .utf8) }
        return (tmp, tmp.url.path)
    }

    func testPackageScriptsPickManagerFromLockfile() throws {
        let scripts = #"{"scripts":{"build":"tsc","start":"node .","dev":"vite"}}"#
        var (tmp, dir) = try project(["package.json": scripts])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir),
                       StartCommand(command: "npm run dev", file: "package.json", target: "dev"))
        (tmp, dir) = try project(["package.json": scripts, "pnpm-lock.yaml": ""])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir)?.command, "pnpm dev")
        (tmp, dir) = try project(["package.json": #"{"scripts":{"start":"node ."}}"#, "yarn.lock": ""])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir)?.command, "yarn start")
        (tmp, dir) = try project(["package.json": #"{"scripts":{"start":"node ."}}"#])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir)?.command, "npm start")
        _ = tmp
    }

    func testFallsBackToOtherProjectFilesOrNil() throws {
        var (tmp, dir) = try project(["package.json": #"{"scripts":{"build":"tsc"}}"#,
                                      "Makefile": "build:\n\tcc x.c\nrun: build\n\t./a.out\n"])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir),
                       StartCommand(command: "make run", file: "Makefile", target: "run"))
        (tmp, dir) = try project(["Makefile": "dev := 1\nall:\n\ttrue\n", "Cargo.toml": ""])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir)?.command, "cargo run")
        (tmp, dir) = try project(["manage.py": ""])
        XCTAssertEqual(StartCommandDetector.detect(directory: dir)?.command, "python3 manage.py runserver")
        (tmp, dir) = try project(["README.md": "nothing to run"])
        XCTAssertNil(StartCommandDetector.detect(directory: dir))
        (tmp, dir) = try project(["package.json": "not json"])
        XCTAssertNil(StartCommandDetector.detect(directory: dir))
        _ = tmp
    }
}

final class PortControlTests: XCTestCase {
    private func port(_ pids: [Int32], uid: Int = 501, executable: String? = "/opt/homebrew/bin/node") -> ListeningPort {
        ListeningPort(port: 3000, pids: pids, process: "node", uid: uid, user: "t", executable: executable)
    }

    func testRefusesSystemForeignAndSpecialProcesses() {
        let control = PortControl(signal: { _, _ in 0 }, currentUID: 501, ownPID: 77)
        XCTAssertTrue(control.canTerminate(port([4100])))
        XCTAssertFalse(control.canTerminate(port([4100], uid: 0)))
        XCTAssertFalse(control.canTerminate(port([1])))
        XCTAssertFalse(control.canTerminate(port([77])))
        XCTAssertFalse(control.canTerminate(port([])))
        XCTAssertFalse(control.canTerminate(port([667], executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")))
        XCTAssertFalse(control.canTerminate(port([644], executable: "/usr/libexec/rapportd")))
    }

    func testRecognizesAgentProcessesByNameOrExecutablePath() {
        var claude = port([1000]); claude.process = "claude"
        XCTAssertTrue(PortControl.isAgent(claude))
        var versioned = port([1001], executable: "/Users/t/.local/share/claude/versions/2.1.323")
        versioned.process = "2.1.323"
        XCTAssertTrue(PortControl.isAgent(versioned))
        var bundled = port([1002], executable: "/Users/t/Library/x/claude.app/Contents/MacOS/claude")
        bundled.process = "helper"
        XCTAssertTrue(PortControl.isAgent(bundled))
        var codex = port([1003], executable: "/opt/homebrew/bin/codex"); codex.process = "codex"
        XCTAssertTrue(PortControl.isAgent(codex))
        // 普通开发服务器，以及名字里只是包含 agent 名的进程，都不算
        XCTAssertFalse(PortControl.isAgent(port([1004])))
        var lookalike = port([1005], executable: "/usr/local/bin/pipenv"); lookalike.process = "pipenv"
        XCTAssertFalse(PortControl.isAgent(lookalike))
    }

    func testTerminateSignalsEachProcessOnceAndReportsFailures() {
        let sent = StateBox<[(Int32, Int32)]>([])
        let control = PortControl(signal: { pid, sig in sent.value.append((pid, sig)); return pid == 9 ? -1 : 0 },
                                  currentUID: 501, ownPID: 77)
        var second = port([4100, 9]); second.port = 3001
        let failed = control.terminate([port([4100]), second, port([5], uid: 0)])
        XCTAssertEqual(sent.value.map(\.0), [4100, 9])
        XCTAssertTrue(sent.value.allSatisfy { $0.1 == SIGTERM })
        XCTAssertEqual(failed, [9, 5])
        sent.value = []
        control.terminate([port([4100])], force: true)
        XCTAssertEqual(sent.value.first?.1, SIGKILL)
    }

    func testStartLineQuotesDirectoryAndRejectsBadCommands() {
        XCTAssertEqual(PortControl.startLine(directory: "/Users/t/my app's", command: " pnpm dev "),
                       #"cd '/Users/t/my app'"'"'s' && pnpm dev"#)
        XCTAssertNil(PortControl.startLine(directory: "relative", command: "pnpm dev"))
        XCTAssertNil(PortControl.startLine(directory: "/x", command: "a\nb"))
        XCTAssertNil(PortControl.startLine(directory: "/x", command: "   "))
        XCTAssertFalse(PortControl.isValidCommand(String(repeating: "a", count: 501)))
    }
}

final class PortSettingsTests: XCTestCase {
    func testMenubarPortsAndProjectCommandsValidation() throws {
        XCTAssertTrue(SettingsStore.isValid(key: "menubar_ports", value: [3000, 8080]))
        XCTAssertTrue(SettingsStore.isValid(key: "menubar_ports", value: [Int]()))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: [0]))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: [70000]))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: [true]))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: [3000.5]))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: Array(1...21)))
        XCTAssertFalse(SettingsStore.isValid(key: "menubar_ports", value: "3000"))
        XCTAssertTrue(SettingsStore.isValid(key: "project_commands", value: ["/Users/t/web": "pnpm dev"]))
        XCTAssertFalse(SettingsStore.isValid(key: "project_commands", value: ["web": "pnpm dev"]))
        XCTAssertFalse(SettingsStore.isValid(key: "project_commands", value: ["/x": "a\nb"]))
        XCTAssertFalse(SettingsStore.isValid(key: "project_commands", value: ["/x": 1]))

        let tmp = try TempDir()
        let store = SettingsStore(path: tmp.path("settings.json"))
        XCTAssertEqual((store.effective()["menubar_ports"] as? [Any])?.count, 0)
        XCTAssertTrue(store.set(key: "menubar_ports", value: [8080, 3000]))
        XCTAssertTrue(store.set(key: "project_commands", value: ["/Users/t/web": "pnpm dev"]))
        let reloaded = SettingsStore(path: tmp.path("settings.json")).effective()
        XCTAssertEqual((reloaded["menubar_ports"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }, [8080, 3000])
        XCTAssertEqual(reloaded["project_commands"] as? [String: String], ["/Users/t/web": "pnpm dev"])
    }
}
