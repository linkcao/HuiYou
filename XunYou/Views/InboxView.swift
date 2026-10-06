import SwiftUI

/// 池子：子弹日记的「随手记」。
///
/// 想到什么先丢进来，不用管什么时候做；它不会自己消失，
/// 也不会自动出现在「今天」——AI 规划时会从这儿挑一两件问你。
struct InboxView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var showArchive = false
    @FocusState private var inputFocused: Bool

    private var canCapture: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                captureBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.inbox.isEmpty {
                            emptyHint
                        } else {
                            poolList
                        }
                        archiveSection
                    }
                    .padding()
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("池子")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 随手记

    private var captureBar: some View {
        HStack(spacing: 8) {
            TextField("想到什么先丢进来…", text: $draft, axis: .vertical)
                .lineLimit(1...3)
                .focused($inputFocused)
                .submitLabel(.done)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit(capture)

            Button(action: capture) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(canCapture ? .accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canCapture)
            .accessibilityLabel("丢进池子")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func capture() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.add(title: text, isSomeday: true)
        draft = ""
        inputFocused = true        // 连着记好几条时不用重新点输入框
    }

    // MARK: - 列表

    private var poolList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("池子里 \(store.inboxCount) 件")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("不排期，也不会丢")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(store.inbox) { item in
                poolRow(item)
            }
        }
    }

    private func poolRow(_ item: TaskItem) -> some View {
        let days = store.daysInPool(item)
        let isStale = days >= TaskStore.staleDays
        let color = item.category.color

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.category.icon)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(item.category.label)
                    if let d = item.durationMinutes {
                        Text("约 \(d) 分钟")
                    }
                    Text(days == 0 ? "今天丢进来的" : "躺了 \(days) 天")
                        .foregroundColor(days >= 7 ? .red : .secondary)
                    if isStale {
                        Text("还做吗？")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let note = item.notes, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                withAnimation { _ = store.promote(id: item.id, to: Calendar.current.startOfDay(for: Date())) }
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
                        withAnimation { _ = store.archive(id: item.id) }
                    } label: {
                        Label("不做了（归档）", systemImage: "archivebox")
                    }
                    Divider()
                }
                Button {
                    store.promote(id: item.id, to: tomorrow)
                } label: {
                    Label("明天做", systemImage: "sunrise")
                }
                Button {
                    store.promote(id: item.id, to: nextWeek)
                } label: {
                    Label("下周再说", systemImage: "calendar.badge.clock")
                }
                Divider()
                Button {
                    store.snooze(id: item.id, days: 7)
                } label: {
                    Label("一周内先别提", systemImage: "bell.slash")
                }
                if !isStale {
                    Button(role: .destructive) {
                        withAnimation { _ = store.archive(id: item.id) }
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
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var nextWeek: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    // MARK: - 空状态 / 已归档

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.7))
            Text("池子还空着")
                .font(.headline)
            Text("想到什么先丢进来，不用管什么时候做。\n它不会自己消失，也不会挤进今天的安排；\n等你规划的时候，我会从这儿挑出来问你。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    @ViewBuilder
    private var archiveSection: some View {
        let archived = store.archivedItems
        if !archived.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation { showArchive.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(.caption)
                        Text("已归档 \(archived.count)")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .rotationEffect(.degrees(showArchive ? 0 : -90))
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                if showArchive {
                    Text("归档只是从池子里移开，记录一直留着。")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    ForEach(archived) { item in
                        HStack(spacing: 10) {
                            Text(item.title)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                withAnimation { _ = store.restore(id: item.id) }
                            } label: {
                                Text("放回池子")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }
}
