import Foundation

/// Every setting the voice feature reads, in one place.
///
/// The UI writes straight to `UserDefaults`; the engine reads through the
/// typed accessors below. Nothing is cached across launches on purpose —
/// the values are cheap and a stale cache would be a bug.
enum AudioSettings {

    // MARK: - Enumerations

    /// How the user starts a capture.
    enum TriggerMode: String, CaseIterable, Identifiable {
        /// A raw key (Globe/fn, Right Command, F-keys) — hold or press.
        case key
        /// A custom hotkey (⌘⇧V style) — no permission prompt needed.
        case hotkey
        /// Always listening for "Ok <agent>". The macOS microphone indicator
        /// stays on for the whole session: macOS does not allow an app to
        /// hide it, and Apple's own Vocal Shortcuts is flagged the same way.
        case wake
        /// The OS records (Siri phrase / Dictation Shortcut) and hands us the
        /// text. Our process never opens the microphone, so the indicator
        /// never lights.
        case shortcut

        var id: String { rawValue }

        var label: String {
            switch self {
            case .key: return "Push-to-talk key"
            case .hotkey: return "Push-to-talk hotkey"
            case .wake: return "Wake word \"Ok <agent>\""
            case .shortcut: return "System shortcut (Siri / Dictation)"
            }
        }

        /// True when this mode needs the microphone open in our process.
        var usesLocalMicrophone: Bool { self != .shortcut }

        /// True when this mode keeps the microphone open permanently.
        var isAlwaysListening: Bool { self == .wake }
    }

    /// What a key press does.
    enum KeyBehaviour: String, CaseIterable, Identifiable {
        case hold
        case press
        var id: String { rawValue }
        var label: String { self == .hold ? "Hold to talk" : "Press once" }
    }

