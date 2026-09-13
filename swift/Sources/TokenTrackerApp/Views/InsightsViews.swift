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
                Text(L10n.text("未计价 \(model.totals.unpriced) 条 · 时间未分配 \(model.totals.unallocatedTokens) Token")).font(.caption)
            }
            if model.risks.isEmpty { Text(L10n.text("尚未设置预算；官方配额风险依赖新鲜样本。")).font(.caption).foregroundStyle(.secondary) }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12))
    }
}

struct ProjectsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: InsightsModel
    @State private var range="week"
    @State private var from=Calendar.current.startOfDay(for:Date())
    @State private var to=Date()
    @State private var rename=""
    @State private var selected:ProjectSummary?
    @State private var showExport=false
    @State private var showBudget=false
    @State private var showAssignments=false
    @State private var showCreate=false
    var body: some View {
        VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading) {
                    Text(selected?.name ?? L10n.text("项目")).font(.title2.bold())
                    Text(L10n.text("\(model.totals.tokens) Token · \(L10n.label(model.totals.costLabel)) · 含估算，非订阅账单")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected != nil { Button(L10n.text("所有项目")) { selected=nil;model.query.projectID=nil;model.refresh() } }
                Button(L10n.text("项目管理")) { showCreate=true }
                Button(L10n.text("预算")) { showBudget=true }
                Button(L10n.text("导出")) { showExport=true }
            }.padding()
            HStack {
                Picker(L10n.text("范围"),selection:$range) {
                    Text(L10n.text("今天")).tag("day");Text(L10n.text("近 7 天")).tag("week");Text(L10n.text("本月")).tag("month");Text(L10n.text("全部")).tag("all");Text(L10n.text("自定义")).tag("custom")
                }.pickerStyle(.segmented).labelsHidden()
                TextField(L10n.text("搜索项目"),text:$model.search).textFieldStyle(.roundedBorder).frame(maxWidth:200)
            }.padding(.horizontal)
            Text(usageIntervalLabel(model.query)).font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            if model.query.tool != nil || model.query.model != nil {
                HStack { Text(L10n.text("筛选：") + (model.query.tool ?? model.query.model ?? "")).font(.caption);Button(L10n.text("清除筛选")) { model.query.tool=nil;model.query.model=nil;model.refresh() } }.padding(.horizontal)
            }
            if range == "custom" {
                HStack {
                    DatePicker(L10n.text("开始"),selection:$from,displayedComponents:.date)
                    DatePicker(L10n.text("结束（包含当天）"),selection:$to,displayedComponents:.date)
                    Button(L10n.text("应用")) { applyRange() }.disabled(from>to)
                }.padding(.horizontal)
            }
            if !model.backfillProgress.isEmpty { Text(model.backfillProgress).font(.caption).foregroundStyle(.secondary) }
            if model.busy { ProgressView().controlSize(.small).padding(4) }
            if let error=model.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if let selected {
                        HStack {
                            TextField(L10n.text("项目名称"),text:$rename)
                            Button(L10n.text("保存名称")) { let id=selected.id,name=rename;model.mutate { try $0.renameProject(id,name:name) } }
                            Button(L10n.text("调整归属")) { showAssignments=true }
                        }
                        TotalsView(totals:model.totals)
                        ForEach(model.risks.filter{$0.projectID==selected.id}) { risk in Text(UIFormat.riskDetail(risk)).font(.caption).foregroundStyle(risk.level>0 ? .orange : .secondary) }
                        if let explanation=model.explanation {
                            Text(L10n.label(explanation.status)).font(.headline)
                            Text(UIFormat.explanation(explanation)).font(.callout).foregroundStyle(.secondary)
                        }
                        if model.analyticsLoading { ProgressView(L10n.text("正在加载分析…")).controlSize(.small) }
                        Text(L10n.text("项目趋势")).font(.headline)
                        Chart(model.daily) { row in
                            BarMark(x:.value(L10n.text("日期"),row.id),y:.value("Token",row.totals.tokens))
                        }.frame(height:160)
                        Text(L10n.text("Agent 分布")).font(.headline)
                        ForEach(model.agents) { row in HStack { Text(toolDisplayName(row.id));Spacer();Text("\(row.totals.tokens) Token") } }
                        Text(L10n.text("模型分布")).font(.headline)
                        ForEach(model.breakdown) { row in
                            HStack { Text(row.id);Spacer();Text("\(row.totals.tokens) Token · \(L10n.label(row.totals.costLabel))").monospacedDigit() }
                        }
                        if let explanation=model.explanation { ExplanationEvidence(explanation:explanation,inspect:model.inspectChange) }
                        Text(L10n.text("主要会话")).font(.headline)
                        ForEach(model.sessions) { session in
                            Button { model.onSession?(session.tool,session.sessionID) } label: {
                                HStack { Text(session.title.isEmpty ? session.sessionID : session.title).lineLimit(1);Spacer();Text("\(session.totals.tokens) Token") }
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(model.projects) { project in
                            Button {
                                selected=project;rename=project.name;model.query.projectID=project.id;model.refresh()
                            } label: {
                                VStack(alignment:.leading,spacing:8) {
                                    HStack { Text(project.name).font(.headline);Spacer();Text("\(project.totals.tokens) Token").monospacedDigit() }
                                    HStack { Text(L10n.text("\(project.totals.sessions) 个会话 · \(L10n.label(project.totals.costLabel))"));Spacer();if let last=project.lastActivity { Text(Date(timeIntervalSince1970:Double(last)/1000),style:.date) } }.font(.caption).foregroundStyle(.secondary)
                                    ForEach(model.risks.filter{$0.projectID==project.id && $0.level>0}) { risk in Text(UIFormat.riskDetail(risk)).font(.caption).foregroundStyle(.orange) }
                                    Text(L10n.text("输入 \(project.totals.input) · 输出 \(project.totals.output) · 缓存读 \(project.totals.cacheRead) · 缓存写 \(project.totals.cacheWrite)")).font(.caption2)
                                }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                            }.buttonStyle(.plain)
                        }
                        if model.projects.count >= 100 { Button(L10n.text("加载更多")) { model.refresh(more:true) } }
                        if model.projects.isEmpty && !model.busy { ContentUnavailableView(L10n.text("此范围暂无项目"),systemImage:"folder",description:Text(L10n.text("来源没有可靠工作目录的用量会保留在未归属中。"))) }
                    }
                }.padding()
            }
        }
        .navigationTitle(selected?.name ?? L10n.text("项目"))
        .onChange(of:model.busy) { _,busy in
            if !busy,let id=model.query.projectID,let project=model.projects.first(where:{$0.id==id}) {
                if selected?.id != id { rename=project.name }
                selected=project
            } else if !busy,model.query.projectID == nil { selected=nil }
        }
        .sheet(isPresented:$showCreate) { ProjectCreateSheet(model:model) }
        .onChange(of:range) { _,_ in applyRange() }
        .task(id:model.search) { try? await Task.sleep(for:.milliseconds(250));if !Task.isCancelled { model.refresh() } }
        .sheet(isPresented:$showExport) { ExportSheet(model:model) }
        .sheet(isPresented:$showBudget) { BudgetSheet(model:model,projectID:selected?.id) }
        .sheet(isPresented:$showAssignments) { AssignmentSheet(model:model,projectID:selected?.id) }
    }
    private func applyRange() {
        var query=UsageQuery.period(range)
        if range == "custom" {
            query.start=Int64(Calendar.current.startOfDay(for:from).timeIntervalSince1970*1000)
            query.end=Int64(Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:to))!.timeIntervalSince1970*1000)
        }
        query.projectID=model.query.projectID;query.tool=model.query.tool;query.model=model.query.model;model.query=query;model.refresh()
    }
}
struct TotalsView: View {
    @ObservedObject private var language = LanguageManager.shared
    let totals:UsageTotals
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("\(totals.tokens) Token").font(.largeTitle.bold()).monospacedDigit()
            Text(L10n.text("非缓存输入 \(totals.input) · 输出 \(totals.output) · 缓存读 \(totals.cacheRead) · 缓存写 \(totals.cacheWrite)"))
            Text(L10n.text("费用合计 \(L10n.label(totals.costLabel)) · 含估算，非订阅账单"))
            Text(L10n.text("\(totals.records) 条用量记录 · 未计价 \(totals.unpriced) 条 · 时间未分配 \(totals.unallocatedTokens) Token")).font(.caption).foregroundStyle(.secondary)
        }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
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
struct ReportsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    @State private var selected:WeeklyReport?
    @State private var week=Date()
    @State private var reportExportQuery:UsageQuery?
    @State private var showExport=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(L10n.text("本地周报")).font(.title2.bold());Spacer()
                DatePicker(L10n.text("周次参考日期"),selection:$week,displayedComponents:.date)
                Button(L10n.text("生成此前完整周")) { let now=week;model.mutate { try $0.generateWeeklyReport(now:now,regenerate:true) } }
                Button(L10n.text("导出数据")) { reportExportQuery=(selected ?? model.reports.first)?.query ?? UsageQuery.period("week");showExport=true }
            }
            Text(L10n.text("自然周：周一至周日 · 本地规则 · 快照不会随补扫静默变化")).font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(model.reports) { report in
                    Button { selected=report } label: {
                        VStack(alignment:.leading) {
                            Text(Date(timeIntervalSince1970:Double(report.query.start ?? 0)/1000),style:.date)
                            Text("\(report.totals.tokens) Token").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }.frame(minWidth:180,maxWidth:240)
                ScrollView {
                    if let report=selected ?? model.reports.first {
                        VStack(alignment:.leading,spacing:12) {
                            TotalsView(totals:report.totals)
                            HStack {
                                Button(L10n.text("导出 Markdown")) { model.exportReport(report) }
                                Button(L10n.text("重新生成")) {
                                    let now=Date(timeIntervalSince1970:Double(report.query.end ?? 0)/1000+3600)
                                    let tz=TimeZone(identifier:report.query.timeZoneID) ?? .current
                                    selected=nil;model.mutate { try $0.generateWeeklyReport(now:now,timeZone:tz,regenerate:true) }
                                }
                            }
                            Text(L10n.text("相比上一自然周：\(report.totals.tokens-report.previous.tokens) Token")).font(.headline)
                            Text(L10n.text("覆盖不完整时，变化不代表实际增长。")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("项目投入")).font(.headline)
                            ForEach(report.projects) { project in
                                HStack { Text(project.name);Spacer();Text("\(project.totals.tokens.formatted()) Token · \(L10n.label(project.totals.costLabel))") }.font(.callout)
                            }
                            Divider()
                            Text(L10n.text("模型与费用依据")).font(.headline)
                            ForEach(report.models) { row in HStack { Text(row.id);Spacer();Text("\(row.totals.tokens.formatted()) Token") } }
                            ForEach(report.costSources) { row in
                                HStack { Text(costSourceName(row.id));Spacer();Text(L10n.label(row.totals.costLabel)) }.font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text(L10n.text("预算与生成时健康")).font(.headline)
                            ForEach(report.budgets) { risk in Text(L10n.label(risk.title)+" · "+UIFormat.riskDetail(risk)).font(.callout) }
                            ForEach(report.health) { health in HStack { Text(toolDisplayName(health.id));Spacer();Text(L10n.label(health.state)) }.font(.caption) }
                            Text(L10n.text("执行活动 \(report.activityCount.formatted()) 次；调用成功不代表任务质量。")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("时区：\(report.query.timeZoneID) · 规则 v\(report.ruleVersion) · 生成于 \(Date(timeIntervalSince1970:Double(report.generatedAt)/1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")).font(.caption2).foregroundStyle(.secondary)

                        }.padding()
                    } else { ContentUnavailableView(L10n.text("尚无周报"),systemImage:"doc.text",description:Text(L10n.text("启动扫描完成后自动生成最近一个完整周，也可以按需生成。"))) }
                }
            }
        }.padding().navigationTitle(L10n.text("本地周报")).onAppear { model.refresh() }.sheet(isPresented:$showExport) { ExportSheet(model:model,queryOverride:reportExportQuery) }
    }
}
struct HealthView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model:InsightsModel
    let tool:String?
    let rescan:()->Void
    @State private var export=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L10n.text("数据健康")).font(.title2.bold());Spacer();Button(L10n.text("重新扫描"),action:rescan);Button(L10n.text("脱敏诊断导出")) { export=true } }
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
                        }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
                    }
                    TotalsView(totals:model.totals)
                }
            }
        }.padding(20).frame(minWidth:600,minHeight:400).sheet(isPresented:$export) { ExportSheet(model:model,diagnostics:true) }
    }
}

struct ExplanationEvidence: View {
    @ObservedObject private var language = LanguageManager.shared
    let explanation: ConsumptionExplanation
    var inspect: ((ChangeContribution)->Void)?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(explanation.context,id:\.self) { Text(L10n.label($0)).font(.caption).foregroundStyle(.secondary) }
            ForEach(["project","tool","model"],id:\.self) { dimension in
                Text(["project":L10n.text("项目贡献"),"tool":L10n.text("Agent 贡献"),"model":L10n.text("模型贡献")][dimension]!).font(.subheadline.bold())
                ForEach(Array(explanation.changes.filter{$0.dimension==dimension}.prefix(5))) { change in
                    Button { inspect?(change) } label: { HStack { Text(change.name).lineLimit(1).truncationMode(.middle);Spacer();Text(String(format:"%+.0f Token",change.delta)).monospacedDigit();Image(systemName:"chevron.right") }.font(.caption) }.buttonStyle(.plain)
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
