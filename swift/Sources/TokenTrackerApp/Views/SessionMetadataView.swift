//
//  SessionMetadataView.swift
//  TokenTrackerApp
//
//  会话元数据展示与文件/目录跳转：在「会话记录」底部预览卡和「会话详情」中共用，
//  统一展示时间、文件夹、会话 ID、模型、成本（Token 四项分解 + 费用）与源文件一键跳转。
//

import AppKit
import SwiftUI
import TokenTrackerCore

enum SessionFileActions {
    static func openFolder(_ path: String) {
        guard SessionSourceResolver.isExistingDirectory(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 在 Finder 中定位并选中会话记录文件；若文件刚被删除则不执行无效打开。
    static func revealFile(_ path: String) {
        guard SessionSourceResolver.fileExists(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 会话信息字段组：时间 / 文件夹 / 会话 ID / 模型 / 成本 / 文件。
struct SessionMetadataRows: View {
    @ObservedObject private var language = LanguageManager.shared

    let tool: String
    let timeText: String
    let folderPath: String
    let folderExists: Bool
    let fallbackProject: String
    let sessionID: String
    let models: [String]
    let stats: UsageStore.ToolStats
    let filePath: String
    let fileExists: Bool
    let yi: Bool
    var showTool: Bool = true
    var compact: Bool = false

    @State private var copiedField: String?

    private var labelWidth: CGFloat { L10n.isEnglish ? 68 : 52 }

    private var displayFolder: String {
        if !folderPath.isEmpty { return abbreviateHomePath(folderPath) }
        if !fallbackProject.isEmpty { return fallbackProject }
        return "—"
    }

    private var folderTooltip: String {
        !folderPath.isEmpty ? folderPath : fallbackProject
    }

    private var modelsText: String {
        let nonEmpty = models.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? "—" : nonEmpty.joined(separator: " · ")
    }

    private var displayFilePath: String {
        filePath.isEmpty ? "" : abbreviateHomePath(filePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if showTool {
                row(label: L10n.text("工具")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(toolColor(tool))
                            .frame(width: 7, height: 7)
                        Text(toolDisplayName(tool))
                            .foregroundStyle(.primary)
                    }
                }
            }

            row(label: L10n.text("时间")) {
                Text(timeText)
                    .monospacedDigit()
                    .foregroundStyle(timeText == "—" ? .tertiary : .primary)
                    .textSelection(.enabled)
            }

            row(label: L10n.text("文件夹"), alignment: .center) {
                HStack(alignment: .center, spacing: 8) {
                    Text(displayFolder)
                        .font(.caption.monospaced())
                        .foregroundStyle(displayFolder == "—" ? .tertiary : .primary)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(folderTooltip)
                    Spacer(minLength: 4)
                    if folderExists, !folderPath.isEmpty {
                        Button {
                            SessionFileActions.openFolder(folderPath)
                        } label: {
                            Label(L10n.text("在 Finder 中打开"), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(folderPath)
                    }
                }
            }

            row(label: L10n.text("会话 ID"), alignment: .center) {
                HStack(alignment: .center, spacing: 8) {
                    Text(sessionID.isEmpty ? "—" : sessionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(sessionID.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(sessionID)
                    Spacer(minLength: 4)
                    if !sessionID.isEmpty {
                        copyButton(field: "sessionID", value: sessionID,
                                   helpText: L10n.text("复制会话 ID"))
                    }
                }
            }

            row(label: L10n.text("模型")) {
                Text(modelsText)
                    .font(.caption.monospaced())
                    .foregroundStyle(modelsText == "—" ? .tertiary : .primary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(modelsText)
            }

            row(label: L10n.text("成本"), alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(UIFormat.sessionTokenBreakdown(stats, yi: yi))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2)
                        .textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(UIFormat.sessionCost(stats))
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        if let partial = UIFormat.sessionPartialUnpricedNote(stats) {
                            Text(partial)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            row(label: L10n.text("文件"), alignment: .center) {
                HStack(alignment: .center, spacing: 8) {
                    if displayFilePath.isEmpty {
                        Text("—")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(displayFilePath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(compact ? 1 : 2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(filePath)
                    }
                    Spacer(minLength: 4)
                    if !filePath.isEmpty {
                        HStack(spacing: 6) {
                            copyButton(field: "filePath", value: filePath,
                                       helpText: L10n.text("复制文件路径"), iconOnly: true)
                            Button {
                                SessionFileActions.revealFile(filePath)
                            } label: {
                                Label(L10n.text("在 Finder 中显示"),
                                      systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!fileExists)
                            .help(fileExists ? filePath : L10n.text("原记录文件已不存在"))
                        }
                    }
                }
            }
        }
        .onChange(of: sessionID) { _, _ in copiedField = nil }
    }

    private func row<Content: View>(label: String,
                                    alignment: VerticalAlignment = .firstTextBaseline,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, alignment == .top ? 1 : 0)
            content()
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyButton(field: String, value: String, helpText: String,
                            iconOnly: Bool = false) -> some View {
        let copied = copiedField == field
        return Button {
            SessionFileActions.copy(value)
            copiedField = field
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1400))
                if copiedField == field { copiedField = nil }
            }
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            } else {
                Label(copied ? L10n.text("已复制") : L10n.text("复制"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.primary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(copied ? L10n.text("已复制") : helpText)
    }
}
