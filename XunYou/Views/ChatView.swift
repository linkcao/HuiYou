import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var vm: ChatViewModel

    /// 生成中的内容（loading / 流式半截文字）都挂在这个锚点上，方便自动滚到底
    private static let bottomAnchor = "chat-bottom-anchor"

    /// 只有有文字的消息才渲染，避免隐藏的 tool_calls 中间产物变成空气泡
    private var visibleMessages: [ChatMessage] {
        vm.messages.filter(\.isVisible)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if visibleMessages.isEmpty {
                                EmptyChatHint()
                            }
                            ForEach(visibleMessages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            if vm.isThinking {
                                VStack(alignment: .leading, spacing: 12) {
                                    // 流式输出：边生成边显示，不用等整段写完
                                    if !vm.liveReply.isEmpty {
                                        MessageBubble(message: ChatMessage(role: .assistant, content: vm.liveReply))
                                    }
                                    ThinkingIndicator(status: vm.statusText, startedAt: vm.thinkingStartedAt)
                                }
                                .id(Self.bottomAnchor)
                            }
                        }
                        .padding()
                    }
                    // 一进来就贴底：会话很长时也不会停在第一条
                    .defaultScrollAnchor(.bottom)
                    // 官方 API：一拖动就收键盘（.interactively 是跟手，容易被误以为没反应）
                    .scrollDismissesKeyboard(.immediately)
                    .onAppear {
                        // 首次布局还没完成时 scrollTo 会落空，稍等一帧再补一次
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            scrollToBottom(proxy, animated: false)
                        }
                    }
                    .onChange(of: vm.messages.count) { _ in
                        scrollToBottom(proxy, animated: true)
                    }
                    .onChange(of: vm.liveReply) { _ in
                        // 跟随流式输出往下滚（不加动画，免得每个字都弹一下）
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: vm.isThinking) { _ in
                        scrollToBottom(proxy, animated: true)
                    }
                }

                // 断线 / 没答完时，给一个明确的出口：不用重新打一遍
                if vm.canRetry {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(vm.retryHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 4)
                        Button("重试") { vm.retryLastTurn() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.10))
                }

                QuickPrompts(vm: vm)

                InputBar(text: $vm.input, isDisabled: vm.isThinking) {
                    vm.send()
                }
            }
            // 显式背景：内容不满屏时也绝不露出窗口底色（否则深色环境下会是一片黑）
            .background(Color(.systemBackground))
            .navigationTitle("洄游")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        vm.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新对话")
                }
            }
        }
    }

    /// 滚到最后一条可见消息（进入页面 / 新消息 / 思考状态变化时调用）；
    /// 正在生成时滚到「底部锚点」——那里可能只有 loading，也可能是流式输出的那半截文字
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if vm.isThinking {
            if animated {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            return
        }
        guard let last = visibleMessages.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

// MARK: - 空状态

struct EmptyChatHint: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "drop.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            Text("闲下来的时候，进来游两圈")
                .font(.headline)
            Text("比如：\n「有点闲，推荐点事做」\n「记一下：周五给猫驱虫」\n「我刚把冰箱清理了」")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.bottom, 40)
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .system:
            EmptyView()

        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "drop.fill")
                    .font(.system(size: 13))
                    .foregroundColor(message.isError ? .orange : .accentColor)
                    .padding(.top, 6)
                MarkdownText(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        (message.isError ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                Spacer(minLength: 40)
            }

        case .tool:
            ToolEventCard(message: message)
        }
    }
}

// MARK: - 工具调用卡片

/// 工具执行记录：折叠时一行摘要，展开后能看到入参与模型的原始返回
struct ToolEventCard: View {
    let message: ChatMessage
    @State private var expanded = false

    private var hasDetail: Bool {
        !(message.toolArgs ?? "").isEmpty || !(message.toolOutput ?? "").isEmpty
    }

    private var icon: String {
        switch message.toolName ?? "" {
        case "list_tasks":    return "list.bullet.rectangle"
        case "add_task":      return "plus.circle"
        case "plan_day":      return "calendar"
        case "split_task":    return "arrow.triangle.branch"
        case "set_routine":   return "alarm"
        case "update_task":   return "pencil"
        case "complete_task": return "checkmark.circle"
        case "delete_task":   return "trash"
        default:              return "wrench.and.screwdriver"
        }
    }

