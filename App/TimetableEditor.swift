import SwiftUI
import WidgetKit

struct TimetableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var timetable = TimetableStore.load()
    @State private var weekday = Timetable.weekday(on: .now)
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("曜日", selection: $weekday) {
                    ForEach(TimetableWeekday.allCases) { day in
                        Text(day.label).tag(day)
                    }
                }
                .pickerStyle(.segmented)

                Section {
                    ForEach(TimetablePeriod.standard) { period in
                        periodFields(period)
                    }
                } footer: {
                    Text("入力した授業を毎週の時間割として表示します。教室は空欄でも保存できます。")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("時間割")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private func periodFields(_ period: TimetablePeriod) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(period.id)限").font(.subheadline.weight(.semibold))
                Text("\(period.start)–\(period.end)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                TextField("授業名", text: field(\.name, for: period))
                    .accessibilityLabel("\(period.id)限の授業名")
                TextField("教室", text: field(\.room, for: period))
                    .font(.subheadline)
                    .accessibilityLabel("\(period.id)限の教室")
            }
        }
        .padding(.vertical, 4)
    }

    private func field(_ field: WritableKeyPath<TimetableClass, String>, for period: TimetablePeriod) -> Binding<String> {
        let slot = TimetableSlot(weekday: weekday.rawValue, period: period.id)
        return Binding {
            timetable.classes[slot]?[keyPath: field] ?? ""
        } set: { value in
            timetable.classes[slot, default: TimetableClass()][keyPath: field] = value
        }
    }

    private func save() {
        do {
            try TimetableStore.save(timetable)
            WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
            dismiss()
        } catch {
            errorMessage = "時間割を保存できませんでした。"
        }
    }
}
