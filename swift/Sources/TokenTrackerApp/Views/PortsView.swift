//
//  PortsView.swift
//  TokenTrackerApp
//
//  端口：先列出本机监听端口（默认过滤系统常驻进程，支持搜索、框架识别与状态栏固定），
//  再把能对上的归到开发项目。可以打开、复制、固定、关闭端口，以及启动 / 重启 / 停止项目；
//  结束进程前一律先确认。
//

import SwiftUI
import TokenTrackerCore

struct PortsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: PortsModel
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                stats
                portsCard
                projectsCard
            }
            .padding(Metrics.pagePadding)
        }
        .pageChrome(title: L10n.text("端口"))
        .onAppear { model.beginWatching() }
        .onDisappear { model.endWatching() }
    }

    // ------------------------------------------------------------ 数字 ----

    private var stats: some View {
        HStack(alignment: .top, spacing: 24) {
            stat(model.hideSystem ? L10n.text("开发端口") : L10n.text("监听端口"), "\(model.scopedPorts.count)")
            stat(L10n.text("匹配到项目"), "\(model.matchedCount)")
            stat(L10n.text("未匹配"), "\(model.unmatchedCount)")
            stat(L10n.text("运行中的项目"), "\(model.runningProjects) / \(model.projects.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // -------------------------------------------------------- 占用端口 ----

    private var portsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.text("占用端口")).font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(L10n.text("搜索端口、进程或项目"), text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .frame(width: 155)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.sunkSurface, in: Capsule())
                FilterChip(selected: model.filter == .all) { model.filter = .all } label: {
                    Text(L10n.text("全部") + " \(model.scopedPorts.count)")
                }
                FilterChip(selected: model.filter == .matched) { model.filter = .matched } label: {
                    Text(L10n.text("已匹配") + " \(model.matchedCount)")
                }
                FilterChip(selected: model.filter == .unmatched) { model.filter = .unmatched } label: {
                    Text(L10n.text("未匹配") + " \(model.unmatchedCount)")
                }
                if model.systemCount > 0 {
                    FilterChip(selected: !model.hideSystem) { model.hideSystem.toggle() } label: {
                        Text(L10n.text("含系统") + " \(model.systemCount)")
                    }
                    .help(L10n.text("切换是否显示 macOS 系统常驻进程占用的端口"))
                }
                Button {
                    model.refresh()
                } label: {
                    Label(model.scanning ? L10n.text("扫描中…") : L10n.text("重新扫描"),
                          systemImage: "arrow.clockwise")
                }
                .disabled(model.scanning)
            }
            if model.ports.isEmpty {
                ContentUnavailableView {
                    Label(model.loaded ? L10n.text("没有正在监听的端口") : L10n.text("正在扫描端口…"),
                          systemImage: "network")
                } description: {
                    if model.loaded { Text(L10n.text("启动一个开发服务器后，它占用的端口会出现在这里。")) }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if model.scopedPorts.isEmpty && model.hideSystem && model.systemCount > 0 {
                ContentUnavailableView {
                    Label(L10n.text("没有正在运行的开发端口"), systemImage: "network")
                } description: {
                    Text(L10n.text("已隐藏 \(model.systemCount) 个系统进程端口；启动开发服务器后会出现在这里。"))
                } actions: {
                    Button(L10n.text("显示系统端口")) { model.hideSystem = false }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ownershipBar
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], spacing: 8) {
                    ForEach(model.visiblePorts) { port in
                        PortTile(port: port, tint: tint(port), owner: owner(port),
                                 pinned: model.isPinned(port.port, state: state),
                                 selected: model.selectedPort == port.port) {
                            model.select(port.port)
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                if model.visiblePorts.isEmpty {
                    Text(L10n.text("没有符合筛选的端口。")).font(.caption).foregroundStyle(.secondary)
                }
                if let port = model.selected {
                    detail(port)
                } else {
                    Text(L10n.text("点一个端口查看工作目录、命令行与进程详情，并打开、固定或关闭它。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.clearNotice() } label: {
                        Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tint(_ port: ListeningPort) -> Color {
        port.projectID == nil ? .secondary : model.color(port.projectID)
    }

    private func owner(_ port: ListeningPort) -> String {
        if let name = port.projectName {
            return model.isAgent(port) ? name + " · " + L10n.text("Agent 进程") : name
        }
        if model.isSystem(port) { return L10n.text("系统进程") }
        if model.isAgent(port) { return L10n.text("Agent 进程") }
        return L10n.text("未匹配")
    }

    private struct OwnershipGroup: Identifiable {
        let id: String
        let name: String
        let count: Int
        let color: Color
    }

    /// 端口归属：每个项目一段，未匹配的灰色一段。
    private var ownershipBar: some View {
        let groups = ownershipGroups
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedBar(
                segments: groups.map {
                    SegmentedBarSegment(value: Double($0.count), color: $0.color, minWidth: 4)
                },
                height: 10,
                spacing: 2,
                cornerRadius: 3
            )
            .animation(.snappy(duration: 0.3), value: groups.map(\.count))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(groups) { group in
                        HStack(spacing: 5) {
                            Circle().fill(group.color).frame(width: 7, height: 7)
                            Text(group.name).foregroundStyle(.secondary)
                            Text("\(group.count)").fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var ownershipGroups: [OwnershipGroup] {
        var counts: [String: (name: String, count: Int)] = [:]
        var order: [String] = []
        for port in model.scopedPorts {
            guard let id = port.projectID else { continue }
            if counts[id] == nil {
                order.append(id)
                counts[id] = (port.projectName ?? id, 0)
            }
            counts[id]!.count += 1
        }
        var groups: [OwnershipGroup] = order.compactMap { id in
            guard let item = counts[id], item.count > 0 else { return nil }
            return OwnershipGroup(id: id, name: item.name, count: item.count, color: model.color(id))
        }
        if model.unmatchedCount > 0 {
            groups.append(OwnershipGroup(id: "__unmatched__", name: L10n.text("未匹配"),
                                         count: model.unmatchedCount, color: Color.secondary.opacity(0.6)))
        }
        return groups
    }

    // ------------------------------------------------------------ 详情 ----

    private func detail(_ port: ListeningPort) -> some View {
        let pinned = model.isPinned(port.port, state: state)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Text(verbatim: ":\(port.port)")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint(port))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(port.displayName).fontWeight(.semibold).lineLimit(1)
                        Text(verbatim: "PID \(port.pids.map(String.init).joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                        Pill(text: port.isLocalOnly ? L10n.text("仅本机") : "\(port.bindDisplay) · " + L10n.text("局域网可达"),
                             tint: port.isLocalOnly ? .secondary : .orange)
                        if let uptime = port.uptime {
                            Text(L10n.text("已运行 \(L10n.Template(verbatim: PortFormat.uptime(uptime)))"))
                                .foregroundStyle(.secondary)
                        }
                        if let mem = port.memoryBytes {
                            Text(PortFormat.memory(mem))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .lineLimit(1)
                    Text(explanation(port)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                detailActions(port, pinned: pinned)
            }

            if let dir = port.cwd ?? port.parentCwd {
                HStack(spacing: 8) {
                    Text(L10n.text("工作目录"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(PortFormat.abbreviate(dir))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.revealDirectory(dir) } label: {
                        Label(L10n.text("打开目录"), systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(L10n.text("在 Finder 中打开"))
                    Button { model.openInTerminal(dir) } label: {
                        Label(L10n.text("终端"), systemImage: "terminal")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(L10n.text("在终端中打开该目录"))
                }
            }

            if let cmd = port.commandLine ?? port.executable, !cmd.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(L10n.text("命令行"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(cmd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.copyCommand(port) } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(L10n.text("复制命令行"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkPanel()
    }

    private func explanation(_ port: ListeningPort) -> String {
        if let name = port.projectName {
            if model.isAgent(port) {
                return L10n.text("匹配到项目 \(L10n.Template(verbatim: name))：这是 Agent 进程，停止项目时不会结束它")
            }
            return L10n.text("匹配到项目 \(L10n.Template(verbatim: name))：进程的工作目录在这个项目里")
        }
        if model.isSystem(port) { return L10n.text("系统进程占用，TokenTracker 不提供关闭") }
        if !model.canClose(port) { return L10n.text("这个进程不属于当前用户，TokenTracker 不提供关闭") }
        return L10n.text("没有正在开发的项目占用这个端口")
    }

    @ViewBuilder
    private func detailActions(_ port: ListeningPort, pinned: Bool) -> some View {
        let force = model.stubborn.contains(port.port)
        if model.pending == .closePort(port.port) || model.pending == .forceClosePort(port.port) {
            let forcing = model.pending == .forceClosePort(port.port)
            HStack(spacing: 8) {
                Text(forcing
                     ? L10n.text("强制结束 \(L10n.Template(verbatim: port.process))？未保存的数据会丢失。")
                     : L10n.text("结束 \(L10n.Template(verbatim: port.process)) 并释放这个端口？"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("取消")) { model.pending = nil }
                Button(forcing ? L10n.text("确认强制结束") : L10n.text("确认关闭"), role: .destructive) {
                    model.closePort(port.port, force: forcing)
                }
            }
        } else {
            HStack(spacing: 6) {
                Button(L10n.text("打开") + " :\(port.port)") { model.openInBrowser(port.port) }
                Button { model.copyURL(port.port) } label: {
                    Image(systemName: "link")
                }
                .help(L10n.text("复制 localhost 地址"))
                Button {
                    model.togglePin(port.port, state: state)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? Color.brand : Color.primary)
                }
                .help(pinned ? L10n.text("已固定到状态栏面板（点击取消）") : L10n.text("固定到状态栏面板"))
                if model.canClose(port) {
                    Button(force ? L10n.text("强制结束") : L10n.text("关闭端口"), role: .destructive) {
                        model.pending = force ? .forceClosePort(port.port) : .closePort(port.port)
                    }
                }
            }
        }
    }

    // -------------------------------------------------------- 开发项目 ----

    private var projectsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: L10n.text("开发项目")) {
                Text(L10n.text("本月有用量或已配启动命令的项目；占用了上面的端口会自动关联"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            if model.projects.isEmpty {
                Text(model.loaded ? L10n.text("本月还没有带工作目录的项目用量。") : L10n.text("正在读取项目…"))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { Divider() }
                        ProjectPortRow(model: model, state: state, project: project)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// 一个端口方块：端口号按归属着色，展示框架名、状态栏固定标记与内存/时长。
private struct PortTile: View {
    let port: ListeningPort
    let tint: Color
    let owner: String
    let pinned: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: ":\(port.port)")
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                    Spacer(minLength: 2)
                    if !port.isLocalOnly {
                        Image(systemName: "network")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(L10n.text("监听地址 \(L10n.Template(verbatim: port.bindDisplay))（局域网可达）"))
                    }
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.brand)
                            .help(L10n.text("已固定到状态栏面板"))
                    }
                }
                Text(port.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(owner).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
                if let footer = footerText {
                    Text(footer)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.brand : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("端口") + " \(port.port), \(port.displayName), \(owner)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footerText: String? {
        var parts: [String] = []
        if let uptime = port.uptime { parts.append(PortFormat.uptime(uptime)) }
        if let mem = port.memoryBytes { parts.append(PortFormat.memory(mem)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 开发项目的一行：状态、启动命令、可点选端口、启动 / 重启 / 停止。
private struct ProjectPortRow: View {
    @ObservedObject var model: PortsModel
    @ObservedObject var state: AppState
    let project: PortsModel.Project
    @State private var draft = ""

    private var editing: Bool { model.editingProject == project.id }
    private var needsCommand: Bool { project.root != nil && project.command == nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(project.running ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
                .accessibilityLabel(project.running ? L10n.text("运行中") : L10n.text("未运行"))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle().fill(model.color(project.id)).frame(width: 7, height: 7)
                    Text(project.name).fontWeight(.semibold).lineLimit(1)
                }
                Text(project.root.map(PortFormat.abbreviate) ?? L10n.text("项目目录已不存在"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(width: 170, alignment: .leading)
            command
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(project.ports) { port in
                    Button {
                        model.revealPort(port.port)
                    } label: {
                        Text(verbatim: ":\(port.port)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(model.color(project.id))
                            .background(model.color(project.id).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("选中查看 :\(port.port) 详情"))
                }
            }
            if !project.agentPorts.isEmpty {
                Text(L10n.text("另有 \(project.agentPorts.count) 个 Agent 端口"))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("Agent 自己占用的端口，停止项目时不受影响")
                          + "：" + project.agentPorts.map { ":\($0.port)" }.joined(separator: " "))
            }
            if let root = project.root {
                Menu {
                    Button(L10n.text("在 Finder 中打开")) { model.revealDirectory(root) }
                    Button(L10n.text("在终端中打开")) { model.openInTerminal(root) }
                    if project.manual != nil {
                        Divider()
                        Button(L10n.text("恢复自动识别")) { model.saveCommand("", for: project.id, state: state) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.text("更多"))
            }
            actions
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var command: some View {
        if project.root == nil {
            EmptyView()
        } else if needsCommand && !editing {
            HStack(spacing: 6) {
                Pill(text: L10n.text("未能识别启动命令"), tint: .orange)
                Button(L10n.text("填写启动命令")) {
                    draft = ""
                    model.editingProject = project.id
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if editing {
            HStack(spacing: 6) {
                TextField(L10n.text("手动填写，例如 npm run dev"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(minWidth: 140, maxWidth: 260)
                    .onSubmit { model.saveCommand(draft, for: project.id, state: state) }
                Button(L10n.text("保存")) { model.saveCommand(draft, for: project.id, state: state) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && project.manual == nil)
                Button(L10n.text("取消")) { model.editingProject = nil }
            }
        } else if let command = project.command {
            HStack(spacing: 6) {
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(L10n.text("修改")) {
                    draft = project.manual ?? command
                    model.editingProject = project.id
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var source: String {
        if project.manual != nil { return L10n.text("手动填写") }
        guard let detected = project.detected else { return "" }
        if let target = detected.target {
            return L10n.text("自动识别 · \(L10n.Template(verbatim: detected.file)) 的 \(L10n.Template(verbatim: target))")
        }
        return L10n.text("自动识别 · \(L10n.Template(verbatim: detected.file))")
    }

    @ViewBuilder
    private var actions: some View {
        if model.pending == .stopProject(project.id) {
            HStack(spacing: 8) {
                Text(L10n.text("将结束 \(Set(project.ports.flatMap(\.pids)).count) 个进程并释放")
                     + " " + project.ports.map { ":\($0.port) (\($0.process))" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button(L10n.text("取消")) { model.pending = nil }
                Button(L10n.text("确认停止"), role: .destructive) { model.stopProject(project.id) }
            }
        } else if model.pending == .restartProject(project.id) {
            HStack(spacing: 8) {
                Text(L10n.text("将先停止 \(Set(project.ports.flatMap(\.pids)).count) 个进程，再在终端重新启动"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button(L10n.text("取消")) { model.pending = nil }
                Button(L10n.text("确认重启")) { model.restartProject(project.id) }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.starting.contains(project.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.text("启动中…")).font(.callout).foregroundStyle(.secondary)
            }
        } else if project.running {
            HStack(spacing: 6) {
                if project.root != nil, project.command != nil, project.ports.contains(where: model.canClose) {
                    Button(L10n.text("重启")) { model.pending = .restartProject(project.id) }
                }
                Button(L10n.text("停止"), role: .destructive) { model.pending = .stopProject(project.id) }
                    .disabled(!project.ports.contains(where: model.canClose))
            }
        } else if project.root != nil {
            Button(L10n.text("启动")) { model.start(project.id) }
                .buttonStyle(.borderedProminent)
                .disabled(project.command == nil)
                .help(L10n.text("在终端里打开并运行启动命令"))
        }
    }
}

enum PortFormat {
    /// 运行时长：按最大的两个单位显示。
    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return L10n.text("\(days) 天") }
        if hours > 0 { return L10n.text("\(hours) 小时 \(minutes) 分") }
        if minutes > 0 { return L10n.text("\(minutes) 分钟") }
        return L10n.text("不到 1 分钟")
    }

    /// 内存常驻体积（RSS）紧凑显示。
    static func memory(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", max(1, mb))
    }

    /// 主目录缩写成 ~
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
