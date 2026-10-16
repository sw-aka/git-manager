import AppKit
import GitManagerCore
import SwiftUI

/// Own the native drag session so its preview, selection and cleanup have the
/// same lifetime. The pan recognizer lets ordinary clicks reach the List.
struct SidebarDragSource: NSViewRepresentable {
    let payload: SidebarDragPayload
    let state: SidebarDragState
    let preview: SidebarDragPreview
    var select: () -> Void = {}
    var click: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.source = self
    }

    final class DragView: NSView, NSDraggingSource {
        var source: SidebarDragSource?
        private var finishDrag: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let pan = NSPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.delaysPrimaryMouseButtonEvents = true
            addGestureRecognizer(pan)
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            click.buttonMask = 1
            // Group names toggle on click; repository clicks use native List selection.
            click.delegate = self
            addGestureRecognizer(click)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Keep context menus, tooltips and drop destinations on the SwiftUI row.
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            return super.hitTest(point)
        }

        @objc private func clicked() { source?.click?() }

        @objc private func drag(_ recognizer: NSPanGestureRecognizer) {
            guard recognizer.state == .began, let event = NSApp.currentEvent,
                  let source else { return }
            let renderer = ImageRenderer(content: source.preview)
            renderer.scale = window?.backingScaleFactor ?? 2
            guard let image = renderer.nsImage else { return }
            let id = source.state.begin(source.payload)
            finishDrag = { source.state.end(id) }
            source.select()

            let item = NSDraggingItem(pasteboardWriter: source.payload.string as NSString)
            let point = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 20, y: point.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
                .animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDrag?()
            finishDrag = nil
        }
    }
}

extension SidebarDragSource.DragView: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        !(gestureRecognizer is NSClickGestureRecognizer) || source?.click != nil
    }
}

struct SidebarDragPreview: View {
    let name: String
    var detail: String? = nil
    let symbol: String
    let colorScheme: ColorScheme

    // Drag previews render outside the sidebar's environment. Resolve both
    // foreground and background from the source row's appearance explicitly.
    private var foreground: Color { colorScheme == .dark ? .white : .black }
    private var background: Color { Color(white: colorScheme == .dark ? 0.18 : 0.97) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(name).fontWeight(.semibold)
            if let detail { Text(detail).font(.caption).foregroundStyle(foreground.opacity(0.75)) }
        }
        .font(.body)
        .foregroundStyle(foreground)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(foreground.opacity(0.18), lineWidth: 1)
        }
        .environment(\.colorScheme, colorScheme)
    }
}
