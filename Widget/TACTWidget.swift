import SwiftUI
import WidgetKit

struct AssignmentEntry: TimelineEntry {
    var date: Date
    let snapshot: Snapshot?
    let status: SyncStatus
    var lastAttemptAt: Date? = nil
    var rooms: [String: String] = [:]
    var assignments: [Assignment] { snapshot?.upcoming(at: date) ?? [] }
}

private let urgentDeadlineInterval: TimeInterval = 3 * 60 * 60

enum SyncStatus {
    case signedOut
    case ready
    case syncing
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
        completion(AssignmentEntry(date: .now, snapshot: snapshot, status: session == nil ? .signedOut : .ready,
                                   rooms: TimetableRooms.values))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AssignmentEntry>) -> Void) {
        Task {
            let firstDayEnd = TACTStore.widgetFirstDayEnd
            var entry = await WidgetBackgroundSync.shared.entry(firstDayEnd: firstDayEnd)
            entry.rooms = TimetableRooms.values

            let lastAttempt = entry.lastAttemptAt ?? entry.snapshot?.syncedAt ?? entry.date
            let scheduled = WidgetSyncSchedule.nextAttempt(after: lastAttempt, at: entry.date, firstDayEnd: firstDayEnd)
            let midnight = AcademicDay.nextDay(after: entry.date)
            let nextSync = entry.status == .signedOut ? midnight : max(entry.date.addingTimeInterval(5 * 60), scheduled)
            var displayDates = Set(entry.assignments.flatMap {
                [$0.due.addingTimeInterval(-urgentDeadlineInterval), $0.due.addingTimeInterval(-60), $0.due, $0.closes]
            }.filter { entry.date < $0 && $0 < nextSync })
            if midnight <= nextSync { displayDates.insert(midnight) }
            if #unavailable(iOS 18.0, macOS 15.0), entry.snapshot != nil {
                // Older iOS needs entries for text updates, independent of TACT requests.
                let interval: TimeInterval = 5 * 60
                let offsets = stride(from: interval, to: nextSync.timeIntervalSince(entry.date), by: interval)
                displayDates.formUnion(offsets.map { entry.date.addingTimeInterval($0) })
            }
            let entries = [entry] + displayDates.sorted().map {
                var future = entry
                future.date = $0
                return future
            }
            completion(Timeline(entries: entries, policy: .after(nextSync)))
        }
    }
}

struct AssignmentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    var entry: AssignmentEntry

    var body: some View {
        WidgetCard(entry: entry, compact: family == .systemSmall)
            .containerBackground(WidgetPalette.background(colorScheme), for: .widget)
    }
}

private enum WidgetPalette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.131, green: 0.134, blue: 0.127)
            : Color(red: 0.973, green: 0.969, blue: 0.950)
    }

    static func urgent(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.99, green: 0.70, blue: 0.64)
            : Color(red: 0.60, green: 0.24, blue: 0.18)
    }
}

struct WidgetCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: AssignmentEntry
    let compact: Bool

    private var displayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 2) {
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
            if !compact {
                Spacer(minLength: 0)
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("\(AcademicDay(on: entry.date).weekdayLabel)曜の時間割")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        if let snapshot = entry.snapshot {
                            syncStatus(snapshot, trailing: true)
                        }
                    }
                    TimetableWidget(timetable: entry.snapshot?.timetable, rooms: entry.rooms, date: entry.date)
                }
                .layoutPriority(1)
            } else if let snapshot = entry.snapshot {
                Spacer(minLength: 0)
                Divider()
                syncStatus(snapshot)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.top, compact ? 14 : 8)
        .padding(.bottom, compact ? 11 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nextAssignment(_ assignment: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(courseName(assignment))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(title(assignment))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 5)
            deadline(assignment)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.80)
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
                    VStack(alignment: .leading, spacing: 0) {
                        Text(courseName(assignment))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(height: 11)
                        Text(title(assignment))
                            .font(.system(size: 11, weight: .semibold))
                            .frame(height: 12)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    deadline(assignment)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 88, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func deadline(_ assignment: Assignment) -> Text {
        guard assignment.hasDeadline else { return Text("締切なし").foregroundColor(.secondary) }
        let remaining = assignment.due.timeIntervalSince(entry.date)
        let color = remaining <= urgentDeadlineInterval ? WidgetPalette.urgent(colorScheme) : Color.primary
        if remaining <= 0 { return Text("締切超過").foregroundColor(color) }
        if remaining < 60 { return Text("あと1分未満").foregroundColor(color) }

        if #available(iOS 18.0, macOS 15.0, *) {
            let format = SystemFormatStyle.DateOffset(
                to: assignment.due, allowedFields: [.day, .hour, .minute], maxFieldCount: 2, sign: .never
            ).calendar(displayCalendar)
            return Text("あと\(TimeDataSource<Date>.currentDate, format: format)").foregroundColor(color)
        }
        return Text("あと\(durationText(remaining))").foregroundColor(color)
    }

    private var emptyMessage: String {
        switch entry.status {
        case .signedOut: "アプリでTACTに接続"
        case .reconnect: "アプリでTACTに再接続"
        case .delayed: "更新できませんでした"
        case .syncing: "課題・小テストを同期中"
        case .ready:
            if let snapshot = entry.snapshot {
                (snapshot.failedCourseCount ?? 0) > 0 ? "一部の講義を取得できません" : "未提出の課題・小テストはありません"
            } else {
                "課題・小テストを取得中"
            }
        }
    }

    private func syncStatus(_ snapshot: Snapshot, trailing: Bool = false) -> some View {
        let label: String
        switch entry.status {
        case .reconnect: label = "要再接続"
        case .delayed: label = "同期失敗・前回"
        case .syncing: label = "同期中・前回"
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
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .multilineTextAlignment(trailing ? .trailing : .leading)
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
        .description("横長サイズは、締切が近い未提出項目と今日の時間割を表示します。")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
        .onBackgroundURLSessionEvents(matching: WidgetBackgroundSync.identifier) { _, completion in
            WidgetBackgroundSync.shared.receiveEvents(completion: completion)
        }
    }
}
