import AppKit
import SwiftUI

/// A text field that reports Tab, Up, Down and Escape so a suggestion list can handle them.
/// Each handler returns false to keep the field's normal behaviour (for example Tab moving focus).
struct CompletingTextField: NSViewRepresentable {
    enum Key { case tab, up, down, escape }

    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard field.stringValue != text else { return }
        field.stringValue = text
        // Keep typing at the end after a suggestion replaces the text.
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompletingTextField

        init(_ parent: CompletingTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): parent.onKey(.tab)
            case #selector(NSResponder.moveUp(_:)): parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onKey(.down)
            case #selector(NSResponder.cancelOperation(_:)): parent.onKey(.escape)
            default: false
            }
        }
    }
}
