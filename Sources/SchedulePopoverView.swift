import SwiftUI

struct SchedulePopoverView: View {
    let agentName: String
    let manager: SubworkerManager
    var onClose: () -> Void

    enum Mode: String, CaseIterable { case hourly = "Hourly", frequent = "Frequent", cron = "Cron" }

    @State private var mode: Mode = .hourly
    @State private var selectedHours: Set<Int> = []
    @State private var selectedDays: Set<Int> = []
    @State private var minute: Int = 0
    @State private var everyMinutes: Int = 10
    @State private var restrictHours: Bool = false
    @State private var frequentHours: Set<Int> = Set(9...18)
    @State private var cronExpression: String = "*/10 * * * *"
    @State private var initialLoaded = false
    @State private var saving = false
    @State private var saveError: String?

    private let daySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let everyPresets = [5, 10, 15, 20, 30, 45, 60, 120, 240]
    private let minutePresets = [0, 5, 10, 15, 20, 30, 45]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modePicker
            Divider().opacity(0.5)

            switch mode {
            case .hourly: hourlySection
            case .frequent: frequentSection
            case .cron: cronSection
            }

            summaryBar
            if let err = saveError {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { loadCurrent() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let photo = ProfilePhotos.shared.circularPhoto(for: agentName, size: 28) {
                Image(nsImage: photo).resizable().frame(width: 28, height: 28).clipShape(Circle())
            }
            Text("Schedule — \(agentName)").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain)
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Hourly").tag(Mode.hourly)
            Text("Frequent").tag(Mode.frequent)
            Text("Cron").tag(Mode.cron)
        }.pickerStyle(.segmented).labelsHidden()
    }

    private var hourlySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("At minute").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $minute) {
                    ForEach(0..<60, id: \.self) { m in Text(String(format: ":%02d", m)).tag(m) }
                }.frame(width: 96).labelsHidden()
                Text("past the hour").font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(minutePresets, id: \.self) { m in
                    Button(String(format: ":%02d", m)) { minute = m }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .tint(minute == m ? .accentColor : nil)
                }
            }
            dayHoursControls(hours: $selectedHours, days: $selectedDays)
            Text("Hours").font(.caption).foregroundColor(.secondary)
            hourGrid(selection: $selectedHours)
        }
    }

    private var frequentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every").font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(everyPresets, id: \.self) { v in
                    Button(action: { everyMinutes = v }) {
                        Text(labelForEvery(v))
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(everyMinutes == v ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                            .foregroundColor(everyMinutes == v ? .white : .primary)
                            .cornerRadius(6)
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Custom:").font(.caption).foregroundColor(.secondary)
                Stepper(value: $everyMinutes, in: 1...1440, step: 1) {
                    Text("\(everyMinutes) min").font(.caption.monospacedDigit())
                }
                .frame(maxWidth: 160)
                Spacer()
            }
            Toggle("Restrict to hours", isOn: $restrictHours).font(.caption).toggleStyle(.switch).scaleEffect(0.8)
            if restrictHours {
                hourGrid(selection: $frequentHours)
                HStack(spacing: 6) {
                    quickButton("9–18") { frequentHours = Set(9...18) }
                    quickButton("All") { frequentHours = Set(0...23) }
                    quickButton("None") { frequentHours = [] }
                }
            }
            Text("Days").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 4) { ForEach(0..<7, id: \.self) { d in dayChip(d, selection: $selectedDays) } }
            HStack(spacing: 6) {
                presetButton("Every day") { selectedDays = [] }
                presetButton("Weekdays") { selectedDays = [1,2,3,4,5] }
                presetButton("Weekend") { selectedDays = [0,6] }
            }
        }
    }

    private var cronSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cron expression (5 fields: minute hour day month weekday)").font(.caption).foregroundColor(.secondary)
            TextField("*/10 * * * *", text: $cronExpression)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            if !isCronValid { Text("Invalid cron — needs 5 fields, e.g. \"*/15 * * * *\"").font(.caption).foregroundColor(.red) }
            Text("Presets").font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                cronPreset("Every 5m", "*/5 * * * *")
                cronPreset("Every 10m", "*/10 * * * *")
                cronPreset("Every 15m", "*/15 * * * *")
                cronPreset("Every 20m", "*/20 * * * *")
                cronPreset("Every 30m", "*/30 * * * *")
                cronPreset("Every 45m", "0,45 * * * *")
                cronPreset("Hourly :00", "0 * * * *")
                cronPreset("Daily 09:00", "0 9 * * *")
                cronPreset("Weekdays 9:00", "0 9 * * 1-5")
            }
            Text("Tip: presets with weekdays set the last cron field automatically.").font(.caption2).foregroundColor(.secondary)
        }
    }

    private var summaryBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text(summary).font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                if saving { ProgressView().scaleEffect(0.6) }
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
            if let next = nextRunPreview {
                Text("Next: \(next)").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func labelForEvery(_ v: Int) -> String {
        if v < 60 { return "\(v)m" }
        if v == 60 { return "60m" }
        return "\(v/60)h"
    }

    private var isCronValid: Bool {
        let parts = cronExpression.split(separator: " ")
        return parts.count == 5 && !cronExpression.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        if saving { return false }
        switch mode {
        case .hourly: return !selectedHours.isEmpty
        case .frequent:
            if restrictHours && frequentHours.isEmpty { return false }
            return everyMinutes >= 1
        case .cron: return isCronValid
        }
    }

    private var summary: String {
        switch mode {
        case .hourly:
            guard !selectedHours.isEmpty else { return "No hours selected" }
            let hs = selectedHours.sorted()
            let pad = { (v: Int) in String(format: "%02d", v) }
            let hLabel = hs.count == 24 ? "every hour at :\(pad(minute))" : "\(pad(hs.first!)):\(pad(minute)) → \(pad(hs.last!)):\(pad(minute)), \(hs.count)×/day"
            return "\(hLabel) · \(daysLabel)"
        case .frequent:
            let hPart: String
            if restrictHours {
                if frequentHours.isEmpty { hPart = "no hours" }
                else if frequentHours.count == 24 { hPart = "all hours" }
                else { hPart = "\(frequentHours.count) hours" }
            } else { hPart = "all hours" }
            if restrictHours && !frequentHours.isEmpty {
                let est = frequentHours.count * 60 / everyMinutes
                return "Every \(everyMinutes)m · ~\(est)×/day · \(hPart) · \(daysLabel)"
            } else {
                let total = 1440 / everyMinutes
                return "Every \(everyMinutes)m · ~\(total)×/day · \(hPart) · \(daysLabel)"
            }
        case .cron:
            return "Cron: \(cronExpression) · \(daysLabel)"
        }
    }

    private var daysLabel: String {
        if selectedDays.isEmpty { return "every day" }
        if selectedDays == [1,2,3,4,5] { return "weekdays only" }
        if selectedDays == [0,6] { return "weekends only" }
        return selectedDays.sorted().map { daySymbols[$0] }.joined(separator: " ")
    }

    private var nextRunPreview: String? {
        switch mode {
        case .frequent: return "every \(everyMinutes) min\(restrictHours ? " in selected hours" : "")"
        case .hourly:
            guard let h = selectedHours.sorted().first else { return nil }
            return String(format: "next ~%02d:%02d", h, minute)
        case .cron: return cronExpression
        }
    }

    private func dayHoursControls(hours: Binding<Set<Int>>, days: Binding<Set<Int>>) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                presetButton("Every day") { days.wrappedValue = [] }
                presetButton("Weekdays") { days.wrappedValue = [1,2,3,4,5] }
                presetButton("Weekend") { days.wrappedValue = [0,6] }
                Spacer()
                quickButton("9h–18h") { hours.wrappedValue = Set(9...18) }
                quickButton("All") { hours.wrappedValue = Set(0...23) }
                quickButton("None") { hours.wrappedValue = [] }
            }
            Text("Days").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) { ForEach(0..<7, id: \.self) { d in dayChip(d, selection: days) } }
        }
    }

    private func hourGrid(selection: Binding<Set<Int>>) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
            ForEach(0..<24, id: \.self) { h in
                let on = selection.wrappedValue.contains(h)
                Button(action: {
                    if on { selection.wrappedValue.remove(h) } else { selection.wrappedValue.insert(h) }
                }) {
                    Text(String(format: "%02d", h))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
                        .foregroundColor(on ? .white : .primary).cornerRadius(5)
                }.buttonStyle(.plain)
            }
        }
    }

    private func dayChip(_ d: Int, selection: Binding<Set<Int>>) -> some View {
        let on = selection.wrappedValue.contains(d)
        return Button(action: {
            if on { selection.wrappedValue.remove(d) } else { selection.wrappedValue.insert(d) }
        }) {
            Text(daySymbols[d]).font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(on ? Color.accentColor.opacity(0.85) : Color(nsColor: .quaternaryLabelColor))
                .foregroundColor(on ? .white : .secondary).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action() }.controlSize(.small).buttonStyle(.bordered)
    }
    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title) { action() }.controlSize(.small).buttonStyle(.borderless).font(.caption)
    }
    private func cronPreset(_ title: String, _ expr: String) -> some View {
        Button(title) { cronExpression = expr }
            .font(.system(size: 10)).buttonStyle(.bordered).controlSize(.mini)
            .tint(cronExpression == expr ? .accentColor : nil)
    }
    private func loadCurrent() {
        guard !initialLoaded else { return }
        initialLoaded = true
        guard let sw = manager.subworkers.first(where: { $0.name == agentName }) else { return }
        let t = sw.scheduleType ?? "interval"
        if t == "cron", let expr = sw.scheduleExpression, !expr.isEmpty {
            mode = .cron; cronExpression = expr; selectedDays = Set(sw.scheduleDays ?? [])
        } else if t == "every", let every = sw.scheduleEvery {
            mode = .frequent; everyMinutes = every; selectedDays = Set(sw.scheduleDays ?? [])
            if let hs = sw.scheduleHours, !hs.isEmpty { restrictHours = true; frequentHours = Set(hs) }
            else { restrictHours = false }
        } else {
            mode = .hourly; selectedHours = Set(sw.scheduleHours ?? [9]); minute = sw.scheduleMinute ?? 0; selectedDays = Set(sw.scheduleDays ?? [])
        }
    }

    private func save() {
        saving = true; saveError = nil
        let payload: [String: Any]
        switch mode {
        case .hourly:
            let days: [Int]? = selectedDays.isEmpty ? nil : selectedDays.sorted()
            payload = ["schedule": ["type": "interval", "hours": selectedHours.sorted(), "minute": minute, "days": days as Any]]
        case .frequent:
            let days: [Int]? = selectedDays.isEmpty ? nil : selectedDays.sorted()
            var sched: [String: Any] = ["type": "every", "every": everyMinutes]
            if restrictHours { sched["hours"] = frequentHours.sorted() }
            if let d = days { sched["days"] = d } else { sched["days"] = NSNull() }
            payload = ["schedule": sched]
        case .cron:
            payload = ["schedule": ["type": "cron", "expression": cronExpression]]
        }
        guard let url = URL(string: "\(manager.currentBaseURL)/status/\(agentName)") else { saving = false; return }
        var req = EliaAuth.authorize(url)
        req.httpMethod = "PUT"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                saving = false
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    saveError = "Save failed: HTTP \(http.statusCode)"
                    return
                }
                if let error { saveError = error.localizedDescription; return }
                Task { await manager.fetchStatus() }
                onClose()
            }
        }.resume()
    }
}
