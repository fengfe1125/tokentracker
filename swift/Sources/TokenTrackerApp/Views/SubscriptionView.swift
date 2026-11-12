import SwiftUI

struct SubscriptionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            SubscriptionSection(cards: state.subscriptionCards,
                                refreshing: state.subscriptionRefreshing, showsHeading: false,
                                openAccountSettings: {
                                    UserDefaults.standard.set(SettingsTab.accounts.rawValue,
                                                              forKey: SettingsTab.storageKey)
                                    state.selection = .settings
                                })
                .padding(Metrics.pagePadding)
        }
        .pageChrome(title: L10n.text("订阅配额与余额")) {
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
