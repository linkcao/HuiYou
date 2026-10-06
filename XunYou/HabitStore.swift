import Foundation

// MARK: - 专注会话

/// 一次习惯专注：够钟后自动打卡。
/// App 可能被切到后台，所以会话要落盘，回前台时结算。
struct HabitFocusSession: Codable, Hashable, Identifiable {
    var habitId: UUID
    var endDate: Date
    var id: UUID { habitId }
}

struct HabitData: Codable {
    var habits: [Habit] = []
    var pendingSessions: [HabitFocusSession] = []
}

// MARK: - 存储

/// 习惯存储：单文件 JSON 持久化，风格与 TaskStore / LifeStore 保持一致
@MainActor
final class HabitStore: ObservableObject {

    @Published var data: HabitData {
        didSet {
            save()
            onDidChange?()
        }
    }

    /// 数据变化回调（接 WatchBridge）
    var onDidChange: (() -> Void)?

    /// 习惯「增删改」时触发（用于重建本地通知提醒），打卡不算结构变化
    var onHabitsChanged: (() -> Void)?

    /// 自动打卡后的提示文案（UI 消费一次后置空）
    @Published var autoCheckInToast: String?

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("huiyou_habits.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(HabitData.self, from: raw) {
            data = decoded
        } else {
            data = HabitData()
        }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }

    // MARK: - 查询

    var habits: [Habit] { data.habits }

    var isEmpty: Bool { data.habits.isEmpty }

    var checkedTodayCount: Int {
        data.habits.filter { $0.checkins.contains(HabitMath.dayKey()) }.count
    }

    var longestRunningStreak: Int {
        data.habits.map { HabitMath.streak(in: Set($0.checkins)) }.max() ?? 0
    }

    func habit(_ id: UUID) -> Habit? { data.habits.first { $0.id == id } }

    private func index(of id: UUID) -> Int? { data.habits.firstIndex { $0.id == id } }

    func streak(_ id: UUID) -> Int {
        guard let h = habit(id) else { return 0 }
        return HabitMath.streak(in: Set(h.checkins))
    }

    func isCheckedToday(_ id: UUID) -> Bool {
        habit(id)?.checkins.contains(HabitMath.dayKey()) ?? false
    }

    /// 今日已打卡的习惯名（给 AI 用）
    var todayCheckedNames: [String] {
        data.habits.filter { $0.checkins.contains(HabitMath.dayKey()) }.map(\.name)
    }

    /// 今日还没打卡的习惯名（给 AI 用）
    var todayMissingNames: [String] {
        data.habits.filter { !$0.checkins.contains(HabitMath.dayKey()) }.map(\.name)
    }

    func recentDays(_ id: UUID, count: Int = 7) -> [(Date, Bool)] {
        guard let h = habit(id) else { return [] }
        return HabitMath.recentDays(Set(h.checkins), count: count)
    }

    func remainingMakeup(_ id: UUID) -> Int {
        guard let h = habit(id) else { return 0 }
        return HabitMath.remainingMakeup(habit: h)
    }

    func canMakeup(_ id: UUID) -> Bool {
        guard let h = habit(id) else { return false }
        return HabitMath.canMakeup(habit: h)
    }

    // MARK: - 打卡

    @discardableResult
    func checkIn(_ id: UUID, on day: Date = Date()) -> Bool {
        guard let i = index(of: id) else { return false }
        let key = HabitMath.dayKey(day)
        guard !data.habits[i].checkins.contains(key) else { return false }
        data.habits[i].checkins.append(key)
        trimIfNeeded(at: i)
        refreshStats(at: i)
        return true
    }

    /// 撤销打卡（今天点错了）
    @discardableResult
    func undoCheckIn(_ id: UUID, on day: Date = Date()) -> Bool {
        guard let i = index(of: id) else { return false }
        let key = HabitMath.dayKey(day)
        guard let pos = data.habits[i].checkins.firstIndex(of: key) else { return false }
        data.habits[i].checkins.remove(at: pos)
        refreshStats(at: i)
        return true
    }

    func toggleToday(_ id: UUID) {
        if isCheckedToday(id) {
            let _ = undoCheckIn(id)
        } else {
            let _ = checkIn(id)
        }
    }

    /// 补签昨天（每月有限额，避免因为「忘了点」而不是「没做到」断掉）
    @discardableResult
    func makeup(_ id: UUID) -> Bool {
        guard let i = index(of: id) else { return false }
        guard HabitMath.canMakeup(habit: data.habits[i]) else { return false }

        let month = HabitMath.monthKey()
        if data.habits[i].makeupMonth != month {
            data.habits[i].makeupMonth = month
            data.habits[i].makeupUsed = 0
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return false }
        let key = HabitMath.dayKey(yesterday)
        guard !data.habits[i].checkins.contains(key) else { return false }

        data.habits[i].checkins.append(key)
        data.habits[i].makeupUsed += 1
        refreshStats(at: i)
        return true
    }

    /// 每天只需要留最近两年多的记录，避免数组无限膨胀
    private func trimIfNeeded(at i: Int) {
        if data.habits[i].checkins.count > 800 {
            data.habits[i].checkins = Array(data.habits[i].checkins.suffix(800))
        }
    }

    /// 重算派生字段：历史最佳只增不减，阶段按当前连续天数推进
    private func refreshStats(at i: Int) {
        let set = Set(data.habits[i].checkins)
        data.habits[i].bestStreak = max(data.habits[i].bestStreak, HabitMath.bestStreak(in: set))
        let current = HabitMath.streak(in: set)
        let goal = max(1, data.habits[i].goalDays)
        data.habits[i].stage = max(1, current / goal + 1)
    }

    // MARK: - 增删改

    @discardableResult
    func add(name: String,
             icon: String = "target",
             hex: String = "#338CF2",
             goalDays: Int = 21,
             reminderHour: Int? = nil,
             reminderMinute: Int? = nil,
             defaultMinutes: Int = 25,
             note: String? = nil) -> Habit? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = Habit(
            name: trimmed,
            icon: icon,
            hex: hex,
            goalDays: max(1, min(365, goalDays)),
            reminderHour: reminderHour.map { max(0, min(23, $0)) },
            reminderMinute: reminderMinute.map { max(0, min(59, $0)) },
            defaultMinutes: max(5, min(240, defaultMinutes)),
            note: (cleanNote?.isEmpty ?? true) ? nil : cleanNote
        )
        data.habits.append(h)
        onHabitsChanged?()
        return h
    }

    /// 编辑保存。打卡记录、历史最佳、补签额度这些累计字段不会被覆盖。
    func update(_ habit: Habit) {
        guard let i = index(of: habit.id) else { return }
        var merged = habit
        merged.name = habit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        merged.goalDays = max(1, min(365, habit.goalDays))
        merged.defaultMinutes = max(5, min(240, habit.defaultMinutes))
        merged.checkins = data.habits[i].checkins
        merged.bestStreak = data.habits[i].bestStreak
        merged.stage = data.habits[i].stage
        merged.createdAt = data.habits[i].createdAt
        merged.makeupMonth = data.habits[i].makeupMonth
        merged.makeupUsed = data.habits[i].makeupUsed
        data.habits[i] = merged
        refreshStats(at: i)
        onHabitsChanged?()
    }

    func delete(_ id: UUID) {
        data.habits.removeAll { $0.id == id }
        data.pendingSessions.removeAll { $0.habitId == id }
        onHabitsChanged?()
    }

    func move(from source: IndexSet, to destination: Int) {
        data.habits.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - 备份 / 恢复

    var snapshot: HabitData { data }

    func replaceAll(_ incoming: HabitData) {
        data = incoming
        onHabitsChanged?()
    }

    /// 合并恢复：习惯按 id 去重，同名习惯的打卡记录取并集，历史最佳取高
    func mergeIn(_ incoming: HabitData) {
        var merged = data
        let known = Set(merged.habits.map(\.id))
        merged.habits.append(contentsOf: incoming.habits.filter { !known.contains($0.id) })

        for i in merged.habits.indices {
            guard let other = incoming.habits.first(where: { $0.id == merged.habits[i].id }) else { continue }
            let union = Set(merged.habits[i].checkins).union(other.checkins)
            merged.habits[i].checkins = union.sorted()
            merged.habits[i].bestStreak = max(merged.habits[i].bestStreak, other.bestStreak)
        }

        let knownSessions = Set(merged.pendingSessions.map(\.habitId))
        merged.pendingSessions.append(contentsOf: incoming.pendingSessions.filter { !knownSessions.contains($0.habitId) })

        data = merged
        onHabitsChanged?()
    }

    // MARK: - 专注会话

    var hasPendingFocus: Bool { !data.pendingSessions.isEmpty }

    func isFocusing(_ id: UUID) -> Bool {
        data.pendingSessions.contains { $0.habitId == id }
    }

    func beginFocus(habitId: UUID, minutes: Int) {
        let end = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
        data.pendingSessions.removeAll { $0.habitId == habitId }
        data.pendingSessions.append(HabitFocusSession(habitId: habitId, endDate: end))
    }

    func cancelFocus(habitId: UUID) {
        data.pendingSessions.removeAll { $0.habitId == habitId }
    }

    func cancelAllFocus() {
        data.pendingSessions.removeAll()
    }

    /// 结算已到点的专注会话 → 自动打卡。返回这次被自动打卡的习惯（用于提示）。
    @discardableResult
    func settleFocusSessions(now: Date = Date()) -> [Habit] {
        let due = data.pendingSessions.filter { $0.endDate <= now }
        guard !due.isEmpty else { return [] }

        var checked: [Habit] = []
        for session in due {
            if checkIn(session.habitId, on: session.endDate), let h = habit(session.habitId) {
                checked.append(h)
            }
        }
        data.pendingSessions.removeAll { $0.endDate <= now }
        if let name = checked.first?.name {
            autoCheckInToast = name
        }
        return checked
    }
}
