import SwiftUI
import Charts
import TokenTrackerCore

struct InsightsOverview: View {
    @ObservedObject var model: InsightsModel
    let rescan: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("数据与风险",systemImage:"checkmark.shield").font(.headline)
                Spacer()
                Button("数据健康") { model.showHealth(rescan:rescan) }
            }
            if let explanation=model.explanation {
                Text(explanation.status).font(.subheadline.bold())
                Text(explanation.detail).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看比较依据") { ExplanationEvidence(explanation:explanation,inspect:model.inspectChange) }
            }
            ForEach(model.risks.filter{$0.level>0}) { risk in
                Label(risk.title+" · "+risk.detail,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("费用依据与统计覆盖") {
                ForEach(model.costSources) { row in HStack { Text(costSourceName(row.id));Spacer();Text(row.totals.costLabel) }.font(.caption) }
                Text("未计价 \(model.totals.unpriced) 条 · 时间未分配 \(model.totals.unallocatedTokens) Token").font(.caption)
            }
            if model.risks.isEmpty { Text("尚未设置预算；官方配额风险依赖新鲜样本。").font(.caption).foregroundStyle(.secondary) }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12))
    }
}

struct ProjectsView: View {
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
                    Text(selected?.name ?? "项目").font(.title2.bold())
                    Text("\(model.totals.tokens) Token · \(model.totals.costLabel) · 含估算，非订阅账单").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected != nil { Button("所有项目") { selected=nil;model.query.projectID=nil;model.refresh() } }
                Button("项目管理") { showCreate=true }
                Button("预算") { showBudget=true }
                Button("导出") { showExport=true }
            }.padding()
            HStack {
                Picker("范围",selection:$range) {
                    Text("今天").tag("day");Text("近 7 天").tag("week");Text("本月").tag("month");Text("全部").tag("all");Text("自定义").tag("custom")
                }.pickerStyle(.segmented)
                TextField("搜索项目",text:$model.search).textFieldStyle(.roundedBorder).frame(maxWidth:200)
            }.padding(.horizontal)
            Text(usageIntervalLabel(model.query)).font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            if model.query.tool != nil || model.query.model != nil {
                HStack { Text("筛选：" + (model.query.tool ?? model.query.model ?? "")).font(.caption);Button("清除筛选") { model.query.tool=nil;model.query.model=nil;model.refresh() } }.padding(.horizontal)
            }
            if range == "custom" {
                HStack {
                    DatePicker("开始",selection:$from,displayedComponents:.date)
                    DatePicker("结束（包含当天）",selection:$to,displayedComponents:.date)
                    Button("应用") { applyRange() }.disabled(from>to)
                }.padding(.horizontal)
            }
            if !model.backfillProgress.isEmpty { Text(model.backfillProgress).font(.caption).foregroundStyle(.secondary) }
            if model.busy { ProgressView().controlSize(.small).padding(4) }
            if let error=model.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    if let selected {
                        HStack {
                            TextField("项目名称",text:$rename)
                            Button("保存名称") { let id=selected.id,name=rename;model.mutate { try $0.renameProject(id,name:name) } }
                            Button("调整归属") { showAssignments=true }
                        }
                        TotalsView(totals:model.totals)
                        ForEach(model.risks.filter{$0.projectID==selected.id}) { risk in Text(risk.detail).font(.caption).foregroundStyle(risk.level>0 ? .orange : .secondary) }
                        if let explanation=model.explanation {
                            Text(explanation.status).font(.headline)
                            Text(explanation.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        if model.analyticsLoading { ProgressView("正在加载分析…").controlSize(.small) }
                        Text("项目趋势").font(.headline)
                        Chart(model.daily) { row in
                            BarMark(x:.value("日期",row.id),y:.value("Token",row.totals.tokens))
                        }.frame(height:160)
                        Text("Agent 分布").font(.headline)
                        ForEach(model.agents) { row in HStack { Text(toolDisplayName(row.id));Spacer();Text("\(row.totals.tokens) Token") } }
                        Text("模型分布").font(.headline)
                        ForEach(model.breakdown) { row in
                            HStack { Text(row.id);Spacer();Text("\(row.totals.tokens) Token · \(row.totals.costLabel)").monospacedDigit() }
                        }
                        if let explanation=model.explanation { ExplanationEvidence(explanation:explanation,inspect:model.inspectChange) }
                        Text("主要会话").font(.headline)
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
                                    HStack { Text("\(project.totals.sessions) 个会话 · \(project.totals.costLabel)");Spacer();if let last=project.lastActivity { Text(Date(timeIntervalSince1970:Double(last)/1000),style:.date) } }.font(.caption).foregroundStyle(.secondary)
                                    ForEach(model.risks.filter{$0.projectID==project.id && $0.level>0}) { risk in Text(risk.detail).font(.caption).foregroundStyle(.orange) }
                                    Text("输入 \(project.totals.input) · 输出 \(project.totals.output) · 缓存读 \(project.totals.cacheRead) · 缓存写 \(project.totals.cacheWrite)").font(.caption2)
                                }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
                            }.buttonStyle(.plain)
                        }
                        if model.projects.count >= 100 { Button("加载更多") { model.refresh(more:true) } }
                        if model.projects.isEmpty && !model.busy { ContentUnavailableView("此范围暂无项目",systemImage:"folder",description:Text("来源没有可靠工作目录的用量会保留在未归属中。")) }
                    }
                }.padding()
            }
        }
        .navigationTitle(selected?.name ?? "项目")
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
    let totals:UsageTotals
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("\(totals.tokens) Token").font(.largeTitle.bold()).monospacedDigit()
            Text("非缓存输入 \(totals.input) · 输出 \(totals.output) · 缓存读 \(totals.cacheRead) · 缓存写 \(totals.cacheWrite)")
            Text("费用合计 \(totals.costLabel) · 含估算，非订阅账单")
            Text("\(totals.records) 条用量记录 · 未计价 \(totals.unpriced) 条 · 时间未分配 \(totals.unallocatedTokens) Token").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
    }
}
struct BudgetSheet: View {
    @ObservedObject var model:InsightsModel
    let projectID:String?
    @Environment(\.dismiss) private var dismiss
    @State private var amount=""
    @State private var unit="tokens"
    @State private var period="month"
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(projectID == nil ? "全局预算" : "项目预算").font(.title2.bold())
            Text("达到 80%、90%、100% 时提示；费用预算含估算，非订阅账单。").font(.caption)
            Picker("单位",selection:$unit) { Text("总 Token").tag("tokens");Text("估算美元").tag("usd") }.pickerStyle(.segmented)
            Picker("周期",selection:$period) { Text("自然日").tag("day");Text("自然周").tag("calendarWeek");Text("自然月").tag("month") }
            TextField("预算上限",text:$amount).textFieldStyle(.roundedBorder)
            Toggle("启用系统通知",isOn:Binding(get:{model.notificationsEnabled},set:{model.setNotifications($0)}))
            ForEach(model.budgets.filter{$0.projectID==projectID}) { budget in
                HStack { Text("\(budget.limit.formatted()) \(budget.unit == "tokens" ? "Token" : "估算美元") / \(["day":"自然日","calendarWeek":"自然周","month":"自然月"][budget.period] ?? budget.period)");Spacer();Button("删除") { let id=budget.id;model.mutate { try $0.deleteBudget(id) } } }
            }
            HStack { Button("关闭") { dismiss() };Spacer();Button("添加预算") {
                guard let limit=Double(amount) else { return }
                let budget=BudgetRule(projectID:projectID,unit:unit,period:period,limit:limit)
                model.mutate { try $0.saveBudget(budget) };amount=""
            }.disabled(Double(amount).map{!$0.isFinite || $0<=0} ?? true) }
        }.padding(24).frame(width:500)
    }
}
struct AssignmentSheet: View {
    @ObservedObject var model:InsightsModel
    let projectID:String?
    @Environment(\.dismiss) private var dismiss
    @State private var path=""
    @State private var tool="codex"
    @State private var session=""
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("手动项目归属").font(.title2.bold())
            Text("会话归属优先于目录归属；恢复自动不会改变原始用量。").font(.caption)
            TextField("完整工作目录路径",text:$path)
            HStack {
                Button("归入此项目") { let path=path,id=projectID;model.mutate { try $0.assignDirectory(path,projectID:id) } }.disabled(!path.hasPrefix("/") || projectID==nil)
                Button("目录恢复自动") { let path=path;model.mutate { try $0.assignDirectory(path,projectID:nil) } }
            }
            Divider()
            Picker("Agent",selection:$tool) { ForEach(ScannerRegistry.all,id:\.self) { Text($0).tag($0) } }
            TextField("会话 ID",text:$session)
            HStack {
                Button("会话归入此项目") { let tool=tool,session=session,id=projectID;model.mutate { try $0.assignSession(tool:tool,sessionID:session,projectID:id) } }.disabled(session.isEmpty || projectID==nil)
                Button("会话恢复自动") { let tool=tool,session=session;model.mutate { try $0.assignSession(tool:tool,sessionID:session,projectID:nil) } }.disabled(session.isEmpty)
            }
            Button("完成") { dismiss() }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:500)
    }
}
struct ExportSheet: View {
    @ObservedObject var model:InsightsModel
    var diagnostics=false
    var queryOverride:UsageQuery? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var kind=ExportKind.usage
    @State private var format=ExportFormat.csv
    @State private var includePrivate=false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("导出当前筛选的数据").font(.title2.bold())
            if !diagnostics { Picker("内容",selection:$kind) { Text("用量记录").tag(ExportKind.usage);Text("会话汇总").tag(ExportKind.sessions);Text("Activity 元数据").tag(ExportKind.activity);Text("统计摘要").tag(ExportKind.summary);Text("数据健康").tag(ExportKind.health) } }
            Picker("格式",selection:$format) { Text("CSV").tag(ExportFormat.csv);Text("JSON").tag(ExportFormat.json) }
            if !diagnostics { Toggle("包含本地项目路径、会话身份和标题",isOn:$includePrivate) }
            Text(includePrivate ? "文件将包含本地身份信息，请确认保存位置。" : "项目、会话、调用和自定义工具使用一致别名，移除路径与标题。").font(.caption).foregroundStyle(.secondary)
            Text("始终排除凭据、提示词、工具参数和输出正文；导出不限于当前列表页。").font(.caption)
            if let message=model.exportMessage { Text(message).foregroundStyle(.green) }
            if model.exporting { ProgressView();Button("取消导出") { model.cancelExport() } }
            if let error=model.error { Text(error).foregroundStyle(.red) }
            HStack { Button("关闭") { dismiss() };Spacer();Button("选择保存位置…") { model.export(kind:kind,format:format,includePrivate:includePrivate,queryOverride:queryOverride) }.disabled(model.exporting) }
        }.padding(24).frame(width:520).onAppear { if diagnostics { kind = .health; includePrivate = false }; model.exportMessage=nil }
    }
}
struct ReportsView: View {
    @ObservedObject var model:InsightsModel
    @State private var selected:WeeklyReport?
    @State private var week=Date()
    @State private var reportExportQuery:UsageQuery?
    @State private var showExport=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("本地周报").font(.title2.bold());Spacer()
                DatePicker("周次参考日期",selection:$week,displayedComponents:.date)
                Button("生成此前完整周") { let now=week;model.mutate { try $0.generateWeeklyReport(now:now,regenerate:true) } }
                Button("导出数据") { reportExportQuery=(selected ?? model.reports.first)?.query ?? UsageQuery.period("week");showExport=true }
            }
            Text("自然周：周一至周日 · 本地规则 · 快照不会随补扫静默变化").font(.caption).foregroundStyle(.secondary)
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
                                Button("导出 Markdown") { model.exportReport(report) }
                                Button("重新生成") {
                                    let now=Date(timeIntervalSince1970:Double(report.query.end ?? 0)/1000+3600)
                                    let tz=TimeZone(identifier:report.query.timeZoneID) ?? .current
                                    selected=nil;model.mutate { try $0.generateWeeklyReport(now:now,timeZone:tz,regenerate:true) }
                                }
                            }
                            Text("相比上一自然周：\(report.totals.tokens-report.previous.tokens) Token").font(.headline)
                            Text("覆盖不完整时，变化不代表实际增长。").font(.caption).foregroundStyle(.secondary)
                            Text("项目投入").font(.headline)
                            ForEach(report.projects) { project in
                                HStack { Text(project.name);Spacer();Text("\(project.totals.tokens.formatted()) Token · \(project.totals.costLabel)") }.font(.callout)
                            }
                            Divider()
                            Text("模型与费用依据").font(.headline)
                            ForEach(report.models) { row in HStack { Text(row.id);Spacer();Text("\(row.totals.tokens.formatted()) Token") } }
                            ForEach(report.costSources) { row in
                                HStack { Text(costSourceName(row.id));Spacer();Text(row.totals.costLabel) }.font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("预算与生成时健康").font(.headline)
                            ForEach(report.budgets) { risk in Text(risk.title+" · "+risk.detail).font(.callout) }
                            ForEach(report.health) { health in HStack { Text(toolDisplayName(health.id));Spacer();Text(health.state) }.font(.caption) }
                            Text("执行活动 \(report.activityCount.formatted()) 次；调用成功不代表任务质量。").font(.caption).foregroundStyle(.secondary)
                            Text("时区：\(report.query.timeZoneID) · 规则 v\(report.ruleVersion) · 生成于 \(Date(timeIntervalSince1970:Double(report.generatedAt)/1000).formatted())").font(.caption2).foregroundStyle(.secondary)

                        }.padding()
                    } else { ContentUnavailableView("尚无周报",systemImage:"doc.text",description:Text("启动扫描完成后自动生成最近一个完整周，也可以按需生成。")) }
                }
            }
        }.padding().navigationTitle("本地周报").onAppear { model.refresh() }.sheet(isPresented:$showExport) { ExportSheet(model:model,queryOverride:reportExportQuery) }
    }
}
struct HealthView: View {
    @ObservedObject var model:InsightsModel
    let tool:String?
    let rescan:()->Void
    @State private var export=false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("数据健康").font(.title2.bold());Spacer();Button("重新扫描",action:rescan);Button("脱敏诊断导出") { export=true } }
            Text("未采集的指标显示未知；没有新增用量本身不是异常。").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(model.health.filter{tool == nil || $0.id==tool}) { health in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(toolDisplayName(health.id)).font(.headline);Spacer();Text(health.state).foregroundStyle(health.state=="正常" ? .green : .orange) }
                            Text("文件 \(health.files) · 新增 \(health.added) · 更新 \(health.updated) · \(health.duration.formatted()) 秒")
                            Text("最近尝试：\(Date(timeIntervalSince1970:Double(health.attemptedAt)/1000).formatted())").font(.caption)
                            Text("最近成功：\(health.succeededAt.map{Date(timeIntervalSince1970:Double($0)/1000).formatted()} ?? "未知")").font(.caption)
                            Text("Activity 解析器 v\(health.parserVersion) · 解析异常：\(health.parseErrors.map(String.init) ?? "未知") · 读取异常：\(health.readErrors.map(String.init) ?? "未知")").font(.caption)
                            Text("工具：\(activityCapability(agent:health.id,category:"tools").rawValue) · Skill：\(activityCapability(agent:health.id,category:"skills").rawValue)").font(.caption)
                            if !health.error.isEmpty { Text(health.error).foregroundStyle(.orange) }
                        }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
                    }
                    TotalsView(totals:model.totals)
                }
            }
        }.padding(20).frame(minWidth:600,minHeight:400).sheet(isPresented:$export) { ExportSheet(model:model,diagnostics:true) }
    }
}

