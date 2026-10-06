import SwiftUI

/// 「今天」页：Tiimo 式分段日程（随时/上午/白天/晚上），参考周条 + 彩色分段 + 任务卡
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var life: LifeStore
    @EnvironmentObject private var habits: HabitStore
    @EnvironmentObject private var vm: ChatViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notifications: NotificationManager

    @State private var selectedDay = Date()
    @State private var showAdd = false
    @State private var showTaskList = false
    @State private var showInbox = false
    @State private var showStale = false
    @State private var addPeriod: DayPeriod = .anytime
    @State private var collapsed: Set<DayPeriod> = []
    @State private var celebrate = false
    @State private var toast: String?

    /// 到点后自动弹一次确认（每个例程每次启动只弹一次，不唠叨）
    @State private var routinePrompt: Routine?
    @State private var showRoutinePrompt = false
    @State private var promptedRoutineIds: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    weekStrip
                    habitStrip
                    routineSection
                    carriedOverSection
                    ForEach(DayPeriod.allCases) { period in
                        section(period)
                    }
                    daySummary
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInbox = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                            if store.inboxCount > 0 {
                                Text("\(store.inboxCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.red))
                                    .offset(x: 9, y: -7)
                            }
                        }
                    }
                    .accessibilityLabel("池子")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showTaskList = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("全部事项")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addPeriod = .anytime
                        showAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .accessibilityLabel("添加事项")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddTaskSheet(defaultPeriod: addPeriod, defaultDay: selectedDay)
            }
            .sheet(isPresented: $showTaskList) {
                TaskListView()
            }
            .sheet(isPresented: $showInbox) {
                InboxView()
            }
            .confirmationDialog(
                routinePrompt.map { "例程「\($0.name)」到点了" } ?? "例程到点了",
                isPresented: $showRoutinePrompt,
                titleVisibility: .visible
            ) {
                Button("现在生成今天的安排") {
                    if let r = routinePrompt { startRoutine(r) }
                }
                Button("今天不做") {
                    if let r = routinePrompt { skipRoutineToday(r) }
                }
                Button("稍后再说", role: .cancel) { }
            } message: {
                if let r = routinePrompt {
                    Text("计划 \(r.timeText)。现在开始会跳到对话页，让 AI 结合你现有的事项直接生成今天的安排；做完了会记下真实的开始和结束时间。")
                }
            }
            .task {
                await autoPromptRoutineIfNeeded()
            }
            .overlay {
                if celebrate {
                    fishToast
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    actionToast(toast)
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(dayTitle(selectedDay))
                .font(.system(size: 34, weight: .bold))
            Spacer()
            Text(dateRangeText)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var dateRangeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: selectedDay)
    }

    private func dayTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(d) { return "今天" }
        f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    // MARK: - 周条

    private var weekStrip: some View {
        let c = Calendar.current
        let start = c.date(from: c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDay)) ?? selectedDay
        let days = (0..<7).compactMap { c.date(byAdding: .day, value: $0, to: start) }
        return HStack(spacing: 10) {
            ForEach(days, id: \.self) { day in
                let isSelected = c.isDate(day, inSameDayAs: selectedDay)
                Button {
                    withAnimation { selectedDay = day }
                } label: {
                    VStack(spacing: 4) {
                        Text(weekLabel(day))
                            .font(.caption2)
                            .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                        Text("\(c.component(.day, from: day))")
                            .font(.system(size: 17, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .white : .primary)
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.9) : .clear)
                            .frame(width: 18, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.08))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func weekLabel(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "今" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f.string(from: d).replacingOccurrences(of: "周", with: "")
    }

    // MARK: - 习惯快照（专注模式的子分支，日常打卡入口）

    @ViewBuilder
    private var habitStrip: some View {
        if !habits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("习惯")
                        .font(.subheadline.weight(.semibold))
                    Text("\(habits.checkedTodayCount)/\(habits.habits.count) 已打卡")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        router.tab = .habits
                    } label: {
                        HStack(spacing: 2) {
                            Text("管理").font(.caption)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(habits.habits) { habit in
                            habitChip(habit)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func habitChip(_ habit: Habit) -> some View {
        let color = Color(habitHex: habit.hex)
        let done = habits.isCheckedToday(habit.id)

        return HStack(spacing: 10) {
            HabitProgressRing(
                progress: habit.stageProgress,
                color: color,
                text: "\(habit.currentStreak)",
                size: 36
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(done ? "今天已完成" : "连续 \(habit.currentStreak) 天")
                    .font(.caption2)
                    .foregroundColor(done ? color : .secondary)
            }

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                    habits.toggleToday(habit.id)
                }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundColor(done ? color : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "撤销今日打卡" : "今日打卡")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 延续（子弹日记的 migrate：昨天没做完的，今天接着来）

    @ViewBuilder
    private var carriedOverSection: some View {
        let overdue = store.overdueItems()
        let recent = overdue.filter { $0.overdueDays() <= 7 }
        let stale = overdue.filter { $0.overdueDays() > 7 }

        if !overdue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("延续")
                        .font(.subheadline.weight(.semibold))
                    Text("\(overdue.count) 件没做完，接着来")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                ForEach(recent) { task in
                    carriedRow(task)
                }

                if !stale.isEmpty {
                    Button {
                        withAnimation { showStale.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .rotationEffect(.degrees(showStale ? 0 : -90))
                            Text(showStale
                                 ? "收起搁置很久的 \(stale.count) 件"
                                 : "还有 \(stale.count) 件搁置超过一周")
                                .font(.caption)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showStale {
                        ForEach(stale) { task in
                            carriedRow(task)
                        }
                    }
                }
            }
        }
    }

    private func carriedRow(_ task: TaskItem) -> some View {
        let days = task.overdueDays()
        let isStale = days >= TaskStore.staleDays
        let color = task.category.color
        // 显式标注类型，避免 Color.opacity 在两个重载之间产生歧义
        let tint: Color = Color.orange.opacity(isStale ? 0.05 : 0.08)

        return HStack(spacing: 10) {
            Button {
                completeWithFish(task)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 22))
                    .foregroundColor(Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isStale ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(days <= 1 ? "昨天到期" : "逾期 \(days) 天")
                        .foregroundColor(days > 7 ? .red : .orange)

                    if isStale {
                        Text("还做吗？")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation { _ = store.promote(id: task.id, to: todayStart) }
            } label: {
                Text("今天做")
                    .font(.caption.weight(.medium))
                    .foregroundColor(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                if isStale {
                    Button(role: .destructive) {
                        archive(task)
                    } label: {
                        Label("不做了（归档）", systemImage: "archivebox")
                    }
                    Divider()
                }
                Button {
                    store.promote(id: task.id, to: tomorrowStart)
                } label: {
                    Label("明天做", systemImage: "sunrise")
                }
                Button {
                    withAnimation { _ = store.shelve(id: task.id) }
                } label: {
                    Label("放回池子", systemImage: "tray.and.arrow.down")
                }
                if !isStale {
                    Divider()
                    Button(role: .destructive) {
                        archive(task)
                    } label: {
                        Label("归档（保留记录）", systemImage: "archivebox")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 归档 + 明确反馈（可逆操作，但要让人知道去哪儿找回来）
    private func archive(_ task: TaskItem) {
        withAnimation { _ = store.archive(id: task.id) }
        showToast("已归档「\(task.title)」，可在池子页恢复")
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation { toast = nil }
        }
    }

    private func actionToast(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }

    private var tomorrowStart: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
    }

    // MARK: - 今日例程

    /// 例程不再需要「先等到 12 点、再手动点执行」：
    /// - 全天都能提前开始（点「提前开始」即可）
    /// - 到点会发本地通知，打开 App 自动弹一次确认
    /// - 开始 / 结束都记真实时间，下次规划 AI 会参考
    @ViewBuilder
    private var routineSection: some View {
        let routines = life.todayRoutines
        if !routines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "alarm.badge.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("今日例程")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        router.tab = .stats
                    } label: {
                        HStack(spacing: 2) {
                            Text("管理").font(.caption)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if !notifications.authorized {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(notifications.denied ? "通知权限被关了，到点提醒发不出来" : "还没开启到点提醒")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 4)
                        Button("开启提醒") {
                            Task { await enableRoutineReminders() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                ForEach(routines) { r in
                    routineRow(r)
                }
            }
        }
    }

    private func routineRow(_ r: Routine) -> some View {
        let status = life.status(of: r)
        let tint = routineTint(status)

        return HStack(spacing: 10) {
            Image(systemName: routineIcon(status))
                .font(.system(size: 17))
                .foregroundColor(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("例程：\(r.name)")
                    .font(.subheadline.weight(.semibold))
                Text(routineSubtitle(r, status))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            routineAction(r, status)

            Menu {
                if isRoutineSettled(status) {
                    Button {
                        undoRoutineToday(r)
                    } label: {
                        Label("撤销今天的记录", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        skipRoutineToday(r)
                    } label: {
                        Label("今天不做", systemImage: "moon.zzz")
                    }
                }
                Button {
                    router.tab = .stats
                } label: {
                    Label("改时间 / 管理", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func routineAction(_ r: Routine, _ status: RoutineStatus) -> some View {
        switch status {
        case .pending:
            Button("提前开始") { startRoutine(r) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .due:
            Button("开始") { startRoutine(r) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .running:
            Button("结束") { finishRoutineNow(r) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .done(let run):
            VStack(alignment: .trailing, spacing: 1) {
                Text("已完成")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
                if let d = run.durationMinutes {
                    Text("用时 \(max(1, d)) 分钟")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case .skipped:
            Button("还是做一下") { undoRoutineToday(r) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func routineSubtitle(_ r: Routine, _ status: RoutineStatus) -> String {
        switch status {
        case .pending(let planned):
            return "计划 \(TaskDate.time(planned)) · \(relativeText(to: planned))"
        case .due(let planned):
            return "计划 \(TaskDate.time(planned)) · 到点了"
        case .running(let started):
            return "\(TaskDate.time(started)) 开始 · 进行中（比计划\(routineOffsetText(r, started))）"
        case .done(let run):
            var s = "\(TaskDate.time(run.startedAt)) → \(run.finishedAt.map(TaskDate.time) ?? "…")"
            if let d = run.durationMinutes { s += " · 用时 \(max(1, d)) 分钟" }
            s += "（计划 \(r.timeText)，实际\(routineOffsetText(r, run.startedAt))）"
            return s
        case .skipped:
            return "今天跳过 · 计划 \(r.timeText)"
        }
    }

    /// 实际开始相对计划「早/晚」多少（这是 AI 下次规划时最有用的信号）
    private func routineOffsetText(_ r: Routine, _ started: Date) -> String {
        let planned = life.plannedDate(for: r, on: started)
        let minutes = Int((started.timeIntervalSince(planned) / 60).rounded())
        if abs(minutes) < 2 { return "准时" }
        return minutes > 0 ? "晚 \(minutes) 分钟" : "早 \(-minutes) 分钟"
    }

    private func relativeText(to date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "到点了" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "还有 \(max(1, minutes)) 分钟" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "还有 \(hours) 小时" : "还有 \(hours) 小时 \(minutes % 60) 分"
    }

    private func routineIcon(_ status: RoutineStatus) -> String {
        switch status {
        case .pending: return "alarm"
        case .due:     return "bell.badge.fill"
        case .running: return "hourglass"
        case .done:    return "checkmark.seal.fill"
        case .skipped: return "moon.zzz.fill"
        }
    }

    private func routineTint(_ status: RoutineStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .due:     return .red
        case .running: return .blue
        case .done:    return .green
        case .skipped: return Color.secondary
        }
    }

    private func isRoutineSettled(_ status: RoutineStatus) -> Bool {
        switch status {
        case .done, .skipped: return true
        default: return false
        }
    }

    // MARK: - 例程动作

    /// 开始执行：写下真实开始时间，跳到对话页让 AI 生成今天的安排
    private func startRoutine(_ r: Routine) {
        guard let run = life.startRoutine(r.id) else {
            showToast("「\(r.name)」今天已经执行过了")
            return
        }
        router.tab = .chat
        vm.send(r.prompt, routineRunId: run.id)
    }

    /// 手动提前结束（AI 回复完也会自动结束，这里给你一个提前收尾的出口）
    private func finishRoutineNow(_ r: Routine) {
        let _ = life.finishRunningRoutine(r.id)
        showToast("已记下「\(r.name)」的完成时间")
    }

    private func skipRoutineToday(_ r: Routine) {
        let _ = life.skipRoutine(r.id)
        showToast("今天先不做「\(r.name)」，已记下")
    }

    private func undoRoutineToday(_ r: Routine) {
        let _ = life.clearTodayRun(r.id)
        showToast("已撤销「\(r.name)」今天的记录")
    }

    /// 到点之后自动确认一次，省得用户自己去找入口。
    /// 同一个例程每次启动只弹一次（已弹过的记在 promptedRoutineIds 里）。
    private func autoPromptRoutineIfNeeded() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !showRoutinePrompt else { return }
        guard let r = life.dueRoutines().first(where: { !promptedRoutineIds.contains($0.id) }) else { return }
        promptedRoutineIds.insert(r.id)
        routinePrompt = r
        showRoutinePrompt = true
    }

    private func enableRoutineReminders() async {
        if !notifications.authorized {
            _ = await notifications.requestAuthorization()
        }
        await notifications.syncRoutines(life.data.routines, runs: life.data.routineRuns)
        if notifications.authorized {
            showToast("已开启到点提醒")
        } else {
            showToast("通知权限没打开：设置 → 通知 → 洄游")
        }
    }

    // MARK: - 分段

    private func section(_ period: DayPeriod) -> some View {
        let items = dayTasks(in: period)
        let isCollapsed = collapsed.contains(period)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation {
                    if isCollapsed { collapsed.remove(period) } else { collapsed.insert(period) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: period.icon)
                        .font(.caption)
                    Text("\(period.label)（\(items.filter { !$0.isDone }.count)）")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(period.color, in: Capsule())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(items) { task in
                    TaskCard(task: task, onToggle: {
                        completeWithFish(task)
                    }, onStart: {
                        LiveActivityManager.shared.start(task: task)
                    })
                }
                dashedAddRow(period)
            }
        }
    }

    private func dashedAddRow(_ period: DayPeriod) -> some View {
        Button {
            addPeriod = period
            showAdd = true
        } label: {
            HStack {
                Text(addHint(period))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func addHint(_ period: DayPeriod) -> String {
        switch period {
        case .anytime: return "今天随时都行"
        case .morning: return "你上午有什么待办？"
        case .daytime: return "白天想安排点什么？"
        case .evening: return "以你喜欢的方式结束一天"
        }
    }

    // MARK: - 汇总

    private var daySummary: some View {
        let done = store.dayDoneCount(selectedDay)
        return HStack {
            Label("今天已完成 \(done) 件", systemImage: "checkmark.seal.fill")
                .font(.subheadline)
            Spacer()
            if done > 0 {
                Text("🐟 池塘里游着 \(store.totalDoneCount) 条鱼")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 数据

    private func dayTasks(in period: DayPeriod) -> [TaskItem] {
        store.tasks(forDay: selectedDay)
            .filter { $0.effectivePeriod == period }
            .sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.createdAt < b.createdAt
                }
            }
    }

    // MARK: - 完成动作 + 养鱼

    private func completeWithFish(_ task: TaskItem) {
        withAnimation {
            if task.isDone {
                let _ = store.reopen(id: task.id)
            } else {
                let _ = store.complete(id: task.id)
                LiveActivityManager.shared.endIfCurrent(taskId: task.id) // 完成即撤下灵动岛
                celebrate = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation { celebrate = false }
                }
            }
        }
    }

    private var fishToast: some View {
        VStack(spacing: 6) {
            Text("🐟")
                .font(.system(size: 40))
            Text("池塘里多了一条鱼！")
                .font(.subheadline.weight(.medium))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - 任务卡

struct TaskCard: View {
    let task: TaskItem
    var onToggle: () -> Void
    /// 点 ▶︎ 把这件事挂上灵动岛专注（可选）
    var onStart: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.category.icon)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(task.category.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .strikethrough(task.isDone)
                    .foregroundColor(task.isDone ? .secondary : .primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !task.isDone, let onStart {
                Button {
                    onStart()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 20))
                        .foregroundColor(task.category.color.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("专注（挂到灵动岛）")
            }

            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(task.isDone ? task.category.color : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(task.isDone ? 0.05 : 0.10))
        )
    }

    private var subtitle: String {
        if let due = task.dueDate {
            if let dur = task.durationMinutes,
               let end = Calendar.current.date(byAdding: .minute, value: dur, to: due) {
                return "\(TaskDate.time(due)) → \(TaskDate.time(end))"
            }
            return TaskDate.time(due)
        }
        if let dur = task.durationMinutes { return "约 \(dur) 分钟" }
        return task.notes ?? ""
    }
}

// MARK: - 添加事项（带默认时段/日期）

struct AddTaskSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    var defaultPeriod: DayPeriod = .anytime
    var defaultDay: Date = Date()

    @State private var title = ""
    @State private var notes = ""
    @State private var category: TaskCategory = .life
    @State private var period: DayPeriod = .anytime
    @State private var durationMinutes = 25
    @State private var hasTime = false
    @State private var dueDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                TextField("事项，如：给小猫剪指甲", text: $title)
                TextField("备注（可选）", text: $notes)

                Picker("分类", selection: $category) {
                    ForEach(TaskCategory.allCases) { c in
                        Label(c.label, systemImage: c.icon).tag(c)
                    }
                }

                Picker("时段", selection: $period) {
                    ForEach(DayPeriod.allCases) { p in
                        Label(p.label, systemImage: p.icon).tag(p)
                    }
                }

                Stepper("预计时长：\(durationMinutes) 分钟", value: $durationMinutes, in: 5...180, step: 5)

                Toggle("具体时间", isOn: $hasTime)
                if hasTime {
                    DatePicker("时间", selection: $dueDate)
                        .onChange(of: dueDate) { d in
                            period = DayPeriod.forDate(d) ?? period
                        }
                }
            }
            .navigationTitle("添加事项")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cal = Calendar.current
                        let finalDue: Date? = hasTime
                            ? cal.date(bySettingHour: cal.component(.hour, from: dueDate),
                                       minute: cal.component(.minute, from: dueDate),
                                       second: 0, of: defaultDay)
                            : nil
                        store.add(title: title,
                                  notes: notes.isEmpty ? nil : notes,
                                  dueDate: finalDue,
                                  category: category,
                                  durationMinutes: durationMinutes,
                                  period: period)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                period = defaultPeriod
                dueDate = defaultDay
            }
        }
    }
}
