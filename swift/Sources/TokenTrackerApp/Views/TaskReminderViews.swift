import SwiftUI
import TokenTrackerCore

struct TaskReminderCard: View {
    @ObservedObject var model: TaskReminderModel
    let id: String
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var expanded = false
    private var row: TaskReminder? { model.reminders.first { $0.id == id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row {
                HStack {
                    Text(row.provider.name).font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("关闭"))
                }
                Text(L10n.label(row.clientName)).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.label(row.statusKey)).fontWeight(.semibold)
                        .foregroundStyle(row.state == .waiting ? Color.orange : Color.primary)
                    Spacer()
                    Text(row.at, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                if !row.project.isEmpty { Text(row.project).font(.caption).lineLimit(1) }
                if !row.tool.isEmpty { Text(row.tool).font(.system(.callout, design: .monospaced)) }
                if let arguments = row.arguments {
                    DisclosureGroup(L10n.text("查看完整请求"), isExpanded: $expanded) {
                        ScrollView {
                            Text(arguments).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }
                }
                if row.state == .waiting {
                    Text(L10n.text("仅处理当前请求；关闭卡片不会批准或拒绝。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.text("拒绝一次")) { model.decide(id, .deny) }
                        Spacer()
                        Button(L10n.text("允许一次")) { model.decide(id, .allow) }
                            .disabled(!row.pending || row.arguments == nil || !expanded)
                    }
                }
                Button(L10n.text("前往原任务")) { model.navigate(row) }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            } else { Text(L10n.text("暂无任务提醒")) }
        }
        .padding(16).frame(width: 360, height: 420, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onHover(perform: hover)
    }
}

struct TaskReminderList: View {
    @ObservedObject var model: TaskReminderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("任务提醒")).font(.title2.bold())
            if model.reminders.isEmpty { Text(L10n.text("暂无任务提醒")).foregroundStyle(.secondary) }
            List(model.reminders.sorted { a, b in a.pending != b.pending ? a.pending : a.at > b.at }) { row in
                Button { model.show(row.id, explicit: true) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.provider.name + " · " + L10n.label(row.statusKey))
                            Text(L10n.label(row.clientName) + " · " + row.project + " · " + row.session.suffix(12))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(row.at, style: .time).font(.caption)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(minWidth: 520, minHeight: 360)
    }
}
