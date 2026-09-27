import AppKit
import SwiftUI

/// Observe presses before SwiftUI waits for a double click or opens a contextual menu.
/// One monitor serves the browser; weak targets follow lazy cell reuse and scrolling.
@MainActor
final class BrowserMouseInteraction {
    private let targets = NSHashTable<BrowserMouseTargetView>.weakObjects()

    func register(_ target: BrowserMouseTargetView) {
        targets.add(target)
    }

    func item(at event: NSEvent, in container: NSView) -> String? {
        // With clipsToBounds disabled, visibleRect can extend beyond the view's bounds.
        guard let window = container.window, event.window === window,
              window.attachedSheet == nil, !container.isHiddenOrHasHiddenAncestor,
              container.bounds.intersection(container.visibleRect).contains(
                container.convert(event.locationInWindow, from: nil))
        else { return nil }

        let visibleTargets = targets.allObjects.filter { target in
            guard target.window === window else { return false }
            let region = target.selectionRegion
            return !region.isHiddenOrHasHiddenAncestor
                && region.bounds.intersection(region.visibleRect).contains(
                    region.convert(event.locationInWindow, from: nil))
        }
        // The checkbox owns its primary press. Selecting the row here would discard
        // the other selected items before the toggle updates its binding.
        if let control = visibleTargets.first(where: \.isSelectionControl) {
            return event.type == .leftMouseDown && !event.modifierFlags.contains(.control)
                ? nil : control.itemID
        }
        return visibleTargets.first?.itemID
    }
}

struct BrowserMouseTarget: NSViewRepresentable {
    let id: String
    let usesTableRow: Bool
    let interaction: BrowserMouseInteraction
    var isSelectionControl = false

    func makeNSView(context: Context) -> BrowserMouseTargetView {
        let view = BrowserMouseTargetView()
        interaction.register(view)
        return view
    }

    func updateNSView(_ view: BrowserMouseTargetView, context: Context) {
        view.itemID = id
        view.usesTableRow = usesTableRow
        view.isSelectionControl = isSelectionControl
    }
}

final class BrowserMouseTargetView: NSView {
    var itemID = ""
    var usesTableRow = false
    var isSelectionControl = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var selectionRegion: NSView {
        if usesTableRow {
            var ancestor = superview
            while let view = ancestor {
                if view is NSTableRowView { return view }
                ancestor = view.superview
            }
        }
        return self
    }
}

struct BrowserMouseMonitor: NSViewRepresentable {
    let interaction: BrowserMouseInteraction
    let onMouseDown: (String, NSEvent) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> BrowserMouseMonitorView {
        BrowserMouseMonitorView()
    }

    func updateNSView(_ view: BrowserMouseMonitorView, context: Context) {
        view.interaction = interaction
        view.isEnabled = isEnabled
        view.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: BrowserMouseMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class BrowserMouseMonitorView: NSView {
    var interaction: BrowserMouseInteraction?
    var isEnabled = true
    var onMouseDown: ((String, NSEvent) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Local AppKit event monitors run synchronously on the main thread.
            MainActor.assumeIsolated {
                self?.handleMouseDown(event)
            }
            return event // Keep native double click, focus, selection and menu handling intact.
        }
    }

    func handleMouseDown(_ event: NSEvent) {
        guard isEnabled, let id = interaction?.item(at: event, in: self) else { return }
        onMouseDown?(id, event)
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
