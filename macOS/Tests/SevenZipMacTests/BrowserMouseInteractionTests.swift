import AppKit
import Testing

@testable import SevenZipMac

@MainActor
private struct MouseFixture {
    let window: NSWindow
    let monitor: BrowserMouseMonitorView
    let target: BrowserMouseTargetView
    let interaction = BrowserMouseInteraction()

    init() {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        monitor = BrowserMouseMonitorView(frame: content.bounds)
        monitor.interaction = interaction
        content.addSubview(monitor)
        target = BrowserMouseTargetView(frame: NSRect(x: 20, y: 40, width: 100, height: 80))
        target.itemID = "file.txt"
        content.addSubview(target)
        interaction.register(target)
    }

    func event(
        _ type: NSEvent.EventType = .leftMouseDown,
        at point: NSPoint = NSPoint(x: 50, y: 60),
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    }

    func cleanup() {
        monitor.stopMonitoring()
        window.close()
    }
}

@Test @MainActor func browserSelectionReceivesMouseDownSynchronously() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    var received: [(String, NSEvent.EventType, NSEvent.ModifierFlags)] = []
    fixture.monitor.onMouseDown = { received.append(($0, $1.type, $1.modifierFlags)) }
    fixture.monitor.handleMouseDown(try fixture.event(modifiers: [.command]))
    #expect(received.count == 1) // No mouse-up or double-click timeout is needed.
    #expect(received.first?.0 == "file.txt")
    #expect(received.first?.1 == .leftMouseDown)
    #expect(received.first?.2 == .command)
    fixture.monitor.handleMouseDown(try fixture.event(.rightMouseDown))
    fixture.monitor.handleMouseDown(try fixture.event(modifiers: [.control]))
    #expect(received.count == 3)
    #expect(received[1].1 == .rightMouseDown)
    #expect(received[2].2 == .control)
}

@Test @MainActor func browserMouseTargetsRespectVisibilityAndInteractionState() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    var calls = 0
    fixture.monitor.onMouseDown = { _, _ in calls += 1 }
    fixture.monitor.handleMouseDown(try fixture.event(at: NSPoint(x: 200, y: 200)))
    #expect(calls == 0, "empty space")
    fixture.monitor.isEnabled = false
    fixture.monitor.handleMouseDown(try fixture.event())
    #expect(calls == 0, "disabled")
    fixture.monitor.isEnabled = true
    fixture.target.isHidden = true
    fixture.monitor.handleMouseDown(try fixture.event())
    #expect(calls == 0, "hidden")
    fixture.target.isHidden = false
    fixture.monitor.frame = NSRect(x: 200, y: 200, width: 100, height: 100)
    fixture.monitor.handleMouseDown(try fixture.event())
    #expect(calls == 0)
}

@Test @MainActor func browserContextSelectionUsesTheWholeNativeRow() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    let row = NSTableRowView(frame: NSRect(x: 0, y: 40, width: 400, height: 80))
    fixture.window.contentView?.addSubview(row)
    row.addSubview(fixture.target)
    fixture.target.frame = NSRect(x: 20, y: 0, width: 100, height: 80)
    fixture.target.usesTableRow = true
    #expect(fixture.interaction.item(
        at: try fixture.event(.rightMouseDown, at: NSPoint(x: 350, y: 60)),
        in: fixture.monitor) == "file.txt")
    #expect(fixture.target.hitTest(NSPoint(x: 50, y: 20)) == nil)
    #expect(fixture.monitor.hitTest(NSPoint(x: 50, y: 60)) == nil)
}

@Test @MainActor func browserMouseTargetsIgnoreOtherWindowsAndReleasedCells() throws {
    let first = MouseFixture()
    let second = MouseFixture()
    defer { first.cleanup(); second.cleanup() }
    #expect(first.interaction.item(at: try second.event(), in: first.monitor) == nil)
    first.target.removeFromSuperview()
    #expect(first.interaction.item(at: try first.event(), in: first.monitor) == nil)
}

