import SwiftUI
import WidgetKit

struct AssignmentEntry: TimelineEntry {
    var date: Date
    let snapshot: Snapshot?
    let status: SyncStatus
    var lastAttemptAt: Date? = nil
    var rooms: [String: String] = [:]
    var summaries: [String: AssignmentSummaryPreview] = [:]
    var assignments: [Assignment] { snapshot?.upcoming(at: date) ?? [] }
}

private let urgentDeadlineInterval: TimeInterval = 3 * 60 * 60

private extension WidgetFamily {
    var isExtraLargePortrait: Bool {
        if #available(iOS 27.0, *) { return self == .systemExtraLargePortrait }
        return false
    }

    var showsSummaries: Bool {
        self == .systemLarge || self == .systemExtraLarge || isExtraLargePortrait
    }
}

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
                       due: now.addingTimeInterval(2 * 3600), closes: now.addingTimeInterval(2 * 3600), submitted: false),
            Assignment(id: "example-2", title: "第7回 確認テスト", course: "オペレーティング・システム",
                       due: now.addingTimeInterval(36 * 3600), closes: now.addingTimeInterval(36 * 3600), submitted: false, isQuiz: true),
            Assignment(id: "example-3", title: "構文解析レポート", course: "コンパイラ",
                       due: now.addingTimeInterval(52 * 3600), closes: now.addingTimeInterval(52 * 3600), submitted: false)
        ]
        let snapshot = Snapshot(sessionID: UUID(), syncedAt: now, assignments: examples)
        let summaries = [
            "example-1": AssignmentSummaryPreview(text: "指定の係数で応答を計算し、グラフと考察を1つのPDFにまとめて提出する。", includesAllPDFs: true),
            "example-3": AssignmentSummaryPreview(text: "配布された文法に従って構文木を描き、導出手順をレポートに記載する。", includesAllPDFs: true)
        ]
        return AssignmentEntry(date: now, snapshot: snapshot, status: .ready, summaries: summaries)
    }

    func getSnapshot(in context: Context, completion: @escaping (AssignmentEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        var entry = cachedEntry()
        loadSummaries(into: &entry, for: context.family)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AssignmentEntry>) -> Void) {
        if context.family.isExtraLargePortrait {
            completion(makeTimeline(from: cachedEntry(), family: context.family))
            Task { @MainActor in _ = await WidgetBackgroundSync.shared.entry() }
            return
        }
        Task { @MainActor in
            var delivered = false
            let fallback = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                delivered = true
                completion(makeTimeline(from: cachedEntry(), family: context.family))
            }
            let entry = await WidgetBackgroundSync.shared.entry()
            fallback.cancel()
            if !delivered {
                completion(makeTimeline(from: entry, family: context.family))
            }
        }
    }

    private func cachedEntry() -> AssignmentEntry {
        do {
            guard let session = try TACTStore.session() else {
                return AssignmentEntry(date: .now, snapshot: nil, status: .signedOut, rooms: TimetableRooms.values)
            }
            let snapshot = TACTStore.snapshot(for: session.id)
            return AssignmentEntry(date: .now, snapshot: snapshot, status: .ready, rooms: TimetableRooms.values)
        } catch {
            return AssignmentEntry(date: .now, snapshot: nil, status: .delayed, rooms: TimetableRooms.values)
        }
    }

    private func makeTimeline(from cached: AssignmentEntry, family: WidgetFamily) -> Timeline<AssignmentEntry> {
        var entry = cached
        entry.rooms = TimetableRooms.values
        loadSummaries(into: &entry, for: family)
        let lastAttempt = entry.lastAttemptAt ?? entry.snapshot?.syncedAt ?? entry.date
        let scheduled = WidgetSyncSchedule.nextAttempt(after: lastAttempt)
        let midnight = AcademicDay.nextDay(after: entry.date)
        let nextSync = entry.status == .signedOut ? midnight : max(entry.date.addingTimeInterval(5 * 60), scheduled)
        var displayDates = Set(entry.assignments.flatMap {
            [$0.due.addingTimeInterval(-urgentDeadlineInterval), $0.due.addingTimeInterval(-60), $0.due, $0.closes]
        }.filter { entry.date < $0 && $0 < nextSync })
        if midnight <= nextSync { displayDates.insert(midnight) }
        if family != .systemSmall, let timetable = entry.snapshot?.timetable {
            // Keep the end-of-class change available even if WidgetKit delays the next sync.
            let today = TimetableDay(classes: timetable, at: entry.date)
            displayDates.formUnion(today.changeDates.filter { $0 > entry.date })
        }
        if (family.showsSummaries || !Self.usesDynamicDates), entry.snapshot != nil {
            // Update static countdowns independently of TACT requests.
            let interval: TimeInterval = 5 * 60
            let offsets = stride(from: interval, to: nextSync.timeIntervalSince(entry.date), by: interval)
            displayDates.formUnion(offsets.map { entry.date.addingTimeInterval($0) })
        }
        let entries = [entry] + displayDates.sorted().map {
            var future = entry
            future.date = $0
            return future
        }
        return Timeline(entries: entries, policy: .after(nextSync))
    }

    private static var usesDynamicDates: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    private func loadSummaries(into entry: inout AssignmentEntry, for family: WidgetFamily) {
        guard family.showsSummaries, let snapshot = entry.snapshot, let account = snapshot.summaryAccount else { return }
        // Load a few extra entries so the next item can appear when a deadline passes.
        for assignment in snapshot.upcoming(at: entry.date).filter({ $0.isQuiz != true }).prefix(8) {
            entry.summaries[assignment.id] = AssignmentSummaryStore.preview(for: assignment, account: account)
        }
    }
}

