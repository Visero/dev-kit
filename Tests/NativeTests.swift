import AppKit
import SwiftUI

@main
struct NativeTests {
    static var passed=0
    static func check(_ name:String,_ condition:Bool) {
        guard condition else { print("FAIL: \(name)");exit(1) }
        passed+=1
    }
    static func waitForHighlight() {
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
    }
    static func main() {
        _=NSApplication.shared
        let source="let value = \"汉字👩🏽‍💻\" // note\nprint(42)"
        let view=HighlightTextView(frame:NSRect(x:0,y:0,width:600,height:240))
        view.isRichText=false;view.allowsUndo=true;view.string=source
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        view.setSelectedRange(NSRange(location:4,length:5))
        let originalStorage=NSAttributedString(attributedString:view.textStorage!)
        let coordinator=CodeEditor.Coordinator(CodeEditor(text:.constant(source),label:"Test",language:.swift))
        coordinator.schedule(view);waitForHighlight()
        check("highlight does not change text",view.string==source)
        check("highlight does not move selection",view.selectedRange()==NSRange(location:4,length:5))
        check("highlight does not add undo actions",view.undoManager?.canUndo != true)
        let layout=view.layoutManager!
        for token in SyntaxLexer.spans(source,language:.swift) {
            check("layout temporary color",layout.temporaryAttribute(.foregroundColor,atCharacterIndex:token.range.location,effectiveRange:nil) is NSColor)
        }
        check("no syntax colors stored",(0..<originalStorage.length).allSatisfy { index in
            let before=originalStorage.attribute(.foregroundColor,at:index,effectiveRange:nil) as? NSColor
            let after=view.textStorage!.attribute(.foregroundColor,at:index,effectiveRange:nil) as? NSColor
            return before == after
        })
        // Cancelled work must not overwrite the most recent input's display.
        coordinator.schedule(view)
        let updated="const next = 7"
        view.string=updated
        coordinator.parent=CodeEditor(text:.constant(updated),label:"Test",language:.javascript)
        coordinator.schedule(view);waitForHighlight()
        check("latest input wins",view.string==updated)
        check("latest color applied",layout.temporaryAttribute(.foregroundColor,atCharacterIndex:13,effectiveRange:nil) is NSColor)
        coordinator.parent=CodeEditor(text:.constant(updated),label:"Test",language:.plain)
        coordinator.schedule(view);waitForHighlight()
        check("plain mode removes highlight",layout.temporaryAttribute(.foregroundColor,atCharacterIndex:0,effectiveRange:nil)==nil)
        func luminance(_ color:NSColor) -> Double {
            let c=color.usingColorSpace(.sRGB)!
            func linear(_ value:CGFloat)->Double { let v=Double(value);return v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        for dark in [false,true] {
            let appearance=NSAppearance(named:dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                let bg=luminance(.textBackgroundColor)
                for kind in [SyntaxKind.keyword,.string,.comment,.number,.literal,.type,.function,.key] {
                    let fg=luminance(SyntaxStyle.color(kind,dark:dark)),contrast=(max(bg,fg)+0.05)/(min(bg,fg)+0.05)
                    check("readable \(kind) \(dark ? "dark" : "light")",contrast>=4.5)
                    let attributed=SyntaxStyle.attributed(source,spans:SyntaxLexer.spans(source,language:.swift),dark:dark)
                    check("attributed source preserved",attributed.string==source)
                    let bridge=SyntaxStyle.swiftUIAttributed(source,spans:SyntaxLexer.spans(source,language:.swift),dark:dark)
                    check("SwiftUI color bridge",bridge.runs.contains{$0.foregroundColor != nil})
                }
            }
        }
        for screen in NSScreen.screens {
            let v=screen.visibleFrame,size=WindowSizing.fitted(availableWidth:v.width,availableHeight:v.height)
            check("window fits visible screen",size.width<v.width && size.height<v.height)
            print("Screen \(screen.localizedName): visible \(Int(v.width))x\(Int(v.height)); default \(Int(size.width))x\(Int(size.height))")
        }
        let windows=CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
        for info in windows where info[kCGWindowOwnerName as String] as? String == "DevKit Preview" {
            if let bounds=info[kCGWindowBounds as String] { print("Preview actual window bounds: \(bounds)") }
        }
        print("PASS: \(passed) native assertions")
    }
}
