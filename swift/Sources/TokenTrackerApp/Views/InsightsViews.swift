import SwiftUI
import Charts
import TokenTrackerCore

struct InsightsOverview: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: InsightsModel
    let rescan: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label(L10n.text("数据与风险"),systemImage:"checkmark.shield").font(.headline)
                Spacer()
                Button(L10n.text("数据健康")) { model.showHealth(rescan:rescan) }
            }
            if let explanation=model.explanation {
                Text(L10n.label(explanation.status)).font(.subheadline.bold())
                Text(UIFormat.explanation(explanation)).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.text("查看比较依据")) { ExplanationEvidence(explanation:explanation,inspect:model.inspectChange) }
            }
            ForEach(model.risks.filter{$0.level>0}) { risk in
                Label(L10n.label(risk.title)+" · "+UIFormat.riskDetail(risk),systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup(L10n.text("费用依据与统计覆盖")) {
                ForEach(model.costSources) { row in HStack { Text(costSourceName(row.id));Spacer();Text(L10n.label(row.totals.costLabel)) }.font(.caption) }
                Text(L10n.text("未计价 \(model.totals.unpriced.formatted(.number)) 条 · 时间未分配 \(model.totals.unallocatedTokens.formatted(.number)) Token")).font(.caption)
            }
            if model.risks.isEmpty { Text(L10n.text("尚未设置预算；官方配额风险依赖新鲜样本。")).font(.caption).foregroundStyle(.secondary) }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.frame(maxWidth:.infinity,alignment:.leading).card()
    }
}

