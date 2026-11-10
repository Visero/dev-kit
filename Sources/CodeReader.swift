import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Standard NSDocument lifecycle supplies Save, undo and unsaved-close protection.
final class CodeReaderDocument: NSDocument {
    var snapshot: CodeFileSnapshot
    var buffer: String {
        didSet { windowControllers.forEach { $0.window?.isDocumentEdited = isDocumentEdited } }
    }
    private var savedBuffer: String
    override var isDocumentEdited: Bool { buffer != savedBuffer }
    var language: CodeLanguage

    init(url: URL, snapshot: CodeFileSnapshot) {
        self.snapshot = snapshot; buffer = snapshot.text;savedBuffer = snapshot.text
        language = CodeFileLanguage.resolve(url,text:snapshot.text)
        super.init()
        fileURL = url; fileType = "public.plain-text"
    }
    override class var autosavesInPlace: Bool { false }
    override func data(ofType typeName: String) throws -> Data { try snapshot.encoded(buffer) }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        if saveOperation == .saveOperation, let original = fileURL {
            try snapshot.checkUnchanged(at:original)
        }
        let writingBuffer = buffer
        try super.write(to:url,ofType:typeName,for:saveOperation,originalContentsURL:absoluteOriginalContentsURL)
        snapshot = try CodeFileSnapshot.read(url)
        savedBuffer = writingBuffer
        windowControllers.forEach { $0.window?.isDocumentEdited = isDocumentEdited }
    }

    func discardForClose() {
        savedBuffer = buffer
        updateChangeCount(.changeCleared)
        windowControllers.forEach { $0.window?.isDocumentEdited = false }
    }
    override func close() {
        // AppKit calls close only after canClose has approved saving/discarding.
        // Clear the custom comparison before native controllers consult it again.
        discardForClose()
        super.close()
    }
    override func makeWindowControllers() {
        let controller = CodeReaderWindowController(document:self)
        addWindowController(controller)
    }
}

final class CodeLineRuler: NSRulerView {
    weak var editor: NSTextView?
    private(set) var index = CodeLineIndex("")
    var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        editor = textView
        super.init(scrollView:scrollView,orientation:.verticalRuler)
        clientView = textView
        rebuild()
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,
                          object:scrollView.contentView,queue:.main) { [weak self] _ in self?.needsDisplay = true })
        observers.append(NotificationCenter.default.addObserver(forName:NSText.didChangeNotification,
                          object:textView,queue:.main) { [weak self] _ in self?.rebuild() })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func rebuild() {
        index = CodeLineIndex(editor?.string ?? "")
        ruleThickness = max(48,CGFloat(String(index.starts.count).count)*9+22)
        needsDisplay = true
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill();bounds.fill()
        guard let view = editor, let layout = view.layoutManager,let container = view.textContainer else { return }
        let visible = view.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect:visible,in:container)
        let characters = layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        let first = index.lineIndex(at:characters.location)
        let last = min(index.starts.count-1,index.lineIndex(at:NSMaxRange(characters))+1)
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular),
                                                 .foregroundColor:NSColor.secondaryLabelColor]
        for i in first...max(first,last) {
            let offset = index.starts[i]
            let lineRect: NSRect
            if offset < (view.string as NSString).length {
                let glyph = layout.glyphIndexForCharacter(at:offset)
                lineRect = layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
            } else { lineRect = layout.extraLineFragmentRect }
            let point = convert(NSPoint(x:0,y:lineRect.minY+view.textContainerOrigin.y),from:view)
            let label = "\(i+1)" as NSString
            let size = label.size(withAttributes:attrs)
            label.draw(at:NSPoint(x:ruleThickness-size.width-12,y:point.y+max(0,(lineRect.height-size.height)/2)),withAttributes:attrs)
        }
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath();divider.move(to:NSPoint(x:bounds.maxX-0.5,y:bounds.minY))
        divider.line(to:NSPoint(x:bounds.maxX-0.5,y:bounds.maxY));divider.stroke()
    }
}

