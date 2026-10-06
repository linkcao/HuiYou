import Foundation
import SwiftUI

// MARK: - 事项分类（Tiimo 风格彩色系统）

enum TaskCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case life      // 生活
    case health    // 健康
    case study     // 学习
    case fun       // 娱乐
    case social    // 社交
    case other     // 其他

    var id: String { rawValue }

    var label: String {
        switch self {
        case .life: return "生活"
        case .health: return "健康"
        case .study: return "学习"
        case .fun: return "娱乐"
        case .social: return "社交"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .life: return "house.fill"
        case .health: return "heart.fill"
        case .study: return "book.fill"
        case .fun: return "gamecontroller.fill"
        case .social: return "person.2.fill"
        case .other: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .life: return Color(red: 0.20, green: 0.55, blue: 0.95)   // 蓝
        case .health: return Color(red: 0.98, green: 0.42, blue: 0.44)  // 珊瑚红
        case .study: return Color(red: 0.45, green: 0.36, blue: 0.92)   // 紫
        case .fun: return Color(red: 0.99, green: 0.68, blue: 0.22)     // 橙黄
        case .social: return Color(red: 0.20, green: 0.72, blue: 0.60)  // 青绿
        case .other: return Color(red: 0.55, green: 0.55, blue: 0.60)   // 灰
        }
    }

    /// Live Activity 用：widget extension 无法引用 App target 的 Color 定义，传 hex 过去解析
    var hex: String {
        switch self {
        case .life: return "#338CF2"
        case .health: return "#FA6B70"
        case .study: return "#735CEB"
        case .fun: return "#FCAD38"
        case .social: return "#33B899"
        case .other: return "#8C8C99"
        }
    }

    /// 模型工具参数说明用
    static let schemaDescription = "life=生活琐事, health=运动健康, study=学习成长, fun=娱乐放松, social=社交联络, other=其他"
}

// MARK: - 一天中的时段（参考 Tiimo 分段日程）

enum DayPeriod: String, Codable, CaseIterable, Identifiable, Hashable {
    case anytime  // 随时
    case morning  // 上午
    case daytime  // 白天
    case evening  // 晚上

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anytime: return "随时"
        case .morning: return "上午"
        case .daytime: return "白天"
        case .evening: return "晚上"
        }
    }

    var icon: String {
        switch self {
        case .anytime: return "clock.fill"
        case .morning: return "sun.and.horizon.fill"
        case .daytime: return "sun.max.fill"
        case .evening: return "moon.stars.fill"
        }
    }

    var color: Color {
        switch self {
        case .anytime: return Color(red: 0.45, green: 0.45, blue: 0.52)
        case .morning: return Color(red: 0.72, green: 0.73, blue: 0.35)
        case .daytime: return Color(red: 0.47, green: 0.36, blue: 0.75)
        case .evening: return Color(red: 0.25, green: 0.28, blue: 0.55)
        }
    }

    /// 按小时推断所属时段
    static func forHour(_ hour: Int) -> DayPeriod {
        switch hour {
        case 5..<12: return .morning
        case 12..<18: return .daytime
        case 18..<24, 0..<5: return .evening
        default: return .anytime
        }
    }

    static func forDate(_ d: Date?) -> DayPeriod? {
        guard let d else { return nil }
        return forHour(Calendar.current.component(.hour, from: d))
    }

    static let schemaDescription = "anytime=随时都行, morning=上午, daytime=白天, evening=晚上"
}

// MARK: - 事项

struct TaskItem: Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var notes: String?
    var dueDate: Date?
    var isDone: Bool = false
    var doneAt: Date?
    var createdAt: Date = Date()
    var category: TaskCategory = .other
    /// 预计时长（分钟），Tiimo 式时间块
    var durationMinutes: Int? = nil
    /// 所属时段（nil = 按 dueDate 小时推断，无时间则归"随时"）
    var period: DayPeriod? = nil
    /// 拆解任务分组 id：同一个大任务拆出的子任务共享
    var groupId: UUID? = nil
    /// 系统日历事件 id（开启日历同步后回写）
    var eventIdentifier: String? = nil

    // MARK: 池子（子弹日记的「随手记」）

    /// 搁置在池子里：不急、未必今天做，但不该丢。不进「今天」视图。
    var isSomeday: Bool = false
    /// 归档时间：从池子移出但**保留记录**。池子里的东西永不自动删除，只能归档。
    var archivedAt: Date? = nil
    /// 最近一次被 AI 拿出来讨论的日期（防止反复催同一件事）
    var surfacedAt: Date? = nil
    /// 手动「先别提」的静默截止日
    var snoozedUntil: Date? = nil
}

