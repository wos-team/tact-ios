import AppIntents
import Foundation

enum TimetableWeekday: Int, CaseIterable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .monday: "月"
        case .tuesday: "火"
        case .wednesday: "水"
        case .thursday: "木"
        case .friday: "金"
        case .saturday: "土"
        case .sunday: "日"
        }
    }
}

struct TimetablePeriod: Identifiable {
    let id: Int
    let start: String
    let end: String

    // Nagoya University’s standard 90-minute periods.
    static let standard = [
        Self(id: 1, start: "08:45", end: "10:15"),
        Self(id: 2, start: "10:30", end: "12:00"),
        Self(id: 3, start: "13:00", end: "14:30"),
        Self(id: 4, start: "14:45", end: "16:15"),
        Self(id: 5, start: "16:30", end: "18:00")
    ]
}

struct TimetableSlot: Hashable, Codable {
    let weekday: Int
    let period: Int
}

struct TimetableClass: Codable {
    var name = ""
    var room = ""
}

struct Timetable: Codable {
    var classes: [TimetableSlot: TimetableClass] = [:]

    static var campusCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func weekday(on date: Date) -> TimetableWeekday {
        TimetableWeekday(rawValue: campusCalendar.component(.weekday, from: date))!
    }

    static func nextDay(after date: Date) -> Date {
        campusCalendar.dateInterval(of: .day, for: date)!.end
    }

    func lesson(on day: TimetableWeekday, period: TimetablePeriod) -> TimetableClass? {
        classes[TimetableSlot(weekday: day.rawValue, period: period.id)]
    }

    func normalized() -> Timetable {
        Timetable(classes: classes.compactMapValues { lesson in
            let name = lesson.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return TimetableClass(name: name, room: lesson.room.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }
}

enum TimetableStore {
    private static let scheduleKey = "weeklyTimetable"
    private static let viewKey = "showWidgetTimetable"

    static var showsTimetable: Bool {
        UserDefaults(suiteName: TACTStore.group)?.bool(forKey: viewKey) ?? false
    }

    static func setShowsTimetable(_ value: Bool) throws {
        guard let defaults = UserDefaults(suiteName: TACTStore.group) else { throw TACTError.storage }
        defaults.set(value, forKey: viewKey)
    }

    static func load() -> Timetable {
        guard let data = UserDefaults(suiteName: TACTStore.group)?.data(forKey: scheduleKey),
              let schedule = try? JSONDecoder().decode(Timetable.self, from: data) else {
            return Timetable()
        }
        return schedule
    }

    static func save(_ schedule: Timetable) throws {
        guard let defaults = UserDefaults(suiteName: TACTStore.group) else { throw TACTError.storage }
        defaults.set(try JSONEncoder().encode(schedule.normalized()), forKey: scheduleKey)
    }
}

struct SetWidgetTimetableIntent: AppIntent {
    static let title: LocalizedStringResource = "ウィジェットの表示切り替え"
    static let openAppWhenRun = false

    @Parameter(title: "時間割を表示")
    var showsTimetable: Bool

    init() {}

    init(showsTimetable: Bool) {
        self.showsTimetable = showsTimetable
    }

    func perform() async throws -> some IntentResult {
        try TimetableStore.setShowsTimetable(showsTimetable)
        return .result()
    }
}
