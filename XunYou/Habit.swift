import Foundation
import SwiftUI

// MARK: - 习惯

/// 一个要养成的习惯（如「每天锻炼」「每天看书」）。
/// 核心指标是「连续天数」：断了当前连续归零，但历史最佳永不清零。
struct Habit: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// SF Symbol 名
    var icon: String = "target"
    /// 主题色 hex（沿用 TaskCategory 那套，widget 侧也能解析）
    var hex: String = "#338CF2"

    /// 当前阶段的目标天数（21 / 42 / 63 …）
    var goalDays: Int = 21
    /// 已经完成的阶段数，每达成一个 goalDays +1
    var stage: Int = 1

    /// 打卡日期集合，格式 yyyy-MM-dd
    var checkins: [String] = []
    /// 历史最长连续天数，永不清零
    var bestStreak: Int = 0

    var createdAt: Date = Date()

    /// 每日提醒时刻；nil 表示不提醒
    var reminderHour: Int? = nil
    var reminderMinute: Int? = nil

    /// 点「专注」时的默认时长（分钟）
    var defaultMinutes: Int = 25

    /// 给 AI 的补充说明（比如「瑜伽，在家做 20 分钟」）
    var note: String? = nil

    // MARK: 补签额度

    /// 补签额度所属月份（yyyy-MM），跨月自动重置
    var makeupMonth: String = ""
    var makeupUsed: Int = 0

    static let monthlyMakeupQuota = 3

    var hasReminder: Bool { reminderHour != nil && reminderMinute != nil }

    var reminderText: String? {
        guard let h = reminderHour, let m = reminderMinute else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
}

// MARK: - 连续天数算法（纯函数，便于复用与验证）

enum HabitMath {

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func dayKey(_ date: Date = Date()) -> String { fmt.string(from: date) }

    static func monthKey(_ date: Date = Date()) -> String { monthFmt.string(from: date) }

    /// 把 yyyy-MM-dd 解回当天零点
    static func date(fromDayKey key: String) -> Date? { fmt.date(from: key) }

    /// 当前连续天数。
    ///
    /// 末端允许是「今天」或「昨天」：今天还没过完，用户随时可以补上，
    /// 这时候显示 0 会让人误以为断了。两端都不沾才算真断（归零）。
    static func streak(in dayKeys: Set<String>, today: Date = Date()) -> Int {
        let cal = Calendar.current
        var cursor = cal.startOfDay(for: today)

        if !dayKeys.contains(dayKey(cursor)) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  dayKeys.contains(dayKey(yesterday)) else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while dayKeys.contains(dayKey(cursor)) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// 历史最长连续天数（把全部日期排序后扫一遍）
    static func bestStreak(in dayKeys: Set<String>) -> Int {
        let cal = Calendar.current
        let days = dayKeys.compactMap { date(fromDayKey: $0) }
            .map { cal.startOfDay(for: $0) }
            .sorted()
        guard !days.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for i in 1..<days.count {
            let gap = cal.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 0
            if gap == 1 {
                run += 1
                best = max(best, run)
            } else if gap > 1 {
                run = 1
            }
        }
        return best
    }

    /// 最近 n 天（含今天）的打卡情况，返回 (日期, 是否打卡)，用于画圆点
    static func recentDays(_ dayKeys: Set<String>, count: Int = 7, today: Date = Date()) -> [(Date, Bool)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        return (0..<count).reversed().compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: -offset, to: start) else { return nil }
            return (d, dayKeys.contains(dayKey(d)))
        }
    }

    /// 昨天是否可补签（只能补昨天，今天直接打卡就行）
    static func canMakeup(habit: Habit, today: Date = Date()) -> Bool {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: today)) else { return false }
        if habit.checkins.contains(dayKey(yesterday)) { return false }
        if cal.isDate(habit.createdAt, inSameDayAs: today) { return false }   // 今天才建的习惯不需要补签
        return remainingMakeup(habit: habit, today: today) > 0
    }

    static func remainingMakeup(habit: Habit, today: Date = Date()) -> Int {
        let used = habit.makeupMonth == monthKey(today) ? habit.makeupUsed : 0
        return max(0, Habit.monthlyMakeupQuota - used)
    }
}

// MARK: - 习惯配色

enum HabitPalette {
    /// 预设主题色，新建时挑
    static let hexes = ["#338CF2", "#FA6B70", "#735CEB", "#FCAD38", "#33B899", "#8C8C99"]

    /// 图标候选
    static let icons = [
        "figure.run", "book.fill", "drop.fill", "dumbbell.fill", "brain.head.profile",
        "leaf.fill", "bed.double.fill", "fork.knife", "pencil.and.outline", "music.note",
        "sun.max.fill", "heart.fill", "figure.walk", "camera.fill", "paintbrush.fill",
    ]

    static func color(hex: String) -> Color { Color(habitHex: hex) }
}

extension Color {
    /// 习惯用 hex 解析（Live Activity / widget 也共用同一套字符串）
    init(habitHex hex: String) {
        var value: UInt64 = 0
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - 进度

extension Habit {
    var currentStreak: Int { HabitMath.streak(in: Set(checkins)) }

    /// 当前阶段内的进度 0...1。
    /// 阶段用「连续天数」推进：连续达到 goalDays 进入巩固期 1，再达到 2×goalDays 进入巩固期 2……
    var stageProgress: Double {
        let n = currentStreak
        let goal = max(1, goalDays)
        let doneInStage = n - goal * (stage - 1)
        return min(1, max(0, Double(doneInStage) / Double(goal)))
    }

    var currentStageGoal: Int { goalDays * stage }

    /// 阶段名：21 天打底，之后每轮进入下一个巩固期
    var stageLabel: String {
        stage <= 1 ? "养成期" : "巩固期 \(stage - 1)"
    }
}