final class CodeReaderWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    let editor = HighlightTextView(frame:NSRect(x:0,y:0,width:980,height:740))
    let scroll = NSScrollView()
    var ruler: CodeLineRuler!
    private let vimToggle = NSButton(checkboxWithTitle:"Vim 模式", target:nil, action:nil)
    private let vimModeLabel = NSTextField(labelWithString:"NORMAL")
    private var generation = UUID()
    private var pending: DispatchWorkItem?
    private weak var fileModel: CodeReaderDocument?
    private var sourceDocument: CodeReaderDocument { fileModel! }

    init(document: CodeReaderDocument) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:760),
                              styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = document.fileURL?.lastPathComponent ?? "代码"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width:500,height:320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window:window)
        fileModel = document
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder;scroll.drawsBackground = true;scroll.backgroundColor = .textBackgroundColor
        scroll.autoresizingMask = [.width,.height]
        editor.isRichText = false;editor.isEditable = true;editor.isSelectable = true;editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize:14,weight:.regular)
        editor.textColor = .labelColor;editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false;editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false;editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false;editor.isGrammarCheckingEnabled = false
        editor.isVerticallyResizable = true;editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero;editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width:12,height:12)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.string = document.buffer;editor.delegate = self
        editor.usesFindBar = true;editor.isIncrementalSearchingEnabled = true
        editor.setAccessibilityLabel("代码编辑区")
        scroll.documentView = editor
        ruler = CodeLineRuler(scrollView:scroll,textView:editor)
        scroll.verticalRulerView = ruler;scroll.hasVerticalRuler = true;scroll.hasHorizontalRuler = false;scroll.rulersVisible = true
        let container = NSView(frame:NSRect(x:0,y:0,width:1000,height:760))
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width,.height]
        container.addSubview(scroll)
        window.contentView = container
        editor.vimEnabled = UserDefaults.standard.bool(forKey:"DevKit.vimMode")
        vimModeLabel.stringValue = editor.vim.mode.label
        vimModeLabel.isHidden = !editor.vimEnabled
        editor.vim.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.vimModeLabel.stringValue = mode.label
            self.vimModeLabel.isHidden = !self.editor.vimEnabled
        }
        installVimBar(in:container)
        window.delegate = self
        editor.themeChanged = { [weak self] in self?.scheduleHighlight() }
        scheduleHighlight()
        window.makeFirstResponder(editor)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pending?.cancel() }
    private func installVimBar(in container: NSView) {
        let bar = NSVisualEffectView()
        bar.material = .popover
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 9
        bar.layer?.masksToBounds = true
        vimToggle.target = self
        vimToggle.action = #selector(toggleVim(_:))
        vimToggle.bezelStyle = .rounded
        vimToggle.controlSize = .small
        vimToggle.state = editor.vimEnabled ? .on : .off
        vimToggle.setAccessibilityLabel("Vim 模式")
        vimModeLabel.font = .monospacedSystemFont(ofSize:10,weight:.semibold)
        vimModeLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views:[vimToggle,vimModeLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:bar.leadingAnchor,constant:8),
            stack.trailingAnchor.constraint(equalTo:bar.trailingAnchor,constant:-8),
            stack.topAnchor.constraint(equalTo:bar.topAnchor,constant:6),
            stack.bottomAnchor.constraint(equalTo:bar.bottomAnchor,constant:-6),
            bar.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-16),
            bar.topAnchor.constraint(equalTo:container.topAnchor,constant:12)])
    }
    @objc private func toggleVim(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on,forKey:"DevKit.vimMode")
        editor.vimEnabled = on
        vimModeLabel.stringValue = editor.vim.mode.label
        vimModeLabel.isHidden = !on
        window?.makeFirstResponder(editor)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose { _ in }
        return false
    }
    func requestClose(completion: @escaping (Bool) -> Void) {
        let model = sourceDocument
        guard model.isDocumentEdited else { model.close();completion(true);return }
        guard let window else { completion(false);return }
        let alert = NSAlert()
        alert.messageText = "保存对“\(model.fileURL?.lastPathComponent ?? "代码")”的修改吗？"
        alert.informativeText = "未保存的修改将会丢失。"
        alert.addButton(withTitle:"保存");alert.addButton(withTitle:"不保存");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window) { response in
            if response == .alertFirstButtonReturn {
                guard let url = model.fileURL else { completion(false);return }
                model.save(to:url,ofType:model.fileType ?? "public.plain-text",for:.saveOperation) { error in
                    if let error { NSApp.presentError(error);completion(false) }
                    else { model.close();completion(true) }
                }
            } else if response == .alertSecondButtonReturn {
                model.close();completion(true)
            } else { completion(false) }
        }
    }
    func undoManager(for view: NSTextView) -> UndoManager? { sourceDocument.undoManager }
    func textDidChange(_ notification: Notification) {
        sourceDocument.buffer = editor.string
        // Undo state is tracked by NSDocument's native undo manager, not duplicated here.
        scheduleHighlight();ruler.rebuild()
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        let proposed = (textView.string as NSString).replacingCharacters(in:affectedCharRange,with:replacementString ?? "")
        guard proposed.utf8.count <= CodeFileSnapshot.maximumBytes else { NSSound.beep();return false }
        return true
    }
    func scheduleHighlight() {
        generation = UUID();pending?.cancel()
        guard !editor.hasMarkedText() else { return }
        let id = generation,text = editor.string,language = sourceDocument.language
        let work = DispatchWorkItem { [weak self] in
            let tokens = SyntaxLexer.spans(text,language:language)
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == id,self.editor.string == text,!self.editor.hasMarkedText(),
                      let layout = self.editor.layoutManager else { return }
                let range = NSRange(location:0,length:text.utf16.count)
                let dark = self.editor.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua
                layout.removeTemporaryAttribute(.foregroundColor,forCharacterRange:range)
                for token in tokens {
                    layout.addTemporaryAttribute(.foregroundColor,value:SyntaxStyle.color(token.kind,dark:dark),forCharacterRange:token.range)
                }
                self.editor.needsDisplay = true;self.ruler.needsDisplay = true
            }
        }
        pending = work
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.12,execute:work)
    }
}

