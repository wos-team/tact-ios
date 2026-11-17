import SwiftUI

struct TimetableWidget: View {
    @Environment(\.colorScheme) private var colorScheme
    let timetable: [TimetableClass]?
    let rooms: [String: String]
    let date: Date

    var body: some View {
        let weekday = AcademicDay(on: date).weekday
        let today = TimetableDay(classes: timetable ?? [], at: date)
        let occupied = today.lessonsByPeriod.keys
        let periods = occupied.contains(where: { $0 > 5 }) ? occupied.sorted() : Array(1...5)
        VStack(alignment: .leading, spacing: 3) {
            if timetable?.isEmpty != false {
                Text(timetable == nil ? "TACTとの同期後に表示" : "曜日・時限を確認できる授業なし")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if occupied.isEmpty {
                Text("授業なし")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(periods, id: \.self) { period in
                        periodView(TimetableSlot(weekday: weekday, period: period),
                                   lessons: today.lessonsByPeriod[period] ?? [],
                                   isActive: today.activePeriod == period)
                    }
                }
            }
        }
    }

    private func periodView(_ slot: TimetableSlot, lessons: [TimetableClass], isActive: Bool) -> some View {
        let period = slot.period
        return VStack(spacing: 1) {
            Text(lessons.count > 1 ? "\(period)限 +\(lessons.count - 1)" : "\(period)限")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            if let first = lessons.first {
                Text(first.name)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                Text(TimetableRooms.room(in: rooms, courseID: first.id, slot: slot) ?? "—")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("—")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("授業なし")
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(isActive ? Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "授業中" : "")
    }
}
