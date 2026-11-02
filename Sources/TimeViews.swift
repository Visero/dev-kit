import SwiftUI

struct EpochPage: View {
    @ObservedObject var store: ToolkitStore
    var minutes: Int { (try? TimeTools.offsetMinutes(store.savedOffset)) ?? 0 }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                OffsetControl(saved:$store.savedOffset)
                Panel {
                    VStack(alignment:.leading,spacing:16) {
                        Label("时间戳 → 日期",systemImage:"arrow.right").font(.system(size:15,weight:.semibold))
                        HStack {
                            TextField("例如：1735689600",text:Binding(get:{store.epochInput},set:{store.epochInput=$0;store.epochResult="";store.epochError=""})).textFieldStyle(.roundedBorder).font(.system(size:14,design:.monospaced)).accessibilityLabel("Unix 时间戳输入").onSubmit(convertEpoch)
                            Picker("单位",selection:$store.epochUnit) { ForEach(EpochUnit.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width:130).labelsHidden()
                            Button("转换",action:convertEpoch).buttonStyle(.borderedProminent).accessibilityLabel("时间戳转日期")
                            Button("现在") { store.epochInput=TimeTools.epoch(Date(),unit:store.epochUnit);convertEpoch() }
                        }
                        ValueBox(label:TimeTools.zoneLabel(minutes),value:store.epochResult)
                        Notice(text:store.epochError,error:true)
                    }.padding(20)
                }
                Panel {
                    VStack(alignment:.leading,spacing:16) {
                        Label("日期 → 时间戳",systemImage:"arrow.left").font(.system(size:15,weight:.semibold))
                        HStack {
                            TextField("yyyy-MM-dd HH:mm:ss",text:Binding(get:{store.dateInput},set:{store.dateInput=$0;store.dateResult="";store.dateError=""})).textFieldStyle(.roundedBorder).font(.system(size:14,design:.monospaced)).accessibilityLabel("日期时间输入").onSubmit(convertDate)
                            Button("转换",action:convertDate).buttonStyle(.borderedProminent).accessibilityLabel("日期转时间戳")
                            Button("现在") { store.dateInput=TimeTools.formatted(Date(),minutes:minutes);convertDate() }
                        }
                        ValueBox(label:"UNIX · 秒 / 毫秒",value:store.dateResult)
                        Notice(text:store.dateError,error:true)
                    }.padding(20)
                }
                Text("Unix 起点为 1970-01-01 00:00:00 UTC。支持负数及毫秒；日期按所选固定 UTC 偏移解释，不套用夏令时。").font(.system(size:11)).foregroundStyle(.secondary)
            }
        }.onChange(of:store.savedOffset) { _,_ in if !store.epochInput.isEmpty { convertEpoch() };if !store.dateInput.isEmpty { convertDate() } }
        .onChange(of:store.epochUnit) { _,_ in store.epochResult="";store.epochError="" }
    }
    func convertEpoch() {
        do { let date=try TimeTools.timestamp(store.epochInput,unit:store.epochUnit);store.epochResult=TimeTools.formatted(date,minutes:minutes);store.epochError="" }
        catch { store.epochResult="";store.epochError=error.localizedDescription }
    }
    func convertDate() {
        do { let date=try TimeTools.parseDate(store.dateInput,minutes:minutes);store.dateResult="\(TimeTools.epoch(date,unit:.seconds)) s  /  \(TimeTools.epoch(date,unit:.milliseconds)) ms";store.dateError="" }
        catch { store.dateResult="";store.dateError=error.localizedDescription }
    }
}
private final class ClockViewState: ObservableObject {
    @Published var showsCustomZone = false
    @Published var editing = false
    @Published var draft = ""
    @Published var error = ""
}

struct ClockPage: View {
    @ObservedObject var store: ToolkitStore
    @StateObject private var viewState = ClockViewState()
    var minutes: Int { (try? TimeTools.offsetMinutes(store.savedOffset)) ?? 0 }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        let date = context.date
                        VStack(spacing:16) {
                            HStack(spacing:16) {
                                LiveClockCard(date:date,minutes:0,title:"UTC+0",subtitle:"协调世界时")
                                LiveClockCard(date:date,minutes:480,title:"UTC+8",subtitle:"北京时间")
                            }
                            .frame(height:max(250, min(440, geometry.size.height - 230)))
                            WorkCountdownCard(date:date,savedTime:$store.workEndTime)
                            HStack(spacing:16) {
                                ValueBox(label:"UNIX SECONDS",value:TimeTools.epoch(Date(timeIntervalSince1970:floor(date.timeIntervalSince1970)),unit:.seconds))
                                    .frame(maxWidth:.infinity)
                                ValueBox(label:"本机时区",value:DateFormatter.localizedString(from:date,dateStyle:.none,timeStyle:.medium))
                                    .frame(maxWidth:.infinity)
                            }
                        }
                    }
                    DisclosureGroup("自定义 UTC 偏移",isExpanded:$viewState.showsCustomZone) {
                        VStack(spacing:12) {
                            OffsetControl(saved:$store.savedOffset)
                            TimelineView(.periodic(from:.now,by:1)) { context in
                                ValueBox(label:TimeTools.zoneLabel(minutes),value:TimeTools.formatted(context.date,minutes:minutes))
                            }
                        }.padding(.top,12)
                    }.font(.system(size:12)).foregroundStyle(.secondary)
                    Text("每秒刷新 · 固定 UTC 偏移 · 下班按 UTC+8 的周一至周五计算，不含节假日及调休。")
                        .font(.system(size:10)).foregroundStyle(.tertiary)
                }.padding(1)
            }
        }
    }
}

