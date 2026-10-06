import Foundation
import UserNotifications

/// 本地通知：习惯到点提醒。
///
/// 免费开发者账号也能用本地通知（不依赖 APNs / push 证书），
/// 比 Routine 那套「打开 App 才补跑」及时得多。
@MainActor
final class NotificationManager: ObservableObject {

    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    private let center = UNUserNotificationCenter.current()

    /// 通知调度是 App 级能力，多处（习惯编辑、AI 工具）都可能触发重建，用单例最省事
    static let shared = NotificationManager()

    private static let prefix = "habit-"
    private static let routinePrefix = "routine-"

    /// 例程提醒一次预约未来多少天（每次回到前台滚动补足）
    private static let routineHorizonDays = 7

    private static func identifier(_ habitId: UUID) -> String {
        "\(prefix)\(habitId.uuidString)"
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private init() {
        // 故意不在 init 里碰通知中心：App 启动关键路径上少碰系统 API，
        // 状态改为按需查询（refreshStatus / sync 里做）
    }

    // MARK: - 授权

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
            denied = false
        case .denied:
            authorized = false
            denied = true
        default:
            authorized = false
            denied = false
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshStatus()
            return granted
        } catch {
            await refreshStatus()
            return false
        }
    }

    // MARK: - 同步

    /// 按当前习惯列表重建全部提醒（新建 / 修改 / 删除后调用）
    func sync(_ habits: [Habit]) async {
        // 没授权就直接跳过：既没必要重建提醒，也避免启动早期调用系统通知 API
        if !authorized {
            await refreshStatus()
        }
        guard authorized else { return }

        let pending = await center.pendingNotificationRequests()
        let wanted = Set(habits.filter(\.hasReminder).map { Self.identifier($0.id) })
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !wanted.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for habit in habits {
            await schedule(habit)
        }
    }

    /// 单个习惯的每日提醒
    func schedule(_ habit: Habit) async {
        let id = Self.identifier(habit.id)
        center.removePendingNotificationRequests(withIdentifiers: [id])

        guard let hour = habit.reminderHour, let minute = habit.reminderMinute else { return }

        let content = UNMutableNotificationContent()
        content.title = "该「\(habit.name)」了"
        if let note = habit.note, !note.isEmpty {
            content.body = note
        } else {
            let streak = habit.currentStreak
            content.body = streak > 0
                ? "已经连续 \(streak) 天，今天别断了"
                : "完成后来打个卡，开始你的连续记录"
        }
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        try? await center.add(request)
    }

    func cancel(_ habitId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(habitId)])
    }

    // MARK: - 例程提醒

    /// 重建例程提醒：滚动预约未来几天的一次性通知。
    ///
    /// 为什么不用 `repeats: true`：例程「今天已经执行/跳过」就不该再响，
    /// 而重复触发器没法按天跳过。一次性通知 + 每次前台重算窗口，
    /// 既能精确跳过已完成的日子，也只要一周内打开过一次 App 就不会断。
    func syncRoutines(_ routines: [Routine], runs: [RoutineRun] = [], now: Date = Date()) async {
        if !authorized {
            await refreshStatus()
        }
        guard authorized else { return }

        let pending = await center.pendingNotificationRequests()
        let existing = Set(pending.map(\.identifier))
        let cal = Calendar.current
        let active = routines.filter(\.enabled)
        // 系统对每个 App 的待发通知有上限（64），按例程数量收窄预约天数
        let horizon = max(1, min(Self.routineHorizonDays, 60 / max(1, active.count)))

        var planned: [(identifier: String, routine: Routine, fireDate: Date)] = []
        for r in active {
            for offset in 0..<horizon {
                guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)),
                      let fire = cal.date(bySettingHour: max(0, min(23, r.hour)),
                                          minute: max(0, min(59, r.minute)),
                                          second: 0, of: day),
                      fire > now else { continue }
                let key = Self.dayKey(fire)
                // 那天已经执行或跳过了，就别提醒
                guard !runs.contains(where: { $0.routineId == r.id && $0.dayKey == key }) else { continue }
                planned.append(("\(Self.routinePrefix)\(r.id.uuidString)-\(key)", r, fire))
            }
        }

        let wanted = Set(planned.map(\.identifier))
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(Self.routinePrefix) && !wanted.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        for p in planned where !existing.contains(p.identifier) {
            await scheduleRoutine(p.routine, identifier: p.identifier, fireDate: p.fireDate)
        }
    }

    /// 单个例程的一次提醒
    private func scheduleRoutine(_ routine: Routine, identifier: String, fireDate: Date) async {
        let content = UNMutableNotificationContent()
        content.title = "⏰ 例程「\(routine.name)」到点了"
        content.body = "打开洄游点一下「开始」，让 AI 帮你安排今天。"
        content.sound = .default
        content.userInfo = ["routineId": routine.id.uuidString]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        try? await center.add(request)
    }

    /// 例程被删除 / 停用时清掉它的全部提醒
    func cancelRoutine(_ routineId: UUID) {
        let prefix = "\(Self.routinePrefix)\(routineId.uuidString)"
        Task {
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    // MARK: - 测试

    /// 5 秒后发一条，用来验证授权与展示是否正常
    func sendTest(_ habit: Habit) async {
        let content = UNMutableNotificationContent()
        content.title = "该「\(habit.name)」了"
        content.body = "这是一条测试提醒，看到说明通知没问题 👍"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(Self.prefix)test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        try? await center.add(request)
    }
}
