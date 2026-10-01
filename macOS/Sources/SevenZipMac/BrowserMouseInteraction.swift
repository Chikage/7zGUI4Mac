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

    func contains(_ event: NSEvent, in container: NSView) -> Bool {
        guard let window = container.window, event.window === window,
              window.attachedSheet == nil, !container.isHiddenOrHasHiddenAncestor else { return false }
        return container.bounds.intersection(container.visibleRect).contains(
            container.convert(event.locationInWindow, from: nil))
    }

    func isSelectionControl(at event: NSEvent, in container: NSView) -> Bool {
        targets.allObjects.contains { target in
            target.isSelectionControl && target.window === container.window
                && !target.isHiddenOrHasHiddenAncestor
                && target.bounds.intersection(target.visibleRect).contains(
                    target.convert(event.locationInWindow, from: nil))
        }
    }

    func itemFrames(in container: NSView) -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for target in targets.allObjects {
            guard !target.isSelectionControl, target.window === container.window else { continue }
            let region = target.selectionRegion
            guard !region.isHiddenOrHasHiddenAncestor,
                  !region.bounds.intersection(region.visibleRect).isEmpty else { continue }
            frames[target.itemID] = container.convert(region.bounds, from: region)
        }
        return frames
    }

    func scrollView(in container: NSView) -> NSScrollView? {
        targets.allObjects.first { $0.window === container.window && !$0.isHiddenOrHasHiddenAncestor }?
            .selectionRegion.enclosingScrollView
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
    @Binding var selection: Set<String>
    let onMouseDown: (String, NSEvent) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> BrowserMouseMonitorView {
        BrowserMouseMonitorView()
    }

    func updateNSView(_ view: BrowserMouseMonitorView, context: Context) {
        view.interaction = interaction
        view.isEnabled = isEnabled
        view.onMouseDown = onMouseDown
        view.readSelection = { selection }
        view.writeSelection = { selection = $0 }
    }

    static func dismantleNSView(_ view: BrowserMouseMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class BrowserMouseMonitorView: NSView {
    var interaction: BrowserMouseInteraction?
    var isEnabled = true
    var onMouseDown: ((String, NSEvent) -> Void)?
    var readSelection: (() -> Set<String>)?
    var writeSelection: ((Set<String>) -> Void)?
    private var monitor: Any?
    private var drag: DragSelection?
    private var selectionRectangle: NSRect?
    private var scrollTimer: Timer?
    private var lastDragEvent: NSEvent?

    private struct DragSelection {
        let start: NSPoint
        let document: NSView?
        let initialSelection: Set<String>
        let modifiers: NSEvent.ModifierFlags
        var active = false
        var frames: [String: NSRect] = [:]
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            // Local AppKit event monitors run synchronously on the main thread.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleEvent(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func handleEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53, drag?.active == true {
            writeSelection?(drag?.initialSelection ?? [])
            endDrag()
            return nil
        }
        if event.type == .leftMouseUp {
            let consumed = drag?.active == true
            endDrag()
            return consumed ? nil : event
        }
        if event.type == .leftMouseDragged {
            guard drag != nil, event.window === window, isEnabled, window?.attachedSheet == nil else {
                endDrag()
                return event
            }
            lastDragEvent = event
            updateDrag(event)
            return drag?.active == true ? nil : event
        }
        guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
        endDrag()
        if event.type == .leftMouseDown, event.clickCount == 1, isEnabled,
           !event.modifierFlags.contains(.control),
           interaction?.contains(event, in: self) == true,
           interaction?.isSelectionControl(at: event, in: self) == false,
           !isNativeControl(at: event)
        {
            let document = interaction?.scrollView(in: self)?.documentView
            drag = DragSelection(
                start: (document ?? self).convert(event.locationInWindow, from: nil), document: document,
                initialSelection: readSelection?() ?? [], modifiers: event.modifierFlags)
        }
        handleMouseDown(event)
        return event // Keep native click, focus and contextual menu handling intact.
    }

    private func isNativeControl(at event: NSEvent) -> Bool {
        guard let root = window?.contentView else { return true }
        var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
        while let view = hit {
            if view is NSScroller || view is NSTableHeaderView || view is NSButton { return true }
            hit = view.superview
        }
        return false
    }

    private func updateDrag(_ event: NSEvent) {
        guard var drag else { return }
        let start = convert(drag.start, from: drag.document ?? self)
        let point = convert(event.locationInWindow, from: nil)
        guard drag.active || hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        drag.active = true
        let rectangle = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: max(1, abs(point.x - start.x)), height: max(1, abs(point.y - start.y)))
        let visible = bounds.intersection(visibleRect)
        let coordinateView = drag.document ?? self
        drag.frames.merge(interaction?.itemFrames(in: coordinateView) ?? [:]) { _, new in new }
        let documentRectangle = coordinateView.convert(rectangle, from: self)
        // Cache visited cells in document coordinates so both expansion and contraction
        // remain accurate as a lazy grid scrolls cells out of the viewport.
        let items = Set(drag.frames.compactMap { id, frame in frame.intersects(documentRectangle) ? id : nil })
        let selected: Set<String>
        if drag.modifiers.contains(.command) {
            selected = drag.initialSelection.symmetricDifference(items)
        } else if drag.modifiers.contains(.shift) {
            selected = drag.initialSelection.union(items)
        } else {
            selected = items
        }
        self.drag = drag
        writeSelection?(selected)
        selectionRectangle = rectangle.intersection(visible)
        needsDisplay = true
        if scrollTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollSelection() }
            }
            RunLoop.main.add(timer, forMode: .common)
            scrollTimer = timer
        }
    }

    private func autoscrollSelection() {
        guard isEnabled, window?.isKeyWindow == true, window?.attachedSheet == nil,
              let event = lastDragEvent, let document = drag?.document,
              let scroll = document.enclosingScrollView else { return }
        let clip = scroll.contentView
        let point = clip.convert(event.locationInWindow, from: nil)
        var origin = clip.bounds.origin
        let margin: CGFloat = 24
        let step: CGFloat = 18
        if point.y < clip.bounds.minY + margin { origin.y -= step }
        if point.y > clip.bounds.maxY - margin { origin.y += step }
        origin.y = min(max(document.bounds.minY, origin.y), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        updateDrag(event)
    }

    private func endDrag() {
        drag = nil
        lastDragEvent = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
        selectionRectangle = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selectionRectangle else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        selectionRectangle.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: selectionRectangle.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    func handleMouseDown(_ event: NSEvent) {
        guard isEnabled, let id = interaction?.item(at: event, in: self) else { return }
        onMouseDown?(id, event)
    }

    func stopMonitoring() {
        endDrag()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