    /// 入参 JSON 美化，方便肉眼核对模型到底传了什么
    private var prettyArgs: String? {
        guard let raw = message.toolArgs, !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }

    /// 返回内容可能很长（比如罗列几十条事项），截断避免撑爆视图
    private var outputSnippet: String? {
        guard let out = message.toolOutput, !out.isEmpty else { return nil }
        let limit = 1600
        if out.count <= limit { return out }
        return String(out.prefix(limit)) + "\n…（已截断，共 \(out.count) 字）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(message.content)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let name = message.toolName {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    if hasDetail {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let args = prettyArgs {
                        detailBlock(title: "入参", body: args)
                    }
                    if let out = outputSnippet {
                        detailBlock(title: "模型看到的返回", body: out)
                    }
                }
                .padding(.top, 9)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - 加载中

/// 思考中的反馈：文案会跟着 agent 的进度变（正在想 / 正在翻看事项 / 正在排计划），
/// 超过几秒还会显示已等时长 —— 免得用户以为卡死了，切出去把请求搞断。
struct ThinkingIndicator: View {
    var status: String
    var startedAt: Date?

    init(status: String = "洄游中…", startedAt: Date? = nil) {
        self.status = status
        self.startedAt = startedAt
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text(label(now: context.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 21)
        }
    }

    private func label(now: Date) -> String {
        guard let startedAt else { return status }
        let seconds = Int(now.timeIntervalSince(startedAt))
        guard seconds >= 6 else { return status }
        return "\(status)（已等 \(seconds) 秒）"
    }
}

// MARK: - 预置问题

struct QuickPrompts: View {
    @ObservedObject var vm: ChatViewModel

    private static let prompts: [(String, String)] = [
        ("🗓️", "帮我安排今天的事"),
        ("🪓", "帮我拆解一个大任务"),
        ("💡", "有点闲，推荐点事做"),
        ("📊", "回顾我最近完成了什么"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.prompts, id: \.1) { emoji, text in
                    Button {
                        vm.send(text)
                    } label: {
                        HStack(spacing: 5) {
                            Text(emoji)
                                .font(.caption)
                            Text(text)
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isThinking)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 输入栏

struct InputBar: View {
    @Binding var text: String
    var isDisabled: Bool
    var onSend: () -> Void

    @FocusState private var focused: Bool
    @StateObject private var speech = SpeechInput()
    /// 开始录音时输入框里已有的文字（语音结果追加在其后）
    @State private var baseText = ""

    private var canSend: Bool {
        !isDisabled && !speech.isRecording
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasText: Bool { !text.isEmpty }

    /// 收起键盘（保留已输入的文字）
    private func collapseKeyboard() {
        if speech.isRecording { speech.stop() }
        focused = false
    }

    /// 放弃这次输入：停止录音、清空文字、收起键盘
    private func cancelInput() {
        if speech.isRecording { speech.stop() }
        baseText = ""
        text = ""
        focused = false
    }

    private func send() {
        guard canSend else { return }
        onSend()
        focused = false   // 发送后立刻收起键盘
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 麦克风（语音输入）
            Button {
                if speech.isRecording {
                    speech.stop()
                } else {
                    baseText = text
                    speech.start()
                }
            } label: {
                Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(speech.isRecording ? .red : Color.secondary.opacity(0.55))
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            TextField("说说你现在想干嘛…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .disabled(isDisabled)
                .submitLabel(.send)                 // 回车键显示「发送」
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .padding(.trailing, hasText ? 24 : 0)   // 给清空按钮留位置
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .trailing) {
                    if hasText {
                        Button {
                            baseText = ""
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color.secondary.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .accessibilityLabel("清空输入")
                    }
                }
                .onSubmit(send)

            // 键盘弹起时的退出按钮：常驻在输入栏里，一次点击就收，不依赖键盘工具条
            if focused {
                Button(action: collapseKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 26))
                        .foregroundColor(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起键盘")
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? .accentColor : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
        .onChange(of: focused) { isFocused in
            // 手动清空遗留状态，避免下次录音把上次的 baseText 带上
            if !isFocused, !hasText { baseText = "" }
        }
        .onReceive(speech.$currentText) { partial in
            // 实时上屏：已有文字 + 语音转写
            guard speech.isRecording else { return }
            text = baseText + partial
        }
    }
}
