//
//  DataSettingsSection.swift
//  TokenTrackerApp
//
//  设置 › 数据与同步：合并原「价格与数据」与「公开统计」。
//  公开统计默认关闭，未配置时折叠表单减少干扰。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct DataSettingsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    @State private var publishEndpoint = ""
    @State private var publishHandle = ""
    @State private var publishDays = 365
    @State private var publishToken = ""
    @State private var showForceConfirmation = false
    @State private var showPublishConfig = false

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (state.settings[key] as? NSNumber)?.boolValue ?? false },
            set: { state.updateSetting(key: key, value: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            priceSection
            localDataSection
            publishSection
        }
        .onAppear {
            loadPublishDrafts()
            state.refreshPublishInfo()
            if state.prefs.publishEnabled || state.publishConfigurationReady {
                showPublishConfig = true
            }
        }
        .alert(L10n.text("确认强制上传？"), isPresented: $showForceConfirmation) {
            Button(L10n.text("强制上传"), role: .destructive) {
                state.performPublish(trigger: .forced)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("这会绕过内容去重、15 分钟间隔和失败退避，但仍会校验服务地址、用户名与 Token。"))
        }
    }

    // ---------------------------------------------------------- 价格估算 ----

    private var priceSection: some View {
        SettingsSection(L10n.text("价格估算")) {
            SettingsToggle(L10n.text("自动同步官方价格"),
                           detail: L10n.text("每天从模型供应商的公开页面更新 API 费率。关闭后仍用本机已保存的费率估算；Token 统计和来源费用不受影响。"),
                           isOn: binding("price_sync_enabled"))
            SettingsDivider()
            SettingsRow(priceSyncStatusText, detail: priceSyncDetail) {
                HStack(spacing: 8) {
                    if state.priceSyncRunning { ProgressView().controlSize(.small) }
                    Button(L10n.text("立即同步")) { state.syncPricesNow() }
                        .disabled(state.priceSyncRunning)
                }
            }
            if !state.priceSyncMessage.isEmpty {
                Text(state.priceSyncMessage)
                    .font(.caption)
                    .foregroundStyle(state.priceSyncState == "failed" ? .red : .secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var priceSyncStatusText: String {
        if state.priceSyncRunning { return L10n.text("正在同步价格…") }
        switch state.priceSyncState {
        case "success": return L10n.text("价格同步成功")
        case "partial": return L10n.text("部分价格来源同步失败")
        case "failed": return L10n.text("价格同步失败，继续使用上次有效价格")
        default: return L10n.text("尚未同步价格")
        }
    }

    private var priceSyncDetail: String {
        guard state.priceSyncLastSuccessAtMs > 0 else { return L10n.text("上次成功同步：从未") }
        let date = Date(timeIntervalSince1970: Double(state.priceSyncLastSuccessAtMs) / 1000)
        return L10n.text("上次成功同步：\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
    }

    // ---------------------------------------------------------- 本地数据 ----

    private var localDataSection: some View {
        SettingsSection(L10n.text("本地数据"),
                        footer: L10n.text("原始用量日志始终只在本机读取和保存。设置保存在 ~/.tokentracker/settings.json。")) {
            SettingsRow(L10n.text("数据目录"), detail: "~/.tokentracker") {
                Button(L10n.text("在 Finder 中打开")) {
                    let path = NSHomeDirectory() + "/.tokentracker"
                    try? FileManager.default.createDirectory(atPath: path,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
    }

    // ---------------------------------------------------------- 公开统计 ----

    private var publishSection: some View {
        SettingsSection(L10n.text("公开统计"), footer: publishPrivacyText) {
            SettingsToggle(L10n.text("扫描后自动上传"), isOn: Binding(
                get: { state.prefs.publishEnabled },
                set: { on in
                    state.setPublishEnabled(on)
                    if on { showPublishConfig = true }
                }
            ))
            SettingsDivider()
            SettingsDisclosureRow(isExpanded: $showPublishConfig) {
                HStack(spacing: 8) {
                    Text(L10n.text("服务配置与上传"))
                    SettingsBadge(
                        text: state.publishConfigurationReady ? L10n.text("已配置") : L10n.text("未配置"),
                        tint: state.publishConfigurationReady ? .green : .secondary
                    )
                }
            }
            if showPublishConfig {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsDivider()
                    SettingsRow(L10n.text("HTTPS 服务地址")) {
                        TextField(L10n.text("HTTPS 服务地址"), text: $publishEndpoint,
                                  prompt: Text("https://tt.example.com"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    SettingsDivider()
                    SettingsRow(L10n.text("用户名")) {
                        TextField(L10n.text("用户名"), text: $publishHandle, prompt: Text("your-handle"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    SettingsDivider()
                    SettingsRow(L10n.text("公开时间范围")) {
                        SettingsMenuPicker(title: publishDaysTitle) {
                            Picker(L10n.text("公开时间范围"), selection: $publishDays) {
                                Text(L10n.text("90 天")).tag(90)
                                Text(L10n.text("365 天")).tag(365)
                                Text(L10n.text("730 天")).tag(730)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    SettingsDivider()
                    SettingsRow(L10n.text("发布 Token")) {
                        HStack(spacing: 8) {
                            SettingsBadge(text: state.publishTokenConfigured ? L10n.text("已配置") : L10n.text("未配置"),
                                          tint: state.publishTokenConfigured ? .green : .secondary)
                            SecureField(L10n.text("发布 Token（留空保持现有）"), text: $publishToken)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                    }
                    SettingsDivider()
                    HStack {
                        if let url = state.publicStatsURL {
                            Link(L10n.text("打开公开数据 →"), destination: url).font(.callout)
                        }
                        Spacer()
                        Button(L10n.text("保存配置")) {
                            state.savePublishConfiguration(endpoint: publishEndpoint,
                                                           handle: publishHandle,
                                                           days: publishDays,
                                                           token: publishToken)
                            publishToken = ""
                            loadPublishDrafts()
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    SettingsDivider()
                    publishStatus
                    SettingsDivider()
                    HStack(spacing: 10) {
                        Button(L10n.text("按规则上传")) { state.performPublish(trigger: .manual) }
                            .disabled(!state.publishConfigurationReady || state.publishBusy)
                        Button(L10n.text("强制上传…")) { showForceConfirmation = true }
                            .disabled(!state.publishConfigurationReady || state.publishBusy)
                        if state.publishBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(L10n.text("查看上传记录…")) { state.showPublishHistory() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if let message = state.publishMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(state.publishFailed ? .red : .secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var publishStatus: some View {
        let snapshot = state.publishState
        SettingsRow(L10n.text("上次成功")) {
            Text(snapshot.lastSuccessAt > 0
                 ? Date(timeIntervalSince1970: snapshot.lastSuccessAt)
                    .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
                 : L10n.text("从未"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        SettingsDivider()
        SettingsRow(L10n.text("本机上传记录")) {
            Text(L10n.text("\(state.publishHistory.count) 条"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if !snapshot.lastError.isEmpty {
            SettingsDivider()
            Text(L10n.text("上次错误：\(snapshot.lastError)"))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(snapshot.lastError)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var publishPrivacyText: String {
        state.prefs.publishEnabled
            ? L10n.text("自动上传已开启。只发送聚合数字；项目路径、会话、提示词、模型名和账号信息不会上传。")
            : L10n.text("自动上传已关闭。手动上传仍可使用；原始日志和敏感信息不会离开本机。")
    }

    private var publishDaysTitle: String {
        switch publishDays {
        case 90: L10n.text("90 天")
        case 730: L10n.text("730 天")
        default: L10n.text("365 天")
        }
    }

    private func loadPublishDrafts() {
        publishEndpoint = state.prefs.publishEndpoint
        publishHandle = state.prefs.publishHandle
        publishDays = state.prefs.publishDays
    }
}
