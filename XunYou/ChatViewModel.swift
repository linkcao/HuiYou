import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isThinking = false
    /// loading 文案：正在想 / 正在执行某个工具
    @Published var statusText: String = "洄游中…"
    /// 这一轮是什么时候开始的（UI 用来显示「已等 N 秒」）
    @Published var thinkingStartedAt: Date?
    /// 流式输出中、还没落进消息列表的文字 —— 边生成边显示，不用干等
    @Published var liveReply: String = ""

    private let agent: Agent
    private let chatFileURL: URL
    private static let maxStoredMessages = 200

    /// 例程触发的那一轮对话结束后回调：把真实的完成时间写回例程执行记录
    var onRoutineTurnFinished: ((UUID) -> Void)?
    /// 数据变化（备份快照用）
    var onDidChange: (() -> Void)?

    /// 正在等待回复的例程执行 id（nil = 普通对话）
    private var pendingRoutineRunId: UUID?
    /// 失败那一轮的例程执行 id：重试时接着用，例程先不算完成
    private var retryRoutineRunId: UUID?

    init(taskStore: TaskStore, lifeStore: LifeStore, habitStore: HabitStore) {
        agent = Agent(taskStore: taskStore, lifeStore: lifeStore, habitStore: habitStore)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        chatFileURL = docs.appendingPathComponent("huiyou_chat.json")
        // 把「现在在干嘛」透给 UI，别让用户盯着一个静止的页面等
        agent.onProgress = { [weak self] text in
            self?.statusText = text
        }
        // 模型的流式输出：先搁在 liveReply 里实时显示，一轮结束后再正式落进消息列表
        agent.onStreamDelta = { [weak self] text in
            self?.liveReply += text
        }
        load()
    }

    // MARK: - 发送

    func send() {
        send(input)
    }

    /// 发送指定文本（预置问题 / 例程触发用）
    func send(_ text: String) {
        send(text, routineRunId: nil)
    }

    /// 例程触发：带上这次执行记录的 id，回复完成后回写真实结束时间
    func send(_ text: String, routineRunId: UUID?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking else { return }
        input = ""
        pendingRoutineRunId = routineRunId
        messages.append(ChatMessage(role: .user, content: t))
        persist()
        beginTurn()
        Task { await run() }
    }

    /// 点击发送后立刻进入「思考中」状态。
    /// 同步设置而不是等 Task 起来：否则会先闪一下「可以重试」的横条，
    /// 用户也会觉得点了没反应。
    private func beginTurn() {
        isThinking = true
        thinkingStartedAt = Date()
        statusText = "洄游中…"
        liveReply = ""
    }

    // MARK: - 重试

    /// 最后一条是「还没答完的用户消息」或「出错气泡」→ 可以一键重试
    var canRetry: Bool {
        guard !isThinking else { return false }
        guard let last = messages.last else { return false }
        if last.role == .user { return true }
        return last.role == .assistant && last.isError
    }

    var retryHint: String {
        guard let last = messages.last else { return "" }
        if last.role == .user { return "这句话还没答完" }
        return "刚才中断了"
    }

    /// 重新发最后那句。错误气泡会被吃掉，不会越堆越多；
    /// 已经执行过的工具结果留在历史里，重试不会把工具再跑一遍。
    func retryLastTurn() {
        guard !isThinking else { return }
        while let last = messages.last, last.role == .assistant, last.isError {
            messages.removeLast()
        }
        guard messages.last?.role == .user else { return }
        pendingRoutineRunId = retryRoutineRunId
        retryRoutineRunId = nil
        persist()
        beginTurn()
        Task { await run() }
    }

    private func run() async {
        var succeeded = false

        defer {
            isThinking = false
            thinkingStartedAt = nil
            liveReply = ""
            persist()
            if let runId = pendingRoutineRunId {
                pendingRoutineRunId = nil
                if succeeded {
                    onRoutineTurnFinished?(runId)
                } else {
                    retryRoutineRunId = runId
                }
            }
        }

        do {
            let reply = try await agent.respond(history: messages)
            withAnimation {
                messages.append(contentsOf: reply.appended)
            }
            succeeded = true
        } catch let partial as AgentPartialFailure {
            // 中途断线：把已经跑出来的工具结果先落进去，保证上下文一致
            withAnimation {
                messages.append(contentsOf: partial.appended)
            }
            messages.append(ChatMessage(role: .assistant,
                                        content: "⚠️ \(partial.errorDescription ?? "出错了")",
                                        isError: true))
        } catch {
            messages.append(ChatMessage(role: .assistant,
                                        content: "⚠️ \(error.localizedDescription)",
                                        isError: true))
        }
    }

    func newConversation() {
        messages.removeAll()
        retryRoutineRunId = nil
        liveReply = ""
        persist()
    }

    // MARK: - 备份 / 恢复

    var snapshot: [ChatMessage] { messages }

    func replaceAll(_ items: [ChatMessage]) {
        messages = items
        retryRoutineRunId = nil
        persist()
    }

    func mergeIn(_ items: [ChatMessage]) {
        let known = Set(messages.map(\.id))
        let extra = items.filter { !known.contains($0.id) }
        guard !extra.isEmpty else { return }
        messages.append(contentsOf: extra)
        persist()
    }

    // MARK: - 持久化（单会话，保留最近 200 条）

    private func load() {
        guard let data = try? Data(contentsOf: chatFileURL),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messages = decoded
    }

    private func persist() {
        let recent = Array(messages.suffix(Self.maxStoredMessages))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        try? data.write(to: chatFileURL, options: .atomic)
        onDidChange?()
    }
}
