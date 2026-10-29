import SwiftUI
import TokenTrackerCore

// Hallmark · component: native calendar · theme: existing system colors
// Pre-emit critique: P4 H4 E4 S5 R5 V4
struct UsageHeatmapView: View {
    @ObservedObject private var language = LanguageManager.shared
    let rows: [UsageStore.DailyRow]
    let excludedTokens: Int64
    let loading: Bool
    let error: String?
    let yi: Bool
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?

    private let gap: CGFloat = 3
    private let rowLabels: [L10n.Template] = ["一", "", "三", "", "五", "", "日"]
    private var map: UsageHeatmap { UsageHeatmap(rows: rows, year: selectedYear) }
    private var focusedDay: UsageHeatmap.Day? {
        let date = hoveredDate ?? selectedDate
        return map.weeks.flatMap { $0 }.compactMap { $0 }.first { $0.date == date }
    }

    var body: some View {
        let data = map
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Token 用量热力图")).font(.headline)
                    Text(L10n.text("全部 Agent · 按年查看，不受顶部时间范围影响"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Picker(L10n.text("年份"), selection: $selectedYear) {
                    ForEach(UsageHeatmap.years(rows: rows), id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }.labelsHidden().frame(width: 92)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if loading && rows.isEmpty {
                Text(L10n.text("正在读取用量…")).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 132)
            } else {
                calendarGrid(data)
                HStack {
                    Text(L10n.text("已记录 \(UIFormat.tokens(data.totalTokens, yi: yi)) Token · \(data.activeDays) 个活跃日"))
                    Spacer()
                    Text(L10n.text("少"))
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 10, height: 10)
                    }
                    Text(L10n.text("多"))
                }.font(.caption).foregroundStyle(.secondary)
                dayDetail
                Text(L10n.text("含输入、输出与缓存 Token；空白格表示未来日期，灰格表示无已记录用量。"))
                    .font(.caption2).foregroundStyle(.secondary)
                if excludedTokens > 0 {
                    Text(L10n.text("另有 \(UIFormat.tokens(excludedTokens, yi: yi)) Token 无法可靠归入某一天，未着色。"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .onChange(of: selectedYear) { _, _ in selectedDate = nil; hoveredDate = nil }
    }

    private func calendarGrid(_ data: UsageHeatmap) -> some View {
        GeometryReader { geometry in
            let cell = min(12, max(4, (geometry.size.width - 25) / CGFloat(data.weeks.count) - gap))
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: gap) {
                    Color.clear.frame(height: 16)
                    ForEach(0..<7) { row in
                        Text(L10n.text(rowLabels[row])).font(.system(size: 9))
                            .foregroundStyle(.secondary).frame(width: 19, height: cell)
                    }
                }
                HStack(alignment: .top, spacing: gap) {
                    ForEach(data.weeks.indices, id: \.self) { week in
                        VStack(spacing: gap) {
                            let monthStart = data.weeks[week].compactMap { $0 }.first {
                                Calendar.current.component(.day, from: $0.date) == 1
                            }
                            let label = monthStart?.date.formatted(.dateTime.month(.abbreviated).locale(language.locale))
                            Color.clear.frame(width: cell, height: 16)
                                .overlay(alignment: .leading) {
                                    if let label { Text(label).font(.system(size: 9)).fixedSize().foregroundStyle(.secondary) }
                                }
                            ForEach(0..<7) { row in
                                if let day = data.weeks[week][row] {
                                    Button { selectedDate = day.date } label: {
                                        RoundedRectangle(cornerRadius: 2).fill(color(data.level(for: day.tokens)))
                                            .overlay {
                                                if (hoveredDate ?? selectedDate) == day.date {
                                                    RoundedRectangle(cornerRadius: 2).strokeBorder(.primary, lineWidth: 1)
                                                }
                                            }
                                            .frame(width: cell, height: cell)
                                    }
                                    .buttonStyle(.plain)
                                    .help(dayLabel(day))
                                    .accessibilityLabel(dayLabel(day))
                                    .onHover { hoveredDate = $0 ? day.date : nil }
                                } else {
                                    Color.clear.frame(width: cell, height: cell).accessibilityHidden(true)
                                }
                            }
                        }
                    }
                }
            }
        }.frame(height: 124)
    }

    @ViewBuilder private var dayDetail: some View {
        if let day = focusedDay {
            VStack(alignment: .leading, spacing: 3) {
                Text(dayLabel(day)).font(.caption.monospacedDigit())
                if !day.agents.isEmpty {
                    Text(day.agents.map { "\(toolDisplayName($0.tool)) \(UIFormat.tokens($0.tokens, yi: yi))" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if day.estimatedTokens > 0 {
                    Text(L10n.text("其中区间估算 \(UIFormat.tokens(day.estimatedTokens, yi: yi)) Token"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 32, alignment: .topLeading)
        } else {
            Text(L10n.text("悬停或点选日期，查看当日 Token 与 Agent 明细"))
                .font(.caption).foregroundStyle(.secondary).frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private func dayLabel(_ day: UsageHeatmap.Day) -> String {
        let date = day.date.formatted(.dateTime.year().month().day().locale(language.locale))
        return date + " · " + (day.tokens == 0 ? L10n.text("无已记录用量") : "\(day.tokens.formatted()) Token")
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.08) : Color.green.opacity([0.0, 0.25, 0.45, 0.7, 1.0][level])
    }
}
