import AppKit
import AVFoundation
import EliaTopBarKit
import SwiftUI

/// The "Audio & Voice" block of the topbar settings.
///
/// Every control writes straight to `UserDefaults` through `AudioSettings` and
/// then tells the app to re-arm the trigger, so there is exactly one source
/// of truth for the voice feature.
///
/// One rule shapes this file: **nothing in a view body may touch a
/// `@MainActor` class**. SwiftUI evaluates the `@ViewBuilder` closures of a
/// body outside the main-actor isolation, so a call into a main-actor object
/// from there makes the runtime do a dynamic executor check — and that check
/// is what crashed the app when the settings window opened. Every such call
/// is therefore wrapped in `Task { @MainActor in … }`, and the file reads are
/// cached in `@State` instead of happening during the body.
struct AudioSettingsSection: View {

    var onSettingsChanged: () -> Void = {}

    @State private var enabled = AudioSettings.enabled
    @State private var triggerMode = AudioSettings.triggerMode
    @State private var triggerKey = AudioSettings.triggerKey
    @State private var keyBehaviour = AudioSettings.keyBehaviour
    @State private var hotkey = AudioSettings.hotkey
    @State private var isRecordingHotkey = false
    @State private var hotkeyMonitor: Any?
    @State private var maxCapture = AudioSettings.maxCaptureSec
    @State private var wakePhrase = AudioSettings.wakePhrase
    @State private var requireAgentName = AudioSettings.requireAgentName
    @State private var inputUID = AudioSettings.inputDeviceUID
    @State private var outputUID = AudioSettings.outputDeviceUID
    @State private var sttModel = AudioSettings.sttModel
    @State private var sttLanguage = AudioSettings.sttLanguage
    @State private var wakeLocale = AudioSettings.wakeLocale
    @State private var soundListenStart = AudioSettings.soundListenStart
    @State private var soundCaptureEnd = AudioSettings.soundCaptureEnd
    @State private var soundTriggered = AudioSettings.soundTriggered
    @State private var soundError = AudioSettings.soundError

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var outputDevices: [AudioOutputDevice] = []
    @State private var engineStatus: String = "checking…"
    @State private var modelCached: Bool?
    @State private var keepLoaded: Bool = AudioSettings.keepSttLoaded
    @State private var engineReady: Bool = false
    @State private var downloadState: String = ""
    @State private var isDownloading = false
    @State private var isTestingMic = false
    @State private var micTestResult: String?
    @State private var suffixIsCustomised = false
    @State private var showSuffixEditor = false
    @State private var wakeAssetStatus: WakeAssetStatus?
    @State private var isInstallingAsset = false
    @State private var microphoneState = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    /// The state of the on-device language pack used for the wake word.
    struct WakeAssetStatus: Equatable {
        let isReady: Bool
        let description: String
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !AudioSettings.isSupportedOS {
                    Text(AudioSettings.unsupportedReason)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                }

                Toggle("Enable voice control", isOn: $enabled)
                    .onChange(of: enabled) { value in
                        AudioSettings.enabled = value
                        rearm()
                        if value {
                            // Ask for the microphone while this window is in
                            // front: a menu-bar app has nowhere else to show
                            // the system prompt.
                            Task { @MainActor in
                                let granted = await VoiceCommandRouter.shared.ensureMicrophoneAccess()
                                microphoneState = granted
                                if granted { rearm() }
                            }
                        }
                    }
                    .disabled(!AudioSettings.isSupportedOS)

                if enabled {
                    Divider()

                    microphoneRow
                    Divider()

                    triggerSection
                    Divider()

                    devicesSection
                    Divider()

                    transcriptionSection
                    Divider()

                    soundsSection
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Audio & Voice", systemImage: "mic.fill")
        }
        .onDisappear {
            stopRecordingHotkey()
        }
        .onAppear {
            loadDevices()
            suffixIsCustomised = VoiceSuffixPrompt.isCustomised
            microphoneState = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            checkEngine()
        }
        .sheet(isPresented: $showSuffixEditor) {
            VoiceSuffixPromptEditor()
        }
    }

