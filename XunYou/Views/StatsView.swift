import SwiftUI

/// 成就页：每日签到、鱼塘（每完成一件事多一条鱼）、统计、每日例程管理
struct StatsView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var life: LifeStore
    @EnvironmentObject private var habits: HabitStore

    @State private var routineEditor: RoutineEditorTarget?
    /// 鱼塘里鱼的随机布局（首次出现时生成，避免每次刷新乱跳）
    @State private var fishLayout: [FishSpec] = []

    struct FishSpec: Identifiable {
        let id: Int
        let emoji: String
        let x: CGFloat      // 0-1 归一化位置
        let y: CGFloat
        let scale: CGFloat
        let speed: Double
        let drift: CGFloat
        let flipped: Bool
    }

    private static let species = ["🐟", "🐠", "🐡", "🦈", "🐙", "🦑"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    checkInCard
                    fishPond
                    statsGrid
                    routinesCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("成就")
            .sheet(item: $routineEditor) { target in
                AddRoutineSheet(routine: target.routine)
            }
            .onAppear {
                ensureFishLayout()
            }
        }
    }

    // MARK: - 签到

    private var checkInCard: some View {
        let streak = life.streak
        return VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundColor(.orange)
            Text(life.checkedInToday ? "今天已签到" : "今日签到")
                .font(.headline)
            Text(streak > 0 ? "已连续签到 \(streak) 天 🔥" : "签到打卡，开始今天的洄游")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    let _ = life.checkIn()
                }
            } label: {
                Text(life.checkedInToday ? "✓ 已签到" : "签到")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(life.checkedInToday ? Color.secondary : Color.orange)
                    )
            }
            .buttonStyle(.plain)
            .disabled(life.checkedInToday)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 鱼塘

    private var fishPond: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🐟 我的池塘")
                    .font(.headline)
                Spacer()
                Text("\(store.totalDoneCount) 条鱼")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text("每完成一件事，池塘里就多一条鱼")
                .font(.caption)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let shown = fishLayout.prefix(min(store.totalDoneCount, 40))
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    ZStack {
                        // 池塘底色
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(colors: [Color(red: 0.75, green: 0.90, blue: 0.98),
                                                        Color(red: 0.55, green: 0.80, blue: 0.95)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        // 波纹
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                                .frame(width: geo.size.width * CGFloat(0.4 + Double(i) * 0.3))
                                .position(x: geo.size.width * 0.8, y: geo.size.height * 0.75)
                        }
                        ForEach(shown) { fish in
                            let phase = swimPhase(fish, at: timeline.date)
                            Text(fish.emoji)
                                .font(.system(size: 22 * fish.scale))
                                .scaleEffect(x: (fish.flipped ? -1 : 1) * (phase < 0 ? -1 : 1), y: 1)
                                .position(x: geo.size.width * fish.x + phase * fish.drift,
                                          y: geo.size.height * fish.y + sin(phase * .pi) * 4)
                        }
                        if store.totalDoneCount == 0 {
                            Text("完成第一件事，迎来第一条鱼 🌱")
                                .font(.caption)
                                .foregroundColor(.blue.opacity(0.6))
                        }
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// -1...1 的往复相位
    private func swimPhase(_ fish: FishSpec, at date: Date) -> CGFloat {
        let t = date.timeIntervalSince1970.truncatingRemainder(dividingBy: fish.speed * 2) / (fish.speed * 2)
        return CGFloat(sin(t * .pi * 2))
    }

    private func ensureFishLayout() {
        guard fishLayout.isEmpty else { return }
        fishLayout = (0..<40).map { i in
            FishSpec(
                id: i,
                emoji: Self.species[i % Self.species.count],
                x: CGFloat.random(in: 0.1...0.9),
                y: CGFloat.random(in: 0.12...0.88),
                scale: CGFloat.random(in: 0.7...1.4),
                speed: Double.random(in: 2...5),
                drift: CGFloat.random(in: 14...42),
                flipped: Bool.random()
            )
        }
    }

    // MARK: - 统计

    private var statsGrid: some View {
        let cal = Calendar.current
        let todayDone = store.dayDoneCount(Date())
        let weekDone = store.tasks.filter { t in
            guard let d = t.doneAt else { return false }
            return cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
        }.count
        let checkinCount = life.data.checkins.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCell(icon: "checkmark.circle.fill", color: .green, value: "\(todayDone)", label: "今日完成")
            statCell(icon: "calendar", color: .blue, value: "\(weekDone)", label: "本周完成")
            statCell(icon: "trophy.fill", color: .orange, value: "\(store.totalDoneCount)", label: "累计完成")
            statCell(icon: "flame.fill", color: .red, value: "\(life.streak) 天", label: "连续签到")
            statCell(icon: "sparkles", color: .purple, value: "\(checkinCount)", label: "累计签到")
            statCell(icon: "fish.fill", color: .teal, value: "\(store.totalDoneCount)", label: "池塘鱼数")
            statCell(icon: "target", color: .pink, value: "\(habits.checkedTodayCount)/\(habits.habits.count)", label: "今日习惯")
            statCell(icon: "chart.line.uptrend.xyaxis", color: .indigo, value: "\(habits.longestRunningStreak) 天", label: "习惯最长连续")
        }
    }

    private func statCell(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            Text(value)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 例程

    private var routinesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("⏰ 每日例程")
                    .font(.headline)
                Spacer()
                Button {
                    routineEditor = .new
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            Text("到点会发本地通知；打开 App 弹一次确认，全天也可以随时提前开始。真实的开始/结束时间会记下来，AI 下次规划时会参考。")
                .font(.caption)
                .foregroundColor(.secondary)

            if life.data.routines.isEmpty {
                Text("还没有例程。试试在对话里对 AI 说「每天早上帮我做规划」")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(life.data.routines) { r in
                    routineRow(r)
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func routineRow(_ r: Routine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(r.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(r.enabled ? .primary : .secondary)
                Text(r.timeText)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(r.enabled ? Color.orange : Color.secondary, in: Capsule())
                Spacer()
                Button {
                    life.toggleRoutine(r.id)
                } label: {
                    Image(systemName: r.enabled ? "bell.fill" : "bell.slash")
                        .font(.caption)
                        .foregroundColor(r.enabled ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.enabled ? "停用这个例程" : "启用这个例程")

                Button {
                    routineEditor = .edit(r)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑例程")

                Button {
                    life.deleteRoutine(r.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除例程")
            }

            Text("指令：\(r.prompt)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let stats = routineStatsText(r) {
                Text(stats)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 真实执行情况：上次开始时间、比计划早/晚多少、最近几次的平均值
    private func routineStatsText(_ r: Routine) -> String? {
        guard let last = life.latestRun(r.id) else {
            return r.enabled ? "还没有执行记录" : "已停用"
        }
        var lines: [String] = []
        var first = "上次：\(TaskDate.format(last.startedAt)) \(TaskDate.time(last.startedAt)) 开始"
        let planned = life.plannedDate(for: r, on: last.startedAt)
        let minutes = Int((last.startedAt.timeIntervalSince(planned) / 60).rounded())
        if abs(minutes) >= 2 {
            first += "（比计划\(minutes > 0 ? "晚" : "早") \(abs(minutes)) 分钟）"
        }
        if let d = last.durationMinutes { first += "，用时 \(max(1, d)) 分钟" }
        lines.append(first)

        if let st = life.stats(for: r.id, days: 7), st.count >= 2 {
            let offset: String
            if st.averageOffsetMinutes == 0 {
                offset = "准时"
            } else if st.averageOffsetMinutes > 0 {
                offset = "晚 \(st.averageOffsetMinutes) 分钟"
            } else {
                offset = "早 \(-st.averageOffsetMinutes) 分钟"
            }
            var second = "最近 \(st.count) 次平均 \(offset)"
            if let ad = st.averageDurationMinutes { second += "，平均用时 \(ad) 分钟" }
            lines.append(second)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 例程编辑器目标

/// 新建 / 编辑二选一，用一个 sheet(item:) 承载，避免同一个视图挂两个 sheet
private enum RoutineEditorTarget: Identifiable {
    case new
    case edit(Routine)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let r): return r.id.uuidString
        }
    }

    var routine: Routine? {
        switch self {
        case .new: return nil
        case .edit(let r): return r
        }
    }
}

// MARK: - 添加 / 编辑例程

struct AddRoutineSheet: View {
    @EnvironmentObject private var life: LifeStore
    @EnvironmentObject private var notifications: NotificationManager
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建
    var routine: Routine? = nil

    @State private var name = ""
    @State private var prompt = ""
    @State private var time = Date()
    @State private var enabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例程名，如：晨间规划", text: $name)
                    TextField("执行时发给 AI 的指令", text: $prompt, axis: .vertical)
                        .lineLimit(2...4)
                    DatePicker("计划时刻", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("启用", isOn: $enabled)
                } footer: {
                    Text("到点会发一条本地通知；打开 App 会弹一次确认，你也可以全天随时提前开始。真实开始/结束时间会记下来，供下次规划参考。")
                }
            }
            .navigationTitle(routine == nil ? "添加例程" : "编辑例程")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let routine else { return }
        name = routine.name
        prompt = routine.prompt
        enabled = routine.enabled
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = routine.hour
        comps.minute = routine.minute
        time = Calendar.current.date(from: comps) ?? Date()
    }

    private func save() {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: time)
        let minute = cal.component(.minute, from: time)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if let routine {
            life.updateRoutine(routine.id,
                               name: trimmedName,
                               prompt: trimmedPrompt.isEmpty ? routine.prompt : trimmedPrompt,
                               hour: hour,
                               minute: minute,
                               enabled: enabled)
        } else {
            let created = life.addRoutine(name: trimmedName,
                                          prompt: trimmedPrompt.isEmpty ? "帮我生成今天的安排" : trimmedPrompt,
                                          hour: hour,
                                          minute: minute)
            if !enabled {
                life.updateRoutine(created.id, enabled: false)
            }
        }

        dismiss()
        Task {
            if enabled, !notifications.authorized {
                _ = await notifications.requestAuthorization()
            }
            await notifications.syncRoutines(life.data.routines, runs: life.data.routineRuns)
        }
    }
}
