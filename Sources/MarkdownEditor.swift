import AppKit
import SwiftUI

struct MarkdownPaint {
    var range: NSRange
    var attributes: [NSAttributedString.Key:Any]
}
/// Display-only Markdown subset. Text is never rewritten or executed by rendering.
enum MarkdownStyler {
    static func paints(_ text:String,activeRange:NSRange,dark:Bool) -> [MarkdownPaint] {
        let source=text as NSString
        guard source.length>0 else { return [] }
        let all=NSRange(location:0,length:source.length)
        var result:[MarkdownPaint]=[], codeRanges:[NSRange]=[]
        func regex(_ pattern:String)->[NSTextCheckingResult] { (try? NSRegularExpression(pattern:pattern))?.matches(in:text,range:all) ?? [] }
        func add(_ range:NSRange,_ attributes:[NSAttributedString.Key:Any]) { if range.length>0 { result.append(MarkdownPaint(range:range,attributes:attributes)) } }
        func active(_ range:NSRange)->Bool { NSIntersectionRange(range,activeRange).length>0 }
        func marker(_ range:NSRange,line:NSRange) {
            add(range,active(line) ? [.foregroundColor:NSColor.secondaryLabelColor] : [.foregroundColor:NSColor.clear,.font:NSFont.systemFont(ofSize:0.1)])
        }
        var cursor=0, fenceStart:Int?, fenceChar:Character?, fenceCount=0, openingRange:NSRange?
        while cursor<source.length {
            let range=source.lineRange(for:NSRange(location:cursor,length:0))
            let line=source.substring(with:range),trim=line.trimmingCharacters(in:.whitespacesAndNewlines)
            let first=trim.first
            let count=first.map { c in trim.prefix(while:{$0 == c}).count } ?? 0
            if let start=fenceStart {
                if first == fenceChar && count>=fenceCount && trim.allSatisfy({$0 == fenceChar}) {
                    let block=NSRange(location:start,length:NSMaxRange(range)-start);codeRanges.append(block)
                    add(block,[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.backgroundColor:NSColor.quaternaryLabelColor.withAlphaComponent(0.12)])
                    if let opening=openingRange { marker(NSRange(location:opening.location,length:(source.substring(with:opening).trimmingCharacters(in:.newlines) as NSString).length),line:opening) }
                    marker(NSRange(location:range.location,length:(line.trimmingCharacters(in:.newlines) as NSString).length),line:range)
                    fenceStart=nil;fenceChar=nil;openingRange=nil
                }
            } else if (first == "`" || first == "~") && count>=3 { fenceStart=range.location;fenceChar=first;fenceCount=count;openingRange=range }
            cursor=NSMaxRange(range)
        }
        if let start=fenceStart {
            let block=NSRange(location:start,length:source.length-start);codeRanges.append(block)
            add(block,[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.backgroundColor:NSColor.quaternaryLabelColor.withAlphaComponent(0.12)])
        }
        func inCode(_ range:NSRange)->Bool { codeRanges.contains{NSIntersectionRange($0,range).length>0} }
        for match in regex(#"(?m)^(#{1,6})[ \t]+([^\r\n]+)"#) where !inCode(match.range) {
            let level=match.range(at:1).length
            add(match.range(at:2),[.font:NSFont.systemFont(ofSize:CGFloat(max(16,30-level*2)),weight:.bold)])
            marker(NSRange(location:match.range.location,length:match.range(at:2).location-match.range.location),line:source.lineRange(for:match.range))
        }
        for match in regex(#"(?m)^[ \t]*(?:[-+*]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#) where !inCode(match.range) {
            add(match.range,[.foregroundColor:NSColor.systemTeal,.font:NSFont.monospacedSystemFont(ofSize:14,weight:.medium)])
        }
        for match in regex(#"(?m)^>[ \t]?(.*)$"#) where !inCode(match.range) {
            add(match.range,[.foregroundColor:NSColor.secondaryLabelColor])
            add(NSRange(location:match.range.location,length:1),[.foregroundColor:NSColor.systemTeal])
        }
        let inline:[(String,NSFont?,NSAttributedString.Key?,Any?)] = [
            (#"(?<!\\)\*\*([^*\r\n]+)\*\*"#,NSFont.boldSystemFont(ofSize:15),nil,nil),
            (#"(?<!\\)__([^_\r\n]+)__"#,NSFont.boldSystemFont(ofSize:15),nil,nil),
            (#"(?<![\\*])\*([^*\r\n]+)\*(?!\*)"#,NSFontManager.shared.convert(NSFont.systemFont(ofSize:15),toHaveTrait:.italicFontMask),nil,nil),
            (#"(?<!\\)~~([^~\r\n]+)~~"#,nil,.strikethroughStyle,NSUnderlineStyle.single.rawValue)
        ]
        let inlineCode=regex(#"(?<![\\`])`([^`\r\n]+)`(?!`)"#)
        for match in inlineCode where !inCode(match.range) {
            codeRanges.append(match.range)
            add(match.range(at:1),[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.systemTeal,.backgroundColor:NSColor.quaternaryLabelColor.withAlphaComponent(0.12)])
            marker(NSRange(location:match.range.location,length:1),line:source.lineRange(for:match.range))
            marker(NSRange(location:NSMaxRange(match.range)-1,length:1),line:source.lineRange(for:match.range))
        }
        for (pattern,font,key,value) in inline {
            for match in regex(pattern) where !inCode(match.range) {
                if let font=font { add(match.range(at:1),[.font:font]) }
                if let key=key,let value=value { add(match.range(at:1),[key:value]) }
                let body=match.range(at:1),line=source.lineRange(for:match.range)
                marker(NSRange(location:match.range.location,length:body.location-match.range.location),line:line)
                marker(NSRange(location:NSMaxRange(body),length:NSMaxRange(match.range)-NSMaxRange(body)),line:line)
            }
        }
        for match in regex(#"(?<!!)\[([^\]\r\n]+)\]\(([^)\r\n]+)\)"#) where !inCode(match.range) {
            // Only visual styling: links are not auto-opened and remote assets are never fetched.
            add(match.range(at:1),[.foregroundColor:NSColor.systemTeal,.underlineStyle:NSUnderlineStyle.single.rawValue])
            let line=source.lineRange(for:match.range),body=match.range(at:1)
            marker(NSRange(location:match.range.location,length:1),line:line)
            marker(NSRange(location:NSMaxRange(body),length:NSMaxRange(match.range)-NSMaxRange(body)),line:line)
        }
        return result
    }
}
final class MarkdownTextView:NSTextView {
    var appearanceChanged:(()->Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();appearanceChanged?() }
}
struct MarkdownEditor:NSViewRepresentable {
    @Binding var text:String
    var editable=true
    var sourceMode=false
    var onReady:((Coordinator)->Void)?
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let view=MarkdownTextView(frame:NSRect(x:0,y:0,width:600,height:400))
        view.isRichText=false;view.allowsUndo=true;view.isEditable=editable;view.isSelectable=true
        view.font = .systemFont(ofSize:15);view.textColor = .labelColor;view.backgroundColor = .textBackgroundColor
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.isAutomaticTextReplacementEnabled=false;view.isAutomaticSpellingCorrectionEnabled=false
        view.isAutomaticLinkDetectionEnabled=false;view.isContinuousSpellCheckingEnabled=false
        view.textContainerInset=NSSize(width:22,height:18)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width]
        view.textContainer?.widthTracksTextView=true
        view.textContainer?.containerSize=NSSize(width:600,height:CGFloat.greatestFiniteMagnitude)
        view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.string=text;view.delegate=context.coordinator;view.setSelectedRange(NSRange(location:0,length:0))
        view.setAccessibilityLabel("Markdown 笔记正文")
        scroll.documentView=view;context.coordinator.view=view
        view.appearanceChanged={ [weak coordinator=context.coordinator] in coordinator?.schedule() }
        context.coordinator.schedule();onReady?(context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? MarkdownTextView else { return }
        let old=context.coordinator.parent;context.coordinator.parent=self
        view.isEditable=editable
        if view.string != text { view.string=text;context.coordinator.schedule() }
        if old.sourceMode != sourceMode || old.scheme != scheme { context.coordinator.schedule() }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:MarkdownEditor
        weak var view:MarkdownTextView?
        var painting=false
        var pending:DispatchWorkItem?
        init(_ parent:MarkdownEditor) { self.parent=parent }
        deinit { pending?.cancel() }
        func textDidChange(_ notification:Notification) {
            guard !painting,let view=view else { return };parent.text=view.string;schedule()
        }
        func textViewDidChangeSelection(_ notification:Notification) { if !painting { schedule() } }
        func schedule() {
            pending?.cancel()
            let work=DispatchWorkItem { [weak self] in self?.render() };pending=work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.08,execute:work)
        }
        func render() {
            guard let view=view,!view.hasMarkedText(),let storage=view.textStorage,!painting else { return }
            painting=true;defer { painting=false }
            let text=view.string,source=text as NSString,selection=view.selectedRange()
            let active=source.length>0 ? source.lineRange(for:NSRange(location:min(selection.location,source.length),length:min(selection.length,max(0,source.length-selection.location)))) : NSRange(location:0,length:0)
            let style=NSMutableParagraphStyle();style.lineSpacing=5;style.paragraphSpacing=5
            storage.beginEditing()
            storage.setAttributes([.font:parent.sourceMode ? NSFont.monospacedSystemFont(ofSize:14,weight:.regular) : NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.labelColor,.paragraphStyle:style],range:NSRange(location:0,length:storage.length))
            if !parent.sourceMode {
                for paint in MarkdownStyler.paints(text,activeRange:active,dark:parent.scheme == .dark) { storage.addAttributes(paint.attributes,range:paint.range) }
            }
            storage.endEditing()
            view.typingAttributes=[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.labelColor,.paragraphStyle:style]
            // Attribute-only edits do not enter UndoManager or change the source string.
        }
        func insert(prefix:String,suffix:String="") {
            guard let view=view,view.isEditable,!view.hasMarkedText() else { return }
            let range=view.selectedRange(),selected=(view.string as NSString).substring(with:range)
            let replacement=prefix+selected+suffix
            view.breakUndoCoalescing()
            guard view.shouldChangeText(in:range,replacementString:replacement) else { return }
            view.replaceCharacters(in:range,with:replacement);view.didChangeText()
            view.setSelectedRange(NSRange(location:range.location+prefix.utf16.count,length:selected.utf16.count))
            view.window?.makeFirstResponder(view);parent.text=view.string;schedule()
        }
    }
}
