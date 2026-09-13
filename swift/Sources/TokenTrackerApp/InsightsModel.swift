import AppKit
import Combine
import CryptoKit
import SwiftUI
import UserNotifications
import TokenTrackerCore

@MainActor
final class InsightsModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    var codexAccountID = "unknown"
    let path: String
    @Published var registry: [ProjectIdentity] = []
    @Published var projects: [ProjectSummary] = []
    @Published var totals = UsageTotals()
    @Published var health: [ScanHealth] = []
    @Published var reports: [WeeklyReport] = []
    @Published var risks: [RiskNotice] = []
    @Published var budgets: [BudgetRule] = []
    @Published var explanation: ConsumptionExplanation?
    @Published var daily: [UsageBreakdown] = []
    @Published var agents: [UsageBreakdown] = []
    @Published var sessions: [UsageSessionSummary] = []
    var onSession: ((String,String) -> Void)?
    @Published var breakdown: [UsageBreakdown] = []
    @Published var query = UsageQuery.period("week")
    @Published var search = ""
    @Published var busy = false
    @Published var analyticsLoading = false
    private var analyticsScope = ""
    @Published private var errorNotice: L10n.Template?
    var error: String? { errorNotice.map(L10n.text) }
    @Published private var backfillProgressNotice: L10n.Template?
    var backfillProgress: String { backfillProgressNotice.map(L10n.text) ?? "" }
    @Published private var exportMessageNotice: L10n.Template?
    var exportMessage: String? { exportMessageNotice.map(L10n.text) }
    @Published var costSources: [UsageBreakdown] = []
    @Published var exporting = false
    @Published var notificationsEnabled = false
    var onNavigate: ((String?) -> Void)?
    private var analysisCancellation = ExportCancellation()
    private let analysisQueue=DispatchQueue(label:"tokentracker.insight-analysis",qos:.utility)
    private let maintenanceQueue=DispatchQueue(label:"tokentracker.insight-maintenance",qos:.utility)
    private let queue=DispatchQueue(label:"tokentracker.insights",qos:.userInitiated)
    private let backfillQueue=DispatchQueue(label:"tokentracker.project-backfill",qos:.utility)
    private var backfillRunning=false
    private let exportQueue=DispatchQueue(label:"tokentracker.exports",qos:.utility)
    private var generation=0
    private var cancellation: ExportCancellation?
    private var healthWindow: NSWindow?
    private var pendingNotifications=Set<String>()
    init(path:String) {
        self.path=path
        super.init()
        notificationsEnabled=ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] != "1" && UserDefaults.standard.bool(forKey:"tt.notifications.enabled")
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate=self }
    }
    func refresh(afterScan: Bool = false, more: Bool = false) {
        generation += 1
        analysisCancellation.cancel();analysisCancellation=ExportCancellation()
        let cancellation=analysisCancellation
        let version=generation,path=path,query=query,search=search,offset=more ? projects.count : 0
        busy=true;analyticsLoading=true
        let scope="\(query.projectID ?? "")|\(query.tool ?? "")|\(query.model ?? "")|\(query.start ?? 0)|\(query.timeZoneID)"
        if scope != analyticsScope {
            explanation=nil;daily=[];agents=[];sessions=[];breakdown=[];costSources=[];analyticsScope=scope
        }
        if afterScan {
            startBackfill()
            maintenanceQueue.async { [weak self] in
                do {
                    let store=try UsageStore(path:path)
                    try store.generateWeeklyReport()
                    let reports=try store.weeklyReports()
                    DispatchQueue.main.async { self?.reports=reports }
                } catch { DispatchQueue.main.async { self?.errorNotice=L10n.message("自动周报生成失败，可在报告页重试") } }
            }
        }
        queue.async { [weak self] in
            do {
                try cancellation.check()
                let store=try UsageStore(path:path)
                let registry=try store.projectRegistry()
                var results=try store.projectSummaries(query,search:search,offset:offset)
                if results.isEmpty,let id=query.projectID,let project=registry.first(where:{$0.id==id}) { results=[ProjectSummary(id:project.id,name:project.name,totals:UsageTotals(),lastActivity:nil)] }
                let projects=results
                let totals=try store.usageTotals(query),health=try store.health(now:store.nowMs())
                DispatchQueue.main.async {
                    guard let self,version==self.generation else { return }
                    self.registry=registry;self.projects=more ? self.projects+projects : projects
                    self.totals=totals;self.health=health;self.busy=false;self.errorNotice=nil
                    self.loadAnalytics(query:query,version:version,cancellation:cancellation)
                }
            } catch is CancellationError { }
            catch { DispatchQueue.main.async { guard let self,version==self.generation else { return };self.busy=false;self.errorNotice=L10n.message("分析数据读取失败，请重试") } }
        }
    }
    private func loadAnalytics(query:UsageQuery,version:Int,cancellation:ExportCancellation) {
        let path=path, account=codexAccountID
        analysisQueue.async { [weak self] in
            do {
                try cancellation.check()
                let store=try UsageStore(path:path)
                let costSources=try store.breakdown(query,dimension:"cost_source")
                let reports=try store.weeklyReports(),budgets=try store.budgets()
                let risks=try store.budgetRisks()+store.quotaRisks(now:store.nowMs(),codexAccountID:account)
                try cancellation.check()
                let explanation=try store.consumptionExplanation(projectID:query.projectID,cancellation:cancellation)
                let breakdown=try store.breakdown(query,dimension:"model")
                let daily=query.projectID == nil ? [] : try store.dailyBreakdown(query,cancellation:cancellation)
                let agents=query.projectID == nil ? [] : try store.breakdown(query,dimension:"tool")
                let sessions=query.projectID == nil ? [] : try store.projectSessions(query)
                DispatchQueue.main.async {
                    guard let self,version==self.generation else { return }
                    self.costSources=costSources;self.reports=reports;self.budgets=budgets
                    self.risks=risks;self.explanation=explanation;self.breakdown=breakdown
                    self.daily=daily;self.agents=agents;self.sessions=sessions
                    self.analyticsLoading=false
                    self.deliver(risks)
                }
            } catch is CancellationError { }
            catch { DispatchQueue.main.async { guard let self,version==self.generation else { return };self.analyticsLoading=false;self.errorNotice=L10n.message("部分分析未完成，请刷新重试") } }
        }
    }
    func startBackfill() {
        guard ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] != "1", !backfillRunning else { return };backfillRunning=true
        let path=path
        backfillQueue.async { [weak self] in
            do {
                let store=try UsageStore(path:path)
                while true {
                    let progress=try ProjectBackfill.runBatch(store:store,roots:ScanRoots())
                    DispatchQueue.main.async { self?.backfillProgressNotice=L10n.message("项目归属补全 \(progress.processed) / \(progress.total)") }
                    if progress.complete { break }
                }
                DispatchQueue.main.async { self?.backfillRunning=false;self?.refresh() }
            } catch {
                DispatchQueue.main.async { self?.backfillRunning=false;self?.backfillProgressNotice=L10n.message("项目归属补全暂停，将在下次扫描后重试") }
            }
        }
    }

    func mutate(_ action: @escaping @Sendable (UsageStore) throws -> Void) {
        let path=path
        queue.async { [weak self] in
            do {
                let store=try UsageStore(path:path);try action(store)
                DispatchQueue.main.async { self?.refresh() }
            } catch {
                DispatchQueue.main.async { self?.errorNotice=L10n.message("保存失败，请检查输入、文件权限与磁盘空间") }
            }
        }
    }
    func createProject(name:String) {
        let id=UUID().uuidString,path=path
        queue.async { [weak self] in
            do {
                try UsageStore(path:path).createProject(id:id,name:name)
                DispatchQueue.main.async { self?.query.projectID=id;self?.search="";self?.refresh() }
            } catch { DispatchQueue.main.async { self?.errorNotice=L10n.message("项目创建失败，请检查名称和存储权限") } }
        }
    }
    func inspectChange(_ change:ChangeContribution) {
        query=UsageQuery.period("day")
        switch change.dimension {
        case "project": query.projectID=change.key ?? change.name
        case "tool": query.tool=change.name
        case "model": query.model=change.name
        default: break
        }
        onInspect?()
        refresh()
    }
    var onInspect: (() -> Void)?
    func setNotifications(_ enabled: Bool) {
        if !enabled { notificationsEnabled=false;UserDefaults.standard.set(false,forKey:"tt.notifications.enabled");return }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { [weak self] granted,_ in
            Task { @MainActor in
                self?.notificationsEnabled=granted;UserDefaults.standard.set(granted,forKey:"tt.notifications.enabled")
                if !granted { self?.errorNotice=L10n.message("系统通知未获授权；应用内提醒仍可使用") }
            }
        }
    }
    private func deliver(_ risks:[RiskNotice]) {
        guard notificationsEnabled else { return }
        for risk in risks where risk.level > 0 && !pendingNotifications.contains(risk.id) {
            pendingNotifications.insert(risk.id)
            let path=path
            queue.async { [weak self] in
                do {
                    let store=try UsageStore(path:path)
                    guard try store.shouldNotify(risk,now:store.nowMs()) else {
                        DispatchQueue.main.async { self?.pendingNotifications.remove(risk.id) };return
                    }
                    let route=SHA256.hash(data:Data(risk.id.utf8)).map { String(format:"%02x",$0) }.joined()
                    _ = try store.conn.execute("INSERT OR REPLACE INTO insight_state VALUES (?,?)",["notification-target:"+route,risk.projectID ?? ""])
                    try store.conn.commit()
                    let content=UNMutableNotificationContent()
                    content.title=L10n.text("TokenTracker 用量提醒")
                    content.body=risk.level == 1 ? L10n.text("按近期速度估算，配额可能在重置前耗尽。打开应用查看。") : L10n.text("一项预算或配额已达到 \(risk.level)% 。打开应用查看。")
                    content.userInfo=["route":route]
                    let request=UNNotificationRequest(identifier:route+":"+risk.cycle+":"+String(risk.level),content:content,trigger:nil)
                    UNUserNotificationCenter.current().add(request) { error in
                        if error == nil {
                            self?.queue.async { try? UsageStore(path:path).markNotified(risk,now:Int64(Date().timeIntervalSince1970*1000)) }
                        }
                        DispatchQueue.main.async { self?.pendingNotifications.remove(risk.id) }
                    }
                } catch { DispatchQueue.main.async { self?.pendingNotifications.remove(risk.id) } }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping () -> Void) {
        let route=response.notification.request.content.userInfo["route"] as? String ?? ""
        Task { @MainActor in
            let path=self.path
            self.queue.async { [weak self] in
                let project=(try? UsageStore(path:path).conn.queryOne("SELECT value FROM insight_state WHERE key=?",["notification-target:"+route]))?.string("value")
                DispatchQueue.main.async { self?.onNavigate?(project?.isEmpty == false ? project : nil) }
            }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) {
        completionHandler([.banner,.sound])
    }
    func showHealth(tool:String? = nil, rescan:@escaping ()->Void) {
        if healthWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:560),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.identifier=NSUserInterfaceItemIdentifier("数据健康");window.title=L10n.text("数据健康");window.isReleasedWhenClosed=false;healthWindow=window;window.center()
        }
        healthWindow?.contentView=NSHostingView(rootView:HealthView(model:self,tool:tool,rescan:rescan).appLanguage())
        healthWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);refresh()
    }
    func export(kind:ExportKind,format:ExportFormat,includePrivate:Bool,queryOverride:UsageQuery? = nil) {
        let effectiveQuery=queryOverride ?? query
        if kind == .activity,effectiveQuery.model != nil { errorNotice=L10n.message("现有证据无法把活动准确归入模型；请清除模型筛选或导出用量记录");return }
        let panel=NSSavePanel();panel.nameFieldStringValue="TokenTracker-\(kind.rawValue).\(format.rawValue)"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let cancellation=ExportCancellation();self.cancellation=cancellation;exporting=true;exportMessageNotice=nil
        let path=path,query=effectiveQuery
        exportQueue.async { [weak self] in
            do {
                try InsightExporter.export(store:UsageStore(path:path),query:query,kind:kind,format:format,destination:url,includePrivate:includePrivate,cancellation:cancellation)
                DispatchQueue.main.async { self?.exporting=false;self?.errorNotice=nil;self?.exportMessageNotice=L10n.message("导出已保存到所选文件") }
            } catch is CancellationError { DispatchQueue.main.async { self?.exporting=false } }
            catch { DispatchQueue.main.async { self?.exporting=false;self?.errorNotice=L10n.message("导出失败，未保存不完整结果") } }
        }
    }
    func clearExportMessage() { exportMessageNotice = nil }

    func cancelExport() { cancellation?.cancel() }
    func exportReport(_ report:WeeklyReport) {
        let panel=NSSavePanel();panel.nameFieldStringValue="TokenTracker-weekly.md"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try report.markdown.write(to:url,atomically:true,encoding:.utf8) } catch { self.errorNotice=L10n.message("周报保存失败") }
    }
}
