import SwiftUI

/// Full schedule editor for one subworker — mirrors ui_electron's schedule-picker.
/// Saves via PUT /status/{name} { schedule: { type: "interval", hours, minute, days } }.
struct SchedulePopoverView: View {
    let agentName: String
    let manager: SubworkerManager
    var onClose: () -> Void

    @State private var selectedHours: Set<Int> = []
    @State private var selectedDays: Set<Int> = []
    @State private var minute: Int = 0
    @State private var initialLoaded = false
    @State private var saving = false
    @State private var saveError: String?

    private let daySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let photo = ProfilePhotos.shared.circularPhoto(for: agentName, size: 28) {
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                }
                Text("Schedule — \(agentName)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $minute) {
                Text(":00").tag(0)
                Text(":15").tag(15)
                Text(":30").tag(30)
                Text(":45").tag(45)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                presetButton("Every day") { selectedDays = [] }
                presetButton("Weekdays") { selectedDays = [1, 2, 3, 4, 5] }
                presetButton("Weekend") { selectedDays = [0, 6] }
                Spacer()
                quickButton("9h–18h") { selectedHours = Set(9...18) }
                quickButton("All") { selectedHours = Set(0...23) }
                quickButton("None") { selectedHours = [] }
            }

            Text("Days")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { d in
                    dayChip(d)
                }
            }

            Text("Hours")
                .font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    hourCell(h)
                }
            }

            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if saving { ProgressView().scaleEffect(0.6) }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || selectedHours.isEmpty)
            }
            if let err = saveError {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { loadCurrent() }
    }

    private var summary: String {
        guard !selectedHours.isEmpty else { return "No hours selected" }
        let hs = selectedHours.sorted()
        let pad = { (v: Int) in String(format: "%02d", v) }
        let hLabel: String
        if hs.count == 24 {
            hLabel = "every hour at :\(pad(minute))"
        } else {
            hLabel = "\(pad(hs.first!)):#\(pad(minute)) → \(pad(hs.last!)):#\(pad(minute)), \(hs.count)×/day"
        }
        let dLabel: String
        if selectedDays.isEmpty { dLabel = "every day" }
        else if selectedDays == [1, 2, 3, 4, 5] { dLabel = "weekdays only" }
        else if selectedDays == [0, 6] { dLabel = "weekends only" }
        else { dLabel = selectedDays.sorted().map { daySymbols[$0] }.joined(separator: " ") }
        return "\(hLabel) · \(dLabel)"
    }

    private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action() }
            .controlSize(.small)
            .buttonStyle(.bordered)
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action() }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .font(.caption)
    }

    private func dayChip(_ d: Int) -> some View {
        let on = selectedDays.contains(d)
        return Button(action: { toggleDay(d) }) {
            Text(daySymbols[d])
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(on ? Color.accentColor.opacity(0.85) : Color(nsColor: .quaternaryLabelColor))
                .foregroundColor(on ? .white : .secondary)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func hourCell(_ h: Int) -> some View {
        let on = selectedHours.contains(h)
        return Button(action: { toggleHour(h) }) {
            Text(String(format: "%02d", h))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                .foregroundColor(on ? .white : .primary)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func toggleDay(_ d: Int) {
        if selectedDays.contains(d) { selectedDays.remove(d) } else { selectedDays.insert(d) }
    }

    private func toggleHour(_ h: Int) {
        if selectedHours.contains(h) { selectedHours.remove(h) } else { selectedHours.insert(h) }
    }

    private func loadCurrent() {
        guard !initialLoaded else { return }
        initialLoaded = true
        guard let sw = manager.subworkers.first(where: { $0.name == agentName }) else { return }
        selectedHours = Set(sw.scheduleHours ?? [9])
        minute = sw.scheduleMinute ?? 0
        selectedDays = Set(sw.scheduleDays ?? [])
    }

    private func save() {
        saving = true
        saveError = nil
        let days: [Int]? = selectedDays.isEmpty ? nil : selectedDays.sorted()
        let payload: [String: Any] = [
            "schedule": [
                "type": "interval",
                "hours": selectedHours.sorted(),
                "minute": minute,
                "days": days as Any,
            ]
        ]
        guard let url = URL(string: "\(manager.currentBaseURL)/status/\(agentName)") else {
            saving = false
            return
        }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                saving = false
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    saveError = "Save failed: HTTP \(http.statusCode)"
                    return
                }
                if let error {
                    saveError = error.localizedDescription
                    return
                }
                Task { await manager.fetchStatus() }
                onClose()
            }
        }.resume()
    }
}
