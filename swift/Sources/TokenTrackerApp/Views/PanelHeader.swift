//
//  PanelHeader.swift
//  TokenTrackerApp
//
//  三个页面共用的顶部条。此前概览是内容区里的 HStack、会话记录靠
//  .searchable 让 SwiftUI 自造搜索栏（裸 NSWindow 没挂 NSToolbar，
//  只有这一页多出约 28pt）、设置是 Form + padding —— 三套机制三种高度，
//  切 tab 时上方会跳。这里统一成固定 52pt + 分隔线。
//

import SwiftUI

struct PanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            Divider()
        }
        .background(.bar)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
