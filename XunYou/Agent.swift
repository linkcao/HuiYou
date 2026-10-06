import Foundation

/// 中途失败：把「已经跑出来的中间产物」一起带出去。
///
/// 为什么需要它：agent 循环可能在第 3 轮才断线，而前两轮的工具（比如刚建好的事项）
/// 已经真执行了。只回一句错误的话，重试时模型看不到这些进度，会把工具再跑一遍
/// （重复建事项）。带上 appended，重试就是接着往下走。
struct AgentPartialFailure: Error, LocalizedError {
    let appended: [ChatMessage]
    let underlying: Error

    var errorDescription: String? { underlying.localizedDescription }
}

/// 手写 Agent 循环：
/// 用户输入 → 模型 → tool_calls → 执行工具 → 结果塞回上下文 → 再问模型 → 直到给出自然语言回复
@MainActor
final class Agent {

    struct Reply {
        let text: String
        /// 本轮新产生的消息（含隐藏的 tool_calls 中间产物 + 可见的工具事件 + 最终回复）
        let appended: [ChatMessage]
    }

    private let store: TaskStore
    private let life: LifeStore
    private let habits: HabitStore
    private let client = DeepSeekClient()
    private static let maxTurns = 8

    /// 过程反馈：现在在干嘛（思考中 / 正在执行某个工具），UI 拿来显示 loading 文案
    var onProgress: ((String) -> Void)?

    /// 流式增量：模型边生成边回调，UI 可以实时显示，而不是干等到最后
    var onStreamDelta: ((String) -> Void)?

    init(taskStore: TaskStore, lifeStore: LifeStore, habitStore: HabitStore) {
        store = taskStore
        life = lifeStore
        habits = habitStore
    }

    /// 工具名 → 人话（loading 文案用，别让用户看 list_tasks 这种）
    static func toolLabel(_ name: String) -> String {
        switch name {
        case "list_tasks":      return "翻看现有事项"
        case "add_task":        return "记下这件事"
        case "update_task":     return "修改事项"
        case "complete_task":   return "打勾完成"
        case "delete_task":     return "删除事项"
        case "plan_day":        return "排今天的计划"
        case "split_task":      return "拆解大任务"
        case "set_routine":     return "设置每日例程"
        case "delete_routine":  return "删除例程"
        case "add_habit":       return "创建习惯"
        case "checkin_habit":   return "给习惯打卡"
        case "list_habits":     return "看习惯进度"
        case "update_habit":    return "修改习惯"
        case "delete_habit":    return "删除习惯"
        case "capture_idea":    return "记进池子"
        case "list_inbox":      return "翻看池子"
        case "set_expectation": return "记下你的要求"
        case "get_settings":    return "查看当前设置"
        case "archive_task":    return "归档"
        default:                return name
        }
    }

    // MARK: - System Prompt

    private func dynamicContext() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd HH:mm EEEE"

        // 当前状态 = 真实时间 + 用户画像 + 每日例程
        var profile = "现在：\(df.string(from: Date()))"
        let done = store.recentDone(12)
        if !done.isEmpty {
            let titles = done.map { t -> String in
                var s = t.title
                if let d = t.doneAt { s += "（\(TaskDate.format(d))完成）" }
                return s
            }.joined(separator: "、")
            profile += "\n用户最近完成过的事（可用于了解偏好与节奏）：\(titles)。用户累计完成 \(store.totalDoneCount) 件事。"
        }
        let exp = life.data.selfExpectation
        if !exp.isEmpty {
            profile += "\n用户对自己的要求/偏好（规划时务必遵守）：\(exp)"
        }
        let routines = life.data.routines
        if !routines.isEmpty {
            var lines: [String] = []
            for r in routines {
                var line = "「\(r.name)」计划每天 \(r.timeText)"
                if !r.enabled { line += "（已停用）" }

                switch life.status(of: r) {
                case .pending:
                    line += "；今天还没到点"
                case .due:
                    line += "；今天已到点，还没开始"
                case .running(let started):
                    line += "；今天 \(TaskDate.time(started)) 已开始（进行中）"
                case .done(let run):
                    var s = "；今天已完成（\(TaskDate.time(run.startedAt))"
                    if let f = run.finishedAt { s += " → \(TaskDate.time(f))" }
                    s += "）"
                    line += s
                case .skipped:
                    line += "；今天已跳过"
                }

                // 真实作息：AI 下次规划时最该参考的就是这个
                if let st = life.stats(for: r.id, days: 7), st.count > 0 {
                    if abs(st.averageOffsetMinutes) < 5 {
                        line += "，近期基本准时开始"
                    } else if st.averageOffsetMinutes > 0 {
                        line += "，近 \(st.count) 次平均比计划晚 \(st.averageOffsetMinutes) 分钟"
                    } else {
                        line += "，近 \(st.count) 次平均比计划早 \(-st.averageOffsetMinutes) 分钟"
                    }
                    if let d = st.averageDurationMinutes { line += "、平均用时 \(d) 分钟" }
                }
                lines.append(line)
            }
            profile += "\n每日例程执行情况（真实时间，规划时参考）：\n  · " + lines.joined(separator: "\n  · ")
        }

        let habitList = habits.habits
        if !habitList.isEmpty {
            let parts = habitList.map { h -> String in
                let today = h.checkins.contains(HabitMath.dayKey()) ? "今天已打卡" : "今天还没打卡"
                return "\(h.name)（连续 \(h.currentStreak) 天，历史最佳 \(h.bestStreak) 天，\(today)）"
            }.joined(separator: "、")
            profile += "\n用户正在养成的习惯：\(parts)"
        }

        // 子弹日记的 migrate：昨天之前到期、还没做完的，默认延续到今天
        let overdue = store.overdueItems()
        if !overdue.isEmpty {
            let parts = overdue.prefix(6).map { "\($0.title)（逾期 \($0.overdueDays()) 天）" }.joined(separator: "、")
            profile += "\n逾期未完成、默认延续到今天的事项：\(parts)。共 \(overdue.count) 件。"
        }

        // 子弹日记的 capture + 「是不是其实不做了」的定期确认
        let poolTotal = store.inboxCount
        if poolTotal > 0 {
            profile += "\n池子里共 \(poolTotal) 件待定（不急、未必今天做）。"
        }

