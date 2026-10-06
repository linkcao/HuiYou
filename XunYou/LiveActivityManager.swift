import ActivityKit
import Foundation

/// 灵动岛 / 锁屏 Live Activity 管理器。
///
/// 两种用法：
/// - `start(task:)`   普通事项专注
/// - `start(habit:)`  习惯专注——够钟后自动打卡（核心联动）
@MainActor
final class LiveActivityManager: ObservableObject {

    static let shared = LiveActivityManager()

    private var activity: Activity<TaskActivityAttributes>?
    private(set) var currentTaskId: UUID?
    private(set) var currentHabitId: UUID?

    /// 专注结束的定时结算任务（App 在前台时生效；被切后台则由回前台时补偿）
    private var settleTask: Task<Void, Never>?

    /// 习惯存储：注入后才能做「专注完成 = 自动打卡」
    private var habitStore: HabitStore?

    init() {}

    func configure(habitStore: HabitStore) {
        self.habitStore = habitStore
        // 冷启动时把上次没结算完的会话补掉
        settleIfNeeded()
    }

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - 事项专注

    /// 开始专注：挂到灵动岛（同屏只保留一个）
    func start(task: TaskItem) {
        end()
        guard isAvailable else {
            print("Live Activities 未开启（或设备不支持）")
            return
        }
        let minutes = Double(max(5, task.durationMinutes ?? 25))
        let now = Date()
        let attributes = TaskActivityAttributes(
            title: task.title,
            categoryIcon: task.category.icon,
            categoryHex: task.category.hex
        )
        let state = TaskActivityAttributes.ContentState(
            startDate: now,
            endDate: now.addingTimeInterval(minutes * 60)
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: state.endDate)
            )
            currentTaskId = task.id
            currentHabitId = nil
        } catch {
            print("Live Activity 启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 习惯专注（够钟自动打卡）

    func start(habit: Habit) {
        end()
        guard isAvailable else {
            print("Live Activities 未开启（或设备不支持）")
            return
        }
        let minutes = max(5, habit.defaultMinutes)
        let now = Date()
        let end = now.addingTimeInterval(Double(minutes) * 60)

        let attributes = TaskActivityAttributes(
            title: habit.name,
            categoryIcon: habit.icon,
            categoryHex: habit.hex,
            habitId: habit.id.uuidString
        )
        let state = TaskActivityAttributes.ContentState(startDate: now, endDate: end)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: end)
            )
            currentHabitId = habit.id
            currentTaskId = nil
            habitStore?.beginFocus(habitId: habit.id, minutes: minutes)
            scheduleSettle(at: end)
        } catch {
            print("Live Activity 启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 结束

    /// 手动撤下。习惯专注被手动中断视为「放弃」，不自动打卡。
    func end() {
        settleTask?.cancel()
        settleTask = nil

        if let hid = currentHabitId {
            habitStore?.cancelFocus(habitId: hid)
        }
        currentHabitId = nil
        currentTaskId = nil

        guard let a = activity else { return }
        activity = nil
        Task {
            await a.end(
                ActivityContent(state: a.content.state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    /// 事项被完成/删除时，若是当前挂在岛上的那条，撤下
    func endIfCurrent(taskId: UUID) {
        guard taskId == currentTaskId else { return }
        end()
    }

    /// 习惯被删除时，若是当前正在专注的那个，撤下
    func endIfFocusing(habitId: UUID) {
        guard habitId == currentHabitId else { return }
        end()
    }

    // MARK: - 自动结算

    private func scheduleSettle(at date: Date) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            let interval = date.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.settleIfNeeded()
        }
    }

    /// 结算所有已到点的习惯专注：自动打卡并撤下灵动岛。
    /// 前台定时器 + App 回到前台时都会调它，两个入口互相兜底。
    func settleIfNeeded() {
        guard let store = habitStore, store.hasPendingFocus else { return }
        let checked = store.settleFocusSessions()
        guard !checked.isEmpty else { return }

        currentHabitId = nil
        settleTask?.cancel()
        settleTask = nil

        if let a = activity {
            activity = nil
            Task {
                await a.end(
                    ActivityContent(state: a.content.state, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
        _ = checked   // 提示文案由 HabitStore.autoCheckInToast 负责
    }
}
