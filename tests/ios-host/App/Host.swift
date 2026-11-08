import SwiftUI
import UIKit

// The smallest app around the Rust scenarios (src/lib.rs): it calls `ak_host_run` once it is in the foreground and
// shows the lines the scenario reports. The last line, with the identifier `status`, is what the UI test reads.

@_silgen_name("ak_host_run")
func hostRun(_ report: @convention(c) (UnsafePointer<UInt8>?, Int) -> Void)

@_silgen_name("ak_host_entered_background")
func hostEnteredBackground()

@_silgen_name("ak_host_tap_acknowledged")
func hostTapAcknowledged()

/// Watches the taps that a button's intent posts (`ActionPost`) and tells Rust when one's acknowledgement completes:
/// the intent returns at its next check, at most 100 ms later.
enum TapWatch {
    private static let lock = NSLock()
    private static var watched = Set<ObjectIdentifier>()
    private static var observer: NSObjectProtocol?

    static func start() {
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("activitykit.action"), object: nil, queue: nil) { note in
            guard let acknowledgement = note.userInfo?["acknowledgement"] as? Progress else { return }
            lock.lock()
            let new = watched.insert(ObjectIdentifier(acknowledgement)).inserted
            lock.unlock()
            guard new else { return }
            DispatchQueue.global().async {
                while !acknowledgement.isFinished { usleep(5_000) }
                hostTapAcknowledged()
            }
        }
    }
}

final class Report: ObservableObject {
    static let shared = Report()
    @Published var lines: [String] = []
}

private let reportLine: @convention(c) (UnsafePointer<UInt8>?, Int) -> Void = { bytes, count in
    guard let bytes else { return }
    let line = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    DispatchQueue.main.async {
        Report.shared.lines.append(line)
        // The scenario is over: the UI test, which cannot see the app while it is in the background, hears it by a
        // Darwin notification, and the app may be suspended.
        if line.hasPrefix("PASS") || line.hasPrefix("FAIL") {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("dev.activitykit.host.finished" as CFString), nil, nil, true)
            MainActor.assumeIsolated { Background.end() }
        }
    }
}

@main
struct HostApp: App {
    @StateObject private var report = Report.shared

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(report.lines.last ?? "launching").font(.headline).accessibilityIdentifier("status")
                ForEach(Array(report.lines.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                Spacer()
            }
            .padding()
            .task { await runWhenActive() }
            // Keep running for a while in the background, so a scenario can act there.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                Background.begin()
                hostEnteredBackground()
            }
        }
    }

    /// An activity starts only in the foreground, which a launching app may not be yet.
    @MainActor private func runWhenActive() async {
        TapWatch.start()
        for _ in 0..<50 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        hostRun(reportLine)
    }
}

/// A background task that keeps the app running for the system's grace period.
@MainActor
enum Background {
    private static var task = UIBackgroundTaskIdentifier.invalid

    static func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask { end() }
    }

    static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
