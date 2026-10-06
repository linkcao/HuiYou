import SwiftUI

/// 极简路由：让「今天」页的习惯条可以直接跳到「习惯」Tab
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case today, chat, habits, stats, settings
    }

    @Published var tab: Tab = .today
}

@main
struct XunYouApp: App {
    @StateObject private var taskStore: TaskStore
    @StateObject private var lifeStore: LifeStore
    @StateObject private var habitStore: HabitStore
    @StateObject private var chatVM: ChatViewModel
    @StateObject private var calSync: CalendarSync
    @StateObject private var watchBridge: WatchBridge
    @StateObject private var notifications = NotificationManager.shared
    @StateObject private var router = AppRouter()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = TaskStore()
        let life = LifeStore()
        let habits = HabitStore()
        let sync = CalendarSync()
        store.calendarSync = sync

        let bridge = WatchBridge()
        // 顺带把「自动快照」挂上：删掉 App 后本地数据就没了，钥匙串里那份是唯一退路
        store.onDidChange = {
            bridge.push()
            BackupMirror.shared.schedule()
        }
        life.onDidChange = {
            bridge.push()
            BackupMirror.shared.schedule()
        }
        habits.onDidChange = {
            BackupMirror.shared.schedule()
        }
        bridge.configure(store: store, life: life)

        // 习惯增删改时重建本地通知提醒（打卡不算结构变化，不重建）
        habits.onHabitsChanged = { [weak habits] in
            guard let habits else { return }
            let snapshot = habits.habits
            Task { await NotificationManager.shared.sync(snapshot) }
        }

        // 例程增删改 / 执行后重建提醒：到点发本地通知，已经执行或跳过的当天不再响
        life.onRoutinesChanged = { [weak life] in
            guard let life else { return }
            let routines = life.data.routines
            let runs = life.data.routineRuns
            Task { await NotificationManager.shared.syncRoutines(routines, runs: runs) }
        }

        // 习惯专注够钟后自动打卡需要 HabitStore
        LiveActivityManager.shared.configure(habitStore: habits)

        let chat = ChatViewModel(taskStore: store, lifeStore: life, habitStore: habits)
        // 例程那轮对话结束时，回写真实的完成时间（下次规划就能参考真实作息）
        chat.onRoutineTurnFinished = { [weak life] runId in
            life?.finishRoutineRun(runId)
        }
        chat.onDidChange = {
            BackupMirror.shared.schedule()
        }

        BackupMirror.shared.configure(tasks: store, life: life, habits: habits, chat: chat)

        _taskStore = StateObject(wrappedValue: store)
        _lifeStore = StateObject(wrappedValue: life)
        _habitStore = StateObject(wrappedValue: habits)
        _chatVM = StateObject(wrappedValue: chat)
        _calSync = StateObject(wrappedValue: sync)
        _watchBridge = StateObject(wrappedValue: bridge)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(taskStore)
                .environmentObject(lifeStore)
                .environmentObject(habitStore)
                .environmentObject(chatVM)
                .environmentObject(calSync)
                .environmentObject(notifications)
                .environmentObject(router)
                .task {
                    // 冷启动也补一份钥匙串快照：万一上次是在 3 秒去抖里被杀掉的
                    BackupMirror.shared.mirrorNow()
                    // 延后到界面稳定之后再重建习惯提醒。
                    // 启动关键路径上碰系统通知 API 有卡住的风险，这里显式让开。
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await notifications.sync(habitStore.habits)
                    await notifications.syncRoutines(lifeStore.data.routines, runs: lifeStore.data.routineRuns)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时补偿结算：App 被切后台期间到点的专注在这里自动打卡
            if phase == .active {
                LiveActivityManager.shared.settleIfNeeded()
                // 例程提醒是滚动预约的，回前台时把窗口补足到未来几天
                let routines = lifeStore.data.routines
                let runs = lifeStore.data.routineRuns
                Task { await NotificationManager.shared.syncRoutines(routines, runs: runs) }
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var router: AppRouter
    @StateObject private var mirror = BackupMirror.shared
    /// 重装后检测到的旧数据快照
    @State private var snapshotOffer: BackupPayload?

    var body: some View {
        TabView(selection: $router.tab) {
            TodayView()
                .tabItem { Label("今天", systemImage: "calendar.day.timeline.left") }
                .tag(AppRouter.Tab.today)
            ChatView()
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppRouter.Tab.chat)
            HabitsView()
                .tabItem { Label("习惯", systemImage: "flame.fill") }
                .tag(AppRouter.Tab.habits)
            StatsView()
                .tabItem { Label("成就", systemImage: "fish.fill") }
                .tag(AppRouter.Tab.stats)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        .task {
            // 本地空空如也、钥匙串里却有快照 → 基本就是「删了 App 又装回来」，问一句
            if let snapshot = mirror.pendingRestoreSnapshot() {
                snapshotOffer = snapshot
            }
        }
        .sheet(item: $snapshotOffer) { snapshot in
            RestoreOfferSheet(snapshot: snapshot) {
                mirror.apply(snapshot, mode: .replace)
            }
        }
    }
}