private struct LiveClockCard: View {
    let date: Date
    let minutes: Int
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing:18) {
            HStack(spacing:7) {
                Circle().fill(.teal).frame(width:6,height:6)
                Text(title).font(.system(size:14,weight:.semibold,design:.monospaced))
                Text(subtitle).font(.system(size:12))
            }.foregroundStyle(.teal)
            Text(TimeTools.formatter(minutes,pattern:"HH:mm:ss").string(from:date))
                .font(.system(size:62,weight:.light,design:.rounded)).monospacedDigit()
                .minimumScaleFactor(0.45).lineLimit(1).textSelection(.enabled)
                .accessibilityLabel("\(title) 当前时间")
                .accessibilityValue(TimeTools.formatter(minutes,pattern:"HH:mm:ss").string(from:date))
            Text(TimeTools.formatter(minutes,pattern:"yyyy-MM-dd  ·  EEEE").string(from:date))
                .font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            CopyButton(text:TimeTools.formatted(date,minutes:minutes)+" "+TimeTools.zoneLabel(minutes),label:"复制时间")
                .buttonStyle(.bordered).accessibilityLabel("复制 \(title) 当前时间")
        }
        .padding(22).frame(minWidth:0,maxWidth:.infinity,maxHeight:.infinity)
        .background {
            RoundedRectangle(cornerRadius:24).fill(.teal.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius:24).stroke(.teal.opacity(0.13),lineWidth:1))
        }
    }
}

private struct WorkCountdownCard: View {
    let date: Date
    @Binding var savedTime: String
    @StateObject private var viewState = ClockViewState()
    var state: WorkdayCountdownState {
        WorkdayCountdown.state(at:date,targetMinutes:(try? WorkdayCountdown.parseTime(savedTime)) ?? WorkdayCountdown.defaultMinutes)
    }
    var body: some View {
        HStack(spacing:16) {
            Image(systemName:"briefcase").font(.system(size:21)).foregroundStyle(.teal)
            VStack(alignment:.leading,spacing:5) {
                Text("下班倒计时").font(.system(size:13,weight:.semibold))
                Text("周一至周五 · \(savedTime) · UTC+8").font(.system(size:11)).foregroundStyle(.secondary)
            }
            Spacer(minLength:8)
            Text(state.display).font(.system(size:28,weight:.medium,design:.rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.teal)
                .accessibilityLabel("下班状态").accessibilityValue(state.display)
            Button {
                viewState.draft = savedTime; viewState.error = ""; viewState.editing = true
            } label: { Image(systemName:"slider.horizontal.3") }
                .buttonStyle(.borderless).help("设置下班时间").accessibilityLabel("设置下班时间")
                .popover(isPresented:$viewState.editing) {
                    VStack(alignment:.leading,spacing:14) {
                        Text("下班时间").font(.headline)
                        Text("北京时间 UTC+8 · 周一至周五\n不含法定节假日和调休；到点显示已下班。").font(.system(size:12)).foregroundStyle(.secondary)
                        HStack {
                            TextField("20:30",text:$viewState.draft).textFieldStyle(.roundedBorder)
                                .font(.system(size:15,design:.monospaced)).frame(width:90)
                                .accessibilityLabel("下班时间 HH:mm").onSubmit(save)
                            Text("24 小时制").font(.system(size:11)).foregroundStyle(.secondary)
                        }
                        Notice(text:viewState.error,error:true)
                        HStack {
                            Button("恢复 20:30") { viewState.draft = WorkdayCountdown.defaultTime; viewState.error = "" }
                            Spacer()
                            Button("取消") { viewState.editing = false }
                            Button("保存",action:save).buttonStyle(.borderedProminent)
                        }
                    }.padding(20).frame(width:330)
                }
        }.padding(18).frame(maxWidth:.infinity)
            .background(Color.teal.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
            .overlay(RoundedRectangle(cornerRadius:16).stroke(Color.teal.opacity(0.16),lineWidth:1))
    }
    private func save() {
        do {
            _ = try WorkdayCountdown.parseTime(viewState.draft)
            savedTime = viewState.draft.trimmingCharacters(in:.whitespacesAndNewlines)
            viewState.error = ""; viewState.editing = false
        } catch { viewState.error = error.localizedDescription }
    }
}
