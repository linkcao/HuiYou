import Foundation
import WatchConnectivity

/// 手表端数据模型：WCSession 接收 iPhone 推送的今日数据，本地缓存兜底
@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var tasks: [WatchTask] = []
    @Published var totalDone = 0
    @Published var streak = 0
    @Published var checkedIn = false

    private static let cacheKey = "hy_watch_cache_v1"

    override init() {
        super.init()
        loadCache()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    // MARK: - 动作（乐观更新 + 通知手机）

    func complete(_ id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        if tasks[i].done { totalDone += 1 } else { totalDone = max(0, totalDone - 1) }
        saveCache()
        send(["complete": id])
    }

    func checkIn() {
        guard !checkedIn else { return }
        checkedIn = true
        streak += 1
        saveCache()
        send(["checkin": true])
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(message) { reply in
                Task { @MainActor in self.apply(reply) }
            }
        }
        // 不可达时：手机端下次唤醒会推 applicationContext 对齐
    }

    // MARK: - 数据应用

    func apply(_ p: [String: Any]) {
        var items: [WatchTask] = []
        if let arr = p["tasks"] as? [[String: Any]] {
            for t in arr {
                items.append(WatchTask(
                    id: t["id"] as? String ?? UUID().uuidString,
                    title: t["title"] as? String ?? "",
                    period: t["period"] as? String ?? "anytime",
                    done: t["done"] as? Bool ?? false,
                    time: t["time"] as? String ?? "",
                    dur: t["dur"] as? Int ?? 0
                ))
            }
        }
        tasks = items
        totalDone = p["totalDone"] as? Int ?? totalDone
        streak = p["streak"] as? Int ?? streak
        checkedIn = p["checkedIn"] as? Bool ?? checkedIn
        saveCache()
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(["request": true]) { reply in
                Task { @MainActor in self.apply(reply) }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    // MARK: - 本地缓存

    private struct Cache: Codable {
        var tasks: [WatchTask]
        var totalDone: Int
        var streak: Int
        var checkedIn: Bool
    }

    private func saveCache() {
        if let d = try? JSONEncoder().encode(Cache(tasks: tasks, totalDone: totalDone, streak: streak, checkedIn: checkedIn)) {
            UserDefaults.standard.set(d, forKey: Self.cacheKey)
        }
    }

    private func loadCache() {
        guard let d = UserDefaults.standard.data(forKey: Self.cacheKey),
              let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        tasks = c.tasks
        totalDone = c.totalDone
        streak = c.streak
        checkedIn = c.checkedIn
    }
}

/// 手表端轻量事项 DTO
struct WatchTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var period: String   // anytime / morning / daytime / evening
    var done: Bool
    var time: String     // "" 或 "HH:mm"
    var dur: Int
}
