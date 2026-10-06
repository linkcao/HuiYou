import ActivityKit
import Foundation

/// 「洄游」专注事项的 Live Activity 属性（App 与 Widget 扩展共用；两个 target 各编译一份本文件）
struct TaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 专注计时区间。锁屏/灵动岛的倒计时与进度条用系统级 timer API 自动走秒，
        /// App 只需在开始时推送一次，无需反复 update
        var startDate: Date
        var endDate: Date
    }

    /// 事项标题（习惯专注时就是习惯名）
    var title: String
    /// 分类 SF Symbol 名
    var categoryIcon: String
    /// 分类颜色（hex 字符串，widget 侧解析）
    var categoryHex: String
    /// 关联的习惯 id（习惯专注时填；普通事项专注为 nil）——够钟后据此自动打卡
    var habitId: String? = nil
}
