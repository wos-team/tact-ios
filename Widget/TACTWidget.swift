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
        let examples = [
            Assignment(id: "example-1", title: "第6回 演習課題", course: "知能システム制御",
                       due: now.addingTimeInterval(6 * 3600), closes: now.addingTimeInterval(6 * 3600), submitted: false),
            Assignment(id: "example-2", title: "第7回 確認テスト", course: "オペレーティング・システム",
                       due: now.addingTimeInterval(36 * 3600), closes: now.addingTimeInterval(36 * 3600), submitted: false, isQuiz: true),
            Assignment(id: "example-3", title: "構文解析レポート", course: "コンパイラ",
                       due: now.addingTimeInterval(52 * 3600), closes: now.addingTimeInterval(52 * 3600), submitted: false)
        ]
        let snapshot = Snapshot(sessionID: UUID(), syncedAt: now, assignments: examples)
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
            var displayDates = Set(entry.assignments.flatMap {
                [$0.due.addingTimeInterval(-60), $0.due, $0.closes]
            }.filter { entry.date < $0 && $0 < nextSync })
            if #unavailable(iOS 18.0, macOS 15.0), entry.snapshot != nil {
                // Older iOS needs entries for text updates, independent of TACT requests.
                let interval: TimeInterval = 5 * 60
                let offsets = stride(from: interval, to: nextSync.timeIntervalSince(entry.date), by: interval)
                displayDates.formUnion(offsets.map { entry.date.addingTimeInterval($0) })
            }
            let entries = [entry] + displayDates.sorted().map {
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
        WidgetCard(entry: entry, compact: family == .systemSmall)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WidgetCard: View {
    let entry: AssignmentEntry
    let compact: Bool

    private var displayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let first = entry.assignments.first {
                if compact {
                    nextAssignment(first)
                } else {
                    assignmentList(Array(entry.assignments.prefix(3)))
                }
            } else {
                Text(emptyMessage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            if let snapshot = entry.snapshot {
                Spacer(minLength: 0)
                syncStatus(snapshot)
            }
        }
        .padding(.horizontal, compact ? 13 : 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nextAssignment(_ assignment: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(courseName(assignment))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(title(assignment))
                .font(.system(size: 14))
                .lineLimit(2)
            Spacer(minLength: 3)
            deadline(assignment)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func assignmentList(_ assignments: [Assignment]) -> some View {
        VStack(spacing: 0) {
            ForEach(assignments) { assignment in
                if assignment.id != assignments.first?.id {
                    Divider()
                }
                HStack(alignment: .center, spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(courseName(assignment))
                            .font(.system(size: 12, weight: .semibold))
                        Text(title(assignment))
                            .font(.system(size: 11))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    deadline(assignment)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 89, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func deadline(_ assignment: Assignment) -> Text {
        guard assignment.hasDeadline else { return Text("締切なし").foregroundColor(.secondary) }
        let remaining = assignment.due.timeIntervalSince(entry.date)
        if remaining <= 0 { return Text("締切超過").foregroundColor(.red) }
        if remaining < 60 { return Text("あと1分未満") }

        if #available(iOS 18.0, macOS 15.0, *) {
            let format = SystemFormatStyle.DateOffset(
                to: assignment.due, allowedFields: [.day, .hour, .minute], maxFieldCount: 2, sign: .never
            ).calendar(displayCalendar)
            return Text("あと\(TimeDataSource<Date>.currentDate, format: format)")
        }
        return Text("あと\(durationText(remaining))")
    }

    private var emptyMessage: String {
        switch entry.status {
        case .signedOut: "アプリでTACTに接続"
        case .reconnect: "アプリでTACTに再接続"
        case .delayed: "更新できませんでした"
        case .ready:
            if let snapshot = entry.snapshot {
                (snapshot.failedCourseCount ?? 0) > 0 ? "一部の講義を取得できません" : "未提出の課題・小テストはありません"
            } else {
                "課題・小テストを取得中"
            }
        }
    }

    private func syncStatus(_ snapshot: Snapshot) -> some View {
        let label: String
        switch entry.status {
        case .reconnect: label = "要再接続"
        case .delayed: label = "前回同期"
        case .ready, .signedOut: label = (snapshot.failedCourseCount ?? 0) > 0 ? "一部同期" : "同期"
        }
        let elapsed: Text
        if #available(iOS 18.0, macOS 15.0, *) {
            let format = SystemFormatStyle.DateReference(
                to: snapshot.syncedAt, allowedFields: [.minute, .hour, .day], thresholdField: .day
            ).calendar(displayCalendar)
            elapsed = Text(.currentDate, format: format)
        } else {
            let age = entry.date.timeIntervalSince(snapshot.syncedAt)
            elapsed = age < 60 ? Text("たった今") : Text("\(durationText(age))前")
        }

        return Text("\(label) \(elapsed)")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int(max(0, duration) / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)日\(hours % 24)時間" }
        if hours > 0 { return "\(hours)時間\(minutes % 60)分" }
        return "\(minutes)分"
    }

    private func title(_ assignment: Assignment) -> String {
        assignment.isQuiz == true ? "小テスト · \(assignment.title)" : assignment.title
    }

    private func courseName(_ assignment: Assignment) -> String {
        let suffix = #/\s*[（(]\s*[0-9]{4}年度?[^）)]*[）)]\s*$/#
        guard let range = assignment.course.firstMatch(of: suffix)?.range, range.lowerBound != assignment.course.startIndex else {
            return assignment.course
        }
        return String(assignment.course[..<range.lowerBound])
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
        .contentMarginsDisabled()
    }
}