    // MARK: - Microphone permission

    @ViewBuilder
    private var microphoneRow: some View {
        Text("Microphone").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

        HStack {
            Text(microphoneStatus)
                .font(.system(size: 10))
                .foregroundStyle(microphoneGranted ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !microphoneGranted {
                Button("Ask macOS") {
                    Task { @MainActor in askForMicrophone() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var microphoneGranted: Bool {
        microphoneState
    }

    private var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Allowed — the microphone is ready."
        case .notDetermined: return "Not decided yet. macOS asks when the first recording starts."
        case .denied: return "Refused. Enable it in System Settings › Privacy & Security › Microphone."
        case .restricted: return "Blocked by a policy on this Mac."
        @unknown default: return "Unknown."
        }
    }

    private func askForMicrophone() {
        Task { @MainActor in
            let granted = await VoiceCommandRouter.shared.ensureMicrophoneAccess()
            microphoneState = granted
            // The trigger was armed with a closed microphone: arm it again
            // now that the system said yes.
            if granted { rearm() }
        }
    }

    // MARK: - Trigger

    @ViewBuilder
    private var triggerSection: some View {
        Text("Trigger").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

        Picker("Mode", selection: $triggerMode) {
            ForEach(AudioSettings.TriggerMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .onChange(of: triggerMode) { mode in
            AudioSettings.triggerMode = mode
            rearm()
        }

        if triggerMode == .key {
            Picker("Key", selection: $triggerKey) {
                ForEach(AudioSettings.TriggerKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .onChange(of: triggerKey) { key in
                AudioSettings.triggerKey = key
                rearm()
            }

            Picker("Behaviour", selection: $keyBehaviour) {
                ForEach(AudioSettings.KeyBehaviour.allCases) { behaviour in
                    Text(behaviour.label).tag(behaviour)
                }
            }
            .onChange(of: keyBehaviour) { value in
                AudioSettings.keyBehaviour = value
                rearm()
            }

            Text("The Globe key and the right-side modifiers need Input Monitoring permission.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if triggerMode == .hotkey {
            HStack {
                Text("Shortcut")
                if isRecordingHotkey {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                } else {
                    TextField("cmd+shift+v", text: $hotkey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                Button(isRecordingHotkey ? "Cancel" : "Re-arm") {
                    if isRecordingHotkey {
                        stopRecordingHotkey()
                    } else {
                        startRecordingHotkey()
                    }
                }
                .buttonStyle(.bordered)
            }
            .onChange(of: hotkey) { value in
                AudioSettings.hotkey = value
                if !isRecordingHotkey { rearm() }
            }
            .onChange(of: triggerMode) { _ in
                stopRecordingHotkey()
            }
            Text("A system shortcut needs no permission and works while the app is in the background.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if triggerMode == .wake {
            HStack {
                Text("Wake phrase")
                TextField("Ok", text: $wakePhrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            .onChange(of: wakePhrase) { value in
                AudioSettings.wakePhrase = value
            }

            Toggle("Require an agent name", isOn: $requireAgentName)
                .onChange(of: requireAgentName) { value in
                    AudioSettings.requireAgentName = value
                }

            Text("macOS keeps the microphone indicator on for as long as an app listens. Apple does the same for its own wake word — there is no way to hide it.")
                .font(.system(size: 10)).foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Idle disarm after")
                Slider(value: Binding(
                    get: { Double(AudioSettings.idleDisarmMin) },
                    set: { AudioSettings.idleDisarmMin = Int($0) }),
                    in: 0...60, step: 5)
                .onChange(of: AudioSettings.idleDisarmMin) { _ in rearm() }
                Text(AudioSettings.idleDisarmMin == 0 ? "never" : "\(AudioSettings.idleDisarmMin) min")
                    .monospacedDigit().foregroundColor(.secondary)
            }
            Text("Closes the microphone after this many idle minutes in wake mode, so the indicator and the RAM go back to baseline. Zero never disarms.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if VoiceCommandRouter.shared.wakeDisarmedByTimer {
                HStack {
                    Text("The wake word disarmed itself after idling. Re-arm to listen again.")
                        .font(.system(size: 10)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Re-arm") {
                        Task { @MainActor in
                            VoiceCommandRouter.shared.rearmWake()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Wake word is not working yet. Use Push-to-talk (key or hotkey) for now.")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if triggerMode == .shortcut {
            Text("The system owns the microphone: set up a Dictation or Siri shortcut that ends on “Open URL” with")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("elia://voice?text=<the dictation>")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            Text("The microphone indicator stays dark because the OS does the recording, not this app.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if triggerMode != .shortcut {
            HStack {
                Text("Max capture")
                Slider(value: $maxCapture, in: 3...60, step: 1)
                    .onChange(of: maxCapture) { value in
                        AudioSettings.maxCaptureSec = value
                    }
                Text("\(Int(maxCapture))s").monospacedDigit().foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Devices

    @ViewBuilder
    private var devicesSection: some View {
        Text("Devices").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

        Picker("Input", selection: $inputUID) {
            ForEach(inputDevices) { device in
                Text(device.name).tag(device.id)
            }
        }
        .onChange(of: inputUID) { value in
            AudioSettings.inputDeviceUID = value
        }

        Picker("Output", selection: $outputUID) {
            ForEach(outputDevices) { device in
                Text(device.name).tag(device.id)
            }
        }
        .onChange(of: outputUID) { value in
            AudioSettings.outputDeviceUID = value
        }

        Button("Refresh devices") {
            Task { @MainActor in loadDevices() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Transcription

    @ViewBuilder
    private var transcriptionSection: some View {
        Text("Transcription").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

        HStack {
            Button("Edit the prompt suffix…") {
                showSuffixEditor = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if suffixIsCustomised {
                Text("customised")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        Text("The suffix is appended to every voice command. Put there how the agent should answer "
             + "out loud — the text-to-speech skill, the macos popup overlay, your wording.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Picker("Whisper model", selection: $sttModel) {
            ForEach(AudioSettings.SttModel.allCases) { model in
                Text("\(model.label) — \(model.sizeLabel)").tag(model)
            }
        }
        .onChange(of: sttModel) { value in
            AudioSettings.sttModel = value
            Task { @MainActor in await checkModelCache() }
        }

        if let cached = modelCached {
            Text(cached
                 ? "\(sttModel.label) is on disk."
                 : "\(sttModel.label) is not downloaded yet. The download needs a connection to huggingface.co.")
                .font(.system(size: 10))
                .foregroundStyle(cached ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle("Keep Whisper loaded in memory", isOn: $keepLoaded)
            .onChange(of: keepLoaded) { value in
                AudioSettings.keepSttLoaded = value
                if !value {
                    Task { @MainActor in await STTDaemon.shared.onKeepLoadedDisabled() }
                }
                rearm()
            }
            .disabled(!engineReady)
        if keepLoaded {
            HStack {
                Text("Unload after")
                Slider(value: Binding(
                    get: { Double(AudioSettings.sttUnloadMin) },
                    set: { AudioSettings.sttUnloadMin = Int($0) }),
                    in: 1...60, step: 1)
                Text("\(AudioSettings.sttUnloadMin) min").monospacedDigit().foregroundColor(.secondary)
            }
            Text("The model (\(sttModel.sizeLabel)) stays resident between commands for speed, then exits after this many idle minutes so the RAM and VRAM go back. Default off: the model is loaded per command.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Picker("Language", selection: $sttLanguage) {
            ForEach(WhisperLanguages.all, id: \.code) { language in
                Text(language.label).tag(language.code)
            }
        }
        .onChange(of: sttLanguage) { value in
            AudioSettings.sttLanguage = value
        }

        Picker("Wake-word language", selection: $wakeLocale) {
            ForEach(AudioSettings.wakeLocales, id: \.code) { locale in
                Text(locale.label).tag(locale.code)
            }
        }
        .onChange(of: wakeLocale) { value in
            AudioSettings.wakeLocale = value
            Task { @MainActor in await checkWakeAsset() }
        }

        // The wake word is heard by the on-device speech model. Without its
        // language pack the app cannot know that "Ok Gilfoyle" was said, so
        // the status is shown and the pack can be installed from here.
        if let asset = wakeAssetStatus {
            HStack {
                Text(asset.description)
                    .font(.system(size: 10))
                    .foregroundStyle(asset.isReady ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !asset.isReady {
                    Button("Install") {
                        Task { @MainActor in await installWakeAsset() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isInstallingAsset)
                }
            }
        }

        HStack {
            Button(isDownloading ? "Downloading…" : "Download model") {
                Task { @MainActor in downloadModel() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloading)
            if !downloadState.isEmpty {
                Text(downloadState).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }

        Text(engineStatus)
            .font(.system(size: 10))
            .foregroundStyle(engineStatus.hasPrefix("ready") ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sounds

    @ViewBuilder
    private var soundsSection: some View {
        Text("Sounds").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

        Toggle("Listening started", isOn: $soundListenStart)
            .onChange(of: soundListenStart) { AudioSettings.soundListenStart = $0 }
        Toggle("Capture ended", isOn: $soundCaptureEnd)
            .onChange(of: soundCaptureEnd) { AudioSettings.soundCaptureEnd = $0 }
        Toggle("Command sent", isOn: $soundTriggered)
            .onChange(of: soundTriggered) { AudioSettings.soundTriggered = $0 }
        Toggle("Error", isOn: $soundError)
            .onChange(of: soundError) { AudioSettings.soundError = $0 }

        Button("Play test sound") {
            Task { @MainActor in
                AudioFeedback.shared.play(.triggered, outputUID: AudioSettings.outputDeviceUID)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        HStack {
            Button(isTestingMic ? "Listening…" : "Test the microphone") {
                Task { @MainActor in runMicTest() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isTestingMic)
            if let result = micTestResult {
                Text(result)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        Text("Records eight seconds, transcribes them, and fires nothing.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    /// Re-arm the trigger. The closure is not main-actor isolated, so the
    /// call is hopped instead of made in place.
    private func rearm() {
        Task { @MainActor in onSettingsChanged() }
    }

    private func startRecordingHotkey() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        FileHandle.standardError.write(Data("DEBUG startRecordingHotkey\n".utf8))
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let spec = Self.hotkeySpec(from: event) else { return event }
            DispatchQueue.main.async {
                self.hotkey = spec
                AudioSettings.hotkey = spec
                self.isRecordingHotkey = false
                self.stopRecordingHotkey()
                self.rearm()
            }
            return nil
        }
    }

    private func stopRecordingHotkey() {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        hotkeyMonitor = nil
        isRecordingHotkey = false
    }

    private static func hotkeySpec(from event: NSEvent) -> String? {
        FileHandle.standardError.write(Data("DEBUG keyDown code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "<nil>") mods=\(event.modifierFlags.rawValue)\n".utf8))
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.function) { parts.append("fn") }
        guard !parts.isEmpty else { return nil }

        // A readable token for ordinary keys, a stable code for everything
        // else (punctuation, symbols, dead keys, function keys).
        let keyToken: String
        if let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           (scalar.value >= 97 && scalar.value <= 122) ||
           (scalar.value >= 48 && scalar.value <= 57) {
            keyToken = chars
        } else if let name = specialKeyName(for: event.keyCode) {
            keyToken = name
        } else {
            keyToken = "keycode:\(event.keyCode)"
        }
        parts.append(keyToken)
        return parts.joined(separator: "+")
    }

    private static func specialKeyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 53: return "escape"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 117: return "forwarddelete"
        case 122...135: return "f\(keyCode - 121)"
        default: return nil
        }
    }

    private func loadDevices() {
        inputDevices = AudioDeviceList.inputDevices()
        outputDevices = AudioDeviceList.outputDevices()
    }

    private func checkEngine() {
        Task { @MainActor in
            let available = await STTEngine.isAvailable()
            engineReady = available
            engineStatus = available
                ? "ready — mlx-whisper found"
                : "mlx-whisper was not found. Install it with: pip3 install mlx-whisper"
            await checkModelCache()
            await checkWakeAsset()
        }
    }

    /// Ask the system whether the on-device wake-word pack is ready.
    private func checkWakeAsset() async {
        guard #available(macOS 26.0, *) else { return }
        let locale = Locale(identifier: AudioSettings.wakeLocale)
        let status = await SpeechAnalyzerService.assetStatus(locale: locale)
        switch status {
        case .installed:
            wakeAssetStatus = WakeAssetStatus(isReady: true,
                                              description: "The wake-word language pack is installed.")
        case .downloading:
            wakeAssetStatus = WakeAssetStatus(isReady: false,
                                              description: "The wake-word language pack is downloading…")
        case .supported:
            wakeAssetStatus = WakeAssetStatus(isReady: false,
                                              description: "The wake-word language pack is missing. Without it the app cannot hear “Ok <agent>”.")
        case .unsupported:
            wakeAssetStatus = WakeAssetStatus(isReady: false,
                                              description: "This Mac cannot do on-device speech for that language.")
        @unknown default:
            wakeAssetStatus = WakeAssetStatus(isReady: false,
                                              description: "The wake-word language pack is not ready.")
        }
    }

    private func installWakeAsset() async {
        guard #available(macOS 26.0, *) else { return }
        isInstallingAsset = true
        try? await SpeechAnalyzerService.installAsset(locale: Locale(identifier: AudioSettings.wakeLocale))
        isInstallingAsset = false
        await checkWakeAsset()
    }

    private func checkModelCache() async {
        modelCached = await STTEngine.isCached(model: AudioSettings.sttModel)
    }

    private func downloadModel() {
        isDownloading = true
        downloadState = ""
        Task { @MainActor in
            do {
                _ = try await STTEngine.download(model: AudioSettings.sttModel)
                downloadState = "\(AudioSettings.sttModel.label) is ready"
            } catch {
                downloadState = error.localizedDescription
            }
            isDownloading = false
            await checkModelCache()
        }
    }

    private func runMicTest() {
        isTestingMic = true
        micTestResult = nil
        Task { @MainActor in
            VoiceCommandRouter.shared.runMicTest { result in
                Task { @MainActor in
                    isTestingMic = false
                    micTestResult = result ?? "nothing was heard"
                }
            }
        }
    }
}

/// The languages Whisper understands. Empty code means "detect it".
enum WhisperLanguages {
    struct Entry: Identifiable {
        let code: String
        let label: String
        var id: String { code }
    }

    static let all: [Entry] = [
        Entry(code: "", label: "Detect automatically"),
        Entry(code: "en", label: "English"),
        Entry(code: "fr", label: "French"),
        Entry(code: "de", label: "German"),
        Entry(code: "es", label: "Spanish"),
        Entry(code: "it", label: "Italian"),
        Entry(code: "pt", label: "Portuguese"),
        Entry(code: "nl", label: "Dutch"),
        Entry(code: "ru", label: "Russian"),
        Entry(code: "zh", label: "Chinese"),
        Entry(code: "ja", label: "Japanese"),
        Entry(code: "ko", label: "Korean"),
        Entry(code: "ar", label: "Arabic"),
        Entry(code: "hi", label: "Hindi"),
        Entry(code: "tr", label: "Turkish"),
        Entry(code: "pl", label: "Polish"),
        Entry(code: "sv", label: "Swedish"),
        Entry(code: "da", label: "Danish"),
        Entry(code: "nb", label: "Norwegian"),
        Entry(code: "fi", label: "Finnish"),
        Entry(code: "cs", label: "Czech"),
        Entry(code: "el", label: "Greek"),
        Entry(code: "he", label: "Hebrew"),
        Entry(code: "th", label: "Thai"),
        Entry(code: "vi", label: "Vietnamese"),
        Entry(code: "id", label: "Indonesian"),
        Entry(code: "uk", label: "Ukrainian"),
        Entry(code: "ro", label: "Romanian"),
        Entry(code: "hu", label: "Hungarian"),
        Entry(code: "ca", label: "Catalan"),
    ]
}
