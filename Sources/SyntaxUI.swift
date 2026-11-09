import AppKit
import SwiftUI

enum SyntaxStyle {
    static func color(_ kind:SyntaxKind,dark:Bool) -> NSColor {
        let rgb:(CGFloat,CGFloat,CGFloat)
        switch kind {
        case .keyword: rgb=dark ? (0.92,0.53,0.65) : (0.65,0.17,0.34)
        case .string: rgb=dark ? (0.69,0.83,0.56) : (0.24,0.43,0.12)
        case .comment: rgb=dark ? (0.58,0.64,0.66) : (0.42,0.46,0.49)
        case .number: rgb=dark ? (0.92,0.73,0.43) : (0.62,0.36,0.05)
        case .literal: rgb=dark ? (0.94,0.62,0.39) : (0.65,0.30,0.07)
        case .type: rgb=dark ? (0.49,0.81,0.88) : (0.04,0.43,0.50)
        case .function: rgb=dark ? (0.50,0.72,0.97) : (0.15,0.38,0.69)
        case .key: rgb=dark ? (0.53,0.78,0.96) : (0.10,0.40,0.66)
        }
        return NSColor(srgbRed:rgb.0,green:rgb.1,blue:rgb.2,alpha:1)
    }
    static func swiftUIAttributed(_ text:String,spans:[SyntaxSpan],dark:Bool) -> AttributedString {
        var output=AttributedString(text)
        output.font = .system(size:13,design:.monospaced)
        for token in spans {
            guard let range=Range(token.range,in:text),
                  let lower=AttributedString.Index(range.lowerBound,within:output),
                  let upper=AttributedString.Index(range.upperBound,within:output) else { continue }
            output[lower..<upper].foregroundColor=Color(nsColor:color(token.kind,dark:dark))
        }
        return output
    }
    static func attributed(_ text:String,spans:[SyntaxSpan],dark:Bool,fontSize:CGFloat=13) -> NSAttributedString {
        let output=NSMutableAttributedString(string:text,attributes:[.font:NSFont.monospacedSystemFont(ofSize:fontSize,weight:.regular),.foregroundColor:NSColor.labelColor])
        for token in spans where NSMaxRange(token.range)<=output.length {
            output.addAttribute(.foregroundColor,value:color(token.kind,dark:dark),range:token.range)
        }
        return output
    }
}
final class HighlightTextView: NSTextView {
    var themeChanged:(()->Void)?
    /// Vim state only runs when the standalone editor window enables it.
    let vim=VimState()
    var vimEnabled=false {
        didSet { vim.reset(vimEnabled ? .normal : .insert) }
    }
    override func keyDown(with event: NSEvent) {
        if handleVimKey(event) { return }
        super.keyDown(with: event)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();themeChanged?() }
}
struct HighlightedCode: View {
    let text:String
    let spans:[SyntaxSpan]
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        Text(SyntaxStyle.swiftUIAttributed(text,spans:spans,dark:scheme == .dark))
            .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
    }
}

/// A one-time resize migration makes the new default effective for existing installs.
/// Later launches keep the user's manually resized window. No defaults are deleted.
struct WindowSizeMigration: NSViewRepresentable {
    func makeNSView(context:Context) -> NSView { ResizeProbe() }
    func updateNSView(_ view:NSView,context:Context) {}
    final class ResizeProbe:NSView {
        private var scheduled=false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !scheduled,window != nil else { return }
            scheduled=true
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
                guard let window=self?.window else { return }
                let key="DevKit.windowSizeMigration.1.2.0"
                guard !UserDefaults.standard.bool(forKey:key), !window.styleMask.contains(.fullScreen) else { return }
                guard let screen=window.screen ?? NSScreen.main else { return }
                let visible=screen.visibleFrame
                let size=WindowSizing.fitted(availableWidth:visible.width,availableHeight:visible.height)
                // Hidden-titlebar windows occupy the content size plus a small frame border.
                var frame=window.frameRect(forContentRect:NSRect(x:0,y:0,width:size.width,height:size.height))
                frame.size.width=min(frame.width,visible.width-16)
                frame.size.height=min(frame.height,visible.height-16)
                frame.origin=NSPoint(x:visible.midX-frame.width/2,y:visible.midY-frame.height/2)
                window.setFrame(frame,display:true,animate:false)
                UserDefaults.standard.set(true,forKey:key)
            }
        }
    }
}