        let surfacing = store.takeSurfaceCandidates(limit: 3)
        if !surfacing.isEmpty {
            let parts = surfacing.map { cand -> String in
                switch cand.reason {
                case .staleOverdue:
                    return "「\(cand.item.title)」逾期 \(cand.days) 天 —— 该确认用户是不是其实不做了（还要做就排期，不做了就归档）"
                case .stalePool:
                    return "「\(cand.item.title)」在池子里躺了 \(cand.days) 天 —— 该问用户是排期还是归档"
                case .freshPool:
                    return "「\(cand.item.title)」在池子里躺了 \(cand.days) 天 —— 可以问要不要今天做"
                }
            }.joined(separator: "\n  · ")
            profile += "\n今天可以拿出来问的（最多挑 1 件，别全列出来）：\n  · \(parts)"
        } else if poolTotal > 0 || !overdue.isEmpty {
            profile += "\n（今天已经提过了，别重复催。）"
        }

        return "【当前状态】\n" + profile + "\n【当前状态结束】"
    }

    /// 完全静态的系统提示：不含时间戳、不含用户画像。
    ///
    /// 为什么不把它们写进来：DeepSeek 的前缀缓存从第 0 个 token 开始逐字匹配，system prompt 就在
    /// token 0 的位置。只要它每轮（甚至每分钟）变一次，后面整段历史都会缓存失效，而 cache miss 的
    /// 输入单价约为 cache hit 的 50 倍。所以静态部分留在 system，动态部分交给 `dynamicContext()`
    /// 拼在最新一条用户消息的前面。
    private static let baseSystemPrompt = """
        你是「洄游」，一个温暖务实的私人生活小助理。名字寓意：从屏幕的漩涡里洄游，回到真实生活。

        用户多半在空闲、无聊、或想整理生活时找你。你的职责：
        1. 推荐马上能做的现实小事：具体、低成本、有成就感（如：给猫换水、下楼走 15 分钟、清理冰箱过期食品、给老朋友发条消息）。
        2. 用工具管理事项：用户想记录或安排什么就调用工具；用户说"我做了 XX"时，若有匹配的待办就标记完成，没有就记录为已完成事项。
        3. 推荐前先调用 list_tasks 查看现有事项，避免重复推荐；可以结合多久没做某类事给出建议。
        4. 规划与拆解（核心能力）：
           - 用户要"安排今天/计划一天"时：先 list_tasks 看现状，可以反问 1-2 个关键问题（今天有什么固定安排？想优先做什么？精力如何？），也可以直接给出方案；确定后用 plan_day 一次性生成当天分段计划。
           - 用户提出大任务（如"准备考试""写报告"）时：用 split_task 拆成 2-6 个可实现的小任务，各带预计时长和时间段（上午/白天/晚上或具体时间），分批执行。
           - 规划要结合用户历史偏好和自我要求（见用户消息开头的【当前状态】），难度循序渐进，别排太满。
        5. 用户想每天定时做什么（如"每天早上帮我做规划"）时，用 set_routine 设置例程：到点会发本地通知，用户在「今天」页一键确认就开始；真实的开始/结束时间都会被记下来供你参考，所以不要建议用户删掉例程。
        6. 习惯养成：用户说"我想养成…/我要每天…"时用 add_habit 创建习惯；用户说"我锻炼完了/今天看书了"且能对上某个习惯时，用 checkin_habit 打卡；用户问习惯进度时用 list_habits。
        7. 子弹日记：用户随口提到但不急的事（"记一下，回头买个路由器""纸巾该补货了""有空研究下 NAS"）用 capture_idea 丢进池子——它不会自己消失，也不会挤进今天的安排。规划前先看【当前状态】里的逾期项和池子。用户说某件搁置很久的事「不做了」时，用 archive_task 归档（记录保留），**不要用 delete_task**。
        8. 配置管家：App 里能设的东西都用对话改，别让用户专门跑去设置页——
           - 长期偏好/自我要求 → set_expectation（用户说"我以后想…""我不想…"这类长期约束时）
           - 习惯改名、改目标、改提醒 → update_habit；不要了 → delete_habit
           - 每日例程 → set_routine 新增、delete_routine 删除
           - 想确认当前配置（模型、日历同步、例程、统计数字）→ get_settings
           例外：API Key、Base URL、模型名**不通过对话修改**——改错会直接把对话通道切断，用户没法自救。用户要改这三样时，引导他去「设置」页。

        规则：
        - 用户表达长期偏好时（"我以后 23 点后不做事"），先调 set_expectation 记下来再回话，不要只口头答应。
        - 【当前状态】里有「逾期未完成」时，把它们排进今天的计划（用户默认接受延续），不要当成新任务重复添加。
        - 【当前状态】给了「今天可以拿出来问的」条目时，**最多挑 1 件**；用户没接话就算了，不要追问，也不要一次全列出来。
          · 标注「可以问要不要今天做」的 → 正常询问。
          · 标注「该问是排期还是归档」或「该确认是不是其实不做了」的 → 用一句轻的话确认：还要做就帮它排期，不做了就调 archive_task 归档（记录保留，不会丢）。**别催促、别说教、别提第二次。**
        - 池子和逾期项永远不要自动删除。用户说不想做了 → archive_task；只是暂时不想看到 → 静默。
        - 【当前状态】里有例程的真实执行时间时，把它当作了解用户真实作息的依据：如果长期比计划早/晚 30 分钟以上，可以顺手建议把例程时间改到更贴近现实（用 set_routine 传同样的 name + 新 time 就是改时间，别新建一个）。
        - 若用户今天还有习惯没打卡，可以在回复末尾轻轻提一句（最多提一个，别唠叨）。
        - 真实时间以每条用户消息开头的【当前状态】为准，所有日期计算都用它。
        - 工具的日期参数格式：yyyy-MM-dd 或 yyyy-MM-dd HH:mm。
        - 添加事项时尽量给 category（\(TaskCategory.schemaDescription)）、duration_minutes（预计分钟数，小事通常 10-60 分钟）；用户明确说了时间就填 due_date；说了时段就填 period（\(DayPeriod.schemaDescription)）。
        - 回复像朋友聊天，简洁有温度；一次最多推荐 3 件事，可以用 emoji 点缀。
        - 回复用 Markdown 排版（短列表、加粗关键词），不要写大段无结构的文字；要对比几项（时间 / 事项 / 时长）时可以用 Markdown 表格，气泡里会自动排版好。
        - 用户纯闲聊也可以陪聊，但瞅准机会把他引回现实小事。
        """

    // MARK: - 工具定义

    private static let addTask = ToolSchema(function: FunctionDef(
        name: "add_task",
        description: "添加一条事项（待办，或已完成的历史记录）",
        parameters: Parameters(
            properties: [
                "title": SchemaProperty(type: "string", description: "事项标题，简洁具体，如「给小猫剪指甲」"),
                "notes": SchemaProperty(type: "string", description: "备注，可选"),
                "due_date": SchemaProperty(type: "string", description: "计划时间，格式 yyyy-MM-dd 或 yyyy-MM-dd HH:mm，可选"),
                "category": SchemaProperty(type: "string", description: "分类：\(TaskCategory.schemaDescription)，可选", enumValues: TaskCategory.allCases.map(\.rawValue)),
                "duration_minutes": SchemaProperty(type: "integer", description: "预计时长（分钟），10-180，可选"),
                "period": SchemaProperty(type: "string", description: "所属时段：\(DayPeriod.schemaDescription)，可选（有 due_date 时可省略）", enumValues: DayPeriod.allCases.map(\.rawValue)),
                "status": SchemaProperty(type: "string", description: "todo=待办（默认），done=记录一件已完成的事", enumValues: ["todo", "done"]),
            ],
            required: ["title"])))

    private static let listTasks = ToolSchema(function: FunctionDef(
        name: "list_tasks",
        description: "查看现有事项列表，推荐前先调用它避免重复",
        parameters: Parameters(
            properties: [
                "filter": SchemaProperty(type: "string", description: "all=全部（默认），todo=待办，done=已完成", enumValues: ["all", "todo", "done"]),
            ])))

    private static let updateTask = ToolSchema(function: FunctionDef(
        name: "update_task",
        description: "修改一条事项（标题、备注、时间、分类、时长、状态），需要先通过 list_tasks 拿到 id",
        parameters: Parameters(
            properties: [
                "id": SchemaProperty(type: "string", description: "事项 id（UUID）"),
                "title": SchemaProperty(type: "string", description: "新标题，可选"),
                "notes": SchemaProperty(type: "string", description: "新备注，可选"),
                "due_date": SchemaProperty(type: "string", description: "新计划时间，可选"),
                "category": SchemaProperty(type: "string", description: "新分类，可选", enumValues: TaskCategory.allCases.map(\.rawValue)),
                "duration_minutes": SchemaProperty(type: "integer", description: "新预计时长（分钟），可选"),
                "status": SchemaProperty(type: "string", description: "todo / done", enumValues: ["todo", "done"]),
                "someday": SchemaProperty(type: "boolean", description: "true=放回池子搁置（会清掉日期），false=从池子里排期出来"),
            ],
            required: ["id"])))

    private static let completeTask = ToolSchema(function: FunctionDef(
        name: "complete_task",
        description: "把一条待办标记为已完成",
        parameters: Parameters(
            properties: [
                "id": SchemaProperty(type: "string", description: "事项 id（UUID）"),
            ],
            required: ["id"])))

    private static let deleteTask = ToolSchema(function: FunctionDef(
        name: "delete_task",
        description: "删除一条事项",
        parameters: Parameters(
            properties: [
                "id": SchemaProperty(type: "string", description: "事项 id（UUID）"),
            ],
            required: ["id"])))

    private static let planDay = ToolSchema(function: FunctionDef(
        name: "plan_day",
        description: "为某天生成一份分段计划（批量创建事项，可带具体时间或只归入时段）。规划确定后调用它落地。",
        parameters: Parameters(
            properties: [
                "date": SchemaProperty(type: "string", description: "计划日期，格式 yyyy-MM-dd，默认今天"),
                "items": SchemaProperty(type: "array", description: "计划项数组，每项含 title（必填）、start_time（HH:mm，可选）、duration_minutes（可选）、category（可选）、period（可选：anytime/morning/daytime/evening）"),
            ],
            required: ["items"])))

    private static let splitTask = ToolSchema(function: FunctionDef(
        name: "split_task",
        description: "把一个大任务拆解成若干小任务，分时段分批执行。生成的小任务会归入同一分组。",
        parameters: Parameters(
            properties: [
                "title": SchemaProperty(type: "string", description: "大任务名称，如「准备英语考试」"),
                "subtasks": SchemaProperty(type: "array", description: "子任务数组，每项含 title（必填）、duration_minutes（建议 15-90）、start_time（HH:mm，可选）、due_date（yyyy-MM-dd，可选）、period（可选）"),
            ],
            required: ["title", "subtasks"])))

    private static let setRoutine = ToolSchema(function: FunctionDef(
        name: "set_routine",
        description: "设置或修改一个每日定时例程：已有同名例程会被更新（改时间 / 改指令 / 启停），不存在则新建。到点 App 会发本地通知，用户在「今天」页一键确认就开始执行，真实开始/结束时间会被记录。",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "例程名，如「晨间规划」。已有同名例程时视为修改它（适合调整时间）"),
                "prompt": SchemaProperty(type: "string", description: "执行时发给你的指令，如「结合我目前的事项，帮我生成今天的安排」。新建时必填，只改时间/启停可省略"),
                "time": SchemaProperty(type: "string", description: "计划时刻，HH:mm"),
                "enabled": SchemaProperty(type: "boolean", description: "false=停用该例程（不再提醒），可选"),
            ],
            required: ["name", "time"])))

    private static let addHabit = ToolSchema(function: FunctionDef(
        name: "add_habit",
        description: "创建一个要养成的每日习惯（会出现在「习惯」页，支持每日打卡与连续天数）",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "习惯名，如「每天锻炼」"),
                "icon": SchemaProperty(type: "string", description: "SF Symbol 图标名，可选，如 figure.run / book.fill / drop.fill / brain.head.profile"),
                "goal_days": SchemaProperty(type: "integer", description: "阶段目标天数，默认 21"),
                "duration_minutes": SchemaProperty(type: "integer", description: "点「专注」时的默认时长（分钟），默认 25"),
                "reminder_time": SchemaProperty(type: "string", description: "每日提醒时刻 HH:mm，可选；填了会创建本地通知提醒"),
                "note": SchemaProperty(type: "string", description: "补充说明，可选"),
            ],
            required: ["name"])))

    private static let checkinHabit = ToolSchema(function: FunctionDef(
        name: "checkin_habit",
        description: "给某个习惯打今天的卡（用户说「我锻炼完了」这类话时用）。名字可以模糊匹配",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "习惯名，用 list_habits 里看到的名字"),
            ],
            required: ["name"])))

    private static let listHabits = ToolSchema(function: FunctionDef(
        name: "list_habits",
        description: "查看用户的习惯列表、连续天数与今日打卡情况",
        parameters: Parameters(
            properties: [
                "filter": SchemaProperty(type: "string", description: "all=全部（默认），missing=今天还没打卡的", enumValues: ["all", "missing"]),
            ])))

    private static let captureIdea = ToolSchema(function: FunctionDef(
        name: "capture_idea",
        description: "把用户随口提到、但不急也未必今天做的事记进「池子」。池子里的东西不会自动消失，也不会挤进今天的安排。用户说「记一下」「回头再说」「有空搞一下」「该补货了」时用它。",
        parameters: Parameters(
            properties: [
                "title": SchemaProperty(type: "string", description: "简洁具体的标题，如「买个路由器」「囤点纸巾」"),
                "notes": SchemaProperty(type: "string", description: "备注，可选"),
                "category": SchemaProperty(type: "string", description: "分类：\(TaskCategory.schemaDescription)，可选", enumValues: TaskCategory.allCases.map(\.rawValue)),
                "duration_minutes": SchemaProperty(type: "integer", description: "预计耗时（分钟），可选。补货、买东西这类顺手小事通常填 5-15"),
            ],
            required: ["title"])))

    private static let listInbox = ToolSchema(function: FunctionDef(
        name: "list_inbox",
        description: "查看池子里搁置着的事（不急、未必今天做，但还没丢）。规划前先看它，再从中挑 1-2 件问用户要不要今天做",
        parameters: Parameters(
            properties: [
                "filter": SchemaProperty(type: "string", description: "all=全部（默认），quick=只列预计 15 分钟内能搞定的顺手小事", enumValues: ["all", "quick"]),
            ])))

    private static let setExpectation = ToolSchema(function: FunctionDef(
        name: "set_expectation",
        description: "记录或修改用户对自己的长期要求/偏好（如「每天要运动30分钟」「23点后不安排任务」「周末少排任务」）。这条会作为规划时的硬约束。只在用户表达长期偏好时用，不要拿它记一次性待办。",
        parameters: Parameters(
            properties: [
                "text": SchemaProperty(type: "string", description: "要记录的内容，简洁一句话"),
                "mode": SchemaProperty(type: "string", description: "append=追加一条（默认），replace=整体重写（仅当用户明确要求清空重写时）", enumValues: ["append", "replace"]),
            ],
            required: ["text"])))

    private static let updateHabit = ToolSchema(function: FunctionDef(
        name: "update_habit",
        description: "修改一个已有习惯：改名、换图标、改阶段目标、改专注时长、改每日提醒、改备注。先用 list_habits 看到习惯名",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "要改的习惯名（可模糊匹配）"),
                "new_name": SchemaProperty(type: "string", description: "新名字，可选"),
                "goal_days": SchemaProperty(type: "integer", description: "新的阶段目标天数，可选"),
                "duration_minutes": SchemaProperty(type: "integer", description: "新的专注时长（分钟），可选"),
                "reminder_time": SchemaProperty(type: "string", description: "新的每日提醒时刻 HH:mm，可选；填 none 表示取消提醒"),
                "icon": SchemaProperty(type: "string", description: "新 SF Symbol 图标名，可选"),
                "note": SchemaProperty(type: "string", description: "新备注，可选"),
            ],
            required: ["name"])))

    private static let deleteHabit = ToolSchema(function: FunctionDef(
        name: "delete_habit",
        description: "删除一个习惯。仅在用户明确说不要了的时候用；如果只是暂时不想看到，改用静默",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "习惯名（可模糊匹配）"),
            ],
            required: ["name"])))

    private static let deleteRoutine = ToolSchema(function: FunctionDef(
        name: "delete_routine",
        description: "删除一个每日例程。先用 get_settings 看到现有例程名",
        parameters: Parameters(
            properties: [
                "name": SchemaProperty(type: "string", description: "例程名（可模糊匹配）"),
            ],
            required: ["name"])))

    private static let archiveTask = ToolSchema(function: FunctionDef(
        name: "archive_task",
        description: "归档一条事项：从今天和池子里移开，但记录一直保留、随时可恢复（**不是删除**）。用户说「这件不做了」「算了别做了」时用它，不要用 delete_task",
        parameters: Parameters(
            properties: [
                "id": SchemaProperty(type: "string", description: "事项 id（UUID）"),
                "restore": SchemaProperty(type: "boolean", description: "true=从归档里恢复回来，可选"),
            ],
            required: ["id"])))

    private static let getSettings = ToolSchema(function: FunctionDef(
        name: "get_settings",
        description: "查看 App 当前配置与整体状态：使用的模型、日历同步是否开启、是否配了 API Key、用户对自己的要求、每日例程列表，以及各类统计数字",
        parameters: Parameters(properties: [:])))

    private var schemas: [ToolSchema] {
        [Self.addTask, Self.listTasks, Self.updateTask, Self.completeTask, Self.deleteTask,
         Self.planDay, Self.splitTask, Self.setRoutine,
         Self.addHabit, Self.checkinHabit, Self.listHabits, Self.updateHabit, Self.deleteHabit,
         Self.captureIdea, Self.listInbox,
         Self.setExpectation, Self.deleteRoutine, Self.getSettings, Self.archiveTask]
    }

    // MARK: - 主循环

    func respond(history: [ChatMessage]) async throws -> Reply {
        // 1. 重建 wire 上下文（history 末尾是刚追加的用户消息）
        //    system 部分逐字不变、历史部分逐字不变，只有最新一条用户消息带动态上下文，
        //    这样 DeepSeek 的前缀缓存才能逐轮命中。
        let dynamic = dynamicContext()
        var wire: [WireMessage] = [WireMessage(role: "system", content: Self.baseSystemPrompt)]
        for (idx, m) in history.enumerated() {
            switch m.role {
            case .system:
                continue
            case .user:
                let isLatest = (idx == history.count - 1)
                wire.append(WireMessage(role: "user", content: isLatest ? "\(dynamic)\n\(m.content)" : m.content))
            case .assistant:
                if let calls = m.toolCalls, !calls.isEmpty {
                    wire.append(WireMessage(role: "assistant", content: m.content.isEmpty ? nil : m.content, tool_calls: calls))
                } else if !m.hidden {
                    wire.append(WireMessage(role: "assistant", content: m.content))
                }
            case .tool:
                wire.append(WireMessage(role: "tool", content: m.content, tool_call_id: m.toolCallId ?? "", name: m.toolName))
            }
        }

        var appended: [ChatMessage] = []
        var finalText = ""

        // 2. agent 循环：模型 → 工具 → 模型 → …
        for turn in 0..<Self.maxTurns {
            onProgress?(turn == 0 ? "正在想…" : "正在接着想…")

            let msg: ChatCompletionResponse.Choice.Message
            do {
                // 流式：模型吐一点就回调一点，UI 边收边显示；网关不支持会自动退回普通请求
                msg = try await client.chat(wire, tools: schemas) { [weak self] delta in
                    self?.onStreamDelta?(delta)
                }
            } catch {
                // 已经跑过的工具不能丢：连中间产物一起交回去，重试时才不会把工具再跑一遍
                if appended.isEmpty { throw error }
                throw AgentPartialFailure(appended: appended, underlying: error)
            }

            guard let calls = msg.tool_calls, !calls.isEmpty else {
                finalText = msg.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                break
            }

            // 记录带 tool_calls 的 assistant 中间产物（隐藏）
            wire.append(WireMessage(role: "assistant", content: msg.content, tool_calls: calls))
            appended.append(ChatMessage(role: .assistant, content: msg.content ?? "", toolCalls: calls, hidden: true))

            for call in calls {
                onProgress?("正在\(Self.toolLabel(call.function.name))…")
                let result = handle(call)
                appended.append(ChatMessage(role: .tool, content: result.display,
                                            toolCallId: call.id, toolName: call.function.name,
                                            toolArgs: call.function.arguments, toolOutput: result.output))
                wire.append(WireMessage(role: "tool", content: result.output, tool_call_id: call.id, name: call.function.name))
            }
        }

        if finalText.isEmpty { finalText = "（这轮没想好说什么，再试一次？）" }
        appended.append(ChatMessage(role: .assistant, content: finalText))
        return Reply(text: finalText, appended: appended)
    }

    // MARK: - 工具执行

    private func handle(_ call: WireToolCall) -> (output: String, display: String) {
        guard let data = call.function.arguments.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (Self.json(["error": "arguments 不是合法 JSON"]), "⚠️ 工具参数解析失败")
        }

        switch call.function.name {
        case "add_task":
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return (Self.json(["error": "title 不能为空"]), "⚠️ 标题为空") }
            let notes = obj["notes"] as? String
            let due = (obj["due_date"] as? String).flatMap(TaskDate.parse)
            let done = (obj["status"] as? String) == "done"
            let category = (obj["category"] as? String).flatMap(TaskCategory.init(rawValue:)) ?? .other
            let duration = (obj["duration_minutes"] as? Int).map { max(5, min(600, $0)) }
            let period = (obj["period"] as? String).flatMap(DayPeriod.init(rawValue:))
            let task = store.add(title: title, notes: notes, dueDate: due, isDone: done,
                                 category: category, durationMinutes: duration,
                                 period: period)
            var d = done ? "✅ 已记录「\(title)」" : "📝 已添加「\(title)」"
            if let due { d += " · \(TaskDate.format(due))" }
            if let period { d += " · \(period.label)" }
            return (Self.json(["id": task.id.uuidString, "title": title, "category": category.rawValue, "status": done ? "done" : "todo"]), d)

        case "plan_day":
            guard let items = obj["items"] as? [[String: Any]], !items.isEmpty else {
                return (Self.json(["error": "items 不能为空"]), "⚠️ 计划项为空")
            }
            let dateStr = obj["date"] as? String
            let base = dateStr.flatMap(TaskDate.parse) ?? Calendar.current.startOfDay(for: Date())
            var created: [TaskItem] = []
            for raw in items {
                guard let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty else { continue }
                let category = (raw["category"] as? String).flatMap(TaskCategory.init(rawValue:)) ?? .other
                let duration = (raw["duration_minutes"] as? Int).map { max(5, min(600, $0)) }
                let period = (raw["period"] as? String).flatMap(DayPeriod.init(rawValue:))
                var due: Date?
                if let hhmm = raw["start_time"] as? String {
                    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 {
                        due = Calendar.current.date(bySettingHour: max(0, min(23, parts[0])), minute: max(0, min(59, parts[1])), second: 0, of: base)
                    }
                } else if dateStr != nil {
                    due = base
                }
                created.append(TaskItem(title: title, notes: nil, dueDate: due,
                                        category: category, durationMinutes: duration, period: period))
            }
            guard !created.isEmpty else { return (Self.json(["error": "没有合法的 items"]), "⚠️ 计划项解析失败") }
            let _ = store.addBatch(created)
            return (Self.json(["created": created.count, "titles": created.map(\.title)]),
                    "🗓️ 已生成 \(created.count) 项计划：\(created.map(\.title).joined(separator: "、"))")

        case "split_task":
            let bigTitle = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !bigTitle.isEmpty else { return (Self.json(["error": "title 不能为空"]), "⚠️ 大任务名为空") }
            guard let subs = obj["subtasks"] as? [[String: Any]], !subs.isEmpty else {
                return (Self.json(["error": "subtasks 不能为空"]), "⚠️ 子任务为空")
            }
            let gid = UUID()
            var created: [TaskItem] = []
            for (idx, raw) in subs.enumerated() {
                guard let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty else { continue }
                let category = (raw["category"] as? String).flatMap(TaskCategory.init(rawValue:)) ?? .other
                let duration = (raw["duration_minutes"] as? Int).map { max(5, min(600, $0)) }
                let period = (raw["period"] as? String).flatMap(DayPeriod.init(rawValue:))
                var due: Date?
                if let hhmm = raw["start_time"] as? String {
                    let parts = hhmm.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 {
                        var comp = DateComponents(); comp.hour = max(0, min(23, parts[0])); comp.minute = max(0, min(59, parts[1]))
                        if let day = (raw["due_date"] as? String).flatMap(TaskDate.parse) {
                            due = Calendar.current.date(bySettingHour: comp.hour!, minute: comp.minute!, second: 0, of: day)
                        } else {
                            due = Calendar.current.date(bySettingHour: comp.hour!, minute: comp.minute!, second: 0, of: Date())
                        }
                    }
                } else if let day = (raw["due_date"] as? String).flatMap(TaskDate.parse) {
                    due = day
                }
                let notes = "【\(bigTitle)】第 \(idx + 1)/\(subs.count) 步"
                created.append(TaskItem(title: title, notes: notes, dueDate: due,
                                        category: category, durationMinutes: duration, period: period, groupId: gid))
            }
            guard !created.isEmpty else { return (Self.json(["error": "没有合法的 subtasks"]), "⚠️ 子任务解析失败") }
            let _ = store.addBatch(created)
            return (Self.json(["groupId": gid.uuidString, "created": created.count, "titles": created.map(\.title)]),
                    "🪓 已拆解「\(bigTitle)」为 \(created.count) 个小任务：\(created.map(\.title).joined(separator: "、"))")

        case "set_routine":
            let name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let prompt = (obj["prompt"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let timeStr = obj["time"] as? String ?? "08:00"
            let parts = timeStr.split(separator: ":").compactMap { Int($0) }
            guard !name.isEmpty, parts.count == 2 else {
                return (Self.json(["error": "参数不合法（需要 name 和 time HH:mm）"]), "⚠️ 例程参数不合法")
            }
            let hour = max(0, min(23, parts[0]))
            let minute = max(0, min(59, parts[1]))
            let enabledFlag = obj["enabled"] as? Bool
            let timeText = String(format: "%02d:%02d", hour, minute)

            // 同名例程 → 改时间/指令/启停（用户说「把晨间规划改到 11 点」时走这里）
            if let existing = life.data.routines.first(where: { $0.name == name }) {
                let updated = life.updateRoutine(existing.id,
                                                 name: name,
                                                 prompt: prompt.isEmpty ? nil : prompt,
                                                 hour: hour,
                                                 minute: minute,
                                                 enabled: enabledFlag ?? existing.enabled)
                let isOff = !(updated?.enabled ?? true)
                return (Self.json(["ok": true, "updated": true, "id": existing.id.uuidString,
                                   "name": name, "time": timeText, "enabled": !isOff]),
                        isOff ? "⏸️ 已停用例程「\(name)」"
                              : "⏰ 已把例程「\(name)」改到每天 \(timeText)")
            }

            guard !prompt.isEmpty else {
                return (Self.json(["error": "新建例程需要 prompt"]), "⚠️ 新例程还缺执行指令")
            }
            let r = life.addRoutine(name: name, prompt: prompt, hour: hour, minute: minute)
            if enabledFlag == false {
                life.updateRoutine(r.id, enabled: false)
            }
            return (Self.json(["id": r.id.uuidString, "name": name, "time": timeText, "enabled": enabledFlag ?? true]),
                    enabledFlag == false
                        ? "⏸️ 已添加例程「\(name)」（当前停用）"
                        : "⏰ 已设置每日例程「\(name)」（每天 \(timeText)，到点会提醒你）")

        case "add_habit":
            let name = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return (Self.json(["error": "name 不能为空"]), "⚠️ 习惯名为空") }

            let rawIcon = (obj["icon"] as? String)?.trimmingCharacters(in: .whitespaces)
            let icon = (rawIcon?.isEmpty ?? true) ? "flame.fill" : rawIcon!
            let goal = obj["goal_days"] as? Int ?? 21
            let duration = obj["duration_minutes"] as? Int ?? 25

            var reminderHour: Int? = nil
            var reminderMinute: Int? = nil
            if let t = obj["reminder_time"] as? String {
                let parts = t.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 {
                    reminderHour = parts[0]
                    reminderMinute = parts[1]
                }
            }

            // 颜色按已有习惯数量轮换，避免全一个色
            let hex = HabitPalette.hexes[habits.habits.count % HabitPalette.hexes.count]
            guard let created = habits.add(name: name, icon: icon, hex: hex, goalDays: goal,
                                           reminderHour: reminderHour, reminderMinute: reminderMinute,
                                           defaultMinutes: duration, note: obj["note"] as? String) else {
                return (Self.json(["error": "创建失败"]), "⚠️ 习惯创建失败")
            }

            var display = "🌱 已创建习惯「\(created.name)」（目标 \(created.goalDays) 天）"
            if let t = created.reminderText { display += " · 每天 \(t) 提醒" }
            return (Self.json(["id": created.id.uuidString, "name": created.name, "goal_days": created.goalDays]),
                    display)

        case "checkin_habit":
            let raw = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return (Self.json(["error": "name 不能为空"]), "⚠️ 没给习惯名") }
            guard let target = Self.matchHabit(raw, in: habits.habits) else {
                let names = habits.habits.map(\.name).joined(separator: "、")
                return (Self.json(["error": "没找到匹配的习惯", "available": habits.habits.map(\.name)]),
                        names.isEmpty ? "⚠️ 还没有任何习惯" : "⚠️ 没找到「\(raw)」，现有：\(names)")
            }
            let alreadyDone = habits.isCheckedToday(target.id)
            if alreadyDone {
                return (Self.json(["id": target.id.uuidString, "name": target.name, "already": true]),
                        "✅ 「\(target.name)」今天已经打过卡了")
            }
            guard habits.checkIn(target.id), let updated = habits.habit(target.id) else {
                return (Self.json(["error": "打卡失败"]), "⚠️ 打卡失败")
            }
            var display = "🔥 已给「\(updated.name)」打卡，连续 \(updated.currentStreak) 天"
            if updated.currentStreak == updated.bestStreak, updated.currentStreak > 1 {
                display += "（追平历史最佳！）"
            } else if updated.bestStreak > updated.currentStreak {
                display += " · 历史最佳 \(updated.bestStreak) 天"
            }
            return (Self.json(["id": updated.id.uuidString, "name": updated.name,
                               "streak": updated.currentStreak, "best": updated.bestStreak]),
                    display)

        case "list_habits":
            let filter = obj["filter"] as? String ?? "all"
            var list = habits.habits
            if filter == "missing" {
                list = list.filter { !$0.checkins.contains(HabitMath.dayKey()) }
            }
            if list.isEmpty {
                return (filter == "missing" ? "（今天所有习惯都打过卡了）" : "（还没有任何习惯）",
                        filter == "missing" ? "🎉 今天的习惯都完成了" : "📋 查看了习惯（空）")
            }
            let text = list.map { h -> String in
                let done = h.checkins.contains(HabitMath.dayKey()) ? "已打卡" : "未打卡"
                var s = "[\(done)] \(h.name) (id: \(h.id.uuidString), 连续: \(h.currentStreak)天, 历史最佳: \(h.bestStreak)天, 目标: \(h.currentStageGoal)天)"
                if let t = h.reminderText { s += " 提醒: 每天\(t)" }
                if let n = h.note, !n.isEmpty { s += " 备注: \(n)" }
                return s
            }.joined(separator: "\n")
            return (text, "📋 查看了 \(list.count) 个习惯")

        case "archive_task":
            guard let archIdStr = obj["id"] as? String, let archId = UUID(uuidString: archIdStr) else {
                return (Self.json(["error": "id 无效"]), "⚠️ 事项 id 无效")
            }
            guard let archTarget = store.task(id: archId) else {
                return (Self.json(["error": "找不到该事项"]), "⚠️ 找不到该事项")
            }
            if obj["restore"] as? Bool == true {
                let _ = store.restore(id: archId)
                return (Self.json(["ok": true, "title": archTarget.title]), "♻️ 已把「\(archTarget.title)」放回来")
            }
            let _ = store.archive(id: archId)
            return (Self.json(["ok": true, "title": archTarget.title]),
                    "🗄️ 已归档「\(archTarget.title)」（记录保留，随时能恢复）")

        case "set_expectation":
            let expText = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expText.isEmpty else { return (Self.json(["error": "text 不能为空"]), "⚠️ 内容为空") }
            let expMode = obj["mode"] as? String ?? "append"

            if expMode == "replace" {
                life.setSelfExpectation(expText)
                return (Self.json(["ok": true, "mode": "replace"]), "📌 已重写「对自己的要求」")
            }
            let currentExp = life.data.selfExpectation.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentExp.contains(expText) {
                return (Self.json(["ok": true, "already": true]), "📌 这条要求已经记着了")
            }
            life.setSelfExpectation(currentExp.isEmpty ? expText : currentExp + "\n" + expText)
            return (Self.json(["ok": true, "mode": "append", "text": expText]), "📌 记下你的要求：\(expText)")

        case "update_habit":
            let habitQuery = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let habitTarget = Self.matchHabit(habitQuery, in: habits.habits) else {
                return (Self.json(["error": "没找到匹配的习惯", "available": habits.habits.map(\.name)]),
                        "⚠️ 没找到「\(habitQuery)」")
            }
            var edited = habitTarget
            if let v = obj["new_name"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                edited.name = v.trimmingCharacters(in: .whitespaces)
            }
            if let v = obj["icon"] as? String, !v.isEmpty { edited.icon = v }
            if let v = obj["goal_days"] as? Int { edited.goalDays = max(1, min(365, v)) }
            if let v = obj["duration_minutes"] as? Int { edited.defaultMinutes = max(5, min(240, v)) }
            if let v = obj["note"] as? String { edited.note = v.isEmpty ? nil : v }
            if let t = obj["reminder_time"] as? String {
                let trimmed = t.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed == "none" || trimmed.isEmpty {
                    edited.reminderHour = nil
                    edited.reminderMinute = nil
                } else {
                    let parts = trimmed.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 {
                        edited.reminderHour = max(0, min(23, parts[0]))
                        edited.reminderMinute = max(0, min(59, parts[1]))
                    }
                }
            }
            habits.update(edited)
            var habitDisplay = "✏️ 已更新习惯「\(edited.name)」（目标 \(edited.goalDays) 天）"
            if let t = edited.reminderText { habitDisplay += " · 每天 \(t) 提醒" }
            return (Self.json(["ok": true, "name": edited.name, "goal_days": edited.goalDays]), habitDisplay)

        case "delete_habit":
            let habitQuery = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let habitTarget = Self.matchHabit(habitQuery, in: habits.habits) else {
                return (Self.json(["error": "没找到匹配的习惯", "available": habits.habits.map(\.name)]),
                        "⚠️ 没找到「\(habitQuery)」")
            }
            let removedName = habitTarget.name
            let removedCheckins = habitTarget.checkins.count
            habits.delete(habitTarget.id)
            return (Self.json(["ok": true, "name": removedName]),
                    "🗑️ 已删除习惯「\(removedName)」（含它记录过的 \(removedCheckins) 次打卡）")

        case "delete_routine":
            let routineQuery = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let allRoutines = life.data.routines
            guard let routineTarget = allRoutines.first(where: { $0.name == routineQuery })
                    ?? allRoutines.first(where: { $0.name.contains(routineQuery) || routineQuery.contains($0.name) }) else {
                return (Self.json(["error": "没找到匹配的例程", "available": allRoutines.map(\.name)]),
                        allRoutines.isEmpty ? "⚠️ 还没有任何例程" : "⚠️ 没找到「\(routineQuery)」")
            }
            let removedRoutine = routineTarget.name
            life.deleteRoutine(routineTarget.id)
            return (Self.json(["ok": true, "name": removedRoutine]), "🗑️ 已删除例程「\(removedRoutine)」")

        case "get_settings":
            var lines: [String] = []
            lines.append("模型：\(AppSettings.shared.model)（要改得去「设置」页，对话里改会导致断线）")
            lines.append("API Key：\(AppSettings.shared.apiKey.isEmpty ? "未配置" : "已配置")")
            lines.append("日历同步：\((store.calendarSync?.enabled ?? false) ? "已开启" : "未开启")")
            lines.append("对自己的要求：\(life.data.selfExpectation.isEmpty ? "（还没写）" : life.data.selfExpectation)")

            if life.data.routines.isEmpty {
                lines.append("每日例程：无")
            } else {
                let rs = life.data.routines
                    .map { r -> String in
                        var s = "\(r.name)(每天\(r.timeText)"
                        if !r.enabled { s += "，已停用" }
                        if let st = life.stats(for: r.id, days: 7), st.count > 0 {
                            if st.averageOffsetMinutes > 0 {
                                s += "，近\(st.count)次平均晚\(st.averageOffsetMinutes)分钟开始"
                            } else if st.averageOffsetMinutes < 0 {
                                s += "，近\(st.count)次平均早\(-st.averageOffsetMinutes)分钟开始"
                            } else {
                                s += "，近\(st.count)次基本准时开始"
                            }
                        }
                        return s + ")"
                    }
                    .joined(separator: "、")
                lines.append("每日例程：\(rs)")
            }

            if !habits.habits.isEmpty {
                let hs = habits.habits
                    .map { "\($0.name)(连续\($0.currentStreak)天/最佳\($0.bestStreak)天)" }
                    .joined(separator: "、")
                lines.append("习惯：\(hs)")
            }

            lines.append("事项：待办 \(store.list(filter: "todo").count) 条 · 今日完成 \(store.dayDoneCount(Date())) 条 · 累计 \(store.totalDoneCount) 条")
            lines.append("池子：\(store.inboxCount) 件待定 · 逾期未完成 \(store.overdueItems().count) 件")

            return (lines.joined(separator: "\n"), "⚙️ 查看了当前配置")

        case "capture_idea":
            let ideaTitle = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !ideaTitle.isEmpty else { return (Self.json(["error": "title 不能为空"]), "⚠️ 标题为空") }
            let ideaCategory = (obj["category"] as? String).flatMap(TaskCategory.init(rawValue:)) ?? .other
            let ideaDuration = (obj["duration_minutes"] as? Int).map { max(5, min(600, $0)) }
            let idea = store.add(title: ideaTitle, notes: obj["notes"] as? String,
                                 category: ideaCategory, durationMinutes: ideaDuration, isSomeday: true)
            var ideaDisplay = "🗂️ 先记进池子了：「\(idea.title)」"
            if let d = ideaDuration, d <= 15 { ideaDisplay += "（顺手就能办）" }
            return (Self.json(["id": idea.id.uuidString, "title": idea.title, "in_inbox": true]), ideaDisplay)

        case "list_inbox":
            let poolFilter = obj["filter"] as? String ?? "all"
            var pool = store.inbox
            if poolFilter == "quick" {
                pool = pool.filter { ($0.durationMinutes ?? 999) <= 15 }
            }
            if pool.isEmpty {
                return (poolFilter == "quick" ? "（池子里没有 15 分钟内能搞定的）" : "（池子是空的）",
                        poolFilter == "quick" ? "🗂️ 池子里没有顺手小事" : "🗂️ 查看了池子（空）")
            }
            let poolText = pool.map { t -> String in
                var s = "[\(t.category.rawValue)] \(t.title) (id: \(t.id.uuidString), 躺了 \(store.daysInPool(t)) 天"
                if let d = t.durationMinutes { s += ", 约\(d)分钟" }
                if let n = t.notes, !n.isEmpty { s += ", 备注: \(n)" }
                return s + ")"
            }.joined(separator: "\n")
            return (poolText, "🗂️ 池子里有 \(pool.count) 件待定")

        case "list_tasks":
            let filter = obj["filter"] as? String ?? "all"
            let list = store.list(filter: filter)
            if list.isEmpty { return ("（当前没有事项）", "📋 查看了事项（空）") }
            let text = list.map { t -> String in
                var s = "[\(t.isDone ? "done" : "todo")] \(t.title) (id: \(t.id.uuidString), category: \(t.category.rawValue), period: \(t.effectivePeriod.rawValue))"
                if let due = t.dueDate { s += " 时间: \(TaskDate.format(due))" }
                if let dur = t.durationMinutes { s += " 时长: \(dur)分钟" }
                return s
            }.joined(separator: "\n")
            return (text, "📋 查看了 \(list.count) 条事项")

        case "update_task":
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else {
                return (Self.json(["error": "id 无效"]), "⚠️ 事项 id 无效")
            }
            let title = obj["title"] as? String
            let notes = obj["notes"] as? String
            let due = (obj["due_date"] as? String).flatMap(TaskDate.parse)
            let status = obj["status"] as? String
            let category = (obj["category"] as? String).flatMap(TaskCategory.init(rawValue:))
            let duration = obj["duration_minutes"] as? Int

            // 池子 ↔ 排期：先切换搁置状态，再走常规更新
            if let someday = obj["someday"] as? Bool {
                if someday {
                    store.shelve(id: id)
                } else {
                    store.promote(id: id, to: due ?? Calendar.current.startOfDay(for: Date()))
                }
            }

            guard let updated = store.update(id: id, title: title, notes: notes, dueDate: due, status: status,
                                             category: category, durationMinutes: duration) else {
                return (Self.json(["error": "找不到该事项"]), "⚠️ 找不到该事项")
            }
            var updateDisplay = "✏️ 已更新「\(updated.title)」"
            if let someday = obj["someday"] as? Bool {
                updateDisplay = someday ? "🗂️ 已把「\(updated.title)」放回池子" : "📌 已把「\(updated.title)」排上日程"
            }
            return (Self.json(["id": updated.id.uuidString, "title": updated.title,
                               "status": updated.isDone ? "done" : "todo",
                               "in_inbox": updated.isInInbox]), updateDisplay)

        case "complete_task":
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr), store.complete(id: id) else {
                return (Self.json(["error": "未找到该待办或已完成"]), "⚠️ 完成失败（找不到该待办）")
            }
            return (Self.json(["ok": true]), "🎉 已完成一条待办")

        case "delete_task":
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr), store.delete(id: id) else {
                return (Self.json(["error": "未找到该事项"]), "⚠️ 删除失败（找不到该事项）")
            }
            return (Self.json(["ok": true]), "🗑️ 已删除一条事项")

        default:
            return (Self.json(["error": "未知工具"]), "⚠️ 未知工具 \(call.function.name)")
        }
    }

    /// 习惯名模糊匹配：精确命中优先，其次互相包含。
    /// 模型可能把「每天锻炼」说成「锻炼」，所以不能只做全等比较。
    private static func matchHabit(_ query: String, in list: [Habit]) -> Habit? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = list.first(where: { $0.name == q }) { return exact }
        return list.first { $0.name.contains(q) || q.contains($0.name) }
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
