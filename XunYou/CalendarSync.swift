import Foundation
import EventKit

/// 系统日历同步：把带计划时间的事项写入 EventKit 的专属「洄游」日历
/// （免费自签 App 可用，不需要 iCloud 权限；日历事件随系统 iCloud 走，等于白捡多端同步）
@MainActor
final class CalendarSync: ObservableObject {
    static let calendarTitle = "洄游"

    /// 是否开启（持久化）
    @Published private(set) var enabled: Bool

    private let store = EKEventStore()
    private var granted = false
    private var calendar: EKCalendar?

    init() {
        enabled = UserDefaults.standard.bool(forKey: "hy_cal_sync")
    }

    private static let key = "hy_cal_sync"

    /// 请求完整日历权限（要能按 id 改/删自己建的事件）
    func enable() async -> Bool {
        if !granted {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        }
        guard granted else { return false }
        calendar = findOrCreate()
        UserDefaults.standard.set(true, forKey: Self.key)
        enabled = true
        return true
    }

    /// 关闭并清掉「洄游」日历（连同名日历一起删，事件不留尸体）
    func disable() {
        if let c = calendar ?? store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) {
            try? store.removeCalendar(c, commit: true)
        }
        calendar = nil
        UserDefaults.standard.set(false, forKey: Self.key)
        enabled = false
    }

    var isReady: Bool { enabled && granted }

    // MARK: - 日历

    private func findOrCreate() -> EKCalendar? {
        if let c = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) { return c }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = Self.calendarTitle
        c.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
        do {
            try store.saveCalendar(c, commit: true)
            return c
        } catch {
            return nil
        }
    }

    // MARK: - 事件增删改（TaskStore 调用）

    /// 新建或更新事项对应的日历事件，回写 eventIdentifier
    func upsert(_ task: inout TaskItem) {
        guard isReady, let due = task.dueDate else { return }
        if let eid = task.eventIdentifier {
            removeEvent(eid)
            task.eventIdentifier = nil
        }
        guard let cal = calendar ?? findOrCreate() else { return }
        let ev = EKEvent(eventStore: store)
        ev.calendar = cal
        ev.title = task.title
        ev.notes = task.notes
        ev.startDate = due
        ev.endDate = due.addingTimeInterval(TimeInterval(max(10, task.durationMinutes ?? 30)) * 60)
        do {
            try store.save(ev, span: .thisEvent)
            task.eventIdentifier = ev.eventIdentifier
        } catch {
            // 保存失败不阻塞主流程
        }
    }

    /// 事项字段变化后刷新（无时间了就撤掉事件）
    func refresh(_ task: inout TaskItem) {
        guard isReady else { return }
        if task.dueDate != nil {
            upsert(&task)
        } else if let eid = task.eventIdentifier {
            removeEvent(eid)
            task.eventIdentifier = nil
        }
    }

    /// 完成 / 重开：事件标题打勾标记
    func setDone(_ task: inout TaskItem) {
        guard isReady, let eid = task.eventIdentifier, let ev = store.event(withIdentifier: eid) else { return }
        ev.title = task.isDone ? "✓ \(task.title)" : task.title
        try? store.save(ev, span: .thisEvent)
    }

    /// 删除事项：连事件一起删
    func remove(_ task: TaskItem) {
        if let eid = task.eventIdentifier { removeEvent(eid) }
    }

    private func removeEvent(_ eid: String) {
        if let ev = store.event(withIdentifier: eid) {
            try? store.remove(ev, span: .thisEvent, commit: true)
        }
    }

    /// 开启时回填：给所有带时间的存量事项补建事件（原地更新 eventIdentifier）
    func backfill(_ tasks: inout [TaskItem]) -> Int {
        guard isReady else { return 0 }
        var n = 0
        for i in tasks.indices where tasks[i].dueDate != nil {
            upsert(&tasks[i])
            if tasks[i].eventIdentifier != nil { n += 1 }
        }
        return n
    }
}
