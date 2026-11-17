import SwiftUI

struct WeeklyTimetableView: View {
    @State private var term = TimetableTerm.current()
    @State private var showsTerms = false
    @State private var selectedDay = {
        let weekday = AcademicDay(on: .now).weekday
        return (2...6).contains(weekday) ? weekday : 2
    }()

    let classes: [TimetableClass]?
    let rooms: [String: String]
    let edit: (TimetableTerm, TimetableSlot?) -> Void

    private let weekdays = ["月", "火", "水", "木", "金"]

    private var years: [Int] {
        Set((classes ?? []).map(\.year) + [TimetableTerm.current().year]).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("曜日", selection: $selectedDay) {
                    ForEach(2...6, id: \.self) { day in
                        Text("\(weekdays[day - 2])曜").tag(day)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                let lessons = (classes ?? []).filter(term.includes)
                let dayLessons = lessons.flatMap { lesson in
                    lesson.slots.filter { $0.weekday == selectedDay }.map { (slot: $0, lesson: lesson) }
                }
                let byPeriod = Dictionary(grouping: dayLessons, by: { $0.slot.period })

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(weekdays[selectedDay - 2])曜日")
                                .font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            if !dayLessons.isEmpty {
                                Text("\(byPeriod.count)コマ")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if byPeriod.isEmpty {
                            Text(emptyMessage(for: lessons))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(byPeriod.keys.sorted(), id: \.self) { period in
                                    Divider()
                                    let slot = TimetableSlot(weekday: selectedDay, period: period)
                                    periodRow(slot, lessons: byPeriod[period, default: []].map(\.lesson))
                                }
                                Divider()
                            }
                        }
                        if !lessons.isEmpty {
                            Button("教室の登録・スクショ取り込み", systemImage: "square.and.pencil") {
                                edit(term, nil)
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("\(term.year)年度 \(term.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("学期切替") { showsTerms = true }
                }
            }
        }
        .sheet(isPresented: $showsTerms) { termPicker }
    }

    private func emptyMessage(for lessons: [TimetableClass]) -> String {
        if classes == nil { return "TACTと同期すると時間割が表示されます。" }
        if lessons.isEmpty { return "この学期の曜日・時限を取得できる授業はありません。" }
        return "この曜日に授業はありません。"
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

    private func periodRow(_ slot: TimetableSlot, lessons: [TimetableClass]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(slot.period)限")
                    .font(.headline.monospacedDigit())
                if TimetablePeriod.standard.indices.contains(slot.period - 1) {
                    let time = TimetablePeriod.standard[slot.period - 1]
                    Text(TimetablePeriod.clock(time.lowerBound))
                    Text(TimetablePeriod.clock(time.upperBound))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(lessons) { lesson in
                    let room = TimetableRooms.room(in: rooms, courseID: lesson.id, slot: slot)
                    Button {
                        edit(term, slot)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(lesson.name).font(.headline)
                                Label(room ?? "教室を登録", systemImage: "location")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("教室を編集")
                }
            }
        }
        .padding(.vertical, 14)
    }
}
