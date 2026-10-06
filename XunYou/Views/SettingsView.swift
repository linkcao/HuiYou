import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("base_url") private var baseURL = "https://api.deepseek.com"
    @AppStorage("model") private var model = "deepseek-chat"
    @EnvironmentObject private var life: LifeStore
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var calSync: CalendarSync
    @StateObject private var mirror = BackupMirror.shared
    @State private var apiKey = ""
    @State private var testResult: String?
    @State private var testing = false
    /// 新要求输入框（加一条就落一条，不再是一个大文本框）
    @State private var newRequirement = ""
    @State private var calOn = false
    @State private var calHint: String?

    // 备份 / 恢复
    @State private var exportURL: URL?
    @State private var backupMessage: String?
    @State private var showImporter = false
    @State private var pendingRestore: BackupPayload?
    @State private var showRestoreConfirm = false
    @State private var showSnapshotConfirm = false

    /// 常见要求，点一下就加上
    private static let presetRequirements = [
        "每天要运动 30 分钟",
        "23 点后不安排任务",
        "周末少排任务",
        "重要的事放在上午做",
        "每天留 30 分钟放空",
    ]

    /// 内置系统提示的摘要（只读）：用来让用户分清「App 内置设定」和「我自己写的要求」
    private static let builtInPromptDigest = """
    · 定位：温暖务实的私人生活小助理，把你从屏幕拉回现实生活。
    · 推荐：只推具体、低成本、马上能做的现实小事，一次最多 3 件。
    · 规划：先看现有事项避免重复；结合你的历史偏好与「我对自己的要求」排期，难度循序渐进、不排太满。
    · 管理：事项、习惯、例程、池子都通过对话里的工具落地，不让你专门跑设置页。
    · 语气：像朋友聊天，简洁有温度，用 Markdown 排版。
    """

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key", text: $apiKey)
                        .autocorrectionDisabled()
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("在 platform.deepseek.com → API Keys 创建。仅保存在本机钥匙串，不经过任何第三方服务器。")
                }

                requirementsSection

                Section {
                    DisclosureGroup("看看内置设定（只读）") {
                        Text(Self.builtInPromptDigest)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("AI 是怎么被设定的")
                } footer: {
                    Text("上面那段是 App 内置的，长短由 App 决定，你不用写、也改不了。真正影响 AI 怎么规划你的生活的，是上一节「我对自己的要求」。")
                }

                Section {
                    Toggle("同步到系统日历", isOn: $calOn)
                    if let calHint {
                        Text(calHint)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("日历")
                } footer: {
                    Text("开启后，带计划时间的事项会写入系统日历里专属的「洄游」日历——锁屏、日历 App、Apple Watch 都能看到，走系统 iCloud 免费多端同步。完成会打 ✓，删除会同步移除。")
                }

                Section("接口") {
                    LabeledContent("Base URL") {
                        TextField("https://api.deepseek.com", text: $baseURL)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("模型") {
                        TextField("deepseek-chat", text: $model)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button(testing ? "测试中…" : "测试连接") {
                        Task { await test() }
                    }
                    .disabled(testing || apiKey.isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                backupSection

                Section("关于洄游") {
                    LabeledContent("版本", value: "1.0")
                    Text("从屏幕的漩涡里洄游，回到真实生活。\n闲下来的时候，进来游两圈。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
        .onAppear {
            apiKey = Keychain.get("api_key") ?? ""
            calOn = calSync.enabled
            refreshExportFile()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { (result: Result<URL, Error>) in
            switch result {
            case .success(let url):
                do {
                    let payload = try Backup.read(from: url)
                    guard !payload.isEmpty else {
                        backupMessage = "这份备份里没有数据"
                        return
                    }
                    pendingRestore = payload
                    showRestoreConfirm = true
                } catch {
                    backupMessage = "读不了这份文件：\(error.localizedDescription)"
                }
            case .failure(let error):
                backupMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .confirmationDialog("恢复这份备份？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("合并到现有数据") { applyRestore(.merge) }
            Button("覆盖现有数据", role: .destructive) { applyRestore(.replace) }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text(pendingRestore?.summary ?? "")
        }
        .confirmationDialog("从自动快照恢复？", isPresented: $showSnapshotConfirm, titleVisibility: .visible) {
            Button("合并这份快照") { restoreFromSnapshot() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("\(snapshotValueText)\n\n会合并进现在的数据（同 id 的不重复添加）。")
        }
        .onChange(of: apiKey) { newValue in
            if newValue.isEmpty {
                Keychain.delete("api_key")
            } else {
                Keychain.set(newValue, forKey: "api_key")
            }
        }
        .onChange(of: calOn) { on in
            Task { @MainActor in
                if on {
                    if await calSync.enable() {
                        let n = store.calendarBackfill(calSync)
                        calHint = n > 0 ? "✅ 已回填 \(n) 件带时间的事项到「洄游」日历" : "✅ 已连接，之后带时间的事项会自动写入日历"
                    } else {
                        calOn = false
                        calHint = "❌ 日历权限被拒绝：系统设置 → 隐私与安全性 → 日历 → 允许「洄游」"
                    }
                } else {
                    calSync.disable()
                    calHint = nil
                }
            }
        }
    }

    // MARK: - 我对自己的要求

    private var requirementsSection: some View {
        let items = life.expectations
        return Section {
            if items.isEmpty {
                Text("还没有写。AI 会按默认节奏帮你安排。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        Text(pair.element)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            life.removeExpectation(at: pair.offset)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除这条要求")
                    }
                }
                .onDelete { offsets in
                    // 从后往前删，避免前面的下标被挤掉
                    for index in offsets.sorted(by: >) {
                        life.removeExpectation(at: index)
                    }
                }
            }

            HStack {
                TextField("加一条，如：每天运动 30 分钟", text: $newRequirement)
                Button("添加") {
                    if life.addExpectation(newRequirement) {
                        newRequirement = ""
                    }
                }
                .disabled(newRequirement.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.presetRequirements, id: \.self) { preset in
                        Button {
                            _ = life.addExpectation(preset)
                        } label: {
                            Text(preset)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(items.isEmpty ? "我对自己的要求" : "我对自己的要求（\(items.count) 条）")
        } footer: {
            Text("一条一行，AI 规划、拆解、推荐时都会当作硬约束。左滑或点减号删除；也可以在对话里直接说「以后……」，AI 会自己记进来。")
        }
    }

    // MARK: - 数据与备份

    private var backupSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("导出备份文件", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    refreshExportFile()
                } label: {
                    Label("导出备份文件", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                showImporter = true
            } label: {
                Label("从备份文件恢复", systemImage: "square.and.arrow.down")
            }

            if mirror.lastMirrorDate != nil {
                LabeledContent("自动快照", value: snapshotValueText)
            }
            if Backup.loadSnapshot() != nil {
                Button {
                    showSnapshotConfirm = true
                } label: {
                    Label("从自动快照恢复", systemImage: "clock.arrow.circlepath")
                }
            }

            if let backupMessage {
                Text(backupMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("数据与备份")
        } footer: {
            Text("数据只在这台手机里，删掉 App 会一起消失。建议偶尔导出一份存到 iCloud Drive / 微信 / 电脑，重装或换机后在这里导入回来。钥匙串里也会自动留一份快照，重装后 App 会主动问你要不要恢复。\n临时腾空间时，请在系统弹窗里选「卸载 App」（保留数据），不要选「删除 App」。")
        }
    }

    private var snapshotValueText: String {
        guard let date = mirror.lastMirrorDate else { return "还没有" }
        let summary = mirror.lastSummary.isEmpty ? "" : " · \(mirror.lastSummary)"
        return "\(Backup.readableStamp(date))\(summary)"
    }

    private func refreshExportFile() {
        let payload = BackupMirror.shared.currentPayload()
        guard !payload.isEmpty else {
            exportURL = nil
            return
        }
        exportURL = try? Backup.exportFile(payload)
    }

    private func applyRestore(_ mode: RestoreMode) {
        guard let payload = pendingRestore else { return }
        BackupMirror.shared.apply(payload, mode: mode)
        backupMessage = mode == .merge
            ? "已合并备份：\(payload.summary)"
            : "已用备份覆盖当前数据：\(payload.summary)"
        pendingRestore = nil
        refreshExportFile()
    }

    private func restoreFromSnapshot() {
        guard let snapshot = Backup.loadSnapshot() else { return }
        BackupMirror.shared.apply(snapshot, mode: .merge)
        backupMessage = "已从自动快照恢复：\(snapshot.summary)"
        refreshExportFile()
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let models = try await DeepSeekClient().listModels()
            testResult = "✅ 连接成功，可用模型：\(models)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - 重装后的恢复询问

/// 删掉 App 再装回来时：本地是空的，但钥匙串里还留着上次的快照 —— 问一句要不要恢复
struct RestoreOfferSheet: View {
    let snapshot: BackupPayload
    var onRestore: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("找到上次的数据")
                        .font(.title3.bold())
                }

                Text("系统钥匙串里留着一份自动快照（\(Backup.readableStamp(snapshot.exportedAt))）：")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(snapshot.summary)
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("恢复后事项、习惯、例程、签到和对话都会回来。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Spacer(minLength: 8)

                Button {
                    onRestore()
                    dismiss()
                } label: {
                    Text("恢复数据")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button("不用了，从零开始") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
