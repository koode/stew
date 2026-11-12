import Carbon
import Foundation
import StewCore

/// System-wide hotkeys through Carbon. They work while another app has focus and need
/// no Accessibility permission. Registered only while the panel shows.
final class HotkeyCenter {
    private var references: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x5354_4557 // "STEW"

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            // Leave the Carbon callback before the handler re-registers hotkeys.
            DispatchQueue.main.async { center.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &eventType, context, &eventHandler)
    }

    /// Replaces all registrations. Returns the shortcuts the system refused (taken by another app).
    @discardableResult
    func set(_ bindings: [(Shortcut, () -> Void)]) -> [Shortcut] {
        unregisterAll()
        var failures: [Shortcut] = []
        let layout = KeyCodes.currentLayoutMap()
        for (shortcut, handler) in bindings {
            guard let keyCode = KeyCodes.code(for: shortcut.key, layout: layout) else {
                failures.append(shortcut)
                continue
            }
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                KeyCodes.carbonModifiers(shortcut.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                references.append(reference)
                handlers[nextID] = handler
            } else {
                failures.append(shortcut)
            }
            nextID &+= 1
        }
        return failures
    }

    func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references = []
        handlers = [:]
    }
}

enum KeyCodes {
    static func carbonModifiers(_ modifiers: Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func code(for key: Key, layout: [Character: UInt16]) -> UInt16? {
        switch key {
        case .special(let special):
            switch special {
            case .return: return UInt16(kVK_Return)
            case .escape: return UInt16(kVK_Escape)
            case .tab: return UInt16(kVK_Tab)
            case .space: return UInt16(kVK_Space)
            case .delete: return UInt16(kVK_Delete)
            case .left: return UInt16(kVK_LeftArrow)
            case .right: return UInt16(kVK_RightArrow)
            case .up: return UInt16(kVK_UpArrow)
            case .down: return UInt16(kVK_DownArrow)
            }
        case .character(let character):
            return layout[character]
        }
    }

    /// Character to key code for the active keyboard layout, so "y" means the key that
    /// types y, also on Dvorak, Colemak or a remapped keyboard.
    static func currentLayoutMap() -> [Character: UInt16] {
        var map: [Character: UInt16] = [:]
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return map
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length == 1,
                      let character = String(utf16CodeUnits: characters, count: 1).lowercased().first else { continue }
                // Lower codes win, so the main row beats the keypad for digits.
                if map[character] == nil { map[character] = UInt16(keyCode) }
            }
        }
        return map
    }
}
