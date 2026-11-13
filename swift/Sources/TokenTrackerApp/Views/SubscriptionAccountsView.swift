import AppKit
import SwiftUI
import TokenTrackerCore

/// 「登录账号…」菜单：有区域的供应商展开成子菜单。
struct SubscriptionLoginMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu(L10n.text("登录账号…")) {
            ForEach(SubscriptionAuth.loginProviders, id: \.self) { provider in
                let regions = SubscriptionAuth.regions(for: provider)
                if regions.isEmpty {
                    Button(provider.displayName) { state.startSubscriptionLogin(provider) }
                } else {
                    Menu(provider.displayName) {
                        ForEach(regions, id: \.self) { region in
                            Button(Self.regionName(region)) { state.startSubscriptionLogin(provider, region: region) }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    static func regionName(_ region: String) -> String {
        switch region {
        case "cn": return L10n.text("中国区")
        case "global": return L10n.text("国际区")
        case "zai": return "Z.ai"
        case "bigmodel": return "BigModel"
        default: return region
        }
    }
}

/// 登录弹窗：设备码 / 粘贴授权码 / 浏览器登录。
struct SubscriptionLoginSheet: View {
    @ObservedObject var state: AppState
    let login: SubscriptionLoginState
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("登录 \(login.provider.displayName)")).font(.headline)
            content
            if let error = state.subscriptionLogin?.error {
                Text(SubscriptionLoginSheet.message(error)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.text("取消")) { state.cancelSubscriptionLogin() }
                    .keyboardShortcut(.cancelAction)
                if state.subscriptionLogin?.flow?.needsPastedCode == true {
                    Button(L10n.text("完成登录")) { state.submitSubscriptionCode(code) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty
                                  || state.subscriptionLogin?.phase == .finishing)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private var content: some View {
        let current = state.subscriptionLogin
        switch (current?.phase, current?.flow?.prompt) {
        case (.starting?, _), (nil, _):
            HStack { ProgressView().controlSize(.small); Text(L10n.text("正在打开官方登录页…")) }
        case (.failed?, _):
            EmptyView()
        case (_, .deviceCode(let userCode, let url)?):
            Text(L10n.text("已在浏览器打开官方登录页。确认页面上的验证码与下面一致后授权，完成后自动返回。"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(userCode).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Button(L10n.text("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                }
            }
            linkRow(url)
            HStack { ProgressView().controlSize(.small); Text(L10n.text("等待授权…")).foregroundStyle(.secondary) }
        case (_, .pasteCode(let url)?):
            Text(L10n.text("已在浏览器打开官方授权页。授权后把页面显示的授权码粘贴到这里。"))
                .fixedSize(horizontal: false, vertical: true)
            linkRow(url)
            TextField(L10n.text("授权码"), text: $code)
                .textFieldStyle(.roundedBorder)
            if current?.phase == .finishing {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在验证…")).foregroundStyle(.secondary) }
            }
        case (_, .browser(let url)?):
            Text(L10n.text("已在浏览器打开官方登录页。登录完成后 TokenTracker 会自动获取账号。"))
                .fixedSize(horizontal: false, vertical: true)
            linkRow(url)
            HStack { ProgressView().controlSize(.small); Text(L10n.text("等待登录…")).foregroundStyle(.secondary) }
        default:
            EmptyView()
        }
    }

    private func linkRow(_ url: URL) -> some View {
        Button(L10n.text("重新打开登录页")) { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
    }

    static func message(_ error: SubscriptionAuthError) -> String {
        switch error {
        case .cancelled: return L10n.text("已取消")
        case .timedOut: return L10n.text("登录超时，请重新开始")
        case .declined: return L10n.text("授权被拒绝")
        case .invalidCode: return L10n.text("授权码无效或已过期，请重新复制后再试")
        case .invalidInput: return L10n.text("输入无效")
        case .unsupported: return L10n.text("暂不支持该供应商登录")
        case .http(let status): return L10n.text("登录失败（\(status)）")
        case .network: return L10n.text("网络连接失败，请重试")
        case .malformed: return L10n.text("官方返回格式无法识别，请重试")
        }
    }
}

/// 手动添加 API Key。
struct AddAPIKeySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var provider: SubscriptionProvider = .deepseek
    @State private var region = "cn"
    @State private var key = ""
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("添加 API Key")).font(.headline)
            Picker(L10n.text("供应商"), selection: $provider) {
                ForEach(SubscriptionAccountStore.apiKeyProviders, id: \.self) { Text($0.displayName).tag($0) }
            }
            if provider == .minimax {
                Picker(L10n.text("区域"), selection: $region) {
                    Text(L10n.text("中国区")).tag("cn")
                    Text(L10n.text("国际区")).tag("global")
                }
                .pickerStyle(.segmented)
            }
            SecureField("API Key", text: $key).textFieldStyle(.roundedBorder)
            TextField(L10n.text("备注（可选）"), text: $label).textFieldStyle(.roundedBorder)
            Text(L10n.text("只用于读取额度或余额，不会发起模型调用。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("添加")) {
                    if state.addSubscriptionKey(provider: provider, key: key, label: label,
                                                region: provider == .minimax ? region : nil) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
