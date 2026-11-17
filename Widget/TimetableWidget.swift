import AppIntents
import SwiftUI

struct TimetableWidget: View {
    let timetable: Timetable
    let date: Date

    private var weekday: TimetableWeekday { Timetable.weekday(on: date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(weekday.label)曜日")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                WidgetViewSwitch(showsTimetable: false)
            }

            HStack(alignment: .top, spacing: 4) {
                ForEach(TimetablePeriod.standard) { period in
                    periodColumn(period)
                }
            }

            if timetable.classes.isEmpty {
                Text("アプリの「時間割」から登録")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func periodColumn(_ period: TimetablePeriod) -> some View {
        let lesson = timetable.lesson(on: weekday, period: period)
        return VStack(alignment: .center, spacing: 2) {
            Text("\(period.id)限")
                .font(.system(size: 11, weight: .semibold))
            VStack(spacing: 0) {
                Text(period.start)
                Text(period.end)
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)

            Divider().padding(.vertical, 1)

            if let lesson {
                Text(lesson.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity, alignment: .top)
                Text(lesson.room)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityLabel("授業なし")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

struct WidgetViewSwitch: View {
    let showsTimetable: Bool

    var body: some View {
        Button(intent: SetWidgetTimetableIntent(showsTimetable: showsTimetable)) {
            Label(showsTimetable ? "時間割" : "提出予定",
                  systemImage: showsTimetable ? "calendar" : "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsTimetable ? "今日の時間割を表示" : "提出予定を表示")
    }
}
