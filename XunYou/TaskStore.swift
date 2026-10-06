import Foundation

/// 今天可以拿出来问用户的候选，附上「为什么现在提它」
struct SurfaceCandidate: Identifiable {
    enum Reason {
        /// 逾期很久——该确认是不是其实不做了
        case staleOverdue
        /// 在池子里躺很久了——该决定排期还是归档
        case stalePool
        /// 池子里的新条目——可以问要不要今天做
        case freshPool
    }

    let item: TaskItem
    let reason: Reason
    /// 逾期天数或躺了几天，随 reason 而定
    let days: Int

    var id: UUID { item.id }
}

/// 事项存储：JSON 文件持久化，免去 SwiftData / CloudKit 依赖（自签 App 拿不到 iCloud 权限）
@MainActor
final class TaskStore: ObservableObject {

    /// 搁置多久算「躺太久了」，该确认是不是其实不做了。
    /// 会话侧的主动询问和页面上的提示都共用这一个阈值。
    static let staleDays = 14
    @Published private(set) var tasks: [TaskItem] = [] {
        didSet {
            save()
            onDidChange?()
        }
    }

    /// 数据变化回调（App 启动时接 WatchBridge 推送手表）
    var onDidChange: (() -> Void)?

    private let fileURL: URL
    /// 系统日历同步（App 启动时注入，nil = 未启用）
    var calendarSync: CalendarSync?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("huiyou_tasks.json")
        load()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) else { return }
        tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - CRUD

    @discardableResult
    func add(title: String, notes: String? = nil, dueDate: Date? = nil, isDone: Bool = false,
             category: TaskCategory = .other, durationMinutes: Int? = nil,
             period: DayPeriod? = nil, groupId: UUID? = nil,
             isSomeday: Bool = false) -> TaskItem {
        var t = TaskItem(title: title, notes: notes, dueDate: dueDate,
                         category: category, durationMinutes: durationMinutes)
        t.isDone = isDone
        t.doneAt = isDone ? Date() : nil
        t.period = period
        t.groupId = groupId
        t.isSomeday = isSomeday
        tasks.insert(t, at: 0)
        // 池子里的东西还没排期，不需要写进系统日历
        if !isSomeday { calendarSync?.upsert(&tasks[0]) }
        return tasks[0]
    }

    /// 批量添加（AI 生成计划 / 拆解任务用），返回新建的事项
    @discardableResult
    func addBatch(_ items: [TaskItem]) -> [TaskItem] {
        tasks.insert(contentsOf: items, at: 0)
        if let sync = calendarSync {
            for i in 0..<min(items.count, tasks.count) { sync.upsert(&tasks[i]) }
        }
        return items
    }

    /// 开启日历同步后回填存量事项
    func calendarBackfill(_ sync: CalendarSync) -> Int {
        var n = 0
        for i in tasks.indices {
            sync.upsert(&tasks[i])
            if tasks[i].eventIdentifier != nil { n += 1 }
        }
        return n
    }

    @discardableResult
    func complete(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isDone else { return false }
        tasks[i].isDone = true
        tasks[i].doneAt = Date()
        calendarSync?.setDone(&tasks[i])
        return true
    }

    @discardableResult
    func reopen(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].isDone else { return false }
        tasks[i].isDone = false
        tasks[i].doneAt = nil
        calendarSync?.setDone(&tasks[i])
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        calendarSync?.remove(tasks[i])
        tasks.remove(at: i)
        return true
    }

    @discardableResult
    func update(id: UUID, title: String? = nil, notes: String? = nil, dueDate: Date? = nil, status: String? = nil,
                category: TaskCategory? = nil, durationMinutes: Int? = nil) -> TaskItem? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        if let title, !title.isEmpty { tasks[i].title = title }
        if let notes { tasks[i].notes = notes }
        if let dueDate { tasks[i].dueDate = dueDate }
        if let category { tasks[i].category = category }
        if let durationMinutes { tasks[i].durationMinutes = max(5, durationMinutes) }
        if status == "done" {
            tasks[i].isDone = true
            tasks[i].doneAt = Date()
        } else if status == "todo" {
            tasks[i].isDone = false
            tasks[i].doneAt = nil
        }
        calendarSync?.refresh(&tasks[i])
        return tasks[i]
    }

    func list(filter: String) -> [TaskItem] {
        let live = tasks.filter { $0.archivedAt == nil }
        switch filter {
        case "todo":   return live.filter { !$0.isDone && !$0.isSomeday }
        case "done":   return live.filter { $0.isDone }
        case "inbox":  return live.filter { $0.isInInbox }
        default:       return live
        }
    }

    // MARK: - 今天视图查询

    /// 某天该看到的事项：
    /// - dueDate 落在这一天的
    /// - 没有时间的待办（挂在「随时」）
    /// 池子里的（isSomeday）和已归档的一律不出现。
    func tasks(forDay day: Date) -> [TaskItem] {
        let c = Calendar.current
        return tasks.filter { t in
            guard t.isScheduled else { return false }   // 池子里 / 已归档的不进今天
            if let due = t.dueDate { return c.isDate(due, inSameDayAs: day) }
            return !t.isDone                            // 无时间：未完成的挂在「随时」
        }
    }

    /// 逾期未完成：dueDate 早于今天零点、未完成、不在池子、未归档。
    /// 这就是子弹日记里的「延续」——昨天没做完的，今天继续挂着。
    func overdueItems(now: Date = Date()) -> [TaskItem] {
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        return tasks
            .filter { t in
                guard let due = t.dueDate else { return false }
                return !t.isDone && t.isScheduled && c.startOfDay(for: due) < today
            }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    // MARK: - 池子（子弹日记的随手记）

    /// 池子里的条目，最早丢进去的排最前（先处理躺得最久的）
    var inbox: [TaskItem] {
        tasks.filter(\.isInInbox).sorted { $0.createdAt < $1.createdAt }
    }

    var inboxCount: Int { inbox.count }

    var archivedItems: [TaskItem] {
        tasks.filter { $0.archivedAt != nil }.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// 把池子里的条目排到某天（清掉搁置状态，写进日历）
    @discardableResult
    func promote(id: UUID, to day: Date? = nil, period: DayPeriod? = nil) -> TaskItem? {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        tasks[i].isSomeday = false
        tasks[i].archivedAt = nil
        tasks[i].snoozedUntil = nil
        if let day {
            tasks[i].dueDate = day
            tasks[i].period = period ?? tasks[i].period
        }
        calendarSync?.upsert(&tasks[i])
        return tasks[i]
    }

    /// 放回池子（今天不做，但别丢）
    @discardableResult
    func shelve(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[i].isSomeday = true
        tasks[i].dueDate = nil
        tasks[i].period = nil
        tasks[i].snoozedUntil = nil
        calendarSync?.remove(tasks[i])
        return true
    }

    /// 归档：从池子移出但保留记录。池子里的东西永不自动删除。
    @discardableResult
    func archive(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[i].archivedAt = Date()
        calendarSync?.remove(tasks[i])
        return true
    }

    @discardableResult
    func restore(id: UUID) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[i].archivedAt = nil
        return true
    }

    /// 「今天先别提」：静默若干天
    func snooze(id: UUID, days: Int = 7) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].snoozedUntil = Calendar.current.date(byAdding: .day, value: max(1, days), to: Date())
    }

    /// 挑出今天可以拿出来问用户的候选。
    ///
    /// 优先级：逾期很久的 > 池子里躺很久的 > 池子里的新条目。
    /// 去抖：每天最多浮一次——一旦今天已经浮过，就不再注入，
    /// 免得同一批东西在每次对话里反复出现惹人烦。
    func takeSurfaceCandidates(limit: Int = 3, staleDays: Int = TaskStore.staleDays, now: Date = Date()) -> [SurfaceCandidate] {
        let c = Calendar.current
        let today = c.startOfDay(for: now)

        let alreadySurfacedToday = tasks.contains { t in
            guard let s = t.surfacedAt else { return false }
            return c.isDate(s, inSameDayAs: today)
        }
        guard !alreadySurfacedToday else { return [] }

        var candidates: [SurfaceCandidate] = []

        // 1) 逾期很久 —— 最该问「是不是其实不做了」
        candidates += overdueItems(now: now)
            .filter { $0.overdueDays(now: now) >= staleDays }
            .sorted { $0.overdueDays(now: now) > $1.overdueDays(now: now) }
            .map { SurfaceCandidate(item: $0, reason: .staleOverdue, days: $0.overdueDays(now: now)) }

        // 2) 在池子里躺很久了 —— 该决定排期还是归档
        let pool = inbox
        candidates += pool
            .filter { daysInPool($0, now: now) >= staleDays }
            .sorted { daysInPool($0, now: now) > daysInPool($1, now: now) }
            .map { SurfaceCandidate(item: $0, reason: .stalePool, days: daysInPool($0, now: now)) }

        // 3) 池子里的新条目
        candidates += pool
            .filter { daysInPool($0, now: now) < staleDays }
            .map { SurfaceCandidate(item: $0, reason: .freshPool, days: daysInPool($0, now: now)) }

        // 静默期的排到最后（但保留：沉默不该等于永远消失）
        let active = candidates.filter { cand in
            guard let until = cand.item.snoozedUntil else { return true }
            return until <= now
        }
        let muted = candidates.filter { cand in
            guard let until = cand.item.snoozedUntil else { return false }
            return until > now
        }

        let picked = Array((active + muted).prefix(limit))
        guard !picked.isEmpty else { return [] }

        let ids = Set(picked.map(\.item.id))
        for i in tasks.indices where ids.contains(tasks[i].id) {
            tasks[i].surfacedAt = now
        }
        return picked
    }

    /// 按 id 取一条事项
    func task(id: UUID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    /// 躺了多少天（池子条目用）
    func daysInPool(_ item: TaskItem, now: Date = Date()) -> Int {
        let c = Calendar.current
        let from = c.startOfDay(for: item.createdAt)
        let to = c.startOfDay(for: now)
        return max(0, c.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    func dayDoneCount(_ day: Date) -> Int {
        let c = Calendar.current
        return tasks.filter { $0.isDone && $0.doneAt.map { c.isDate($0, inSameDayAs: day) } == true }.count
    }

    // MARK: - 备份 / 恢复

    var snapshot: [TaskItem] { tasks }

    /// 覆盖恢复
    func replaceAll(_ items: [TaskItem]) {
        tasks = items
        resyncCalendar()
    }

    /// 合并恢复：只补本地没有的（按 id 去重）
    func mergeIn(_ items: [TaskItem]) {
        let known = Set(tasks.map(\.id))
        let extra = items.filter { !known.contains($0.id) }
        guard !extra.isEmpty else { return }
        tasks.append(contentsOf: extra)
        resyncCalendar()
    }

    /// 恢复后把系统日历补回来
    private func resyncCalendar() {
        guard let sync = calendarSync, sync.enabled else { return }
        _ = calendarBackfill(sync)
    }

    var totalDoneCount: Int { tasks.filter(\.isDone).count }

    /// 最近完成的 n 条（AI 回顾历史用）
    func recentDone(_ n: Int = 15) -> [TaskItem] {
        tasks.filter(\.isDone)
            .sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
            .prefix(n)
            .map { $0 }
    }
}