struct BudgetSheet: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    let projectID:String?
    @Environment(\.dismiss) private var dismiss
    @State private var amount=""
    @State private var unit="tokens"
    @State private var period="month"
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(projectID == nil ? L10n.text("全局预算") : L10n.text("项目预算")).font(.title2.bold())
            Text(L10n.text("达到 80%、90%、100% 时提示；费用预算含估算，非订阅账单。")).font(.caption)
            Picker(L10n.text("单位"),selection:$unit) { Text(L10n.text("总 Token")).tag("tokens");Text(L10n.text("估算美元")).tag("usd") }.pickerStyle(.segmented).labelsHidden()
            Picker(L10n.text("周期"),selection:$period) { Text(L10n.text("自然日")).tag("day");Text(L10n.text("自然周")).tag("calendarWeek");Text(L10n.text("自然月")).tag("month") }
            TextField(L10n.text("预算上限"),text:$amount).textFieldStyle(.roundedBorder)
            Toggle(L10n.text("启用系统通知"),isOn:Binding(get:{model.notificationsEnabled},set:{model.setNotifications($0)}))
            ForEach(model.budgets.filter{$0.projectID==projectID}) { budget in
                HStack { Text("\(budget.limit.formatted()) \(budget.unit == "tokens" ? "Token" : L10n.text("估算美元")) / \(["day":L10n.text("自然日"),"calendarWeek":L10n.text("自然周"),"month":L10n.text("自然月")][budget.period] ?? budget.period)");Spacer();Button(L10n.text("删除")) { let id=budget.id;model.mutate { try $0.deleteBudget(id) } } }
            }
            HStack { Button(L10n.text("关闭")) { dismiss() };Spacer();Button(L10n.text("添加预算")) {
                guard let limit=Double(amount) else { return }
                let budget=BudgetRule(projectID:projectID,unit:unit,period:period,limit:limit)
                model.mutate { try $0.saveBudget(budget) };amount=""
            }.disabled(Double(amount).map{!$0.isFinite || $0<=0} ?? true) }
        }.padding(24).frame(width:500)
    }
}
struct AssignmentSheet: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    let projectID:String?
    @Environment(\.dismiss) private var dismiss
    @State private var path=""
    @State private var tool="codex"
    @State private var session=""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L10n.text("手动项目归属")).font(.title2.bold())
            Text(L10n.text("会话归属优先于目录归属；恢复自动不会改变原始用量。")).font(.caption)
            TextField(L10n.text("完整工作目录路径"),text:$path)
            HStack {
                Button(L10n.text("归入此项目")) { let path=path,id=projectID;model.mutate { try $0.assignDirectory(path,projectID:id) } }.disabled(!path.hasPrefix("/") || projectID==nil)
                Button(L10n.text("目录恢复自动")) { let path=path;model.mutate { try $0.assignDirectory(path,projectID:nil) } }
            }
            Divider()
            Picker("Agent",selection:$tool) { ForEach(ScannerRegistry.all,id:\.self) { Text($0).tag($0) } }
            TextField(L10n.text("会话 ID"),text:$session)
            HStack {
                Button(L10n.text("会话归入此项目")) { let tool=tool,session=session,id=projectID;model.mutate { try $0.assignSession(tool:tool,sessionID:session,projectID:id) } }.disabled(session.isEmpty || projectID==nil)
                Button(L10n.text("会话恢复自动")) { let tool=tool,session=session;model.mutate { try $0.assignSession(tool:tool,sessionID:session,projectID:nil) } }.disabled(session.isEmpty)
            }
            Button(L10n.text("完成")) { dismiss() }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:500)
    }
}
struct ExportSheet: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    var diagnostics=false
    var queryOverride:UsageQuery? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var kind=ExportKind.usage
    @State private var format=ExportFormat.csv
    @State private var includePrivate=false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("导出当前筛选的数据")).font(.title2.bold())
            if !diagnostics { Picker(L10n.text("内容"),selection:$kind) { Text(L10n.text("用量记录")).tag(ExportKind.usage);Text(L10n.text("会话汇总")).tag(ExportKind.sessions);Text(L10n.text("Activity 元数据")).tag(ExportKind.activity);Text(L10n.text("统计摘要")).tag(ExportKind.summary);Text(L10n.text("数据健康")).tag(ExportKind.health) } }
            Picker(L10n.text("格式"),selection:$format) { Text("CSV").tag(ExportFormat.csv);Text("JSON").tag(ExportFormat.json) }
            if !diagnostics { Toggle(L10n.text("包含本地项目路径、会话身份和标题"),isOn:$includePrivate) }
            Text(includePrivate ? L10n.text("文件将包含本地身份信息，请确认保存位置。") : L10n.text("项目、会话、调用和自定义工具使用一致别名，移除路径与标题。")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("始终排除凭据、提示词、工具参数和输出正文；导出不限于当前列表页。")).font(.caption)
            if let message=model.exportMessage { Text(message).foregroundStyle(.green) }
            if model.exporting { ProgressView();Button(L10n.text("取消导出")) { model.cancelExport() } }
            if let error=model.error { Text(error).foregroundStyle(.red) }
            HStack { Button(L10n.text("关闭")) { dismiss() };Spacer();Button(L10n.text("选择保存位置…")) { model.export(kind:kind,format:format,includePrivate:includePrivate,queryOverride:queryOverride) }.disabled(model.exporting) }
        }.padding(24).frame(width:520).onAppear { if diagnostics { kind = .health; includePrivate = false }; model.clearExportMessage() }
    }
}
struct HealthView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    let tool:String?
    let rescan:()->Void
    @State private var export=false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L10n.text("数据健康")).font(.title2.bold());Spacer();Button(L10n.text("重新扫描"),action:rescan);Button(L10n.text("脱敏诊断导出")) { export=true };Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(L10n.text("未采集的指标显示未知；没有新增用量本身不是异常。")).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(model.health.filter{tool == nil || $0.id==tool}) { health in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(toolDisplayName(health.id)).font(.headline);Spacer();Text(L10n.label(health.state)).foregroundStyle(health.state=="正常" ? .green : .orange) }
                            Text(L10n.text("文件 \(health.files) · 新增 \(health.added) · 更新 \(health.updated) · \(health.duration.formatted()) 秒"))
                            Text(L10n.text("最近尝试：\(Date(timeIntervalSince1970:Double(health.attemptedAt)/1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")).font(.caption)
                            Text(L10n.text("最近成功：\(health.succeededAt.map{Date(timeIntervalSince1970:Double($0)/1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))} ?? L10n.text("未知"))")).font(.caption)
                            Text(L10n.text("Activity 解析器 v\(health.parserVersion) · 解析异常：\(health.parseErrors.map(String.init) ?? L10n.text("未知")) · 读取异常：\(health.readErrors.map(String.init) ?? L10n.text("未知"))")).font(.caption)
                            Text(L10n.text("工具：\(activityCapability(agent:health.id,category:"tools").rawValue) · Skill：\(activityCapability(agent:health.id,category:"skills").rawValue)")).font(.caption)
                            if !health.error.isEmpty { Text(L10n.label(health.error)).foregroundStyle(.orange) }
                        }.frame(maxWidth:.infinity,alignment:.leading).card()
                    }
                    TotalsView(totals:model.totals)
                }
            }
        }.padding(20).frame(width:680,height:520).sheet(isPresented:$export) { ExportSheet(model:model,diagnostics:true) }
    }
}

