import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches one key for push-to-talk.
///
/// Two mechanisms, because they need different permissions:
/// - a `CGEventTap` for a raw key (Globe/fn, Right Command, F-keys). macOS
///   only hands those over to a process with Input Monitoring, so the tap
///   fails silently without it — hence the explicit pre-flight check.
/// - a Carbon global hotkey for the "hotkey" mode. `RegisterEventHotKey`
///   needs no permission at all, which is why it is the safe default.
final class KeyTriggerListener {

    /// Fired on the main actor when the key goes down.
    var onPress: (@MainActor () -> Void)?
    /// Fired on the main actor when the key comes back up.
    var onRelease: (@MainActor () -> Void)?
    /// Fired when the system refused the event tap.
    var onPermissionNeeded: (@MainActor () -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var watchedCode: UInt16 = 0
    private var behaviour: AudioSettings.KeyBehaviour = .hold

    /// Virtual key codes we can watch.
    private static let globeKeyCode: UInt16 = 0x3F        // kVK_Function
    private static let rightCommandKeyCode: UInt16 = 0x36 // kVK_RightCommand
    private static let rightOptionKeyCode: UInt16 = 0x3D   // kVK_RightOption

    // MARK: - Lifecycle

    /// Start watching. Returns false when the system refused the tap.
    @discardableResult
    func start(key: AudioSettings.TriggerKey, behaviour: AudioSettings.KeyBehaviour) -> Bool {
        stop()
        self.behaviour = behaviour

        guard let code = Self.keyCode(for: key) else { return false }

        // The Globe key arrives as a flags-changed event, not a key event.
        let needsFlags = (code == Self.globeKeyCode)
        if needsFlags, !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            Task { @MainActor [weak self] in self?.onPermissionNeeded?() }
            return false
        }

        var mask = CGEventMask(1 << UInt32(CGEventType.keyDown.rawValue))
        mask |= CGEventMask(1 << UInt32(CGEventType.keyUp.rawValue))
        if needsFlags {
            mask |= CGEventMask(1 << UInt32(CGEventType.flagsChanged.rawValue))
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<KeyTriggerListener>.fromOpaque(refcon).takeUnretainedValue()
            listener.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                         place: .headInsertEventTap,
                                         options: .defaultTap,
                                         eventsOfInterest: mask,
                                         callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            CGRequestListenEventAccess()
            Task { @MainActor [weak self] in self?.onPermissionNeeded?() }
            return false
        }

        self.tap = tap
        self.watchedCode = code
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        source = nil
        tap = nil
        isDown = false
    }

    deinit {
        stop()
    }

    // MARK: - Events

    private func handle(type: CGEventType, event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard UInt16(truncatingIfNeeded: code) == watchedCode else { return }

        switch type {
        case .keyDown:
            press()
        case .keyUp:
            release()
        case .flagsChanged:
            // The Globe key is a modifier: it shows up here and nowhere else.
            let isDown = event.getIntegerValueField(.keyboardEventKeycode) == Int(watchedCode)
            if isDown && !self.isDown { press() }
            if !isDown && self.isDown { release() }
        default:
            break
        }
    }

    private func press() {
        guard !isDown else { return }
        isDown = true
        let handler = onPress
        Task { @MainActor in handler?() }
    }

    private func release() {
        guard isDown else { return }
        isDown = false
        let handler = onRelease
        Task { @MainActor in handler?() }
    }

    // MARK: - Key codes

    static func keyCode(for key: AudioSettings.TriggerKey) -> UInt16? {
        switch key {
        case .globe: return globeKeyCode
        case .rightCommand: return rightCommandKeyCode
        case .rightOption: return rightOptionKeyCode
        case .none: return nil
        default: return key.functionKeyCode
        }
    }
}

/// A system-wide hotkey that needs no permission.
///
/// `RegisterEventHotKey` is the only way to get a global shortcut without
/// Input Monitoring, so the "hotkey" trigger mode uses it.
final class GlobalHotKey {

    /// Fired on the main actor when the shortcut is pressed.
    var onTrigger: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x454C4941 // 'ELIA'

    /// Register the shortcut. Returns false when the system refused it.
    @discardableResult
    func register(spec: String, onTrigger: (@MainActor () -> Void)? = nil) -> Bool {
        unregister()
        guard let parsed = HotKeySpec.parse(spec) else { return false }
        self.onTrigger = onTrigger ?? self.onTrigger

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon in
                guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event,
                                              EventParamName(kEventParamDirectObject),
                                              EventParamType(typeEventHotKeyID),
                                              nil,
                                              MemoryLayout<EventHotKeyID>.size,
                                              nil,
                                              &hotKeyID)
                if status == noErr,
                   hotKeyID.signature == GlobalHotKey.signature {
                    let owner = Unmanaged<GlobalHotKey>.fromOpaque(refcon).takeUnretainedValue()
                    let handler = owner.onTrigger
                    Task { @MainActor in handler?() }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        let registerStatus = RegisterEventHotKey(parsed.keyCode,
                                                 parsed.modifiers,
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    deinit {
        unregister()
    }
}

/// A shortcut written as "cmd+shift+v".
struct HotKeySpec {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Parse a shortcut string. Returns nil when it cannot be understood.
    static func parse(_ spec: String) -> HotKeySpec? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = parts.last else { return nil }

        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            // Fn is not a Carbon hot-key modifier, but keep the token so a
            // recorded shortcut can be displayed and retried instead of being
            // rejected outright.
            case "fn", "function": modifiers |= 0x00800000
            default: break
            }
        }
        let keyCode: UInt32?
        if last.hasPrefix("keycode:") || last.hasPrefix("kc:") {
            let value = last.split(separator: ":", maxSplits: 1).last ?? ""
            keyCode = UInt32(value)
        } else if let named = VirtualKeyCodes.named(last) {
            keyCode = named
        } else {
            keyCode = VirtualKeyCodes.letter(last) ?? VirtualKeyCodes.digit(last)
        }
        guard let keyCode else { return nil }
        return HotKeySpec(keyCode: keyCode, modifiers: modifiers)
    }
}

enum VirtualKeyCodes {
    static func named(_ value: String) -> UInt32? {
        switch value {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "forwarddelete": return 117
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default:
            if value.hasPrefix("f"), let n = Int(value.dropFirst()), n >= 1, n <= 12 {
                return UInt32(121 + (n - 1))
            }
            return nil
        }
    }


    /// macOS virtual key codes, not ASCII codes: `RegisterEventHotKey`
    /// needs the former, which is why the previous implementation never
    /// registered a shortcut.
    private static let letterCodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static let digitCodes: [Character: UInt32] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29,
    ]

    static func letter(_ value: String) -> UInt32? {
        guard value.count == 1, let char = value.lowercased().first else { return nil }
        return letterCodes[char]
    }

    static func digit(_ value: String) -> UInt32? {
        guard value.count == 1, let char = value.first else { return nil }
        return digitCodes[char]
    }
}
