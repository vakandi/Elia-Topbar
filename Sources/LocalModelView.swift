import Foundation
import SwiftUI

// MARK: - Probe

/// One model served by a local endpoint (Ollama `/api/tags` or an
/// OpenAI-compatible `/v1/models`).
struct LocalModelEntry: Identifiable, Hashable, Sendable {
    let id: String
    let sizeBytes: Int64
    let parameterSize: String
    let quantization: String

    var sizeLabel: String {
        guard sizeBytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// "9.4B · Q4_K_M · 6 GB" — empty parts are dropped so LM Studio entries
    /// (which expose none of the Ollama details) still render cleanly.
    var detailLabel: String {
        [parameterSize, quantization, sizeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// A reachable local server. `providerID` is the prefix written into the
/// agent's model id (`ollama/…` vs `local/…`), so it must reflect what
/// actually answered: Ollama's native API or a generic OpenAI-compatible one.
struct LocalModelServer: Equatable, Sendable {
    let baseURL: String
    let providerID: String
    let models: [LocalModelEntry]
    let version: String?

    var isOllama: Bool { providerID == "ollama" }

    var title: String { isOllama ? "Ollama" : "OpenAI-compatible server" }

    var headline: String {
        var parts: [String] = []
        if isOllama { parts.append(version.map { "Ollama \($0)" } ?? "Ollama") } else { parts.append(title) }
        parts.append(baseURL)
        parts.append(models.count == 1 ? "1 model" : "\(models.count) models")
        return parts.joined(separator: " · ")
    }
}

enum LocalModelProbeError: LocalizedError {
    case invalidURL(String)
    case unreachable(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "“\(raw)” is not a valid base URL."
        case .unreachable(let base):
            return "Nothing answered at \(base)."
        case .unexpectedResponse(let base):
            return "\(base) answered, but not like an Ollama or OpenAI-compatible server."
        }
    }
}

/// Detection runs against every candidate in parallel and keeps the first hit
/// in preference order. A stale saved URL must never hide a live server behind
/// its own timeout — sequential probing did exactly that.
enum LocalModelProbe {
    static let savedBaseURLKey = "localModelBaseURL"

    static var savedBaseURL: String {
        UserDefaults.standard.string(forKey: savedBaseURLKey) ?? ""
    }

    /// Accepts `host:port`, `http://host:port/v1`, trailing slashes. Returns
    /// the API *root* (no `/v1`): Ollama's native routes live there, and the
    /// OpenAI-compatible probe appends `/v1` itself.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            value = "http://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/v1") { value.removeLast(3) }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return value
    }

    static func candidates() -> [String] {
        var raw: [String] = []
        // An explicit OLLAMA_HOST wins: it is the only source that knows about
        // a non-default port the user already configured for the CLI.
        if let env = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !env.isEmpty {
            raw.append(env)
        }
        raw.append(savedBaseURL)
        raw.append("http://127.0.0.1:11434")
        raw.append("http://localhost:11434")

        var seen = Set<String>()
        return raw.compactMap(normalize).filter { seen.insert($0).inserted }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.5
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func detect() async -> LocalModelServer? {
        let list = candidates()
        guard !list.isEmpty else { return nil }

        let hits = await withTaskGroup(of: (Int, LocalModelServer?).self) { group -> [Int: LocalModelServer] in
            for (index, candidate) in list.enumerated() {
                group.addTask {
                    (index, try? await probe(candidate))
                }
            }
            var found: [Int: LocalModelServer] = [:]
            for await (index, server) in group {
                if let server { found[index] = server }
            }
            return found
        }
        return list.indices.compactMap { hits[$0] }.first
    }

    /// Explicit probe for the URL typed in the field. Tries Ollama first, then
    /// a generic OpenAI-compatible endpoint, and surfaces a single readable
    /// error instead of whichever URLSession error happened to come last.
    static func probe(_ raw: String) async throws -> LocalModelServer {
        guard let base = normalize(raw) else { throw LocalModelProbeError.invalidURL(raw) }
        if let server = try? await probeOllama(base) { return server }
        if let server = try? await probeOpenAICompatible(base) { return server }
        throw LocalModelProbeError.unreachable(base)
    }

    private static func probeOllama(_ base: String) async throws -> LocalModelServer {
        guard let url = URL(string: base + "/api/tags") else {
            throw LocalModelProbeError.invalidURL(base)
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalModelProbeError.unexpectedResponse(base)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = json["models"] as? [[String: Any]] else {
            throw LocalModelProbeError.unexpectedResponse(base)
        }

        let models = rawModels.compactMap { entry(fromOllama: $0) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return LocalModelServer(baseURL: base, providerID: "ollama",
                                models: models, version: await ollamaVersion(base))
    }

    private static func probeOpenAICompatible(_ base: String) async throws -> LocalModelServer {
        guard let url = URL(string: base + "/v1/models") else {
            throw LocalModelProbeError.invalidURL(base)
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalModelProbeError.unexpectedResponse(base)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            throw LocalModelProbeError.unexpectedResponse(base)
        }

        let models = rows.compactMap { row -> LocalModelEntry? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return LocalModelEntry(id: id, sizeBytes: 0, parameterSize: "", quantization: "")
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return LocalModelServer(baseURL: base, providerID: "local", models: models, version: nil)
    }

    private static func entry(fromOllama row: [String: Any]) -> LocalModelEntry? {
        let name = (row["name"] as? String) ?? (row["model"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let details = row["details"] as? [String: Any]
        return LocalModelEntry(
            id: name,
            sizeBytes: (row["size"] as? NSNumber)?.int64Value ?? 0,
            parameterSize: details?["parameter_size"] as? String ?? "",
            quantization: details?["quantization_level"] as? String ?? ""
        )
    }

    private static func ollamaVersion(_ base: String) async -> String? {
        guard let url = URL(string: base + "/api/version"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }
}

// MARK: - Popup

/// Local-model picker: detects the Ollama server that is actually running,
/// proposes its address, then applies `provider/model` to the chosen agent.
struct LocalModelView: View {
    let agentName: String
    let currentModel: String
    var onClose: () -> Void
    var onApply: (LocalModelServer, LocalModelEntry) -> Void

    private enum Phase: Equatable {
        case detecting
        case ready
        case failed(String)
    }

    @State private var baseURL: String = LocalModelProbe.savedBaseURL
    @State private var server: LocalModelServer?
    @State private var selectedModelID: String = ""
    @State private var phase: Phase = .detecting
    @State private var busy = false

    private var selectedModel: LocalModelEntry? {
        server?.models.first { $0.id == selectedModelID }
    }

    private var targetModelID: String? {
        guard let server, let model = selectedModel else { return nil }
        return "\(server.providerID)/\(model.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            detectionCard
            baseURLRow
            modelSection
            caption
            Spacer(minLength: 0)
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 540)
        .task { await autoDetect() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer").foregroundColor(.secondary)
            Text("Local model — \(agentName)").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var detectionCard: some View {
        HStack(alignment: .top, spacing: 8) {
            switch phase {
            case .detecting:
                ProgressView().controlSize(.small)
                Text("Looking for a running Ollama server…")
                    .font(.caption).foregroundColor(.secondary)
            case .ready:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server?.headline ?? "Connected")
                        .font(.caption).foregroundColor(.primary)
                    if let server, LocalModelProbe.normalize(baseURL) != server.baseURL {
                        Button("Use \(server.baseURL)") { baseURL = server.baseURL }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(.caption).foregroundColor(.secondary)
                    Button("Retry detection") { Task { await autoDetect() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var baseURLRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Base URL").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("http://127.0.0.1:11434", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await probeTypedURL() } }
                Button(busy ? "Testing…" : "Test") { Task { await probeTypedURL() } }
                    .disabled(busy || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Refresh") { Task { await probeTypedURL() } }
                    .disabled(busy || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.caption).foregroundColor(.secondary)
            if let server, !server.models.isEmpty {
                Picker("", selection: $selectedModelID) {
                    Text("Select a model…").tag("")
                    ForEach(server.models) { model in
                        Text(model.detailLabel.isEmpty ? model.id : "\(model.id)  (\(model.detailLabel))")
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(busy)
            } else if server != nil {
                Text("Server reachable, but no model is pulled yet. Pull one first, e.g. `ollama pull qwen3`.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Detection fills this list from the server's own catalog.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let targetModelID {
                Text("\(agentName) → \(targetModelID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("Applying registers this model with BunControl (provider `\(server?.providerID ?? "ollama")`, base URL above) and restarts the engine when needed.")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if !currentModel.isEmpty {
                Text("Current: \(currentModel)")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel", action: onClose)
            Button("Apply to \(agentName)") {
                guard let server, let model = selectedModel else { return }
                UserDefaults.standard.set(server.baseURL, forKey: LocalModelProbe.savedBaseURLKey)
                onApply(server, model)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(server == nil || selectedModel == nil)
        }
    }

    // MARK: Actions

    private func autoDetect() async {
        phase = .detecting
        busy = true
        let found = await LocalModelProbe.detect()
        busy = false

        guard let found else {
            phase = .failed("No Ollama server answered on 127.0.0.1:11434 or localhost:11434. Start Ollama, or type the address below.")
            return
        }
        adopt(found)
        phase = .ready
    }

    private func probeTypedURL() async {
        busy = true
        defer { busy = false }
        do {
            let probed = try await LocalModelProbe.probe(baseURL)
            adopt(probed)
            phase = .ready
        } catch {
            // A failed manual probe keeps the last good catalog visible rather
            // than blanking the picker the user was about to use.
            phase = .failed(error.localizedDescription)
        }
    }

    private func adopt(_ found: LocalModelServer) {
        server = found
        baseURL = found.baseURL
        UserDefaults.standard.set(found.baseURL, forKey: LocalModelProbe.savedBaseURLKey)
        // Keep the currently configured model selected when the server serves
        // it, so reopening the popup is a no-op confirmation.
        if let match = found.models.first(where: { currentModel.hasSuffix($0.id) }) {
            selectedModelID = match.id
        } else if found.models.count == 1 {
            // A single-model server has only one thing to pick: preselect it so
            // Apply is live as soon as detection lands.
            selectedModelID = found.models[0].id
        } else if !found.models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ""
        }
    }
}
