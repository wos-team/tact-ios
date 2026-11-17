import SwiftUI

struct TimetableWidget: View {
    let timetable: [TimetableClass]?
    let rooms: [String: String]
    let date: Date

    var body: some View {
        let day = AcademicDay(on: date)
        let today = (timetable ?? []).filter(day.includes)
        let occupied = Set(today.flatMap(\.slots).filter { $0.weekday == day.weekday }.map(\.period))
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
                        let slot = TimetableSlot(weekday: day.weekday, period: period)
                        periodView(period, lessons: today.filter { $0.slots.contains(slot) })
                    }
                }
            }
        }
    }

    private func periodView(_ period: Int, lessons: [TimetableClass]) -> some View {
        VStack(spacing: 1) {
            Text(lessons.count > 1 ? "\(period)限 +\(lessons.count - 1)" : "\(period)限")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            if let first = lessons.first {
                Text(first.name)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                Text(rooms[first.id] ?? "—")
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
        .accessibilityElement(children: .combine)
    }
}