final class CodeReaderManager: ObservableObject {
    static let shared = CodeReaderManager()
    let recent: RecentCodeFiles
    private let documents: NSDocumentController
    @Published var lastError = ""

    init(defaults: UserDefaults = .standard, documents: NSDocumentController = .shared) {
        recent = RecentCodeFiles(defaults:defaults);self.documents = documents
    }
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true;panel.canChooseDirectories = false;panel.allowsMultipleSelection = false
        panel.prompt = "打开代码";panel.message = "代码将在独立窗口中打开，支持行号、高亮与 ⌘S 保存。"
        panel.begin { [weak self] response in
            guard response == .OK,let url = panel.url else { return }
            _ = self?.open(url)
        }
    }
    @discardableResult
    func open(_ input: URL) -> Bool {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = documents.documents.first(where:{ $0 is CodeReaderDocument && $0.fileURL == url }) {
            existing.showWindows();recent.record(url);return true
        }
        do {
            let snapshot = try CodeFileSnapshot.read(url)
            let document = CodeReaderDocument(url:url,snapshot:snapshot)
            documents.addDocument(document)
            document.makeWindowControllers();document.showWindows()
            recent.record(url);lastError = ""
            return true
        } catch {
            lastError = error.localizedDescription
            let alert = NSAlert();alert.messageText = "无法打开 \(url.lastPathComponent)"
            alert.informativeText = lastError;alert.runModal()
            return false
        }
    }
}