struct AssignmentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    var entry: AssignmentEntry

    var body: some View {
        WidgetCard(entry: entry, compact: family == .systemSmall, large: family == .systemLarge,
                   extraLarge: family == .systemExtraLarge, tall: family.isExtraLargePortrait)
            .containerBackground(WidgetPalette.background(colorScheme), for: .widget)
            .widgetURL(family.showsSummaries
                       ? entry.assignments.first(where: { $0.detailURL != nil })?.detailURL : nil)
    }
}

private enum WidgetPalette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.085, green: 0.115, blue: 0.18)
            : Color(red: 0.966, green: 0.975, blue: 0.998)
    }

    static func category(_ assignment: Assignment, _ scheme: ColorScheme) -> Color {
        if assignment.isQuiz == true {
            return scheme == .dark ? Color(red: 0.84, green: 0.73, blue: 1)
                : Color(red: 0.40, green: 0.22, blue: 0.66)
        }
        return scheme == .dark ? Color(red: 0.58, green: 0.80, blue: 1)
            : Color(red: 0.12, green: 0.34, blue: 0.69)
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
    var large = false
    var extraLarge = false
    var tall = false

    private var displayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    var body: some View {
        if large || extraLarge || tall {
            summaryCard
        } else {
            standardCard
        }
    }

    private var standardCard: some View {
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
                    .frame(maxHeight: compact ? .infinity : nil, alignment: .center)
            }
            if !compact {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Label("\(AcademicDay(on: entry.date).weekdayLabel)曜の時間割", systemImage: "calendar")
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

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("締切の近い課題", systemImage: "checklist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.indigo)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize()
                Spacer(minLength: 0)
                if let snapshot = entry.snapshot { syncStatus(snapshot, trailing: true) }
            }
            Divider()

            if entry.assignments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: entry.snapshot == nil ? "arrow.trianglehead.clockwise" : "tray")
                        .font(.title2)
                        .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.indigo)
                        .accessibilityHidden(true)
                    Text(emptyMessage)
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                let assignments = Array(entry.assignments.prefix(extraLarge ? 6 : tall ? 4 : 3))
                if extraLarge && assignments.count > 1 {
                    let columnCount = (assignments.count + 1) / 2
                    HStack(alignment: .top, spacing: 14) {
                        summaryRows(Array(assignments.prefix(columnCount)), lineLimit: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle()
                            .fill(.secondary.opacity(0.25))
                            .frame(width: 1)
                            .accessibilityHidden(true)
                        summaryRows(Array(assignments.dropFirst(columnCount)), lineLimit: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    summaryRows(assignments, lineLimit: assignments.count >= 3 ? 1 : assignments.count == 2 ? 2 : 5)
                }
                Spacer(minLength: 0)
            }

            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("\(AcademicDay(on: entry.date).weekdayLabel)曜の時間割", systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.indigo)
                    .accessibilityAddTraits(.isHeader)
                TimetableWidget(timetable: entry.snapshot?.timetable, rooms: entry.rooms, date: entry.date)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summaryRows(_ assignments: [Assignment], lineLimit: Int? = nil) -> some View {
        let lines = lineLimit ?? (assignments.count == 1 ? 8 : assignments.count == 2 ? 4 : 2)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(assignments) { assignment in
                summaryRow(assignment, lines: lines)
            }
        }
    }

    private func summaryRow(_ assignment: Assignment, lines: Int) -> some View {
        let preview = entry.summaries[assignment.id]
        let tint = WidgetPalette.category(assignment, colorScheme)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(assignment.displayCourse)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetPalette.category(assignment, colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
                deadline(assignment)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(title(assignment))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if let summary = preview?.text {
                Text((preview?.includesAllPDFs == false ? "一部PDF未反映 · " : "") + summary.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(lines)
                    .privacySensitive()
            } else if let excerpt = preview?.originalExcerpt {
                Text("指示文 · " + excerpt.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(lines)
                    .privacySensitive()
            } else if assignment.isQuiz != true {
                Text("内容はアプリで確認")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, tall ? 4 : 6)
        .background(tint.opacity(colorScheme == .dark ? 0.11 : 0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 2).padding(.vertical, 6).accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private func nextAssignment(_ assignment: Assignment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.displayCourse)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetPalette.category(assignment, colorScheme))
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
                GeometryReader { geometry in
                    let spacing: CGFloat = 6
                    let columnWidth = max(0, (geometry.size.width - 2 * spacing) / 3)

                    HStack(spacing: spacing) {
                        Text(assignment.displayCourse)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.84)
                            .frame(width: columnWidth, alignment: .leading)

                        Text(title(assignment))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(WidgetPalette.category(assignment, colorScheme))
                            .minimumScaleFactor(0.86)
                            .frame(width: columnWidth, alignment: .leading)

                        deadline(assignment)
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.trailing)
                            .frame(width: columnWidth, alignment: .trailing)
                    }
                    .lineLimit(1)
                    .frame(height: geometry.size.height)
                }
                .frame(height: 24)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func deadline(_ assignment: Assignment) -> Text {
        guard assignment.hasDeadline else { return Text("締切なし").foregroundColor(.secondary) }
        let remaining = assignment.due.timeIntervalSince(entry.date)
        let color = remaining <= urgentDeadlineInterval ? WidgetPalette.urgent(colorScheme)
            : WidgetPalette.category(assignment, colorScheme)
        if remaining <= 0 { return Text("締切超過").foregroundColor(color) }
        if remaining < 60 { return Text("あと1分未満").foregroundColor(color) }

        if #available(iOS 18.0, macOS 15.0, *), !large, !extraLarge, !tall {
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
        if #available(iOS 18.0, macOS 15.0, *), !large, !extraLarge, !tall {
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


}

@main
struct TACTWidget: Widget {
    private var families: [WidgetFamily] {
        let standard: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { return standard + [.systemExtraLargePortrait] }
        return standard
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TACTAssignments", provider: AssignmentProvider()) { entry in
            AssignmentWidgetView(entry: entry)
        }
        .configurationDisplayName("TACTの課題・小テスト")
        .description("横長は今日の時間割、大サイズは締切が近い課題とその内容を表示します。")
        .supportedFamilies(families)
        .contentMarginsDisabled()
        .onBackgroundURLSessionEvents(matching: WidgetBackgroundSync.identifier) { _, completion in
            WidgetBackgroundSync.shared.receiveEvents(completion: completion)
        }
    }
}
