import SwiftUI
import WidgetKit

struct TimetableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rooms = TimetableRooms.values
    @State private var errorMessage: String?

    let timetable: [TimetableClass]?

    private var currentClasses: [TimetableClass] {
        let day = AcademicDay(on: .now)
        return (timetable ?? []).filter(day.isCurrentTerm).sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if currentClasses.isEmpty {
                        Text(timetable == nil ? "TACTと同期すると、履修中の授業が表示されます。" : "今期の曜日・時限を読み取れた授業はありません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(currentClasses) { lesson in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(lesson.name).font(.subheadline.weight(.semibold))
                            TextField("教室（例：工232）", text: room(for: lesson.id))
                                .accessibilityLabel("\(lesson.name)の教室")
                        }
                    }
                } footer: {
                    Text("授業名と曜日・時限はTACTから取得します。教室は空欄でも使えます。")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("教室の登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(currentClasses.isEmpty)
                }
            }
        }
    }

    private func room(for id: String) -> Binding<String> {
        Binding { rooms[id] ?? "" } set: { rooms[id] = $0 }
    }

    private func save() {
        do {
            try TimetableRooms.save(rooms)
            WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
            dismiss()
        } catch {
            errorMessage = "教室を保存できませんでした。"
        }
    }
}
