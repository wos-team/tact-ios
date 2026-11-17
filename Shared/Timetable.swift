import Foundation

struct TimetableSlot: Hashable, Codable {
    let weekday: Int
    let period: Int
}

struct TimetableClass: Identifiable, Codable {
    enum Season: String, Codable { case spring, fall, fullYear }

    let id: String
    let name: String
    let year: Int
    let season: Season
    let quarter: Int?
    let slots: [TimetableSlot]

    init?(site: SiteResponse.Site) {
        let format = #/[（(]\s*([0-9]{4})\s*年度\s*(春学期|秋学期|春|秋|前期|後期|通年)\s*(?:(II|I|[12一二])\s*期?)?\s*[/／]\s*([^）)]+)[）)]/#
        guard let match = site.title.precomposedStringWithCompatibilityMapping.firstMatch(of: format)
            ?? site.shortDescription?.precomposedStringWithCompatibilityMapping.firstMatch(of: format),
              let year = Int(match.1) else { return nil }

        let words = ["日", "月", "火", "水", "木", "金", "土"]
        let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let periodFormat = #/([日月火水木金土])(?:曜日|曜)?\s*([1-9一二三四五六七八九])\s*(?:時限|限)?(?:\s*[-‐–~〜～]\s*([1-9一二三四五六七八九])\s*(?:時限|限)?)?/#
        var seen = Set<TimetableSlot>()
        let parsedSlots = match.4.matches(of: periodFormat).flatMap { meeting -> [TimetableSlot] in
            guard let day = words.firstIndex(of: String(meeting.1)),
                  let start = Int(meeting.2) ?? digits.firstIndex(of: String(meeting.2)).map({ $0 + 1 }) else {
                return []
            }
            let end = meeting.3.flatMap { Int($0) ?? digits.firstIndex(of: String($0)).map({ $0 + 1 }) } ?? start
            return (start...max(start, end)).map { TimetableSlot(weekday: day + 1, period: $0) }
        }.filter { seen.insert($0).inserted }
        guard !parsedSlots.isEmpty else { return nil }

        // Keep the original spelling; normalize only the metadata when matching it.
        let titleMatch = site.title.firstMatch(of: #/[（(]\s*[0-9０-９]{4}\s*年度\s*(?:春|秋|前期|後期|通年)/#)
        let name = titleMatch.map { String(site.title[..<$0.range.lowerBound]) } ?? site.title
        self.id = site.id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.year = year
        switch match.2 {
        case "春", "春学期", "前期": season = .spring
        case "秋", "秋学期", "後期": season = .fall
        default: season = .fullYear
        }
        quarter = match.3.map { $0 == "1" || $0 == "一" || $0 == "I" ? 1 : 2 }
        slots = parsedSlots
    }
}

struct AcademicDay {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    // 2026 term dates and weekday substitutions from Nagoya University's teaching calendar.
    // Quarter-specific classes for other years require the corresponding published dates.
    let year: Int
    let season: TimetableClass.Season
    let weekday: Int
    let quarter: Int?
    let inTeachingPeriod: Bool

    init(on date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let month = parts.month!
        let day = month * 100 + parts.day!
        year = parts.year! - (month < 4 ? 1 : 0)
        season = (4...9).contains(month) ? .spring : .fall

        let defaultWeekday = parts.weekday!
        guard year == 2026 else {
            weekday = defaultWeekday
            quarter = nil
            inTeachingPeriod = true
            return
        }

        let substitutions = [429: 4, 627: 5, 720: 2, 1012: 2, 1120: 2, 106: 3, 107: 2]
        weekday = substitutions[day] ?? defaultWeekday
        if season == .spring {
            let starts = [2: 615, 3: 616, 4: 617, 5: 611, 6: 605]
            quarter = day >= starts[weekday, default: 605] ? 2 : 1
            inTeachingPeriod = (410...805).contains(day) && day != 501 && day != 612
        } else {
            let starts = [2: 1130, 3: 1208, 4: 1202, 5: 1203, 6: 1204]
            quarter = day < 400 || day >= starts[weekday, default: 1130] ? 2 : 1
            inTeachingPeriod = ((1002...1227).contains(day) || (106...205).contains(day)) && day != 115
        }
    }

    var weekdayLabel: String {
        ["日", "月", "火", "水", "木", "金", "土"][weekday - 1]
    }

    func includes(_ lesson: TimetableClass) -> Bool {
        inTeachingPeriod && isCurrentTerm(lesson)
    }

    func isCurrentTerm(_ lesson: TimetableClass) -> Bool {
        lesson.year == year && (lesson.season == season || lesson.season == .fullYear)
            && (lesson.quarter == nil || lesson.quarter == quarter)
    }

    static func nextDay(after date: Date) -> Date {
        calendar.dateInterval(of: .day, for: date)!.end
    }
}

struct TimetableDay {
    private static let periodTimes: [Range<Int>] = [
        525..<615,   // 08:45–10:15
        630..<720,   // 10:30–12:00
        780..<870,   // 13:00–14:30
        885..<975,   // 14:45–16:15
        990..<1080   // 16:30–18:00
    ]

    let lessonsByPeriod: [Int: [TimetableClass]]
    let activePeriod: Int?
    let changeDates: [Date]

    init(classes: [TimetableClass], at date: Date) {
        let academicDay = AcademicDay(on: date)
        var lessons: [Int: [TimetableClass]] = [:]
        for lesson in classes where academicDay.includes(lesson) {
            for slot in lesson.slots where slot.weekday == academicDay.weekday {
                lessons[slot.period, default: []].append(lesson)
            }
        }
        lessonsByPeriod = lessons

        let calendar = AcademicDay.calendar
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else {
            activePeriod = nil
            changeDates = []
            return
        }

        let startOfDay = calendar.startOfDay(for: date)
        let occupiedPeriods = Self.periodTimes.enumerated().compactMap { index, time -> (Int, Range<Date>)? in
            let period = index + 1
            guard lessons[period] != nil else { return nil }
            let start = startOfDay.addingTimeInterval(TimeInterval(time.lowerBound * 60))
            let end = startOfDay.addingTimeInterval(TimeInterval(time.upperBound * 60))
            return (period, start..<end)
        }
        activePeriod = occupiedPeriods.first { $0.1.contains(date) }?.0
        changeDates = occupiedPeriods.flatMap { [$0.1.lowerBound, $0.1.upperBound] }
    }
}

enum TimetableRooms {
    static var values: [String: String] {
        UserDefaults(suiteName: TACTStore.group)?.dictionary(forKey: "timetableRoomsBySite") as? [String: String] ?? [:]
    }

    static func save(_ rooms: [String: String]) throws {
        guard let defaults = UserDefaults(suiteName: TACTStore.group) else { throw TACTError.storage }
        defaults.set(rooms.compactMapValues { value in
            let room = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return room.isEmpty ? nil : room
        }, forKey: "timetableRoomsBySite")
    }
}