struct ExplanationEvidence: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.unitYi) private var yi
    let explanation: ConsumptionExplanation
    var inspect: ((ChangeContribution)->Void)?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(explanation.context,id:\.self) { Text(L10n.label($0)).font(.caption).foregroundStyle(.secondary) }
            ForEach(["project","tool","model"],id:\.self) { dimension in
                Text(["project":L10n.text("项目贡献"),"tool":L10n.text("Agent 贡献"),"model":L10n.text("模型贡献")][dimension]!).font(.subheadline.bold())
                ForEach(Array(explanation.changes.filter{$0.dimension==dimension}.prefix(5))) { change in
                    Button { inspect?(change) } label: { HStack { Text(change.name).lineLimit(1).truncationMode(.middle);Spacer();Text(UIFormat.signedCompact(Int64(change.delta),yi:yi)+" Token").monospacedDigit();Image(systemName:"chevron.right") }.font(.caption) }.buttonStyle(.plain)
                }
            }
        }
    }
}

func costSourceName(_ source:String) -> String {
    ["estimate":L10n.text("价格表估算"),"native":L10n.text("来源报告费用"),"native_actual":L10n.text("来源报告实际费用"),"native_estimate":L10n.text("来源报告估算"),"provider_estimate":L10n.text("来源报告估算"),"recomputed":L10n.text("历史重算"),"legacy":L10n.text("历史记录"),"native_included":L10n.text("已包含于来源费用")][source] ?? L10n.text("来源费用或历史校准")
}

struct ProjectCreateSheet: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var selectedID=""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("项目管理")).font(.title2.bold())
            TextField(L10n.text("新项目名称"),text:$name).textFieldStyle(.roundedBorder)
            Button(L10n.text("创建项目")) { model.createProject(name:name);dismiss() }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            Divider()
            Picker(L10n.text("已有项目"),selection:$selectedID) {
                Text(L10n.text("选择项目")).tag("")
                ForEach(model.registry) { Text($0.name).tag($0.id) }
            }
            Button(L10n.text("打开项目")) { model.query.projectID=selectedID;model.search="";model.refresh();dismiss() }.disabled(selectedID.isEmpty)
            Text(L10n.text("创建后可按目录或会话调整归属；恢复自动即可撤销归属变更。")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("关闭")) { dismiss() }
        }.padding(24).frame(width:460)
    }
}

func usageIntervalLabel(_ query:UsageQuery) -> String {
    guard let start=query.start,let end=query.end else { return L10n.text("全部历史（含时间未分配记录）") }
    let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:query.timeZoneID);formatter.locale=L10n.locale;formatter.setLocalizedDateFormatFromTemplate("yyyyMMMdHHmm")
    return formatter.string(from:Date(timeIntervalSince1970:Double(start)/1000))+" — "+formatter.string(from:Date(timeIntervalSince1970:Double(end)/1000))+" · "+query.timeZoneID
}
