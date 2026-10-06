import SwiftUI

struct TaskListView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var showAdd = false
    @State private var categoryFilter: TaskCategory?

    private var filterIcon: String {
        categoryFilter == nil
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var pending: [TaskItem] {
        store.tasks.filter { t in
            guard !t.isDone else { return false }
            guard let f = categoryFilter else { return true }
            return t.category == f
        }
        .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var done: [TaskItem] {
        store.tasks.filter { t in
            guard t.isDone else { return false }
            guard let f = categoryFilter else { return true }
            return t.category == f
        }
        .sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.tasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("还没有事项")
                            .foregroundColor(.secondary)
                        Text("在对话里说「记一下：周末给猫驱虫」\n就会出现在这里")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        Section("待办 · \(pending.count)") {
                            ForEach(pending) { task in
                                TaskRow(task: task)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button {
                                            store.complete(id: task.id)
                                        } label: {
                                            Label("完成", systemImage: "checkmark")
                                        }
                                        .tint(.green)
                                        Button(role: .destructive) {
                                            store.delete(id: task.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }

                        Section("已完成 · \(done.count)") {
                            ForEach(done) { task in
                                TaskRow(task: task)
                                    .swipeActions(edge: .trailing) {
                                        Button {
                                            store.reopen(id: task.id)
                                        } label: {
                                            Label("恢复", systemImage: "arrow.uturn.backward")
                                        }
                                        .tint(.orange)
                                        Button(role: .destructive) {
                                            store.delete(id: task.id)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("事项")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("全部分类") { categoryFilter = nil }
                        ForEach(TaskCategory.allCases) { c in
                            Button {
                                categoryFilter = c
                            } label: {
                                Label(c.label, systemImage: c.icon)
                            }
                        }
                    } label: {
                        Image(systemName: filterIcon)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddTaskSheet()
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

// MARK: - 行

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.category.icon)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(task.category.color))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundColor(task.isDone ? .secondary : .primary)

                HStack(spacing: 8) {
                    Text(task.category.label)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(task.category.color.opacity(0.15), in: Capsule())

                    if let due = task.dueDate, !task.isDone {
                        Label(TaskDate.format(due), systemImage: "clock")
                    }
                    if let dur = task.durationMinutes {
                        Label("\(dur)分钟", systemImage: "timer")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let n = task.notes, !n.isEmpty {
                    Text(n)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
