import Foundation
import Observation
import AppKit
import UserNotifications

/// Background work shown in the toolbar task capsule, as toasts, and as macOS notifications.
struct ForgeTask: Identifiable {
    enum Kind { case generate, slice, compare, upload, print, download }
    enum State: Equatable { case running, done, failed }

    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var progress: Double?          // nil = indeterminate
    var state: State = .running
    var started = Date()
    var finished: Date?
    var assetID: String?
    var stage: Stage?
    var cancel: (() -> Void)?
    var retry: (() -> Void)?
    /// Label for the retry button ("Retry" when nil).
    var retryTitle: String?
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var assetID: String?
    var stage: Stage?
    var thumb: URL?
    var isError = false
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

@Observable @MainActor
final class TaskCenter {
    var tasks: [ForgeTask] = []
    var toast: Toast?
    private var askedForNotifications = false

    var running: [ForgeTask] { tasks.filter { $0.state == .running } }
    var finished: [ForgeTask] { tasks.filter { $0.state != .running }.sorted { ($0.finished ?? .distantPast) > ($1.finished ?? .distantPast) } }

    @discardableResult
    func start(_ kind: ForgeTask.Kind, title: String, detail: String = "", assetID: String? = nil, stage: Stage? = nil,
               cancel: (() -> Void)? = nil) -> UUID {
        // one running task per kind+asset; replace a stale one
        tasks.removeAll { $0.kind == kind && $0.assetID == assetID && $0.state == .running }
        let t = ForgeTask(kind: kind, title: title, detail: detail, assetID: assetID, stage: stage, cancel: cancel)
        tasks.insert(t, at: 0)
        requestNotificationPermission()
        return t.id
    }

    func update(_ id: UUID, detail: String? = nil, progress: Double? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let detail { tasks[i].detail = detail }
        tasks[i].progress = progress
    }

    /// Marks a task done or failed, then tells the user: a toast when the app is frontmost, a system notification otherwise.
    func finish(_ id: UUID, success: Bool, title: String? = nil, detail: String, thumb: URL? = nil, retry: (() -> Void)? = nil,
                retryTitle: String? = nil) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].state = success ? .done : .failed
        tasks[i].finished = Date()
        tasks[i].detail = detail
        tasks[i].progress = nil
        tasks[i].cancel = nil
        tasks[i].retry = retry
        tasks[i].retryTitle = retryTitle
        if let title { tasks[i].title = title }
        let t = tasks[i]
        announce(title: t.title, detail: detail, assetID: t.assetID, stage: t.stage, thumb: thumb, isError: !success)
        if tasks.count > 30 { tasks.removeLast(tasks.count - 30) }
    }

    func remove(_ id: UUID) { tasks.removeAll { $0.id == id } }
    func clearFinished() { tasks.removeAll { $0.state != .running } }

    func announce(title: String, detail: String, assetID: String? = nil, stage: Stage? = nil, thumb: URL? = nil, isError: Bool = false) {
        if NSApp.isActive {
            let t = Toast(title: title, detail: detail, assetID: assetID, stage: stage, thumb: thumb, isError: isError)
            toast = t
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                if self.toast?.id == t.id { self.toast = nil }
            }
        } else {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = detail
            content.sound = .default
            if let assetID { content.userInfo = ["assetID": assetID, "stage": stage?.rawValue ?? ""] }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func requestNotificationPermission() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
