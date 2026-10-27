import SwiftUI

struct SubscriptionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.text("订阅配额与余额"), subtitle: nil) {
                if state.subscriptionRefreshing { ProgressView().controlSize(.small) }
                Button(L10n.text("刷新")) { state.refreshQuotas(force: true) }
                    .disabled(state.subscriptionRefreshing)
            }
            ScrollView {
                SubscriptionSection(cards: state.subscriptionCards,
                                    refreshing: state.subscriptionRefreshing, showsHeading: false)
                    .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("订阅配额与余额"))
    }
}
