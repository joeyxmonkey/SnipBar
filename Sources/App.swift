import AppKit
import Carbon
import SwiftUI

@main
@MainActor
enum SnipBar {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var overlay: Overlay?
    private var capturing = false
    private var toast: NSPanel?
    private var toastTimer: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.menuBarVisibilityChanged = { [weak self] in self?.updateMenuBar() }
        preferences.startHotKey { [weak self] in self?.startCapture() }
        updateMenuBar()

        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !capturing { showSettings() }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        preferences.refreshLoginStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        preferences.stopHotKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        preferences.cancelRecording()
    }

    private func updateMenuBar() {
        if !preferences.showMenuBarIcon {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnipBar")
        item.button?.toolTip = "SnipBar"
        let menu = NSMenu()
        let actions: [(String, Selector, String)] = [
            ("New Snip", #selector(startCapture), ""),
            ("Settings…", #selector(showSettings), ","),
            ("Quit SnipBar", #selector(quit), "q")
        ]
        for (title, action, key) in actions {
            if action == #selector(quit) { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        preferences.refreshLoginStatus()
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, chooseFolder: { [weak self] in
                guard let self, let window = self.settingsWindow else { return }
                self.preferences.chooseFolder(relativeTo: window)
            }, requestPermission: { [weak self] in self?.checkPermissionFromSettings() },
               capture: { [weak self] in self?.startCapture() },
               quit: { [weak self] in self?.quit() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "SnipBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func checkPermissionFromSettings() {
        if ensureScreenAccess() {
            showToast("Screen recording is allowed")
        }
    }

    private func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Allow SnipBar to capture the screen"
        alert.informativeText = "Enable SnipBar in System Settings under Privacy & Security → Screen & System Audio Recording. If macOS asks you to quit and reopen SnipBar, follow that prompt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    @objc private func startCapture() {
        if overlay != nil {
            finishCapture(nil)
            return
        }
        guard !capturing, !preferences.recording else { return }
        dismissToast()
        capturing = true
        Task {
            guard ensureScreenAccess() else {
                capturing = false
                return
            }
            do {
                let (snapshots, windows) = try await Capture.prepare()
                overlay = Overlay(snapshots: snapshots, windows: windows) { [weak self] selection in
                    self?.finishCapture(selection)
                }
            } catch {
                capturing = false
                showError(error)
            }
        }
    }

    private func finishCapture(_ selection: Selection?) {
        guard overlay != nil else { return }
        overlay?.dismiss()
        overlay = nil
        guard let selection else {
            capturing = false
            return
        }

        let output = preferences.output
        let folder = preferences.saveFolder
        Task {
            defer { capturing = false }
            do {
                let image: CGImage
                switch selection {
                case .image(let selected): image = selected
                case .window(let window, let scale): image = try await Capture.window(window, scale: scale)
                }
                showToast(try Capture.deliver(image, output: output, folder: folder))
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }

    private func showToast(_ message: String) {
        dismissToast()
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
            return
        }

        let label = Label(message, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(3)
            .fixedSize()
        let view = NSHostingView(rootView: label)
        let size = view.fittingSize
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                           y: screen.visibleFrame.maxY - size.height - 16,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        panel.orderFrontRegardless()
        toast = panel
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        toastTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            self?.dismissToast()
        }
    }

    private func dismissToast() {
        toastTimer?.cancel()
        toastTimer = nil
        toast?.orderOut(nil)
        toast = nil
    }
}
