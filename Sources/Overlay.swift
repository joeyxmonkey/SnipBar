import AppKit
import ScreenCaptureKit
import SwiftUI

enum CaptureMode: CaseIterable {
    case rectangle, freeform, window, fullScreen

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .freeform: "Freeform"
        case .window: "Window"
        case .fullScreen: "Full Screen"
        }
    }

    var icon: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .freeform: "lasso"
        case .window: "macwindow"
        case .fullScreen: "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum Selection {
    case image(CGImage)
    case window(SCWindow, scale: CGFloat)
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Overlay: ObservableObject {
    @Published private(set) var mode: CaptureMode = .rectangle
    private var panels: [OverlayPanel] = []
    private var surfaces: [SelectionView] = []
    private let finish: (Selection?) -> Void

    init(snapshots: [DisplaySnapshot], windows: [SelectableWindow], finish: @escaping (Selection?) -> Void) {
        self.finish = finish
        let cursor = NSEvent.mouseLocation
        let active = snapshots.first { $0.screen.frame.contains(cursor) } ?? snapshots[0]
        for snapshot in snapshots {
            let panel = OverlayPanel(contentRect: snapshot.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.setFrame(snapshot.screen.frame, display: false)

            let surface = SelectionView(snapshot: snapshot, windows: windows)
            surface.pick = { [weak self] selection in self?.finish(selection) }
            surface.cancel = { [weak self] in self?.finish(nil) }
            panel.contentView = surface
            panels.append(panel)
            surfaces.append(surface)

            if snapshot.screen.captureDisplayID == active.screen.captureDisplayID {
                let toolbar = NSHostingView(rootView: SnipToolbar(mode: self, pick: { [weak self] mode in
                    self?.select(mode, snapshot: snapshot)
                }, cancel: { [weak self] in self?.finish(nil) }))
                toolbar.translatesAutoresizingMaskIntoConstraints = false
                surface.addSubview(toolbar)
                surface.toolbar = toolbar
                NSLayoutConstraint.activate([
                    toolbar.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
                    toolbar.topAnchor.constraint(equalTo: surface.topAnchor, constant: 32)
                ])
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(surface)
                surface.layoutSubtreeIfNeeded()
                surface.refreshCursor()
            } else {
                panel.orderFrontRegardless()
            }
        }
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        surfaces.forEach { $0.discardCursorRects() }
        NSCursor.arrow.set()
        panels.removeAll()
        surfaces.removeAll()
    }

    private func select(_ mode: CaptureMode, snapshot: DisplaySnapshot) {
        if mode == .fullScreen {
            finish(.image(snapshot.image))
        } else {
            self.mode = mode
            for surface in surfaces {
                surface.mode = mode
                if let window = surface.window, window.frame.contains(NSEvent.mouseLocation) {
                    surface.refreshCursor()
                }
            }
        }
    }
}

private struct SnipToolbar: View {
    @ObservedObject var mode: Overlay
    let pick: (CaptureMode) -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases, id: \.self) { item in
                Button {
                    pick(item)
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 34)
                        .background {
                            if mode.mode == item {
                                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.23))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .help(item.title)
            }

            Divider().frame(height: 21).padding(.horizontal, 2)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 33, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            .help("Cancel (Esc)")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.16)))
        .shadow(color: .black.opacity(0.32), radius: 12, y: 3)
        .padding(12)
    }
}

private final class SelectionView: NSView {
    let snapshot: DisplaySnapshot
    let windows: [SelectableWindow]
    private let background: NSImage
    private var start: CGPoint?
    private var current: CGPoint?
    private var outline: [CGPoint] = []
    private var hovered: SelectableWindow?

    weak var toolbar: NSView?
    var pick: ((Selection) -> Void)?
    var cancel: (() -> Void)?
    var mode: CaptureMode = .rectangle {
        didSet {
            start = nil
            current = nil
            outline = []
            hovered = mode == .window ? windowAt(localMouse) : nil
            needsDisplay = true
        }
    }

    init(snapshot: DisplaySnapshot, windows: [SelectableWindow]) {
        self.snapshot = snapshot
        self.windows = windows
        background = NSImage(cgImage: snapshot.image, size: snapshot.size)
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        setAccessibilityLabel("Screenshot selection area")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved,
            .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSnapshot()
        NSColor.black.withAlphaComponent(0.46).setFill()
        dirtyRect.fill()

        let path: NSBezierPath
        switch mode {
        case .window:
            guard let hovered else { return }
            path = NSBezierPath(rect: localRect(hovered.bounds).intersection(bounds))
        case .freeform:
            guard let first = outline.first, outline.count > 1 else { return }
            path = NSBezierPath()
            path.move(to: first)
            outline.dropFirst().forEach { path.line(to: $0) }
            path.close()
            path.windingRule = .evenOdd
        case .rectangle, .fullScreen:
            guard let start, let current else { return }
            path = NSBezierPath(rect: rectangle(from: start, to: current))
        }

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawSnapshot()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawSnapshot() {
        background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { cancel?() }

    func refreshCursor() {
        if start == nil, let toolbar, toolbar.frame.contains(localMouse) {
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { refreshCursor() }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = point(for: event)
        if mode == .window {
            hovered = windowAt(point)
        } else {
            start = point
            current = point
            outline = mode == .freeform ? [point] : []
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard start != nil else { return }
        NSCursor.crosshair.set()
        let point = point(for: event)
        current = point
        if mode == .freeform { outline.append(point) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = point(for: event)
        if mode == .window {
            if let selected = windowAt(end) {
                pick?(.window(selected.window, scale: snapshot.pixelScale.width))
            }
            return
        }

        guard let start else { return }
        let selection: CGRect
        if mode == .freeform {
            if outline.last != end { outline.append(end) }
            let path = CGMutablePath()
            path.addLines(between: outline)
            selection = path.boundingBox
        } else {
            selection = rectangle(from: start, to: end)
        }
        if selection.width >= 2, selection.height >= 2,
           let image = snapshot.crop(selection, outline: outline) {
            pick?(.image(image))
        } else {
            self.start = nil
            current = nil
            outline = []
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        refreshCursor()
        guard mode == .window else { return }
        hovered = windowAt(point(for: event))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    private var localMouse: CGPoint {
        convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private var displayOrigin: CGPoint {
        if let id = snapshot.screen.captureDisplayID { return CGDisplayBounds(id).origin }
        return .zero
    }

    private func windowAt(_ point: CGPoint) -> SelectableWindow? {
        let global = CGPoint(x: displayOrigin.x + point.x, y: displayOrigin.y + point.y)
        return windows.first { $0.bounds.contains(global) }
    }

    private func localRect(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
    }

    private func rectangle(from first: CGPoint, to second: CGPoint) -> CGRect {
        CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
               width: abs(second.x - first.x), height: abs(second.y - first.y))
    }
}
