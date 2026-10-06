import SwiftUI

/// 习惯页：连续天数进度、每日打卡、专注联动
struct HabitsView: View {
    @EnvironmentObject private var store: HabitStore
    @EnvironmentObject private var notifications: NotificationManager

    @State private var showNew = false
    @State private var editing: Habit?
    @State private var toast: String?
    /// 灵动岛可用性只在出现时查一次，不要放进 body 里反复调系统 API
    @State private var canUseLiveActivity = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard

                    if store.isEmpty {
                        emptyHint
                    } else {
                        ForEach(store.habits) { habit in
                            habitCard(habit)
                        }
                        footerHint
                    }
                }
                .padding()
                .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("习惯")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("新建习惯")
                }
            }
            .sheet(isPresented: $showNew) {
                HabitEditorSheet(habit: nil)
            }
            .sheet(item: $editing) { habit in
                HabitEditorSheet(habit: habit)
            }
            .overlay(alignment: .top) {
                if let toast {
                    toastView(toast)
                }
            }
            .onAppear {
                canUseLiveActivity = LiveActivityManager.shared.isAvailable
            }
            .onReceive(store.$autoCheckInToast) { name in
                guard let name, !name.isEmpty else { return }
                store.autoCheckInToast = nil
                showToast("🎉 「\(name)」专注完成，已自动打卡")
            }
        }
    }

    // MARK: - 概览

    private var summaryCard: some View {
        let total = store.habits.count
        let checked = store.checkedTodayCount
        let best = store.longestRunningStreak

        return HStack(spacing: 0) {
            summaryCell(value: "\(checked)/\(total)", label: "今日已打卡", color: .green)
            Divider().frame(height: 34)
            summaryCell(value: "\(best) 天", label: "当前最长连续", color: .orange)
            Divider().frame(height: 34)
            summaryCell(value: "\(store.habits.map(\.bestStreak).max() ?? 0) 天", label: "历史最佳", color: .purple)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func summaryCell(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 空状态

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame")
                .font(.system(size: 40))
                .foregroundColor(.orange.opacity(0.7))
            Text("还没有习惯")
                .font(.headline)
            Text("挑一件想每天做的事，比如「每天锻炼 20 分钟」。\n连续打卡会累积天数，断了当前连续归零，\n但历史最佳会一直留着。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showNew = true
            } label: {
                Text("新建第一个习惯")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.top, 60)
    }

    private var footerHint: some View {
        Text("点「专注」会把习惯挂上灵动岛，倒计时结束自动打卡；中途撤下则视为放弃。")
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    // MARK: - 习惯卡片

    private func habitCard(_ habit: Habit) -> some View {
        let color = Color(habitHex: habit.hex)
        let streak = habit.currentStreak
        let done = store.isCheckedToday(habit.id)
        let focusing = store.isFocusing(habit.id)

        return VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                HabitProgressRing(
                    progress: habit.stageProgress,
                    color: color,
                    text: "\(streak)",
                    caption: "/\(habit.currentStageGoal)"
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: habit.icon)
                            .font(.caption)
                            .foregroundColor(color)
                        Text(habit.name)
                            .font(.headline)
                            .lineLimit(1)
                        if habit.hasReminder, let t = habit.reminderText {
                            Text(t)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("连续 \(streak) 天 · 最佳 \(habit.bestStreak) 天 · \(habit.stageLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    dotRow(habit, color: color)

                    if let note = habit.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                        store.toggleToday(habit.id)
                    }
                } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 30))
                        .foregroundColor(done ? color : Color.secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "撤销今日打卡" : "今日打卡")
            }

            HStack(spacing: 10) {
                Button {
                    LiveActivityManager.shared.start(habit: habit)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: focusing ? "dot.radiowaves.left.and.right" : "play.fill")
                            .font(.caption)
                        Text(focusing ? "专注中" : "专注 \(habit.defaultMinutes) 分钟")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canUseLiveActivity)

                Spacer()

                Menu {
                    Button {
                        editing = habit
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    if store.canMakeup(habit.id) {
                        Button {
                            withAnimation {
                                let _ = store.makeup(habit.id)
                            }
                        } label: {
                            Label("补签昨天（本月还剩 \(store.remainingMakeup(habit.id)) 次）",
                                  systemImage: "calendar.badge.plus")
                        }
                    }

                    if store.isCheckedToday(habit.id) {
                        Button {
                            let _ = store.undoCheckIn(habit.id)
                        } label: {
                            Label("撤销今日打卡", systemImage: "arrow.uturn.backward")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        LiveActivityManager.shared.endIfFocusing(habitId: habit.id)
                        store.delete(habit.id)
                        notifications.cancel(habit.id)
                    } label: {
                        Label("删除习惯", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func dotRow(_ habit: Habit, color: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(store.recentDays(habit.id, count: 7).enumerated()), id: \.offset) { _, entry in
                Circle()
                    .fill(entry.1 ? color : Color.secondary.opacity(0.18))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - 提示

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation { toast = nil }
        }
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 进度环

struct HabitProgressRing: View {
    let progress: Double
    let color: Color
    let text: String
    var caption: String? = nil
    var size: CGFloat = 54

    var body: some View {
        let lineWidth: CGFloat = size > 44 ? 5 : 3.5
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(1, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(text)
                    .font(.system(size: size * 0.30, weight: .semibold))
                    .monospacedDigit()
                if let caption {
                    Text(caption)
                        .font(.system(size: size * 0.17))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 新建 / 编辑

struct HabitEditorSheet: View {
    @EnvironmentObject private var store: HabitStore
    @EnvironmentObject private var notifications: NotificationManager
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建
    let habit: Habit?

    @State private var name = ""
    @State private var note = ""
    @State private var icon = "figure.run"
    @State private var hex = HabitPalette.hexes[0]
    @State private var goalDays = 21
    @State private var durationMinutes = 25
    @State private var hasReminder = false
    @State private var reminderTime = Date()

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("习惯名，如：每天锻炼", text: $name)
                    TextField("备注（可选，会用在提醒文案里）", text: $note)
                }

                Section("图标") {
                    iconGrid
                }

                Section("主题色") {
                    colorRow
                }

                Section {
                    Stepper("阶段目标：\(goalDays) 天", value: $goalDays, in: 7...91, step: 7)
                    Stepper("专注时长：\(durationMinutes) 分钟", value: $durationMinutes, in: 5...120, step: 5)
                } footer: {
                    Text("21 天只是第一阶段。连续天数达标记后自动进入下一个巩固期，进度环按新阶段重新算，连续记录不会被打断；一旦断签，当前连续归零重来，但历史最佳一直保留。")
                }

                Section {
                    Toggle("每日提醒", isOn: $hasReminder)
                    if hasReminder {
                        DatePicker("提醒时刻", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    if notifications.denied {
                        Text("通知权限已关闭，去「设置 → 通知 → 洄游」打开才能收到提醒。")
                    } else {
                        Text("用本地通知提醒，不需要后台推送权限。")
                    }
                }
            }
            .navigationTitle(habit == nil ? "新建习惯" : "编辑习惯")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .onChange(of: hasReminder) { on in
                guard on else { return }
                Task {
                    if !notifications.authorized {
                        _ = await notifications.requestAuthorization()
                    }
                }
            }
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
            ForEach(HabitPalette.icons, id: \.self) { symbol in
                Button {
                    icon = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 19))
                        .foregroundColor(icon == symbol ? .white : .secondary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(icon == symbol
                                          ? Color(habitHex: hex)
                                          : Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {
        HStack(spacing: 14) {
            ForEach(HabitPalette.hexes, id: \.self) { h in
                Button {
                    hex = h
                } label: {
                    Circle()
                        .fill(Color(habitHex: h))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.55), lineWidth: 2)
                                .opacity(hex == h ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func load() {
        guard let habit else { return }
        name = habit.name
        note = habit.note ?? ""
        icon = habit.icon
        hex = habit.hex
        goalDays = habit.goalDays
        durationMinutes = habit.defaultMinutes
        if let h = habit.reminderHour, let m = habit.reminderMinute {
            hasReminder = true
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = h
            comps.minute = m
            reminderTime = Calendar.current.date(from: comps) ?? Date()
        }
    }

    private func save() {
        let cal = Calendar.current
        let hour = hasReminder ? cal.component(.hour, from: reminderTime) : nil
        let minute = hasReminder ? cal.component(.minute, from: reminderTime) : nil
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if var existing = habit {
            existing.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.note = cleanNote.isEmpty ? nil : cleanNote
            existing.icon = icon
            existing.hex = hex
            existing.goalDays = goalDays
            existing.defaultMinutes = durationMinutes
            existing.reminderHour = hour
            existing.reminderMinute = minute
            store.update(existing)
        } else {
            _ = store.add(
                name: name,
                icon: icon,
                hex: hex,
                goalDays: goalDays,
                reminderHour: hour,
                reminderMinute: minute,
                defaultMinutes: durationMinutes,
                note: cleanNote.isEmpty ? nil : cleanNote
            )
        }

        dismiss()
        Task { await notifications.sync(store.habits) }
    }
}
