import Foundation
import WatchConnectivity

/// iPhone → Apple Watch 数据桥：
/// 事项/签到一有变化就推 applicationContext；手表打勾/签到通过 sendMessage 回传
@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    private var store: TaskStore?
    private var life: LifeStore?

    func configure(store: TaskStore, life: LifeStore) {
        self.store = store
        self.life = life
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    // MARK: - 数据快照

    private func payload() -> [String: Any] {
        var items: [[String: Any]] = []
        for t in store?.tasks(forDay: Date()) ?? [] {
            items.append([
                "id": t.id.uuidString,
                "title": t.title,
                "period": t.effectivePeriod.rawValue,
                "done": t.isDone,
                "time": t.dueDate.map(TaskDate.time) ?? "",
                "dur": t.durationMinutes ?? 0,
            ])
        }
        return [
            "tasks": items,
            "totalDone": store?.totalDoneCount ?? 0,
            "streak": life?.streak ?? 0,
            "checkedIn": life?.checkedInToday ?? false,
            "ts": Date().timeIntervalSince1970,
        ]
    }

    private func pushNow() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        try? s.updateApplicationContext(payload())
    }

    /// 数据变化时调用（线程安全，内部跳主队列）
    nonisolated func push() {
        Task { @MainActor in self.pushNow() }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if activationState == .activated { self.pushNow() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 手表发来的消息：打勾完成 / 签到 / 请求数据
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            if let idStr = message["complete"] as? String, let id = UUID(uuidString: idStr) {
                let _ = self.store?.complete(id: id)
            }
            if message["checkin"] != nil {
                let _ = self.life?.checkIn()
            }
            replyHandler(self.payload())
            self.pushNow()
        }
    }
}
