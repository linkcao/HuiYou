import Foundation

// MARK: - 每日例程

/// 每日例程：到点由「本地通知」提醒，用户一键确认就开始执行。
/// 每次执行都落一条 RoutineRun，真实的开始 / 结束时间会喂给 AI，
/// 下次规划时就能参考你的真实作息（而不是只看计划时刻）。
struct Routine: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String                // 如「晨间规划」
    var prompt: String              // 发给 AI 的指令，如「帮我生成今天的安排」
    var hour: Int                   // 计划时刻
    var minute: Int
    /// 停用后不再提醒、也不出现在今日例程里
    var enabled: Bool = true
    /// 最近一次执行的归属日 yyyy-MM-dd（一天只跑一次）
    var lastRunDay: String? = nil

    init(id: UUID = UUID(), name: String, prompt: String, hour: Int, minute: Int,
         enabled: Bool = true, lastRunDay: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.hour = hour
        self.minute = minute
        self.enabled = enabled
        self.lastRunDay = lastRunDay
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, hour, minute, enabled, lastRunDay
    }

    /// 自定义解码：老数据没有 enabled 字段，缺省视为启用。
    /// 不写这段的话，加了新字段会让整份 LifeData 解码失败 → 用户数据被清空。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? "帮我生成今天的安排"
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastRunDay = try c.decodeIfPresent(String.self, forKey: .lastRunDay)
    }

    /// HH:mm
    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

// MARK: - 例程执行记录

/// 一次例程执行：计划时刻 + 真实开始 / 结束时刻。
/// 跳过（今天不做）也会记一条，skipped = true。
struct RoutineRun: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var routineId: UUID
    /// 归属日 yyyy-MM-dd
    var dayKey: String
    /// 当天的计划时刻
    var plannedAt: Date
    /// 真实开始时刻
    var startedAt: Date
    /// 真实结束时刻（nil = 进行中）
    var finishedAt: Date? = nil
    /// 今天主动跳过
    var skipped: Bool = false

    /// 实际用时（分钟）
    var durationMinutes: Int? {
        guard let finishedAt else { return nil }
        return max(0, Int(finishedAt.timeIntervalSince(startedAt) / 60))
    }

    /// 实际开始相对计划的偏移（秒，正数 = 比计划晚，负数 = 提前）
    var startOffset: TimeInterval { startedAt.timeIntervalSince(plannedAt) }
}

/// 例程今天的执行状态
enum RoutineStatus: Equatable {
    /// 还没到点
    case pending(plannedAt: Date)
    /// 到点了还没开始
    case due(plannedAt: Date)
    /// 已经开始、还没结束
    case running(startedAt: Date)
    /// 今天已完成（带真实开始 / 结束时间）
    case done(run: RoutineRun)
    /// 今天主动跳过
    case skipped
}

/// 最近一段时间的执行统计（给 UI 和 AI 用）
struct RoutineStats {
    var count: Int
    /// 实际开始相对计划的平均偏移（分钟，正 = 比计划晚）
    var averageOffsetMinutes: Int
    /// 平均用时（分钟）
    var averageDurationMinutes: Int?
}

// MARK: - 生活数据

/// 生活数据：自我要求、签到记录、每日例程与执行记录（单文件持久化）
struct LifeData: Codable {
    var selfExpectation: String = ""            // 用户对自己的要求/偏好，供 AI 规划参考
    var checkins: [String] = []                 // 已签到日期 yyyy-MM-dd
    var routines: [Routine] = []
    /// 例程执行记录（含真实开始 / 结束时间），保留最近若干条
    var routineRuns: [RoutineRun] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case selfExpectation, checkins, routines, routineRuns
    }

    /// 自定义解码：逐字段 decodeIfPresent，保证加字段不会让老数据整份失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selfExpectation = try c.decodeIfPresent(String.self, forKey: .selfExpectation) ?? ""
        checkins = try c.decodeIfPresent([String].self, forKey: .checkins) ?? []
        routines = try c.decodeIfPresent([Routine].self, forKey: .routines) ?? []
        routineRuns = try c.decodeIfPresent([RoutineRun].self, forKey: .routineRuns) ?? []
    }
}

@MainActor
final class LifeStore: ObservableObject {
    @Published var data: LifeData {
        didSet {
            save()
            onDidChange?()
        }
    }

    /// 数据变化回调（接 WatchBridge，把签到/鱼数推给手表）
    var onDidChange: (() -> Void)?

    /// 例程结构或执行状态变化时触发（用于重建本地通知提醒）
    var onRoutinesChanged: (() -> Void)?

    private let fileURL: URL