final class DevKitAppDelegate: NSObject, NSApplicationDelegate {
    private var launchTime = Date()
    private var pendingLaunchFileOpen = false
    private var hiddenMainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchTime = Date()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let success = filenames.map { CodeReaderManager.shared.open(URL(fileURLWithPath:$0)) }.allSatisfy { $0 }
        sender.reply(toOpenOrPrint:success ? .success : .failure)
        noteLaunchFileOpen()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.filter(\.isFileURL).forEach { _ = CodeReaderManager.shared.open($0) }
        noteLaunchFileOpen()
    }
    /// 从 Finder 打开文件时，SwiftUI 的 WindowGroup 也会照常创建主窗口，
    /// 于是读者窗口旁边多出一个没人用的主窗口。启动瞬间的文件打开请求记为
    /// 「启动即打开文件」，等窗口都建好后再把主窗口收起来。
    private func noteLaunchFileOpen() {
        guard Date().timeIntervalSince(launchTime) < 3 else { return }
        pendingLaunchFileOpen = true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.45) { [weak self] in
            guard let self, self.pendingLaunchFileOpen else { return }
            self.pendingLaunchFileOpen = false
            self.hideLaunchMainWindow()
        }
    }
    private func hideLaunchMainWindow() {
        guard let window = NSApp.windows.first(where:{ $0.title == "DevKit · 开发工具箱" }) else { return }
        window.orderOut(nil)
        hiddenMainWindow = window
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let window = hiddenMainWindow ?? NSApp.windows.first(where:{ $0.title == "DevKit · 开发工具箱" }) {
            hiddenMainWindow = nil
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = NSDocumentController.shared.documents.compactMap { $0 as? CodeReaderDocument }.filter(\.isDocumentEdited)
        guard !dirty.isEmpty else { return .terminateNow }
        closeForQuit(dirty,index:0)
        return .terminateLater
    }
    private func closeForQuit(_ documents: [CodeReaderDocument], index: Int) {
        guard index < documents.count else { NSApp.reply(toApplicationShouldTerminate:true);return }
        guard let controller = documents[index].windowControllers.first as? CodeReaderWindowController else {
            NSApp.reply(toApplicationShouldTerminate:false);return
        }
        controller.requestClose { [weak self] approved in
            if approved { self?.closeForQuit(documents,index:index+1) }
            else { NSApp.reply(toApplicationShouldTerminate:false) }
        }
    }
}

struct CodeReaderPage: View {
    @ObservedObject var manager: CodeReaderManager
    @ObservedObject var recent: RecentCodeFiles
    @ObservedObject private var opener = CodeDefaultOpener.shared
    init(manager: CodeReaderManager) { self.manager = manager;recent = manager.recent }
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            Button(action:manager.chooseFile) { Label("打开代码文件",systemImage:"folder") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityLabel("打开代码文件")
            VStack(alignment:.leading,spacing:10) {
                VStack(alignment:.leading,spacing:3) {
                    Text("常用代码格式默认用 DevKit 打开").font(.system(size:13,weight:.medium))
                    Text("逐个开启，关闭即恢复原来的应用；系统会为每一项弹出确认。不含 .txt")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:16),count:3),spacing:9) {
                    ForEach(CodeDefaultOpener.extensions,id:\.self) { ext in
                        HStack(spacing:8) {
                            Text(".\(ext)").font(.system(size:12,design:.monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength:0)
                            Toggle("",isOn:Binding(get:{opener.isEnabled(ext)},set:{opener.setEnabled($0,for:ext)}))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                .disabled(opener.isPending(ext))
                                .accessibilityLabel("用 DevKit 打开 .\(ext) 文件")
                        }
                    }
                }
                Text(CodeDefaultOpener.tsNote).font(.system(size:11)).foregroundStyle(.tertiary)
                if !opener.message.isEmpty {
                    Text(opener.message).font(.system(size:11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
            .padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            if !recent.urls.isEmpty {
                Text("最近打开").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                VStack(spacing:0) {
                    ForEach(recent.urls,id:\.path) { url in
                        Button { manager.open(url) } label: {
                            HStack(spacing:12) {
                                Image(systemName:"doc.text").foregroundStyle(.teal)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(url.lastPathComponent).font(.system(size:14,weight:.medium))
                                    Text(url.deletingLastPathComponent().path).font(.system(size:11)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName:"arrow.up.right").font(.system(size:11)).foregroundStyle(.tertiary)
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("打开 \(url.lastPathComponent)")
                        if url != recent.urls.last { Divider() }
                    }
                }.background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            }
            Spacer()
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .onAppear { opener.refresh() }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in opener.refresh() }
        .onReceive(Timer.publish(every:2,on:.main,in:.common).autoconnect()) { _ in opener.refresh() }
    }
}
