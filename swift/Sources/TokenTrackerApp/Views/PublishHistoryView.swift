//
//  PublishHistoryView.swift
//  TokenTrackerApp
//

import SwiftUI
import TokenTrackerCore

struct PublishHistoryView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("上传记录")).font(.title2.weight(.semibold))
                    Text(L10n.text("仅保留最近 50 次真正发起的网络上传"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.refreshPublishInfo()
                } label: {
                    Label(L10n.text("刷新"), systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) { confirmClear = true } label: {
                    Label(L10n.text("清空"), systemImage: "trash")
                }
                .disabled(state.publishHistory.isEmpty)
            }
            .padding(16)

            Divider()

            if state.publishHistory.isEmpty {
                ContentUnavailableView(L10n.text("还没有上传记录"), systemImage: "clock.arrow.circlepath",
                                       description: Text(L10n.text("配置校验失败、未变化和限流跳过不会记在这里。")))
            } else {
                List(state.publishHistory) { attempt in
                    attemptRow(attempt)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .onAppear { state.refreshPublishInfo() }
        .alert(L10n.text("清空上传记录？"), isPresented: $confirmClear) {
            Button(L10n.text("清空"), role: .destructive) { state.clearPublishHistory() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("只会删除本机历史，不会改变上传配置或公开数据。"))
        }
    }

    private func attemptRow(_ attempt: PublishAttempt) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: attempt.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(attempt.succeeded ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(triggerName(attempt.trigger)).fontWeight(.medium)
                    Text(attempt.succeeded ? L10n.text("成功") : L10n.text("失败"))
                        .foregroundStyle(attempt.succeeded ? .green : .red)
                    Spacer()
                    Text(Date(timeIntervalSince1970: attempt.timestamp)
                        .formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("HTTP \(attempt.status)")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attempt.bytes),
                                                   countStyle: .file))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if !attempt.error.isEmpty {
                    Text(attempt.error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func triggerName(_ trigger: PublishTrigger) -> String {
        switch trigger {
        case .automatic: return L10n.text("自动上传")
        case .manual: return L10n.text("按规则上传")
        case .forced: return L10n.text("强制上传")
        }
    }
}
