import PhotosUI
import SwiftUI
import WidgetKit

struct TimetableEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rooms = TimetableRooms.values
    @State private var errorMessage: String?
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var suggestions: [Suggestion] = []
    @State private var importDetails: TimetableScreenshot?

    let timetable: [TimetableClass]?
    let term: TimetableTerm
    let selectedSlot: TimetableSlot?
    let allowsImport: Bool
    let onSaved: () -> Void

    init(timetable: [TimetableClass]?, term: TimetableTerm = .current(), slot: TimetableSlot? = nil,
         photo: PhotosPickerItem? = nil, allowsImport: Bool = true, onSaved: @escaping () -> Void) {
        self.timetable = timetable
        self.term = term
        selectedSlot = slot
        self.allowsImport = allowsImport
        self.onSaved = onSaved
        _photo = State(initialValue: photo)
    }

    private var currentClasses: [TimetableClass] {
        (timetable ?? []).filter { lesson in
            term.includes(lesson) && (selectedSlot.map { lesson.slots.contains($0) } ?? true)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                if selectedSlot == nil && allowsImport {
                    importSection
                } else if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                if let importDetails {
                    Section {
                        ForEach($suggestions) { $suggestion in
                            suggestionRow($suggestion)
                        }
                    } header: {
                        Text("読み取り結果を確認")
                    } footer: {
                        let unmatched = suggestions.filter { $0.matches.isEmpty }.count
                        VStack(alignment: .leading, spacing: 3) {
                            if let label = importDetails.termLabel { Text("画像の学期：\(label)") }
                            if isDifferentAcademicYear(importDetails) {
                                Text("画像の年度が選択した年度と異なります。登録するコマを選んでください。")
                            }
                            Text("表示中の学期のTACT時間割に曜日・時限で照合しています。保存前に授業名と教室を確認してください。")
                            if importDetails.unregisteredCount > 0 {
                                Text("画像で教室が未登録：\(importDetails.unregisteredCount)コマ")
                            }
                            if unmatched > 0 { Text("TACTに照合先なし：\(unmatched)コマ") }
                        }
                    }
                } else {
                    Section {
                        if currentClasses.isEmpty {
                            Text(timetable == nil ? "TACTと同期すると、履修中の授業が表示されます。" : "この学期の曜日・時限を読み取れた授業はありません。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(currentClasses) { lesson in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(lesson.name).font(.subheadline.weight(.semibold))
                                ForEach(lesson.slots.filter { selectedSlot == nil || $0 == selectedSlot }, id: \.self) { slot in
                                    HStack {
                                        Text(slot.label).font(.caption).foregroundStyle(.secondary)
                                        TextField("教室（例：工232）", text: room(for: lesson.id, slot: slot))
                                            .accessibilityLabel("\(lesson.name) \(slot.label)の教室")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(selectedSlot?.label ?? "手入力")
                    }
                }
            }
            .navigationTitle("教室の登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(reading || currentClasses.isEmpty ||
                                  (importDetails != nil && !suggestions.contains(where: \.canSave)))
                }
            }
            .task(id: photo) {
                if let photo { await read(photo) }
            }
        }
    }

    private var importSection: some View {
        Section {
            PhotosPicker(selection: $photo, matching: .images) {
                Label("すごい時間割のスクリーンショットを選ぶ", systemImage: "photo")
            }
            .disabled(reading || currentClasses.isEmpty)
            if reading { ProgressView("スクリーンショットを読み取り中") }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            Text("月〜金・1〜5限の表全体が入った画像を選んでください。読み取りは端末内で行います。")
        }
    }

    private struct Suggestion: Identifiable {
        let slot: TimetableSlot
        let matches: [TimetableClass]
        var selectedCourse: String?
        var room: String

        var id: TimetableSlot { slot }
        var canSave: Bool { selectedCourse != nil && !room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func suggestionRow(_ suggestion: Binding<Suggestion>) -> some View {
        let value = suggestion.wrappedValue
        return VStack(alignment: .leading, spacing: 5) {
            Text(value.slot.label).font(.caption).foregroundStyle(.secondary)
            if value.matches.count > 1 {
                Picker("TACTの授業", selection: suggestion.selectedCourse) {
                    Text("保存しない").tag(nil as String?)
                    ForEach(value.matches) { Text($0.name).tag(Optional($0.id)) }
                }
            } else if let match = value.matches.first {
                Text(match.name).font(.subheadline.weight(.semibold))
                Toggle("このコマを登録", isOn: Binding {
                    suggestion.wrappedValue.selectedCourse != nil
                } set: { enabled in
                    suggestion.wrappedValue.selectedCourse = enabled ? match.id : nil
                })
                .font(.caption)
            } else {
                Text("照合先なし").font(.caption).foregroundStyle(.secondary)
            }
            TextField("読み取った教室", text: suggestion.room)
                .disabled(value.matches.isEmpty)
        }
    }

    @MainActor
    private func read(_ photo: PhotosPickerItem) async {
        reading = true
        errorMessage = nil
        importDetails = nil
        suggestions = []
        defer { if !Task.isCancelled { reading = false } }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else {
                throw TimetableScreenshotReader.ReadError.image
            }
            let parsed = try await Task.detached(priority: .userInitiated) {
                try TimetableScreenshotReader.read(data)
            }.value
            try Task.checkCancellation()
            let refined = await TimetableScreenshotReader.refine(parsed)
            try Task.checkCancellation()
            suggestions = refined.rooms.map { cell in
                let matches = currentClasses.filter { $0.slots.contains(cell.slot) }
                return Suggestion(slot: cell.slot, matches: matches,
                                  selectedCourse: matches.count == 1 && !isDifferentAcademicYear(refined) ? matches.first?.id : nil,
                                  room: cell.room)
            }
            importDetails = refined
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isDifferentAcademicYear(_ screenshot: TimetableScreenshot) -> Bool {
        guard let label = screenshot.termLabel, let year = Int(label.prefix(4)) else { return false }
        return year != term.year
    }

    private func room(for id: String, slot: TimetableSlot) -> Binding<String> {
        Binding { TimetableRooms.room(in: rooms, courseID: id, slot: slot) ?? "" } set: {
            if let previous = rooms.removeValue(forKey: id),
               let lesson = currentClasses.first(where: { $0.id == id }) {
                for scheduled in lesson.slots {
                    let key = TimetableRooms.key(for: id, slot: scheduled)
                    if rooms[key] == nil { rooms[key] = previous }
                }
            }
            rooms[TimetableRooms.key(for: id, slot: slot)] = $0
        }
    }

    private func save() {
        do {
            for suggestion in suggestions where suggestion.canSave {
                guard let course = suggestion.selectedCourse else { continue }
                rooms[TimetableRooms.key(for: course, slot: suggestion.slot)] = suggestion.room
            }
            try TimetableRooms.save(rooms)
            WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
            onSaved()
            dismiss()
        } catch {
            errorMessage = "教室を保存できませんでした。"
        }
    }
}
