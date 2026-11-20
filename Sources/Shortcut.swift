import AppKit
import Carbon
import Combine

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_S),
                                   modifiers: UInt32(cmdKey | shiftKey), keyLabel: "S")

    var label: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        else { return nil }

        let supported = [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                         (.shift, shiftKey), (.command, cmdKey)]
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←",
            kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let code = Int(event.keyCode)
        let label: String
        if let name = special[code] {
            label = name
        } else if let index = functionKeys.firstIndex(of: code) {
            label = "F\(index + 1)"
        } else if let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            label = characters.uppercased()
        } else {
            return nil
        }

        self.init(keyCode: UInt32(code), modifiers: supported.reduce(0) {
            flags.contains($1.0) ? $0 | UInt32($1.1) : $0
        }, keyLabel: label)
    }
}

@MainActor
final class GlobalShortcut {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var identifier: UInt32 = 0
    private static let signature: OSType = 0x536E6970 // Snip

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                let listener = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                guard hotKey.signature == GlobalShortcut.signature, hotKey.id == listener.identifier,
                      listener.registration != nil else { return OSStatus(eventNotHandledErr) }
                listener.action()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private let action: () -> Void

    func register(_ shortcut: Shortcut) -> Bool {
        guard handler != nil else { return false }
        let nextID = identifier &+ 1
        let hotKey = EventHotKeyID(signature: Self.signature, id: nextID)
        var nextRegistration: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKey,
                                        GetApplicationEventTarget(), 0, &nextRegistration)
        guard status == noErr, let nextRegistration else { return false }

        suspend()
        identifier = nextID
        registration = nextRegistration
        return true
    }

    func suspend() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
    }

    func stop() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
