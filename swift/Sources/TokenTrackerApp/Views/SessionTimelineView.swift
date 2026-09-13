import SwiftUI
import TokenTrackerCore

struct SessionTimelineView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state:AppState
    let tool:String,sessionID:String
    @State private var rows:[ActivityEvent]=[]
    @State private var before:Int64?
    @State private var beforeID:Int64?
    @State private var status="all"
    @State private var kind="all"
    @State private var confidence="all"
    @State private var collapsed=Set<String>()
    @State private var loading=false
    @State private var failed=false
    private var filterID:String { tool+sessionID+status+kind+confidence }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Picker(L10n.text("状态"),selection:$status) { Text(L10n.text("全部结果")).tag("all");Text(L10n.text("成功")).tag("success");Text(L10n.text("错误")).tag("error");Text(L10n.text("拒绝")).tag("denied");Text(L10n.text("未知")).tag("unknown") }
                Picker(L10n.text("类型"),selection:$kind) { Text(L10n.text("全部类型")).tag("all");Text(L10n.text("工具")).tag("tool");Text("Skill").tag("skill");Text(L10n.text("子 Agent")).tag("agent") }
                Picker(L10n.text("证据"),selection:$confidence) { Text(L10n.text("全部证据")).tag("all");Text(L10n.text("精确")).tag("exact");Text(L10n.text("推导")).tag("derived") }
            }.labelsHidden()
            Text(L10n.text("请求观察与执行证据分开展示；不会将会话 Token 或费用分摊到工具。结果未知不代表仍在运行。")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(groups,id:\.key) { group in
                        if group.label.isEmpty { ForEach(group.events,id:\.srcKey) { eventRow($0) } }
                        else { DisclosureGroup(isExpanded:Binding(get:{!collapsed.contains(group.key)},set:{ if $0 { collapsed.remove(group.key) } else { collapsed.insert(group.key) } })) { ForEach(group.events,id:\.srcKey) { eventRow($0) } } label: { Text(group.label) } }
                    }
                    if rows.contains(where:{$0.startedAt == nil && $0.endedAt == nil}) {
                        Text(L10n.text("时间未知")).font(.headline)
                        ForEach(rows.filter{$0.startedAt == nil && $0.endedAt == nil},id:\.srcKey) { event in eventRow(event) }
                    }
                    if loading { ProgressView() }
                    if failed { Text(L10n.text("时间线读取失败")).foregroundStyle(.red);Button(L10n.text("重试")) { Task { await load(reset:rows.isEmpty) } } }
                    if before != nil { Button(L10n.text("加载更早的 200 条")) { Task { await load(reset:false) } }.disabled(loading) }
                    if rows.isEmpty && !loading && !failed { ContentUnavailableView(L10n.text("暂无可用活动证据"),systemImage:"point.3.connected.trianglepath.dotted") }
                }
            }
        }.padding().task(id:filterID) { await load(reset:true) }
    }
    private struct GroupedEvents { var key:String;var label:String;var events:[ActivityEvent] }
    private var groups:[GroupedEvents] {
        let timed=rows.filter{$0.startedAt != nil || $0.endedAt != nil}
        let parentIDs=Set(timed.map(\.parentCallID).filter{!$0.isEmpty})
        var groups:[GroupedEvents]=[],positions:[String:Int]=[:]
        for event in timed {
            let parent = !event.parentCallID.isEmpty ? event.parentCallID : parentIDs.contains(event.callID) ? event.callID : ""
            let key = !event.turnID.isEmpty ? "turn:"+event.turnID : !parent.isEmpty ? "call:"+parent : "event:"+event.srcKey
            let label = !event.turnID.isEmpty ? "Turn \(event.turnID)" : !parent.isEmpty ? L10n.text("调用组 \(parent)") : ""
            if let index=positions[key] { groups[index].events.append(event) }
            else { positions[key]=groups.count;groups.append(GroupedEvents(key:key,label:label,events:[event])) }
        }
        return groups
    }
    private func eventRow(_ event:ActivityEvent) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Image(systemName:event.eventKind == .agent ? "person.2" : "wrench.and.screwdriver")
                Text(event.canonicalName).font(.headline)
                Spacer()
                Text(event.status == "unknown" || event.endedAt == nil ? L10n.text("结果未知") : activityStatusLabel(event.status)).font(.caption)
            }
            HStack {
                Text(event.eventLayer == .requestFallback ? L10n.text("请求观察") : event.eventLayer == .lifecycle ? L10n.text("生命周期") : L10n.text("执行证据"))
                Text(event.confidence == "exact" ? L10n.text("精确") : L10n.text("推导"))
                if let start=event.startedAt ?? event.endedAt { Text(Date(timeIntervalSince1970:Double(start)/1000),style:.time) }
                if let end=event.endedAt { Text(L10n.text("结束"));Text(Date(timeIntervalSince1970:Double(end)/1000),style:.time) }
                if let duration=event.durationMs { Text("\(duration) ms") }
            }.font(.caption).foregroundStyle(.secondary)
            if !event.turnID.isEmpty { Text("Turn：\(event.turnID)").font(.caption2).textSelection(.enabled) }
            if !event.parentCallID.isEmpty { Text(L10n.text("父调用：\(event.parentCallID)")).font(.caption2).textSelection(.enabled) }
        }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:10))
    }
    private func load(reset:Bool) async {
        let requested=filterID
        if reset { rows=[];before=nil;beforeID=nil }
        loading=true;failed=false
        let result=await state.activityTimelinePage(range:"all",agent:tool,sessionID:sessionID,confidence:confidence,status:status == "all" ? nil : status,limit:200,before:before,beforeID:beforeID,kind:ActivityKind(rawValue:kind),query:nil)
        guard !Task.isCancelled,filterID==requested else { return }
        if let result { rows += result.rows;before=result.nextBefore;beforeID=result.nextBeforeID } else { failed=true }
        loading=false
    }
}