@Test @MainActor func checkboxPressBypassesRowSelectionButKeepsContextSelection() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    let checkbox = BrowserMouseTargetView(frame: NSRect(x: 40, y: 50, width: 20, height: 20))
    checkbox.itemID = fixture.target.itemID
    checkbox.isSelectionControl = true
    fixture.window.contentView?.addSubview(checkbox)
    fixture.interaction.register(checkbox)

    #expect(fixture.interaction.item(at: try fixture.event(), in: fixture.monitor) == nil)
    #expect(fixture.interaction.item(
        at: try fixture.event(modifiers: [.command]), in: fixture.monitor) == nil)
    #expect(fixture.interaction.item(
        at: try fixture.event(.rightMouseDown), in: fixture.monitor) == "file.txt")
    #expect(fixture.interaction.item(
        at: try fixture.event(modifiers: [.control]), in: fixture.monitor) == "file.txt")
    #expect(fixture.interaction.item(
        at: try fixture.event(at: NSPoint(x: 90, y: 60)), in: fixture.monitor) == "file.txt")

    checkbox.removeFromSuperview()
    #expect(fixture.interaction.item(at: try fixture.event(), in: fixture.monitor) == "file.txt")
}

@Test @MainActor func dragSelectsMultipleItemsAndShrinksInBothDirections() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    let second = BrowserMouseTargetView(frame: NSRect(x: 140, y: 40, width: 100, height: 80))
    second.itemID = "second.txt"
    fixture.window.contentView?.addSubview(second)
    fixture.interaction.register(second)
    var selection: Set<String> = ["old.txt"]
    fixture.monitor.readSelection = { selection }
    fixture.monitor.writeSelection = { selection = $0 }
    #expect(fixture.monitor.handleEvent(try fixture.event(at: NSPoint(x: 270, y: 150))) != nil)
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged, at: NSPoint(x: 10, y: 30))) == nil)
    #expect(selection == ["file.txt", "second.txt"])
    _ = fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged, at: NSPoint(x: 130, y: 30)))
    #expect(selection == ["second.txt"])
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseUp, at: NSPoint(x: 130, y: 30))) == nil)
    #expect(selection == ["second.txt"])
}

@Test @MainActor func marqueeHonorsCommandShiftAndCheckboxes() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    var selection: Set<String> = []
    fixture.monitor.readSelection = { selection }
    fixture.monitor.writeSelection = { selection = $0 }
    for modifiers: NSEvent.ModifierFlags in [[.command], [.shift]] {
        selection = ["file.txt", "other.txt"]
        _ = fixture.monitor.handleEvent(try fixture.event(at: NSPoint(x: 10, y: 30), modifiers: modifiers))
        _ = fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged, at: NSPoint(x: 100, y: 100)))
        #expect(selection == (modifiers == .command ? ["other.txt"] : ["file.txt", "other.txt"]))
        _ = fixture.monitor.handleEvent(try fixture.event(.leftMouseUp))
    }
    let checkbox = BrowserMouseTargetView(frame: NSRect(x: 40, y: 50, width: 20, height: 20))
    checkbox.itemID = "file.txt"
    checkbox.isSelectionControl = true
    fixture.window.contentView?.addSubview(checkbox)
    fixture.interaction.register(checkbox)
    selection = ["other.txt"]
    _ = fixture.monitor.handleEvent(try fixture.event())
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged, at: NSPoint(x: 100, y: 100))) != nil)
    #expect(selection == ["other.txt"])
}

@Test @MainActor func dragPreservesSimpleClicksAndDisabledBrowser() throws {
    let fixture = MouseFixture()
    defer { fixture.cleanup() }
    var selection: Set<String> = ["old"]
    fixture.monitor.readSelection = { selection }
    fixture.monitor.writeSelection = { selection = $0 }
    _ = fixture.monitor.handleEvent(try fixture.event())
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged, at: NSPoint(x: 51, y: 61))) != nil)
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseUp)) != nil)
    #expect(selection == ["old"])
    fixture.monitor.isEnabled = false
    _ = fixture.monitor.handleEvent(try fixture.event(at: NSPoint(x: 10, y: 30)))
    #expect(fixture.monitor.handleEvent(try fixture.event(.leftMouseDragged)) != nil)
    #expect(selection == ["old"])
}
