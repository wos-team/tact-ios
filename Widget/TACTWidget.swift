import SwiftUI
import WidgetKit

struct AssignmentEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    let status: SyncStatus
    var assignments: [Assignment] { snapshot?.upcoming(at: date) ?? [] }
}

enum SyncStatus {
    case signedOut
    case ready
    case reconnect
    case delayed
}

struct AssignmentProvider: TimelineProvider {
    func placeholder(in context: Context) -> AssignmentEntry {
        let now = Date()
        let due = now.addingTimeInterval(6 * 60 * 60)
        let example = Assignment(id: "example", title: "第4回 レポート", course: "情報リテラシー", due: due, closes: due, submitted: false)
        let snapshot = Snapshot(sessionID: UUID(), syncedAt: now, assignments: [example])
        return AssignmentEntry(date: now, snapshot: snapshot, status: .ready)
    }

    func getSnapshot(in context: Context, completion: @escaping (AssignmentEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let session = try? TACTStore.session()
        let snapshot = session.flatMap { TACTStore.snapshot(for: $0.id) }
        completion(AssignmentEntry(date: .now, snapshot: snapshot, status: session == nil ? .signedOut : .ready))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AssignmentEntry>) -> Void) {
        Task {
            let entry = await loadEntry()
            let lastAttempt = entry.status == .ready ? entry.snapshot?.syncedAt ?? entry.date : entry.date
            let nextSync = max(entry.date.addingTimeInterval(5 * 60),
                               lastAttempt.addingTimeInterval(TACTClient.refreshInterval))
            let closeTimes = Set(entry.assignments.map(\.closes)).filter { $0 < nextSync }
            let entries = [entry] + closeTimes.sorted().map {
                AssignmentEntry(date: $0, snapshot: entry.snapshot, status: entry.status)
            }
            completion(Timeline(entries: entries, policy: entry.status == .signedOut ? .never : .after(nextSync)))
        }
    }

    private func loadEntry() async -> AssignmentEntry {
        do {
            guard let session = try TACTStore.session() else {
                return AssignmentEntry(date: .now, snapshot: nil, status: .signedOut)
            }
            let cached = TACTStore.snapshot(for: session.id)
            if let cached, Date().timeIntervalSince(cached.syncedAt) < TACTClient.refreshInterval {
                return AssignmentEntry(date: .now, snapshot: cached, status: .ready)
            }

            do {
                let snapshot = try await TACTClient.fetch(using: session)
                guard try TACTStore.session()?.id == session.id else {
                    return AssignmentEntry(date: .now, snapshot: nil, status: .delayed)
                }
                try TACTStore.save(snapshot)
                return AssignmentEntry(date: .now, snapshot: TACTStore.snapshot(for: session.id), status: .ready)
            } catch TACTError.signInRequired {
                return AssignmentEntry(date: .now, snapshot: cached, status: .reconnect)
            } catch {
                return AssignmentEntry(date: .now, snapshot: cached, status: .delayed)
            }
        } catch {
            return AssignmentEntry(date: .now, snapshot: nil, status: .delayed)
        }
    }
}

struct AssignmentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AssignmentEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("課題・小テスト", systemImage: "checklist")
                .font(.caption.bold())
                .foregroundStyle(.tint)

            let assignments = entry.assignments.prefix(family == .systemSmall ? 1 : 3)
            if assignments.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
            }
            ForEach(assignments) { assignment in
                if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assignment.title).font(.subheadline.bold()).lineLimit(2)
                        Text(assignment.courseLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        deadline(for: assignment)
                            .font(.caption.bold())
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(assignment.title).fontWeight(.semibold).lineLimit(1)
                        Text(assignment.courseLabel).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        deadline(for: assignment)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                Text(syncLabel(snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func deadline(for assignment: Assignment) -> Text {
        if assignment.hasDeadline {
            return Text(assignment.due, format: .dateTime.month().day().hour().minute())
        }
        return Text("締切なし")
    }

    private var emptyMessage: String {
        switch entry.status {
        case .signedOut: "アプリを開いてTACTに接続"
        case .ready:
            if let snapshot = entry.snapshot {
                (snapshot.failedCourseCount ?? 0) > 0 ? "一部の講義を取得できません" : "未提出の課題・小テストはありません"
            } else {
                "課題・小テストを取得中"
            }
        case .reconnect: "アプリを開いて再接続"
        case .delayed: "課題・小テストを更新できません"
        }
    }

    private func syncLabel(_ snapshot: Snapshot) -> String {
        let time = snapshot.syncedAt.formatted(.dateTime.month().day().hour().minute())
        if entry.status == .reconnect { return "要再接続・\(time)" }
        if (snapshot.failedCourseCount ?? 0) > 0 { return "一部同期 \(time)" }
        return "同期 \(time)"
    }
}

@main
struct TACTWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TACTAssignments", provider: AssignmentProvider()) { entry in
            AssignmentWidgetView(entry: entry)
        }
        .configurationDisplayName("TACTの課題・小テスト")
        .description("締切が近い未提出の課題・小テストを表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
