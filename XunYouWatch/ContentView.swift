import SwiftUI

/// 手表端首页：一个页面搞定——今日分段安排 + 打勾 + 签到/鱼数
struct WatchHomeView: View {
    @EnvironmentObject private var model: WatchModel

    private let periodOrder = ["morning", "daytime", "evening", "anytime"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header

                if !model.checkedIn {
                    Button {
                        model.checkIn()
                    } label: {
                        Label("今日签到", systemImage: "hand.tap.fill")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                    .buttonStyle(.bordered)
                }

                ForEach(periodOrder, id: \.self) { p in
                    let items = model.tasks.filter { $0.period == p }
                    if !items.isEmpty {
                        section(p, items: items)
                    }
                }

                if model.tasks.isEmpty {
                    VStack(spacing: 6) {
                        Text("🐟")
                            .font(.title2)
                        Text("今天还没有安排\n在 iPhone 上找洄游聊聊")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("洄游")
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Text("🐟\(model.totalDone)")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.blue)
            if model.streak > 0 {
                Text("🔥\(model.streak)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.orange)
            }
            Spacer()
            let undone = model.tasks.filter { !$0.done }.count
            Text(undone > 0 ? "剩 \(undone) 件" : (model.tasks.isEmpty ? "" : "全部完成 🎉"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 分段

    private func section(_ p: String, items: [WatchTask]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label(for: p), systemImage: icon(for: p))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color(for: p))
            ForEach(items) { row($0) }
        }
    }

    private func row(_ t: WatchTask) -> some View {
        Button {
            model.complete(t.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(t.done ? .green : .gray)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title)
                        .font(.caption)
                        .strikethrough(t.done)
                        .foregroundColor(t.done ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !t.time.isEmpty || t.dur > 0 {
                        Text(subtitle(t))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func subtitle(_ t: WatchTask) -> String {
        var s = t.time
        if t.dur > 0 { s += s.isEmpty ? "\(t.dur)分钟" : " · \(t.dur)分" }
        return s
    }

    // MARK: - 时段样式（与手机端一致）

    private func label(for p: String) -> String {
        ["anytime": "随时", "morning": "上午", "daytime": "白天", "evening": "晚上"][p] ?? "随时"
    }
    private func icon(for p: String) -> String {
        ["anytime": "clock.fill", "morning": "sun.and.horizon.fill", "daytime": "sun.max.fill", "evening": "moon.stars.fill"][p] ?? "clock.fill"
    }
    private func color(for p: String) -> Color {
        switch p {
        case "morning": return Color(red: 0.72, green: 0.73, blue: 0.35)
        case "daytime": return Color(red: 0.47, green: 0.36, blue: 0.75)
        case "evening": return Color(red: 0.55, green: 0.60, blue: 0.85)
        default: return .secondary
        }
    }
}
