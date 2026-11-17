import SwiftUI

struct WeeklyTimetableView: View {
    @State private var term = TimetableTerm.current()
    @State private var showsTerms = false

    let classes: [TimetableClass]?
    let rooms: [String: String]
    let edit: (TimetableTerm, TimetableSlot?) -> Void

    private let weekdays = Array(2...6)
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 94

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
            let railWidth: CGFloat = 37
            let columnWidth = max(0, (geometry.size.width - railWidth) / 5)
            let today = AcademicDay(on: .now).weekday

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ruledCell(width: railWidth, height: 34) {
                        Text("時限").font(.caption2.weight(.medium))
                    }
                    ForEach(weekdays, id: \.self) { day in
                        ruledCell(width: columnWidth, height: 34) {
                            let isToday = term == .current() && day == today
                            Text(TimetableSlot(weekday: day, period: 1).label.prefix(1))
                                .font(.subheadline.weight(isToday ? .bold : .medium))
                                .foregroundStyle(isToday ? Color.accentColor : .primary)
                                .accessibilityAddTraits(isToday ? .isSelected : [])
                        }
                    }
                }
                .background(.quaternary)

                ForEach(periods, id: \.self) { period in
                    HStack(spacing: 0) {
                        ruledCell(width: railWidth, height: rowHeight) {
                            periodLabel(period)
                        }
                        .background(.quaternary.opacity(0.5))
                        ForEach(weekdays, id: \.self) { day in
                            let slot = TimetableSlot(weekday: day, period: period)
                            ruledCell(width: columnWidth, height: rowHeight) {
                                lessonCell(bySlot[slot, default: []], slot: slot)
                            }
                        }
                    }
                }
            }
            .border(.tertiary, width: 1)
        }
        .frame(height: 34 + CGFloat(periods.count) * rowHeight)
    }

    private func ruledCell<Content: View>(
        width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: width, height: height)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.tertiary).frame(width: 1).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.tertiary).frame(height: 1).allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func lessonCell(_ lessons: [TimetableClass], slot: TimetableSlot) -> some View {
        if let first = lessons.first {
            let room = TimetableRooms.room(in: rooms, courseID: first.id, slot: slot)
            Button {
                edit(term, slot)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(4)
                        .layoutPriority(1)
                    if let room {
                        Text(room)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if lessons.count > 1 {
                        Text("ほか\(lessons.count - 1)件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(slot.label)、\(first.name)、教室\(room ?? "未登録")")
            .accessibilityHint("教室を編集")
        } else {
            Color.clear.accessibilityHidden(true)
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

}
