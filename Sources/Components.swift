import SwiftUI
import AppKit

struct Panel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { VStack(alignment:.leading,spacing:0,content:content).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(Color.primary.opacity(0.075),lineWidth:1)) }
}
struct Notice: View {
    let text: String
    var error=false
    var body: some View {
        if !text.isEmpty { Label(text,systemImage:error ? "exclamationmark.circle.fill" : "checkmark.circle.fill").font(.system(size:12)).foregroundStyle(error ? Color.red : Color.teal).textSelection(.enabled).padding(.vertical,5) }
    }
}
final class CopyState: ObservableObject { @Published var copied=false }
struct CopyButton: View {
    var text: String
    var label="复制"
    @StateObject private var status=CopyState()
    var body: some View {
        Button {
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
            status.copied=true
            DispatchQueue.main.asyncAfter(deadline:.now()+1.3) { status.copied=false }
        } label: { Label(status.copied ? "已复制" : label,systemImage:status.copied ? "checkmark" : "doc.on.doc") }
        .disabled(text.isEmpty)
    }
}
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable=true
    var label: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll=NSScrollView()
        scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .noBorder;scroll.drawsBackground=false
        let view=NSTextView(frame:.zero)
        view.isRichText=false;view.isEditable=editable;view.isSelectable=true;view.allowsUndo=true
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        view.textColor = .labelColor;view.backgroundColor = .textBackgroundColor
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false;view.isAutomaticTextReplacementEnabled=false
        view.isAutomaticSpellingCorrectionEnabled=false;view.isContinuousSpellCheckingEnabled=false
        view.textContainerInset=NSSize(width:12,height:12)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=true
        view.autoresizingMask=[.width]
        view.minSize=NSSize(width:0,height:0);view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView=false
        view.setAccessibilityLabel(label)
        view.delegate=context.coordinator;view.string=text
        scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        guard let view=scroll.documentView as? NSTextView else { return }
        context.coordinator.parent=self
        if view.string != text { view.string=text }
        view.isEditable=editable
    }
    class Coordinator: NSObject,NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent=parent }
        func textDidChange(_ notification: Notification) { if let view=notification.object as? NSTextView { parent.text=view.string } }
    }
}
struct EditorPanel: View {
    let title: String
    let badge: String
    @Binding var text: String
    var editable=true
    var body: some View {
        Panel {
            HStack {
                Text(title).font(.system(size:12,weight:.semibold))
                Spacer()
                Text(badge).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                if !editable { CopyButton(text:text).buttonStyle(.borderless).font(.system(size:11)) }
            }.padding(.horizontal,14).padding(.vertical,12)
            Divider()
            CodeEditor(text:$text,editable:editable,label:title).clipShape(UnevenRoundedRectangle(bottomLeadingRadius:16,bottomTrailingRadius:16))
        }
    }
}
final class OffsetState: ObservableObject {
    @Published var draft=""
    @Published var error=""
}
struct OffsetControl: View {
    @Binding var saved: String
    @StateObject private var state=OffsetState()
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:10) {
                Image(systemName:"globe").foregroundStyle(.teal)
                Text("UTC 偏移").font(.system(size:12,weight:.medium))
                TextField("0",text:$state.draft).textFieldStyle(.roundedBorder).frame(width:74).accessibilityLabel("UTC 偏移值").onSubmit(apply)
                Button("应用",action:apply)
                ForEach(["0","8","9","-5"],id:\.self) { value in Button(value=="0" ? "UTC" : "\(value.hasPrefix("-") ? "" : "+")\(value)") { state.draft=value;apply() }.buttonStyle(.borderless) }
                Spacer()
                Text(TimeTools.zoneLabel((try? TimeTools.offsetMinutes(saved)) ?? 0)).font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(.teal)
            }
            if !state.error.isEmpty { Notice(text:state.error,error:true) }
        }.onAppear { state.draft=saved }.onChange(of:saved) { _,new in state.draft=new }
    }
    func apply() {
        do { _=try TimeTools.offsetMinutes(state.draft);saved=state.draft.trimmingCharacters(in:.whitespacesAndNewlines);state.error="" }
        catch { state.error=error.localizedDescription }
    }
}
struct ValueBox: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment:.center) {
            VStack(alignment:.leading,spacing:7) { Text(label).font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary);Text(value.isEmpty ? "等待转换" : value).font(.system(size:16,weight:.medium,design:.monospaced)).textSelection(.enabled).foregroundStyle(value.isEmpty ? .secondary : .primary) }
            Spacer();CopyButton(text:value).buttonStyle(.borderless)
        }.padding(16).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
    }
}
