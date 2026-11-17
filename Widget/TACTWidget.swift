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
    @Environment(\.colorScheme) private var colorScheme
    var entry: AssignmentEntry

    var body: some View {
        WidgetCard(entry: entry, compact: family == .systemSmall)
            .containerBackground(for: .widget) {
                WidgetPalette.background(dark: colorScheme == .dark)
            }
    }
}

private enum WidgetPalette {
    static func background(dark: Bool) -> some View {
        LinearGradient(colors: dark
                       ? [Color(red: 0.12, green: 0.19, blue: 0.28), Color(red: 0.07, green: 0.11, blue: 0.18)]
                       : [Color(red: 0.97, green: 0.98, blue: 1), Color(red: 0.89, green: 0.94, blue: 0.99)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct WidgetCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: AssignmentEntry
    let compact: Bool

    private var dark: Bool { colorScheme == .dark }
    private var blue: Color { dark ? Color(red: 0.58, green: 0.81, blue: 1) : Color(red: 0.12, green: 0.36, blue: 0.64) }
    private var amber: Color { dark ? Color(red: 1, green: 0.77, blue: 0.42) : Color(red: 0.55, green: 0.29, blue: 0.05) }

    private let dayFormat = Date.FormatStyle().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "ja_JP"))
    private let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ja_JP"))

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 5) {
            header
            if let first = entry.assignments.first {
                if compact {
                    nextDeadline(first)
                } else {
                    deadlineList(Array(entry.assignments.prefix(3)))
                }
            } else {
                emptyState
            }
            if let snapshot = entry.snapshot {
                Spacer(minLength: 0)
                syncStatus(snapshot)
            }
        }
        .padding(.horizontal, compact ? 13 : 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(compact ? "次の締切" : "提出予定")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let first = entry.assignments.first {
                if compact {
                    Text(first.isQuiz == true ? "小テスト" : "課題")
                        .foregroundStyle(kindColor(for: first))
                } else {
                    Text("未提出 \(entry.assignments.count)件")
                        .monospacedDigit()
                        .foregroundStyle(blue)
                }
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)
    }

    private func nextDeadline(_ assignment: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if assignment.hasDeadline {
                    Text(assignment.due, format: dayFormat)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(assignment.due, format: timeFormat)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                } else {
                    Text("締切なし").font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(isUrgent(assignment) ? amber : .primary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .combine)

            Text(assignment.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: symbol(for: assignment))
                    .foregroundStyle(kindColor(for: assignment))
                    .widgetAccentable()
                    .accessibilityLabel(assignment.isQuiz == true ? "小テスト" : "課題")
                Text(courseName(assignment)).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
        }
    }

    private func deadlineList(_ assignments: [Assignment]) -> some View {
        VStack(spacing: 0) {
            ForEach(assignments) { assignment in
                if assignment.id != assignments.first?.id {
                    Rectangle()
                        .fill(.primary.opacity(0.11))
                        .frame(height: 0.5)
                        .padding(.leading, 26)
                        .accessibilityHidden(true)
                }
                deadlineRow(assignment)
            }
        }
    }

    private func deadlineRow(_ assignment: Assignment) -> some View {
        HStack(spacing: 7) {
            let color = kindColor(for: assignment)
            Image(systemName: symbol(for: assignment))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(color.opacity(dark ? 0.14 : 0.12), in: RoundedRectangle(cornerRadius: 6))
                .widgetAccentable()
                .accessibilityLabel(assignment.isQuiz == true ? "小テスト" : "課題")

            VStack(alignment: .leading, spacing: 0) {
                Text(assignment.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(courseName(assignment)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if assignment.hasDeadline {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(assignment.due, format: timeFormat)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isUrgent(assignment) ? amber : .primary)
                    Text(assignment.due, format: dayFormat)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("締切なし").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: emptyIcon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(blue)
                .accessibilityHidden(true)
            Text(emptyMessage)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var emptyIcon: String {
        switch entry.status {
        case .signedOut, .reconnect: "link"
        case .delayed: "arrow.clockwise"
        case .ready:
            if let snapshot = entry.snapshot, (snapshot.failedCourseCount ?? 0) == 0 {
                "checkmark.circle"
            } else {
                "clock"
            }
        }
    }

    private var emptyMessage: String {
        switch entry.status {
        case .signedOut: "アプリでTACTに接続"
        case .reconnect: "アプリでTACTに再接続"
        case .delayed: "更新できませんでした"
        case .ready:
            if let snapshot = entry.snapshot {
                (snapshot.failedCourseCount ?? 0) > 0 ? "一部の講義を取得できません" : "未提出の項目はありません"
            } else {
                "課題・小テストを取得中"
            }
        }
    }

    private func syncStatus(_ snapshot: Snapshot) -> some View {
        let partial = (snapshot.failedCourseCount ?? 0) > 0
        let status: (label: String, symbol: String)
        switch entry.status {
        case .reconnect: status = ("要再接続", "link")
        case .delayed: status = ("前回同期", "clock")
        case .ready, .signedOut:
            status = partial ? ("一部同期", "exclamationmark.circle") : ("同期", "arrow.clockwise")
        }

        return HStack(spacing: 4) {
            Image(systemName: status.symbol).accessibilityHidden(true)
            Text(status.label)
            if !Calendar.current.isDate(snapshot.syncedAt, inSameDayAs: entry.date) {
                Text(snapshot.syncedAt, format: dayFormat)
            }
            Text(snapshot.syncedAt, format: timeFormat).monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(entry.status == .reconnect ? amber : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private func courseName(_ assignment: Assignment) -> String {
        let suffix = #/\s*[（(]\s*[0-9]{4}年度?[^）)]*[）)]\s*$/#
        guard let range = assignment.course.firstMatch(of: suffix)?.range, range.lowerBound != assignment.course.startIndex else {
            return assignment.course
        }
        return String(assignment.course[..<range.lowerBound])
    }

    private func symbol(for assignment: Assignment) -> String {
        assignment.isQuiz == true ? "questionmark.circle" : "doc.text"
    }

    private func kindColor(for assignment: Assignment) -> Color { assignment.isQuiz == true ? amber : blue }

    private func isUrgent(_ assignment: Assignment) -> Bool {
        assignment.hasDeadline && assignment.due.timeIntervalSince(entry.date) <= 24 * 3600
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
