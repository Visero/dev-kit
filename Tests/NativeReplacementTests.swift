import AppKit
import Foundation

@main
struct NativeReplacementTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    /// Performs the exact Coordinator.performReplacement sequence.
    static func replace(_ view: NSTextView, _ newText: String) {
        let range = NSRange(location: 0, length: (view.string as NSString).length)
        _ = view.shouldChangeText(in: range, replacementString: newText)
        view.replaceCharacters(in: range, with: newText)
        view.didChangeText()
    }

    static func main() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)

        guard let view = scrollView.documentView as? NSTextView else {
            print("FAIL: no text view"); exit(1)
        }
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.isRichText = false
        view.string = "original text"
        view.undoManager?.removeAllActions()

        // 1. First replacement registers a single undoable action.
        replace(view, "formatted v1")
        check("replacement applied", view.string == "formatted v1")
        check("undo can undo", view.undoManager?.canUndo == true)

        // 2. Undo restores original.
        view.undoManager?.undo()
        check("undo restores original", view.string == "original text")

        // 3. Redo restores formatted v1.
        view.undoManager?.redo()
        check("redo restores v1", view.string == "formatted v1")

        // 4. Second replacement (after first) creates its own undo action.
        replace(view, "formatted v2")
        check("second replacement applied", view.string == "formatted v2")
        view.undoManager?.undo()
        check("second undo restores v1", view.string == "formatted v1")

        // 5. Undo again goes back to original.
        view.undoManager?.undo()
        check("full undo restores original", view.string == "original text")

        // 6. Empty replacement (clear) also undoable.
        replace(view, "")
        check("clear applied", view.string == "")
        check("clear undoable", view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        check("clear undo restores", view.string == "original text")

        print("PASS: \(passed) native replacement/undo assertions")
    }
}