    /// 执行记录保留上限，避免文件无限膨胀
    private static let maxRuns = 400

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("huiyou_life.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LifeData.self, from: raw) {
            data = decoded
        } else {
            data = LifeData()
        }
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: fileURL, options: .atomic)
    }

    // MARK: - 日期 key

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - 签到

    var checkedInToday: Bool { data.checkins.contains(Self.dayKey()) }

    /// 连续签到天数（含今天或昨天为末端）。
    /// 算法与习惯养成共用，见 HabitMath.streak。
    var streak: Int {
        HabitMath.streak(in: Set(data.checkins))
    }

    @discardableResult
    func checkIn() -> Bool {
        let key = Self.dayKey()
        guard !data.checkins.contains(key) else { return false }
        data.checkins.append(key)
        return true
    }

    // MARK: - 对自己的要求

    func setSelfExpectation(_ text: String) {
        data.selfExpectation = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把自由文本拆成一条条要求（AI 的 set_expectation 是按换行追加的）
    static func splitExpectations(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 结构化后的要求列表（设置页按条展示 / 删除）
    var expectations: [String] { Self.splitExpectations(data.selfExpectation) }

    /// 追加一条要求，重复的忽略。返回是否真的加上了
    @discardableResult
    func addExpectation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var list = expectations
        guard !list.contains(t) else { return false }
        list.append(t)
        setSelfExpectation(list.joined(separator: "\n"))
        return true
    }

    func removeExpectation(at index: Int) {
        var list = expectations
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        setSelfExpectation(list.joined(separator: "\n"))
    }

    func updateExpectation(at index: Int, to text: String) {
        var list = expectations
        guard list.indices.contains(index) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        list[index] = t
        setSelfExpectation(list.joined(separator: "\n"))
    }

    // MARK: - 备份 / 恢复

    /// 覆盖恢复
    func replaceAll(_ incoming: LifeData) {
        data = incoming
        onRoutinesChanged?()
    }

    /// 合并恢复：例程 / 执行记录按 id 去重，签到取并集，自我要求本地没写才带过来
    func mergeIn(_ incoming: LifeData) {
        var merged = data

        let knownRoutines = Set(merged.routines.map(\.id))
        merged.routines.append(contentsOf: incoming.routines.filter { !knownRoutines.contains($0.id) })

        merged.checkins = Array(Set(merged.checkins).union(incoming.checkins)).sorted()

        let knownRuns = Set(merged.routineRuns.map(\.id))
        merged.routineRuns.append(contentsOf: incoming.routineRuns.filter { !knownRuns.contains($0.id) })
        trimRuns()

        if merged.selfExpectation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.selfExpectation = incoming.selfExpectation
        }

        data = merged
        onRoutinesChanged?()
    }

    // MARK: - 例程：查询

    /// 启用中的例程（停用的不提醒、不进今日例程）
    var activeRoutines: [Routine] { data.routines.filter(\.enabled) }

    /// 今日例程（按计划时刻排序）
    var todayRoutines: [Routine] {
        activeRoutines.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// 某个例程在某天的计划时刻
    func plannedDate(for r: Routine, on day: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        return cal.date(bySettingHour: max(0, min(23, r.hour)),
                        minute: max(0, min(59, r.minute)),
                        second: 0, of: start) ?? start
    }

    /// 某个例程某天的那条执行记录
    func run(for routineId: UUID, on day: Date = Date()) -> RoutineRun? {
        let key = Self.dayKey(day)
        return data.routineRuns
            .filter { $0.routineId == routineId && $0.dayKey == key }
            .max { $0.startedAt < $1.startedAt }
    }

    /// 今天正在进行的那次执行（有开始时间、还没结束、未跳过）
    func runningRun(now: Date = Date()) -> RoutineRun? {
        let key = Self.dayKey(now)
        return data.routineRuns.first { $0.dayKey == key && $0.finishedAt == nil && !$0.skipped }
    }

    /// 今天的状态
    func status(of r: Routine, now: Date = Date()) -> RoutineStatus {
        let planned = plannedDate(for: r, on: now)
        if let run = run(for: r.id, on: now) {
            if run.skipped { return .skipped }
            if run.finishedAt == nil { return .running(startedAt: run.startedAt) }
            return .done(run: run)
        }
        return now >= planned ? .due(plannedAt: planned) : .pending(plannedAt: planned)
    }

    /// 今天已到点、还没执行（也没跳过）的例程
    func dueRoutines(now: Date = Date()) -> [Routine] {
        todayRoutines.filter { r in
            if case .due = status(of: r, now: now) { return true }
            return false
        }
    }

    /// 最近 n 天的真实执行记录（不含跳过），新的在前
    func recentRuns(_ routineId: UUID, days: Int = 14, now: Date = Date()) -> [RoutineRun] {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: now)) ?? now
        return data.routineRuns
            .filter { $0.routineId == routineId && !$0.skipped && $0.startedAt >= from }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// 最近一次真实执行（不含跳过）
    func latestRun(_ routineId: UUID) -> RoutineRun? {
        data.routineRuns
            .filter { $0.routineId == routineId && !$0.skipped }
            .max { $0.startedAt < $1.startedAt }
    }

    /// 最近一段时间的执行统计：平均比计划早/晚多少、平均用时
    func stats(for routineId: UUID, days: Int = 7, now: Date = Date()) -> RoutineStats? {
        let runs = recentRuns(routineId, days: days, now: now)
        guard !runs.isEmpty else { return nil }
        let offsets = runs.map { Int(($0.startOffset / 60).rounded()) }
        let avgOffset = offsets.reduce(0, +) / offsets.count
        let durations = runs.compactMap(\.durationMinutes)
        let avgDuration = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
        return RoutineStats(count: runs.count,
                            averageOffsetMinutes: avgOffset,
                            averageDurationMinutes: avgDuration)
    }

    // MARK: - 例程：动作

    /// 开始执行：写下真实的开始时刻。同一天重复点返回已有那条（已结束 / 已跳过的返回 nil）
    @discardableResult
    func startRoutine(_ id: UUID, now: Date = Date()) -> RoutineRun? {
        guard let i = data.routines.firstIndex(where: { $0.id == id }) else { return nil }
        if let existing = run(for: id, on: now) {
            guard existing.finishedAt == nil, !existing.skipped else { return nil }
            return existing
        }
        let r = data.routines[i]
        let run = RoutineRun(routineId: id,
                             dayKey: Self.dayKey(now),
                             plannedAt: plannedDate(for: r, on: now),
                             startedAt: now)
        data.routineRuns.append(run)
        data.routines[i].lastRunDay = run.dayKey
        trimRuns()
        onRoutinesChanged?()
        return run
    }

    /// 写下真实的结束时刻（AI 回复完成时自动调用，也可以手动提前结束）
    func finishRoutineRun(_ runId: UUID, now: Date = Date()) {
        guard let i = data.routineRuns.firstIndex(where: { $0.id == runId }),
              data.routineRuns[i].finishedAt == nil else { return }
        data.routineRuns[i].finishedAt = now
        onRoutinesChanged?()
    }

    /// 手动结束某个例程今天正在进行的那次执行（提前收尾）
    @discardableResult
    func finishRunningRoutine(_ id: UUID, now: Date = Date()) -> RoutineRun? {
        guard let active = run(for: id, on: now), active.finishedAt == nil, !active.skipped else { return nil }
        finishRoutineRun(active.id, now: now)
        return data.routineRuns.first { $0.id == active.id }
    }

    /// 今天不做
    @discardableResult
    func skipRoutine(_ id: UUID, on day: Date = Date(), now: Date = Date()) -> Bool {
        guard let i = data.routines.firstIndex(where: { $0.id == id }) else { return false }
        let key = Self.dayKey(day)
        if let existing = run(for: id, on: day),
           let pos = data.routineRuns.firstIndex(where: { $0.id == existing.id }) {
            data.routineRuns[pos].skipped = true
            data.routineRuns[pos].finishedAt = now
        } else {
            let r = data.routines[i]
            data.routineRuns.append(RoutineRun(routineId: id,
                                               dayKey: key,
                                               plannedAt: plannedDate(for: r, on: day),
                                               startedAt: now,
                                               finishedAt: now,
                                               skipped: true))
        }
        data.routines[i].lastRunDay = key
        trimRuns()
        onRoutinesChanged?()
        return true
    }

    /// 撤销今天的执行记录（跳过 / 已完成 → 回到待执行）
    @discardableResult
    func clearTodayRun(_ id: UUID, on day: Date = Date()) -> Bool {
        let key = Self.dayKey(day)
        let before = data.routineRuns.count
        data.routineRuns.removeAll { $0.routineId == id && $0.dayKey == key }
        if let i = data.routines.firstIndex(where: { $0.id == id }), data.routines[i].lastRunDay == key {
            data.routines[i].lastRunDay = nil
        }
        guard data.routineRuns.count != before else { return false }
        onRoutinesChanged?()
        return true
    }

    // MARK: - 例程：增删改

    @discardableResult
    func addRoutine(name: String, prompt: String, hour: Int, minute: Int) -> Routine {
        let r = Routine(name: name,
                        prompt: prompt,
                        hour: max(0, min(23, hour)),
                        minute: max(0, min(59, minute)))
        data.routines.append(r)
        onRoutinesChanged?()
        return r
    }

    /// 改例程（时间 / 名字 / 指令 / 启停）。传 nil 的字段保持不变
    @discardableResult
    func updateRoutine(_ id: UUID,
                       name: String? = nil,
                       prompt: String? = nil,
                       hour: Int? = nil,
                       minute: Int? = nil,
                       enabled: Bool? = nil) -> Routine? {
        guard let i = data.routines.firstIndex(where: { $0.id == id }) else { return nil }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data.routines[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data.routines[i].prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let hour { data.routines[i].hour = max(0, min(23, hour)) }
        if let minute { data.routines[i].minute = max(0, min(59, minute)) }
        if let enabled { data.routines[i].enabled = enabled }
        onRoutinesChanged?()
        return data.routines[i]
    }

    func toggleRoutine(_ id: UUID) {
        guard let i = data.routines.firstIndex(where: { $0.id == id }) else { return }
        data.routines[i].enabled.toggle()
        onRoutinesChanged?()
    }

    func deleteRoutine(_ id: UUID) {
        data.routines.removeAll { $0.id == id }
        data.routineRuns.removeAll { $0.routineId == id }
        onRoutinesChanged?()
    }

    // MARK: - 私有

    private func trimRuns() {
        if data.routineRuns.count > Self.maxRuns {
            data.routineRuns = Array(data.routineRuns.suffix(Self.maxRuns))
        }
    }
}
