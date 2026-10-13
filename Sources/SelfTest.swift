import AppKit

/// Headless stress harness, enabled only by `ELIATOPBAR_SELFTEST_CYCLES=<n>`.
///
/// GUI automation cannot reach a LSUIElement status item, so the popup and log
/// viewer cycles are driven through the same entry points the menu uses. This
/// is what makes the overnight leak numbers reproducible instead of asserted.
///
/// It prints observed RSS / thread / log-size at each checkpoint and exits.
enum SelfTest {

    /// Weak holder so a test can prove an object really deallocated instead of
    /// inferring it from a count.
    final class WeakBox {
        weak var value: AnyObject?
        init(_ v: AnyObject?) { value = v }
    }

    static var burst: Int {
        guard let raw = ProcessInfo.processInfo.environment["ELIATOPBAR_SELFTEST_BURST"],
              let n = Int(raw), n > 0 else { return 0 }
        return n
    }

    static var burstRepeats: Int {
        Int(ProcessInfo.processInfo.environment["ELIATOPBAR_SELFTEST_BURSTS"] ?? "") ?? 1
    }

    static var cycleDelay: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["ELIATOPBAR_SELFTEST_DELAY"] ?? "") ?? 0.25
    }

    static var cycles: Int {
        guard let raw = ProcessInfo.processInfo.environment["ELIATOPBAR_SELFTEST_CYCLES"],
              let n = Int(raw), n > 0 else { return 0 }
        return n
    }

    private static func rssBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    private static func threadCount() -> Int {
        var count = mach_msg_type_number_t(0)
        var threads: thread_act_array_t?
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)) }
        return Int(count)
    }

    private static func logSize() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: "/tmp/EliaTopBar.log")[.size] as? Int) ?? 0
    }

    static func report(_ label: String, _ probe: () -> String) {
        let f = Double(rssBytes()) / 1_048_576.0
        print(String(format: "SELFTEST %-28s rss=%.1fMB threads=%d log=%.1fKB %@",
                     (label as NSString).utf8String!, f, threadCount(), Double(logSize()) / 1024.0, probe()))
        fflush(stdout)
    }

    @MainActor
    static func runBurst(count: Int, repeats: Int,
                         openAll: @escaping @MainActor () -> Void,
                         closeAll: @escaping @MainActor () -> Void,
                         probe: @escaping @MainActor () -> String) {
        report("burst start", probe)
        for r in 0..<repeats {
            openAll()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            report("burst \(r+1)/\(repeats) open", probe)
            closeAll()
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            report("burst \(r+1)/\(repeats) closed", probe)
        }
        for s in [10, 30] {
            RunLoop.main.run(until: Date().addingTimeInterval(s == 10 ? 7 : 20))
            report("drain +\(s)s", probe)
        }
        fflush(stdout)
        exit(0)
    }

    /// Runs on the main actor after launch. `open`/`close` are the AppDelegate
    /// closures, injected so this file never touches its private state.
    @MainActor
    static func run(cycles: Int,
                    openPopup: @escaping @MainActor (Int) -> Void,
                    closePopup: @escaping @MainActor () -> Void,
                    openLog: @escaping @MainActor (Int) -> Void,
                    closeLog: @escaping @MainActor () -> Void,
                    probe: @escaping @MainActor () -> String) {

        report("start", probe)
        var burstPeakThreads = 0

        for i in 0..<cycles {
            autoreleasepool {
                openPopup(i)
                burstPeakThreads = max(burstPeakThreads, threadCount())
                closePopup()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(Self.cycleDelay))
            if i % 10 == 0 {
                report("popup cycle \(i)", probe)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        report("after \(cycles) popup cycles", probe)

        for i in 0..<cycles {
            autoreleasepool {
                openLog(i)
                burstPeakThreads = max(burstPeakThreads, threadCount())
                closeLog()
            }
            // Pace like a human clicking, not a tight loop. AppKit allocates a
            // CoreAnimation IOSurface per presentation and reclaims it on a
            // later runloop pass; hammering presentation starves that reclaim.
            RunLoop.main.run(until: Date().addingTimeInterval(Self.cycleDelay))
            if i % 10 == 0 {
                report("logviewer cycle \(i)", probe)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        report("after \(cycles) logviewer cycles", probe)

        // If in-flight fetches are the cause, RSS falls back here. If it is a
        // true leak, it stays flat-high. The difference is the whole question.
        for s in [5, 15, 30] {
            RunLoop.main.run(until: Date().addingTimeInterval(Double(s) - (s == 5 ? 1 : (s == 15 ? 5 : 15))))
            report("drain +\(s)s", probe)
        }

        print("SELFTEST peak threads during cycles: \(burstPeakThreads)")
        report("end", probe)
        fflush(stdout)
        exit(0)
    }
}