struct ExplanationEvidence: View {
    let explanation: ConsumptionExplanation
    var inspect: ((ChangeContribution)->Void)?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(explanation.context,id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(["project","tool","model"],id:\.self) { dimension in
                Text(["project":"项目贡献","tool":"Agent 贡献","model":"模型贡献"][dimension]!).font(.subheadline.bold())
                ForEach(Array(explanation.changes.filter{$0.dimension==dimension}.prefix(5))) { change in
                    Button { inspect?(change) } label: { HStack { Text(change.name).lineLimit(1).truncationMode(.middle);Spacer();Text(String(format:"%+.0f Token",change.delta)).monospacedDigit();Image(systemName:"chevron.right") }.font(.caption) }.buttonStyle(.plain)
                }
            }
        }
    }
}

func costSourceName(_ source:String) -> String {
    ["estimate":"价格表估算","native":"来源报告费用","native_actual":"来源报告实际费用","native_estimate":"来源报告估算","provider_estimate":"来源报告估算","recomputed":"历史重算","legacy":"历史记录","native_included":"已包含于来源费用"][source] ?? "来源费用或历史校准"
}

struct ProjectCreateSheet: View {
    @ObservedObject var model:InsightsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var selectedID=""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("项目管理").font(.title2.bold())
            TextField("新项目名称",text:$name).textFieldStyle(.roundedBorder)
            Button("创建项目") { model.createProject(name:name);dismiss() }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            Divider()
            Picker("已有项目",selection:$selectedID) {
                Text("选择项目").tag("")
                ForEach(model.registry) { Text($0.name).tag($0.id) }
            }
            Button("打开项目") { model.query.projectID=selectedID;model.search="";model.refresh();dismiss() }.disabled(selectedID.isEmpty)
            Text("创建后可按目录或会话调整归属；恢复自动即可撤销归属变更。").font(.caption).foregroundStyle(.secondary)
            Button("关闭") { dismiss() }
        }.padding(24).frame(width:460)
    }
}

func usageIntervalLabel(_ query:UsageQuery) -> String {
    guard let start=query.start,let end=query.end else { return "全部历史（含时间未分配记录）" }
    let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:query.timeZoneID);formatter.dateFormat="yyyy-MM-dd HH:mm"
    return formatter.string(from:Date(timeIntervalSince1970:Double(start)/1000))+" — "+formatter.string(from:Date(timeIntervalSince1970:Double(end)/1000))+" · "+query.timeZoneID
}
