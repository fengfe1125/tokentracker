//
//  SessionTranscriptView.swift
//  TokenTrackerApp
//
//  会话详情里的「对话」页：按需读取本机原始记录，预览这次会话都聊了什么，
//  并可导出（或复制）为 Markdown。内容只在内存中，不写入用量库。
//

import AppKit
import SwiftUI
import TokenTrackerCore
import UniformTypeIdentifiers

struct SessionTranscriptView: View {
    @ObservedObject private var language = LanguageManager.shared
    let session: SessionRowModel
    /// 源文件路径；`pathResolved` 为 false 时详情还在加载，路径可能尚未解析
    let filePath: String
    let pathResolved: Bool
    let metadata: TranscriptMarkdown.Metadata

    @AppStorage("tt.transcript.showTools") private var showTools = true
    @AppStorage("tt.transcript.showThinking") private var showThinking = false
    @AppStorage("tt.transcript.showSystem") private var showSystem = false

    @State private var transcript: SessionTranscript?
    @State private var loadedKey = ""
    @State private var items: [TranscriptItem] = []
    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var fullText: Set<Int> = []
    @State private var notice: L10n.Template = ""
    @State private var exportedURL: URL?

    private var loadKey: String { "\(session.id)|\(filePath)|\(pathResolved)" }
    private var filter: TranscriptFilter {
        TranscriptFilter(includeTools: showTools, includeThinking: showThinking, includeSystem: showSystem)
    }
    private var itemsKey: String {
        "\(loadedKey)|\(showTools)|\(showThinking)|\(showSystem)|\(search)"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            content
        }
        .task(id: loadKey) { await load() }
        .task(id: itemsKey) { await rebuildItems() }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Button(L10n.text("导出 Markdown…")) { exportMarkdown() }
                    Button(L10n.text("复制为 Markdown")) { copyMarkdown() }
                } label: {
                    Label(L10n.text("导出 Markdown"), systemImage: "square.and.arrow.up")
                } primaryAction: {
                    exportMarkdown()
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(transcript?.status != .ok || transcript?.entries.isEmpty != false)
                .help(L10n.text("按当前显示选项导出为 Markdown（不受搜索影响）"))
            }
            HStack(spacing: 6) {
                FilterChip(selected: showTools, action: { showTools.toggle() }) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(L10n.text("工具调用"))
                }
                FilterChip(selected: showThinking, action: { showThinking.toggle() }) {
                    Image(systemName: "brain")
                    Text(L10n.text("思考"))
                }
                FilterChip(selected: showSystem, action: { showSystem.toggle() }) {
                    Image(systemName: "info.circle")
                    Text(L10n.text("系统注入"))
                }
                Spacer(minLength: 8)
                PageSearchField(text: $search, prompt: L10n.text("搜索对话"))
                    .frame(maxWidth: 200)
            }
            if !notice.key.isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.text(notice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let exportedURL {
                        Button(L10n.text("在 Finder 中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var statsText: String {
        guard let transcript, transcript.status == .ok else { return L10n.text("对话记录") }
        var text = L10n.text("\(transcript.count(.user)) 条提问 · \(transcript.count(.assistant)) 条回复 · \(transcript.count(.toolCall)) 次工具调用")
        if !search.isEmpty { text += " · " + L10n.text("匹配 \(items.count) 条") }
        return text
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let transcript, transcript.status != .ok {
            unavailable(transcript.status)
        } else if let transcript, loadedKey == loadKey {
            if items.isEmpty {
                emptyState(transcript)
            } else {
                list(transcript)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在读取本机对话记录…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ transcript: SessionTranscript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.droppedEntries > 0 {
                        Text(L10n.text("对话过长，只显示最近的部分（省略了最早的 \(transcript.droppedEntries) 条记录）"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(items) { item in
                        TranscriptItemRow(item: item, tool: session.tool,
                                          expanded: binding(for: item.id, in: $expanded),
                                          fullText: binding(for: item.id, in: $fullText))
                            .id(item.id)
                    }
                }
                .padding(14)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    Button { withAnimation { proxy.scrollTo(items.first?.id, anchor: .top) } } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .help(L10n.text("回到开头"))
                    Button { withAnimation { proxy.scrollTo(items.last?.id, anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .help(L10n.text("跳到末尾"))
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
        }
    }

    private func emptyState(_ transcript: SessionTranscript) -> some View {
        let hiddenSystem = showSystem ? 0 : transcript.count(.system)
        let hiddenTools = showTools ? 0 : transcript.count(.toolCall)
        let description: String
        if !search.isEmpty {
            description = L10n.text("没有包含「\(search)」的内容")
        } else if hiddenSystem + hiddenTools > 0 {
            description = L10n.text("已隐藏 \(hiddenSystem) 条系统注入、\(hiddenTools) 次工具调用，可在上方打开显示")
        } else {
            description = L10n.text("原始记录里没有可显示的消息")
        }
        return ContentUnavailableView(L10n.text("没有可显示的对话内容"),
                                      systemImage: "text.bubble",
                                      description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ status: SessionTranscript.Status) -> some View {
        let (title, icon, description): (String, String, String) = {
            switch status {
            case .missingSource:
                return (L10n.text("找不到原始记录文件"), "doc.questionmark",
                        L10n.text("原日志可能已被删除或移动；已统计的用量不受影响"))
            case .unreadable:
                return (L10n.text("无法读取原始记录"), "exclamationmark.triangle",
                        session.tool == "dsh"
                            ? L10n.text("DSH 记录需要系统 zstd（brew install zstd）")
                            : L10n.text("文件可能没有读取权限或正被占用，稍后再试"))
            case .unsupported, .ok:
                return (L10n.text("这个来源没有对话正文"), "text.bubble",
                        L10n.text("该记录只包含用量统计，无法还原对话内容"))
            }
        }()
        return ContentUnavailableView(title, systemImage: icon, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for id: Int, in set: Binding<Set<Int>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    // MARK: - 读取

    private func load() async {
        // 详情还没解析出路径时先等着（task 会在路径到达后重跑）
        guard pathResolved || !filePath.isEmpty else { return }
        let key = loadKey
        if loadedKey == key, transcript != nil { return }
        transcript = nil
        expanded = []
        fullText = []
        notice = ""
        exportedURL = nil
        let tool = session.tool, sid = session.sessionID, path = filePath
        let loaded = await Task.detached(priority: .userInitiated) {
            SessionTranscriptReader.load(tool: tool, sessionID: sid, filePath: path)
        }.value
        guard !Task.isCancelled, key == loadKey else { return }
        transcript = loaded
        loadedKey = key
    }

    private func rebuildItems() async {
        guard let transcript, transcript.status == .ok else {
            items = []
            return
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            try? await Task.sleep(nanoseconds: 180_000_000)   // 输入防抖
            if Task.isCancelled { return }
        }
        let entries = transcript.entries, filter = filter
        let built = await Task.detached(priority: .userInitiated) { () -> [TranscriptItem] in
            let all = TranscriptItem.build(entries, filter: filter)
            guard !query.isEmpty else { return all }
            return all.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
        }.value
        guard !Task.isCancelled else { return }
        items = built
    }

    // MARK: - 导出

    private var markdownLabels: TranscriptMarkdown.Labels {
        var labels = TranscriptMarkdown.Labels()
        labels.agent = L10n.text("Agent")
        labels.sessionID = L10n.text("会话 ID")
        labels.workspace = L10n.text("工作目录")
        labels.time = L10n.text("时间")
        labels.models = L10n.text("模型")
        labels.source = L10n.text("源文件")
        labels.exportedAt = L10n.text("导出时间")
        labels.user = L10n.text("用户")
        labels.assistant = L10n.text("助手")
        labels.thinking = L10n.text("思考")
        labels.system = L10n.text("系统 / 上下文注入")
        labels.tool = L10n.text("未命名工具")
        labels.arguments = L10n.text("参数")
        labels.result = L10n.text("结果")
        labels.error = L10n.text("出错")
        labels.noResult = L10n.text("（未记录结果）")
        labels.clipped = L10n.text("（内容过长，已截断，仅保留前 {0} 个字符）")
        labels.dropped = L10n.text("（对话过长，省略了最早的 {0} 条记录）")
        labels.empty = L10n.text("（没有可显示的对话内容）")
        return labels
    }

    private func renderMarkdown() -> String? {
        guard let transcript, transcript.status == .ok else { return nil }
        return TranscriptMarkdown.render(transcript, metadata: metadata, filter: filter, labels: markdownLabels)
    }

    private func exportMarkdown() {
        guard let markdown = renderMarkdown() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = TranscriptMarkdown.suggestedFileName(title: session.title,
                                                                          sessionID: session.sessionID)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            exportedURL = url
            notice = L10n.message("已导出到 \(url.lastPathComponent)")
        } catch {
            exportedURL = nil
            notice = L10n.message("导出失败，文件未保存")
        }
    }

    private func copyMarkdown() {
        guard let markdown = renderMarkdown() else { return }
        SessionFileActions.copy(markdown)
        exportedURL = nil
        notice = L10n.message("已复制 Markdown 到剪贴板")
    }
}

// MARK: - 行

private struct TranscriptItemRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let item: TranscriptItem
    let tool: String
    @Binding var expanded: Bool
    @Binding var fullText: Bool

    var body: some View {
        switch item {
        case .message(let entry):
            switch entry.kind {
            case .user: userBubble(entry)
            case .assistant: assistantBubble(entry)
            case .thinking:
                CollapsibleRow(icon: "brain", title: L10n.text("思考"), preview: entry.summary,
                               tint: .purple, expanded: $expanded) {
                    LongText(text: entry.text, clipped: entry.clipped, full: $fullText, markdown: false)
                        .foregroundStyle(.secondary)
                }
            case .system:
                CollapsibleRow(icon: "info.circle", title: L10n.text("系统注入"), preview: entry.summary,
                               tint: .secondary, expanded: $expanded) {
                    LongText(text: entry.text, clipped: entry.clipped, full: $fullText, markdown: false)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        case .tool(let call, let result):
            toolRow(call: call, result: result)
        }
    }

    private func header(icon: String, title: String, tint: Color, entry: TranscriptEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
            if !entry.model.isEmpty {
                Text(entry.model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let ts = entry.timestamp {
                Text(UIFormat.sessionDateTime(ms: ts))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func userBubble(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(icon: "person.fill", title: L10n.text("你"), tint: Color.brand, entry: entry)
            LongText(text: entry.text, clipped: entry.clipped, full: $fullText, markdown: false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brand.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func assistantBubble(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(icon: "sparkles", title: toolDisplayName(tool), tint: toolColor(tool), entry: entry)
            LongText(text: entry.text, clipped: entry.clipped, full: $fullText, markdown: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder))
    }

    private func toolRow(call: TranscriptEntry?, result: TranscriptEntry?) -> some View {
        let name = call?.toolName ?? result?.toolName ?? ""
        let failed = result?.isError == true
        return CollapsibleRow(icon: failed ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver",
                              title: name.isEmpty ? L10n.text("未命名工具") : name,
                              preview: call?.summary ?? result?.summary ?? "",
                              tint: failed ? .red : .orange,
                              monospacedTitle: true,
                              trailing: result == nil && call != nil ? L10n.text("无结果") : nil,
                              expanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let call, !call.text.isEmpty {
                    CodeBox(label: L10n.text("参数"), text: call.text, clipped: call.clipped, full: $fullText)
                }
                if let result {
                    CodeBox(label: failed ? L10n.text("结果（出错）") : L10n.text("结果"),
                            text: result.text, clipped: result.clipped, full: $fullText)
                }
            }
        }
    }
}

/// 可折叠的单行条目（思考 / 系统注入 / 工具调用）
private struct CollapsibleRow<Detail: View>: View {
    let icon: String
    let title: String
    let preview: String
    let tint: Color
    var monospacedTitle = false
    var trailing: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(monospacedTitle ? .caption.monospaced().weight(.semibold) : .caption.weight(.semibold))
                        .lineLimit(1)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let trailing {
                        Text(trailing)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                detail()
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 等宽代码框：工具参数与结果
private struct CodeBox: View {
    let label: String
    let text: String
    let clipped: Bool
    @Binding var full: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LongText(text: text.isEmpty ? "—" : text, clipped: clipped, full: $full, markdown: false,
                     previewLimit: 3_000)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// 长文本：默认只渲染前一段，避免单条超长消息拖慢列表；可展开全文
private struct LongText: View {
    @ObservedObject private var language = LanguageManager.shared
    let text: String
    let clipped: Bool
    @Binding var full: Bool
    let markdown: Bool
    var previewLimit = 6_000

    var body: some View {
        let needsCut = text.count > previewLimit
        let shown = (needsCut && !full) ? String(text.prefix(previewLimit)) : text
        VStack(alignment: .leading, spacing: 4) {
            Text(markdown ? TranscriptMarkdownText.attributed(shown) : AttributedString(shown))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if needsCut {
                Button(full ? L10n.text("收起全文") : L10n.text("展开全文（共 \(text.count) 字）")) { full.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if clipped && (!needsCut || full) {
                Text(L10n.text("原文过长，预览只保留前 \(text.count) 个字符"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

enum TranscriptMarkdownText {
    /// 助手回复是 Markdown：渲染行内样式（粗体、代码、链接），保留换行
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
