//
//  AccountsView.swift
//  TokenTrackerApp
//
//  账号：上半是各账号的官方配额与余额，下半是账号管理（登录、添加 API Key、
//  Codex 多账号切换）。凭据快照仅存本机 ~/.tokentracker（0600）。
//

import SwiftUI
import TokenTrackerCore

struct AccountsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                SubscriptionSection(cards: state.subscriptionCards,
                                    refreshing: state.subscriptionRefreshing, showsHeading: false)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            SubscriptionAccountsSection(state: state)
            if state.detectInfo["codex"]?.installed == true {
                CodexAccountsSection(model: state.codex)
            }
        }
        .formStyle(.grouped)
        .pageChrome(title: L10n.text("账号")) {
            if state.subscriptionRefreshing { ProgressView().controlSize(.small) }
            Button {
                state.refreshQuotas(force: true)
            } label: {
                Label(L10n.text("刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(state.subscriptionRefreshing)
            .help(L10n.text("刷新"))
        }
    }
}

/// Codex 多账号：保存当前登录、一键切换、重命名 / 删除。
struct CodexAccountsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: CodexAccountsModel
    @State private var showCaptureSheet = false
    @State private var captureName = ""
    @State private var renameTarget: CodexAccount?
    @State private var renameName = ""

    var body: some View {
        Section(L10n.text("Codex 账号")) {
            Button(L10n.text("保存当前登录账号…")) {
                captureName = ""
                showCaptureSheet = true
            }
            if model.accounts.isEmpty {
                Text(L10n.text("还没有保存的账号。先在 Codex 登录，再点上面的按钮把当前登录存进来。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts) { account in
                    codexAccountRow(account)
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("切换后请重启 Codex 生效；账号之间切换不会丢会话。凭据快照仅存本机，不上传。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    .alert(L10n.text("保存当前登录账号"), isPresented: $showCaptureSheet) {
        TextField(L10n.text("备注名（留空则用邮箱）"), text: $captureName)
        Button(L10n.text("保存")) {
            model.captureCurrent(name: captureName)
            captureName = ""
        }
        Button(L10n.text("取消"), role: .cancel) { captureName = "" }
    } message: {
        Text(L10n.text("把当前 Codex 登录的凭据快照存到本机，之后可一键切回。"))
    }
    .alert(L10n.text("重命名账号"), isPresented: renamePresented, presenting: renameTarget) { account in
        TextField(L10n.text("备注名"), text: $renameName)
        Button(L10n.text("确定")) {
            model.rename(id: account.id, name: renameName)
            renameTarget = nil
        }
        Button(L10n.text("取消"), role: .cancel) { renameTarget = nil }
    }
    }

    @ViewBuilder
    private func codexAccountRow(_ account: CodexAccount) -> some View {
        let isActive = model.activeID == account.id
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(L10n.text("当前生效"))
                    }
                }
                if let subtitle = codexAccountSubtitle(account) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isActive {
                Button(L10n.text("切换")) { model.switchTo(id: account.id) }
            }
            Menu {
                Button(L10n.text("重命名…")) {
                    renameName = account.name
                    renameTarget = account
                }
                Button(L10n.text("删除"), role: .destructive) {
                    model.remove(id: account.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func codexAccountSubtitle(_ account: CodexAccount) -> String? {
        var parts: [String] = []
        if let email = account.email, !email.isEmpty { parts.append(email) }
        if let plan = account.plan, !plan.isEmpty { parts.append(plan) }
        parts.append("id …\(account.id.suffix(6))")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }
}
