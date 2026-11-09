import AppKit

/// Minimal Vim-style state for the standalone editor window.
/// Insert mode passes every keystroke through to AppKit; normal mode consumes a
/// small, deliberate command set so typing cannot modify the buffer by accident.
final class VimState {
    enum Mode {
        case normal, insert
        var label: String {
            switch self {
            case .normal: return "NORMAL"
            case .insert: return "INSERT"
            }
        }
    }
    private(set) var mode: Mode = .insert
    var pending: Character?
    var yanked = ""
    var onModeChange: ((Mode) -> Void)?

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        onModeChange?(mode)
    }
    func reset(_ mode: Mode) { pending = nil; setMode(mode) }
}

extension HighlightTextView {
    /// Consumes the event when normal mode owns it; returns false for pass-through.
    func handleVimKey(_ event: NSEvent) -> Bool {
        guard vimEnabled else { return false }
        // Leave menu/service shortcuts (⌘S, ⌘F, ⌃…) to AppKit.
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if event.keyCode == 53 { // Esc leaves insert mode.
            if vim.mode == .insert { vim.setMode(.normal); moveLeft(nil) }
            return true
        }
        guard vim.mode == .normal else { return false }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let key = characters.first else { return true }

        if let pending = vim.pending {
            vim.pending = nil
            switch (pending, key) {
            case ("d", "d"): deleteCurrentLine()
            case ("y", "y"): yankCurrentLine()
            case ("g", "g"): moveToBeginningOfDocument(nil)
            default: NSSound.beep()
            }
            return true
        }

        switch key {
        case "h": moveLeft(nil)
        case "j": moveDown(nil)
        case "k": moveUp(nil)
        case "l": moveRight(nil)
        case "i": vim.setMode(.insert)
        case "a": moveRight(nil); vim.setMode(.insert)
        case "I": moveToBeginningOfParagraph(nil); vim.setMode(.insert)
        case "A": moveToEndOfParagraph(nil); vim.setMode(.insert)
        case "o":
            moveToEndOfParagraph(nil)
            insertText("\n", replacementRange: selectedRange())
            vim.setMode(.insert)
        case "O":
            moveToBeginningOfParagraph(nil)
            insertText("\n", replacementRange: selectedRange())
            moveUp(nil); moveToEndOfParagraph(nil)
            vim.setMode(.insert)
        case "x": deleteForward(nil)
        case "u": undoManager?.undo()
        case "p":
            if !vim.yanked.isEmpty { insertText(vim.yanked, replacementRange: selectedRange()) }
        case "0": moveToBeginningOfParagraph(nil)
        case "$": moveToEndOfParagraph(nil)
        case "w": moveWordForward(nil)
        case "b": moveWordBackward(nil)
        case "G": moveToEndOfDocument(nil)
        case "d", "y", "g": vim.pending = key
        default: NSSound.beep()
        }
        return true
    }

    private func lineRangeAtCaret() -> NSRange {
        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        return text.lineRange(for: NSRange(location: caret, length: 0))
    }
    private func deleteCurrentLine() {
        insertText("", replacementRange: lineRangeAtCaret())
    }
    private func yankCurrentLine() {
        vim.yanked = (string as NSString).substring(with: lineRangeAtCaret())
    }
}
