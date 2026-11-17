import SwiftUI

struct WeeklyTimetableView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var term = TimetableTerm.current()
    @State private var showsTerms = false

    let classes: [TimetableClass]?
    let rooms: [String: String]
    let edit: (TimetableTerm, TimetableSlot?) -> Void

    private let weekdays = Array(2...6)
    private let gap: CGFloat = 4
    private let rowHeight: CGFloat = 94

    private var years: [Int] {
        Set((classes ?? []).map(\.year) + [TimetableTerm.current().year]).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let lessons = (classes ?? []).filter(term.includes)
                let lastPeriod = lessons.flatMap(\.slots).map(\.period).max() ?? 5
                let periods = Array(1...max(5, lastPeriod))
                var bySlot: [TimetableSlot: [TimetableClass]] {
                    var result: [TimetableSlot: [TimetableClass]] = [:]
                    for lesson in lessons {
                        for slot in lesson.slots { result[slot, default: []].append(lesson) }
                    }
                    return result
                }
                VStack(alignment: .leading, spacing: 14) {
                    grid(periods: periods, bySlot: bySlot)
                    if lessons.isEmpty {
                        Text(classes == nil ? "TACTと同期すると時間割が表示されます。" : "この学期の曜日・時限を取得できる授業はありません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            edit(term, nil)
                        } label: {
                            Label("教室の登録・スクショ取り込み", systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .background(canvas)
            .navigationTitle("\(term.year)年度 \(term.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("学期切替") { showsTerms = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $showsTerms) { termPicker }
    }

    private var termPicker: some View {
        NavigationStack {
            List {
                Picker("年度", selection: Binding {
                    term.year
                } set: { year in
                    term = TimetableTerm(year: year, index: term.index)
                }) {
                    ForEach(years, id: \.self) { Text("\($0)年度").tag($0) }
                }
                Section("学期") {
                    ForEach(1...4, id: \.self) { index in
                        let candidate = TimetableTerm(year: term.year, index: index)
                        Button {
                            term = candidate
                            showsTerms = false
                        } label: {
                            HStack {
                                Text(candidate.label)
                                Spacer()
                                if term == candidate { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .accessibilityAddTraits(term == candidate ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("学期切替")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showsTerms = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func grid(periods: [Int], bySlot: [TimetableSlot: [TimetableClass]]) -> some View {
        GeometryReader { geometry in
            let railWidth: CGFloat = 29
            let cellWidth = max(0, (geometry.size.width - railWidth - gap * 5) / 5)
            let today = AcademicDay.calendar.component(.weekday, from: .now)
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Color.clear.frame(width: railWidth)
                    ForEach(weekdays, id: \.self) { day in
                        Text(TimetableSlot(weekday: day, period: 1).label.prefix(1))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(term == .current() && day == today ? Color.white : .secondary)
                            .frame(width: 26, height: 26)
                            .background {
                                if term == .current() && day == today {
                                    Circle().fill(Color.accentColor)
                                }
                            }
                            .frame(width: cellWidth)
                    }
                }
                .frame(height: 33)
                ForEach(periods, id: \.self) { period in
                    HStack(spacing: gap) {
                        periodLabel(period).frame(width: railWidth)
                        ForEach(weekdays, id: \.self) { day in
                            let slot = TimetableSlot(weekday: day, period: period)
                            let lessons = bySlot[slot] ?? []
                            cell(lessons, slot: slot, width: cellWidth)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .frame(height: 33 + CGFloat(periods.count) * (rowHeight + gap))
    }

    private func cell(_ lessons: [TimetableClass], slot: TimetableSlot, width: CGFloat) -> some View {
        Group {
            if let first = lessons.first {
                let room = TimetableRooms.room(in: rooms, courseID: first.id, slot: slot)
                Button {
                    edit(term, slot)
                } label: {
                    VStack(spacing: 4) {
                        Text(first.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(4)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.center)
                            .frame(maxHeight: .infinity)
                        if lessons.count > 1 {
                            Text("ほか\(lessons.count - 1)件")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        Text(room ?? "未登録")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .background(emptyCell, in: Capsule())
                    }
                    .padding(4)
                    .frame(width: width, height: rowHeight)
                    .background(occupiedCell, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(slot.label)、\(first.name)、教室\(room ?? "未登録")")
                .accessibilityHint("教室を編集")
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(emptyCell)
                    .frame(width: width, height: rowHeight)
                    .accessibilityHidden(true)
            }
        }
    }

    private func periodLabel(_ period: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(period)").font(.headline)
            if TimetablePeriod.standard.indices.contains(period - 1) {
                let time = TimetablePeriod.standard[period - 1]
                VStack(spacing: 1) {
                    Text(TimetablePeriod.clock(time.lowerBound))
                    Text(TimetablePeriod.clock(time.upperBound))
                }
                .font(.system(size: 8).monospacedDigit())
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(period)限")
    }

    private var canvas: Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.13, blue: 0.17) : Color(red: 0.94, green: 0.97, blue: 1)
    }

    private var emptyCell: Color {
        colorScheme == .dark ? Color(red: 0.15, green: 0.18, blue: 0.23) : .white
    }

    private var occupiedCell: Color {
        colorScheme == .dark ? Color(red: 0.19, green: 0.32, blue: 0.47) : Color(red: 0.75, green: 0.86, blue: 0.98)
    }
}
