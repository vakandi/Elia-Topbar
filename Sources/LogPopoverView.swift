import SwiftUI

struct LogPopoverView: View {
    let subworkerName: String
    let baseURL: String

    @State private var lines: [String] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("📋 Logs: \(subworkerName)")
                    .font(.headline)
                Spacer()
                Button("Refresh") { fetchLogs() }
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading logs…")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(maxWidth: .infinity)
                        } else if let loadError {
                            Text(loadError)
                                .foregroundColor(.red)
                                .padding()
                        } else if lines.isEmpty {
                            Text("No log lines available")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: lines.count) { _ in
                    if !lines.isEmpty {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            fetchLogs()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            fetchLogs(showSpinner: false)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func fetchLogs(showSpinner: Bool = true) {
        guard let url = URL(string: "\(baseURL)/logs/\(subworkerName)?lines=50") else { return }
        if showSpinner { loading = true }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let logLines = json["lines"] as? [String] else {
                    loading = false
                    if lines.isEmpty {
                        loadError = "Could not load logs"
                    }
                    return
                }
                lines = logLines
                loadError = nil
                loading = false
            }
        }.resume()
    }
}
