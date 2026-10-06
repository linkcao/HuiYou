import Foundation
import SwiftUI

// MARK: - 数据快照

/// 全量数据快照：既能导出成文件，也会在每次数据变化后自动存进系统钥匙串。
///
/// 为什么用钥匙串兜底：事项 / 习惯 / 例程 / 对话都存在沙盒 Documents 里，
/// **删掉 App 就一起没了**；而钥匙串条目在删除 App 后仍留在系统中
/// （API Key 一直没丢就是这个原因）。所以重装后能靠这份快照问用户一句「要不要恢复」。
struct BackupPayload: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()
    var tasks: [TaskItem] = []
    var life: LifeData = LifeData()
    var habits: HabitData = HabitData()
    var chat: [ChatMessage] = []

    /// 完全没有内容（用来判断「这是新装的 App」）
    var isEmpty: Bool {
        tasks.isEmpty
            && habits.habits.isEmpty
            && life.routines.isEmpty
            && life.checkins.isEmpty
            && life.selfExpectation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chat.isEmpty
    }

    /// 给用户看的人话摘要
    var summary: String {
        var parts: [String] = []
        if !tasks.isEmpty {
            let todo = tasks.filter { !$0.isDone && $0.isScheduled }.count
            parts.append("\(tasks.count) 条事项（待办 \(todo)）")
        }
        if !habits.habits.isEmpty { parts.append("\(habits.habits.count) 个习惯") }
        if !life.routines.isEmpty { parts.append("\(life.routines.count) 个例程") }
        if !life.checkins.isEmpty { parts.append("\(life.checkins.count) 天签到") }
        if !chat.isEmpty { parts.append("\(chat.count) 条对话") }
        return parts.isEmpty ? "（这份备份是空的）" : parts.joined(separator: "、")
    }

    /// 存钥匙串时收一收：聊天记录只留最近若干条，别让条目太大
    func trimmedForSnapshot(chatLimit: Int = 60) -> BackupPayload {
        guard chat.count > chatLimit else { return self }
        var copy = self
        copy.chat = Array(chat.suffix(chatLimit))
        return copy
    }
}

extension BackupPayload: Identifiable {
    var id: String { String(exportedAt.timeIntervalSince1970) }
}

/// 恢复方式
enum RestoreMode {
    /// 覆盖现在的数据
    case replace
    /// 只补本地没有的（按 id 去重）
    case merge
}

// MARK: - 编解码 + 钥匙串

enum Backup {
    /// 钥匙串里那份自动快照的 key
    static let keychainKey = "recovery_snapshot"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// 钥匙串用紧凑格式（省地方）
    private static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func encode(_ payload: BackupPayload) throws -> Data { try encoder.encode(payload) }

    static func decode(_ data: Data) throws -> BackupPayload { try decoder.decode(BackupPayload.self, from: data) }

    /// 生成一份可分享的备份文件，返回文件 URL
    static func exportFile(_ payload: BackupPayload) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("XunYouBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("洄游备份-\(fileStamp(payload.exportedAt)).json")
        try encode(payload).write(to: url, options: .atomic)
        return url
    }

    /// 读取用户选中的备份文件（fileImporter 给的是安全作用域 URL）
    static func read(from url: URL) throws -> BackupPayload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try decode(try Data(contentsOf: url))
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: date)
    }

    static func readableStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    // MARK: 钥匙串快照

    static func saveSnapshot(_ payload: BackupPayload) {
        guard let data = try? compactEncoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return }
        Keychain.set(text, forKey: keychainKey)
    }

    static func loadSnapshot() -> BackupPayload? {
        guard let text = Keychain.get(keychainKey),
              let data = text.data(using: .utf8) else { return nil }
        return try? decode(data)
    }

    static func clearSnapshot() {
        Keychain.delete(keychainKey)
    }
}

// MARK: - 自动快照器

/// 任何数据变化后合并 3 秒写一次钥匙串。
///
/// 刻意「本地为空时不写」：删掉 App 重装时本地是空的，
/// 这时写入会把还没恢复的旧快照覆盖掉，机会就没了。
@MainActor
final class BackupMirror: ObservableObject {
    static let shared = BackupMirror()

    @Published private(set) var lastMirrorDate: Date?
    @Published private(set) var lastSummary: String = ""

    private weak var tasks: TaskStore?
    private weak var life: LifeStore?
    private weak var habits: HabitStore?
    private weak var chat: ChatViewModel?
    private var scheduled = false

    private init() {
        if let snap = Backup.loadSnapshot() {
            lastMirrorDate = snap.exportedAt
            lastSummary = snap.summary
        }
    }

    /// 由 App 启动时注入四个 Store（各 Store 的 onDidChange 里调 schedule()）
    func configure(tasks: TaskStore, life: LifeStore, habits: HabitStore, chat: ChatViewModel) {
        self.tasks = tasks
        self.life = life
        self.habits = habits
        self.chat = chat
    }

    /// 数据变了：合并 3 秒写一次，别每敲一个字都动钥匙串
    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.scheduled = false
            self.mirrorNow()
        }
    }

    func currentPayload() -> BackupPayload {
        BackupPayload(exportedAt: Date(),
                      tasks: tasks?.snapshot ?? [],
                      life: life?.data ?? LifeData(),
                      habits: habits?.data ?? HabitData(),
                      chat: chat?.snapshot ?? [])
    }

    func mirrorNow() {
        let payload = currentPayload()
        guard !payload.isEmpty else { return }
        let trimmed = payload.trimmedForSnapshot()
        Backup.saveSnapshot(trimmed)
        lastMirrorDate = trimmed.exportedAt
        lastSummary = trimmed.summary
    }

    /// 本地啥都没有、钥匙串里却有快照 → 大概率是「删了 App 重装」，该问一句要不要恢复
    func pendingRestoreSnapshot() -> BackupPayload? {
        guard currentPayload().isEmpty else { return nil }
        guard let snap = Backup.loadSnapshot(), !snap.isEmpty else { return nil }
        return snap
    }

    /// 应用一份快照
    func apply(_ payload: BackupPayload, mode: RestoreMode) {
        guard let tasks, let life, let habits, let chat else { return }

        switch mode {
        case .replace:
            tasks.replaceAll(payload.tasks)
            life.replaceAll(payload.life)
            habits.replaceAll(payload.habits)
            chat.replaceAll(payload.chat)
        case .merge:
            tasks.mergeIn(payload.tasks)
            life.mergeIn(payload.life)
            habits.mergeIn(payload.habits)
            chat.mergeIn(payload.chat)
        }

        // 恢复后把本地通知与日历同步补回来
        let habitList = habits.habits
        let routines = life.data.routines
        let runs = life.data.routineRuns
        Task {
            await NotificationManager.shared.sync(habitList)
            await NotificationManager.shared.syncRoutines(routines, runs: runs)
        }

        mirrorNow()
    }
}