// 自定义解码：老数据（v1/v2 无 period/groupId，v3 无池子字段）也能读
extension TaskItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, notes, dueDate, isDone, doneAt, createdAt, category, durationMinutes, period, groupId, eventIdentifier
        case isSomeday, archivedAt, surfacedAt, snoozedUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        category = try c.decodeIfPresent(TaskCategory.self, forKey: .category) ?? .other
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        period = try c.decodeIfPresent(DayPeriod.self, forKey: .period)
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        eventIdentifier = try c.decodeIfPresent(String.self, forKey: .eventIdentifier)
        isSomeday = try c.decodeIfPresent(Bool.self, forKey: .isSomeday) ?? false
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        surfacedAt = try c.decodeIfPresent(Date.self, forKey: .surfacedAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    }
}

/// 事项在时间轴上的有效时段：显式 period 优先，否则按时间推断
extension TaskItem {
    var effectivePeriod: DayPeriod {
        period ?? DayPeriod.forDate(dueDate) ?? .anytime
    }

    /// 是否正躺在池子里（搁置 + 未完成 + 未归档）
    var isInInbox: Bool { isSomeday && !isDone && archivedAt == nil }

    /// 是否属于正常排期（不在池子、未归档）
    var isScheduled: Bool { !isSomeday && archivedAt == nil }

    /// 逾期天数：dueDate 早于今天零点且未完成时，返回正整数
    func overdueDays(now: Date = Date()) -> Int {
        guard !isDone, isScheduled, let due = dueDate else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dueDay = cal.startOfDay(for: due)
        guard dueDay < today else { return 0 }
        return cal.dateComponents([.day], from: dueDay, to: today).day ?? 0
    }
}

// MARK: - 聊天消息

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// hidden = true 的 assistant 消息是带 tool_calls 的中间产物，不在 UI 显示，仅用于重建上下文
struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: MessageRole
    var content: String
    var toolCalls: [WireToolCall]? = nil
    var toolCallId: String? = nil
    var toolName: String? = nil
    /// 工具入参（原始 JSON 字符串），供展开查看
    var toolArgs: String? = nil
    /// 工具返回给模型的原始内容，供展开查看
    var toolOutput: String? = nil
    var hidden: Bool = false
    /// 出错提示气泡（UI 会配一个「重试」入口）
    var isError: Bool = false

    init(id: UUID = UUID(), role: MessageRole, content: String,
         toolCalls: [WireToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil,
         toolArgs: String? = nil, toolOutput: String? = nil,
         hidden: Bool = false, isError: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolOutput = toolOutput
        self.hidden = hidden
        self.isError = isError
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, toolCalls, toolCallId, toolName, toolArgs, toolOutput, hidden, isError
    }

    /// 自定义解码：加字段不能让老对话记录整份失效（否则历史对话会被清空）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(MessageRole.self, forKey: .role) ?? .assistant
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try c.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolArgs = try c.decodeIfPresent(String.self, forKey: .toolArgs)
        toolOutput = try c.decodeIfPresent(String.self, forKey: .toolOutput)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    /// UI 是否需要渲染这条消息。
    /// 隐藏的中间产物如果带文字（模型先说话再调工具）仍要显示，
    /// 而没有文字的消息一律不渲染 —— 否则会出现空白气泡。
    var isVisible: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 日期工具

enum TaskDate {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return dayFormatter.date(from: t) ?? minuteFormatter.date(from: t)
    }

    static func format(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "今天" }
        if c.isDateInTomorrow(d) { return "明天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) {
            f.dateFormat = "M月d日"
        } else {
            f.dateFormat = "yyyy年M月d日"
        }
        return f.string(from: d)
    }

    /// HH:mm
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
