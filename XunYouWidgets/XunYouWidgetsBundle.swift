import SwiftUI
import WidgetKit

@main
struct XunYouWidgetsBundle: WidgetBundle {
    var body: some Widget {
        XunYouTaskLiveActivity()
    }
}

// MARK: - 灵动岛 / 锁屏 Live Activity

struct XunYouTaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            // 锁屏横幅
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.categoryIcon)
                        .font(.title3)
                        .foregroundColor(Color(hex: context.attributes.categoryHex))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 68, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(
                            timerInterval: context.state.startDate...context.state.endDate,
                            countsDown: false
                        )
                        .tint(Color(hex: context.attributes.categoryHex))
                        HStack {
                            Label("正在专注", systemImage: "drop.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("洄游")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.categoryIcon)
                    .foregroundColor(Color(hex: context.attributes.categoryHex))
            } compactTrailing: {
                Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 40)
            } minimal: {
                Image(systemName: context.attributes.categoryIcon)
                    .foregroundColor(Color(hex: context.attributes.categoryHex))
            }
        }
    }
}

// MARK: - 锁屏视图

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TaskActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: context.attributes.categoryIcon)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(
                    Color(hex: context.attributes.categoryHex),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(context.attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                ProgressView(
                    timerInterval: context.state.startDate...context.state.endDate,
                    countsDown: false
                )
                .tint(Color(hex: context.attributes.categoryHex))
            }

            Spacer(minLength: 8)

            Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                .font(.title2.monospacedDigit().weight(.semibold))
                .frame(maxWidth: 80, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
    }
}

// MARK: - hex 颜色

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
