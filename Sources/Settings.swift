import AppKit
import Carbon
import ServiceManagement
import SwiftUI

enum Output: String, CaseIterable, Identifiable {
    case clipboard = "Copy only"
    case file = "Save only"
    case both = "Save and copy"

    var id: Self { self }
    var savesFile: Bool { self != .clipboard }
    var copiesImage: Bool { self != .file }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var output: Output {
        didSet { defaults.set(output.rawValue, forKey: "output") }
    }
    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            menuBarVisibilityChanged?()
        }
    }
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginMessage = ""
    var menuBarVisibilityChanged: (() -> Void)?

    @Published private(set) var folder: URL?
    @Published private(set) var shortcut: Shortcut
    @Published private(set) var recording = false
    @Published private(set) var shortcutMessage = ""

    private let defaults = UserDefaults.standard
    private var hotKey: GlobalShortcut?
    private var keyMonitor: Any?
    private var folderBookmark: Data?

    init() {
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? false
        output = defaults.string(forKey: "output").flatMap(Output.init(rawValue:)) ?? .clipboard
        shortcut = defaults.data(forKey: "shortcut").flatMap {
            try? JSONDecoder().decode(Shortcut.self, from: $0)
        } ?? .standard
        folderBookmark = defaults.data(forKey: "folderBookmark")
        folder = defaults.string(forKey: "folderPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folderBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: folderBookmark,
                                       options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                       bookmarkDataIsStale: &stale) {
                folder = resolved
                if stale { rememberFolder(resolved) }
            }
        }
    }

    var saveFolder: URL {
        folder ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnipBar", isDirectory: true)
    }

    var startsAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setStartsAtLogin(_ enabled: Bool) {
        loginMessage = ""
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginMessage = error.localizedDescription
        }
        refreshLoginStatus()
    }

    func startHotKey(action: @escaping () -> Void) {
        let listener = GlobalShortcut(action: action)
        hotKey = listener
        restoreHotKey()
    }

    func stopHotKey() {
        removeKeyMonitor()
        hotKey?.stop()
        hotKey = nil
    }

    func beginRecording() {
        guard !recording else { return }
        hotKey?.suspend()
        recording = true
        shortcutMessage = "Press a shortcut with ⌘, ⌃, or ⌥. Press Esc to cancel."
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.isARepeat { return nil }
            if event.keyCode == kVK_Escape {
                self.cancelRecording()
            } else if let candidate = Shortcut(event: event) {
                if self.hotKey?.register(candidate) == true {
                    self.commitShortcut(candidate)
                    self.removeKeyMonitor()
                } else {
                    self.shortcutMessage = "\(candidate.label) is unavailable. Try another shortcut."
                }
            }
            return nil
        }
        if keyMonitor == nil { cancelRecording() }
    }

    func cancelRecording() {
        guard recording else { return }
        removeKeyMonitor()
        restoreHotKey()
    }

    func resetShortcut() {
        if recording { cancelRecording() }
        guard shortcut != .standard || !shortcutMessage.isEmpty else { return }
        if hotKey?.register(.standard) == true {
            commitShortcut(.standard)
        } else {
            shortcutMessage = "\(Shortcut.standard.label) is unavailable."
        }
    }

    func chooseFolder(relativeTo window: NSWindow) {
        cancelRecording()
        let panel = NSOpenPanel()
        panel.message = "Choose where SnipBar saves screenshots."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder ?? saveFolder.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.rememberFolder(url)
        }
    }

    private func rememberFolder(_ url: URL) {
        folder = url
        defaults.set(url.path, forKey: "folderPath")
        folderBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(folderBookmark, forKey: "folderBookmark")
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = false
    }

    private func restoreHotKey() {
        shortcutMessage = hotKey?.register(shortcut) == true ? "" : "\(shortcut.label) is unavailable. Set a different shortcut."
    }

    private func commitShortcut(_ value: Shortcut) {
        shortcut = value
        defaults.set(try? JSONEncoder().encode(value), forKey: "shortcut")
        shortcutMessage = ""
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let chooseFolder: () -> Void
    let requestPermission: () -> Void
    let capture: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Form {
                Section("Capture") {
                    Picker("After capture", selection: $preferences.output) {
                        ForEach(Output.allCases) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Save location")
                        Spacer()
                        Text(preferences.saveFolder.path(percentEncoded: false).replacingOccurrences(
                            of: NSHomeDirectory() + "/", with: "~/", options: .anchored))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(preferences.saveFolder.path)
                        Button("Choose…", action: chooseFolder)
                    }
                }

                Section("Keyboard") {
                    HStack {
                        Text("Global shortcut")
                        Spacer()
                        Button(preferences.recording ? "Press keys…" : preferences.shortcut.label) {
                            if preferences.recording {
                                preferences.cancelRecording()
                            } else {
                                preferences.beginRecording()
                            }
                        }
                        .monospaced()
                        .help("Record a new global shortcut")
                        Button("Reset") { preferences.resetShortcut() }
                    }
                    if !preferences.shortcutMessage.isEmpty {
                        Text(preferences.shortcutMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Background") {
                    Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
                    Toggle("Start at login", isOn: Binding(get: { preferences.startsAtLogin },
                                                          set: preferences.setStartsAtLogin))
                    if preferences.loginStatus == .requiresApproval {
                        Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    if !preferences.loginMessage.isEmpty {
                        Text(preferences.loginMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    if !preferences.showMenuBarIcon {
                        Text("Open SnipBar from Applications to return to settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Screen Recording Access…", action: requestPermission)
                Spacer()
                Button("Quit SnipBar", action: quit)
                Button("New Snip", action: capture)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500, height: 505, alignment: .topLeading)
    }
}