    /// The raw keys we can watch without a hotkey recorder.
    enum TriggerKey: String, CaseIterable, Identifiable {
        case globe
        case rightCommand
        case rightOption
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .globe: return "Globe / fn"
            case .rightCommand: return "Right Command"
            case .rightOption: return "Right Option"
            case .none: return "None"
            default: return rawValue.uppercased()
            }
        }

        /// The macOS virtual key code for function keys.
        var functionKeyCode: UInt16? {
            switch self {
            case .f1: return 122
            case .f2: return 120
            case .f3: return 99
            case .f4: return 118
            case .f5: return 96
            case .f6: return 97
            case .f7: return 98
            case .f8: return 100
            case .f9: return 101
            case .f10: return 109
            case .f11: return 103
            case .f12: return 111
            default: return nil
            }
        }
    }

    /// The Whisper models offered in the settings.
    enum SttModel: String, CaseIterable, Identifiable {
        case tiny
        case base
        case small
        case medium
        case largeV3 = "large-v3"
        case turbo

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tiny: return "tiny"
            case .base: return "base"
            case .small: return "small"
            case .medium: return "medium"
            case .largeV3: return "large-v3"
            case .turbo: return "turbo"
            }
        }

        /// The Hugging Face repo mlx-whisper loads. Note that turbo has no
        /// `-mlx` suffix — it is published as a plain repo.
        var repoID: String {
            switch self {
            case .tiny: return "mlx-community/whisper-tiny-mlx"
            case .base: return "mlx-community/whisper-base-mlx"
            case .small: return "mlx-community/whisper-small-mlx"
            case .medium: return "mlx-community/whisper-medium-mlx"
            case .largeV3: return "mlx-community/whisper-large-v3-mlx"
            case .turbo: return "mlx-community/whisper-large-v3-turbo"
            }
        }

        /// Rough on-disk size, for the "not downloaded" line.
        var sizeLabel: String {
            switch self {
            case .tiny: return "~75 MB"
            case .base: return "~145 MB"
            case .small: return "~480 MB"
            case .medium: return "~1.5 GB"
            case .largeV3: return "~3 GB"
            case .turbo: return "~1.6 GB"
            }
        }

        /// How long the transcription may take before it is killed.
        var timeout: TimeInterval {
            switch self {
            case .tiny, .base, .small: return 20
            case .medium: return 45
            case .largeV3, .turbo: return 90
            }
        }
    }

    // MARK: - Keys

    enum Key {
        static let enabled = "voiceEnabled"
        static let triggerMode = "voiceTriggerMode"
        static let triggerKey = "voiceTriggerKey"
        static let hotkey = "voiceHotkey"
        static let keyBehaviour = "voiceKeyBehaviour"
        static let holdThresholdMs = "voiceHoldThresholdMs"
        static let maxCaptureSec = "voiceMaxCaptureSec"
        static let wakePhrase = "voiceWakePhrase"
        static let requireAgentName = "voiceRequireAgentName"
        static let inputDeviceUID = "voiceInputDeviceUID"
        static let outputDeviceUID = "voiceOutputDeviceUID"
        static let sttModel = "voiceSttModel"
        static let sttLanguage = "voiceSttLanguage"
        static let wakeLocale = "voiceWakeLocale"
        static let soundListenStart = "voiceSoundListenStart"
        static let soundCaptureEnd = "voiceSoundCaptureEnd"
        static let soundTriggered = "voiceSoundTriggered"
        static let soundError = "voiceSoundError"
        static let confirmTranscript = "voiceConfirmTranscript"
        static let fuzzyMatch = "voiceFuzzyMatch"
        static let idleDisarmMin = "voiceIdleDisarmMin"
        static let micBadgeInMenuBar = "voiceMicBadgeInMenuBar"
        static let recentVoiceAgents = "voiceRecentAgents"
        static let keepSttLoaded = "voiceKeepSttLoaded"
        static let sttUnloadMin = "voiceSttUnloadMin"
    }

    // MARK: - Accessors

    private static var defaults: UserDefaults { .standard }

    static var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    static var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: defaults.string(forKey: Key.triggerMode) ?? "") ?? .key }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerMode) }
    }

    static var triggerKey: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: Key.triggerKey) ?? "") ?? .globe }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerKey) }
    }

    static var hotkey: String {
        get { defaults.string(forKey: Key.hotkey) ?? "" }
        set { defaults.set(newValue, forKey: Key.hotkey) }
    }

    static var keyBehaviour: KeyBehaviour {
        get { KeyBehaviour(rawValue: defaults.string(forKey: Key.keyBehaviour) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Key.keyBehaviour) }
    }

    static var holdThresholdMs: Double {
        get { defaults.object(forKey: Key.holdThresholdMs) as? Double ?? 250 }
        set { defaults.set(newValue, forKey: Key.holdThresholdMs) }
    }

    static var maxCaptureSec: Double {
        get { defaults.object(forKey: Key.maxCaptureSec) as? Double ?? 12 }
        set { defaults.set(newValue, forKey: Key.maxCaptureSec) }
    }

    static var wakePhrase: String {
        get { defaults.string(forKey: Key.wakePhrase) ?? "Ok" }
        set { defaults.set(newValue, forKey: Key.wakePhrase) }
    }

    static var requireAgentName: Bool {
        get { defaults.object(forKey: Key.requireAgentName) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.requireAgentName) }
    }

    static var inputDeviceUID: String {
        get { defaults.string(forKey: Key.inputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    static var outputDeviceUID: String {
        get { defaults.string(forKey: Key.outputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Key.outputDeviceUID) }
    }

    static var sttModel: SttModel {
        get { SttModel(rawValue: defaults.string(forKey: Key.sttModel) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.sttModel) }
    }

    /// Empty means "auto-detect".
    static var sttLanguage: String {
        get { defaults.string(forKey: Key.sttLanguage) ?? "" }
        set { defaults.set(newValue, forKey: Key.sttLanguage) }
    }

    static var wakeLocale: String {
        get { defaults.string(forKey: Key.wakeLocale) ?? "en-US" }
        set { defaults.set(newValue, forKey: Key.wakeLocale) }
    }

    static var soundListenStart: Bool {
        get { defaults.object(forKey: Key.soundListenStart) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundListenStart) }
    }

    static var soundCaptureEnd: Bool {
        get { defaults.object(forKey: Key.soundCaptureEnd) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundCaptureEnd) }
    }

    static var soundTriggered: Bool {
        get { defaults.object(forKey: Key.soundTriggered) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundTriggered) }
    }

    static var soundError: Bool {
        get { defaults.object(forKey: Key.soundError) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundError) }
    }

    static var confirmTranscript: Bool {
        get { defaults.object(forKey: Key.confirmTranscript) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.confirmTranscript) }
    }

    static var fuzzyMatch: Bool {
        get { defaults.object(forKey: Key.fuzzyMatch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fuzzyMatch) }
    }

    /// Minutes of idleness before an always-listening session disarms itself.
    /// Zero never disarms.
    static var idleDisarmMin: Int {
        get { defaults.object(forKey: Key.idleDisarmMin) as? Int ?? 30 }
        set { defaults.set(newValue, forKey: Key.idleDisarmMin) }
    }

    static var keepSttLoaded: Bool {
        get { defaults.object(forKey: Key.keepSttLoaded) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.keepSttLoaded) }
    }

    static var sttUnloadMin: Int {
        get { defaults.object(forKey: Key.sttUnloadMin) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Key.sttUnloadMin) }
    }

    static var recentVoiceAgents: [String] {
        get { defaults.stringArray(forKey: Key.recentVoiceAgents) ?? [] }
        set {
            var out: [String] = []
            for name in newValue {
                if !out.contains(name) { out.append(name) }
            }
            defaults.set(Array(out.prefix(10)), forKey: Key.recentVoiceAgents)
        }
    }

    static var micBadgeInMenuBar: Bool {
        get { defaults.object(forKey: Key.micBadgeInMenuBar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.micBadgeInMenuBar) }
    }

    // MARK: - Environment

    /// A locale the on-device speech model can use for the wake word.
    struct WakeLocale: Identifiable {
        let code: String
        let label: String
        var id: String { code }
    }

    /// The locales offered for the wake word. The system's own list is much
    /// longer; these are the ones that make sense for the agents.
    static let wakeLocales: [WakeLocale] = [
        WakeLocale(code: "en-US", label: "English (US)"),
        WakeLocale(code: "en-GB", label: "English (UK)"),
        WakeLocale(code: "en-CA", label: "English (Canada)"),
        WakeLocale(code: "fr-FR", label: "French (France)"),
        WakeLocale(code: "fr-CA", label: "French (Canada)"),
        WakeLocale(code: "de-DE", label: "German"),
        WakeLocale(code: "es-ES", label: "Spanish (Spain)"),
        WakeLocale(code: "es-MX", label: "Spanish (Mexico)"),
        WakeLocale(code: "it-IT", label: "Italian"),
        WakeLocale(code: "pt-BR", label: "Portuguese (Brazil)"),
        WakeLocale(code: "pt-PT", label: "Portuguese (Portugal)"),
        WakeLocale(code: "nl-NL", label: "Dutch"),
        WakeLocale(code: "ru-RU", label: "Russian"),
        WakeLocale(code: "uk-UA", label: "Ukrainian"),
        WakeLocale(code: "pl-PL", label: "Polish"),
        WakeLocale(code: "tr-TR", label: "Turkish"),
        WakeLocale(code: "ar-SA", label: "Arabic"),
        WakeLocale(code: "hi-IN", label: "Hindi"),
        WakeLocale(code: "zh-CN", label: "Chinese (Simplified)"),
        WakeLocale(code: "zh-TW", label: "Chinese (Traditional)"),
        WakeLocale(code: "ja-JP", label: "Japanese"),
        WakeLocale(code: "ko-KR", label: "Korean"),
    ]

    /// The feature needs the macOS 26 Speech stack.
    static var isSupportedOS: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var unsupportedReason: String {
        "Voice control needs macOS 26 (SpeechAnalyzer). This Mac runs macOS \(ProcessInfo.processInfo.operatingSystemVersionString)."
    }
}
