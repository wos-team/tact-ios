import PhotosUI
import SwiftUI
import WidgetKit

@main
struct TACTApp: App {
    var body: some Scene {
        WindowGroup { AssignmentsView() }
    }
}

struct AssignmentsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: Snapshot?
    @State private var connected = false
    @State private var hasPendingSession = false
    @State private var needsReconnect = false
    @State private var syncing = false
    @State private var showsSignIn = false
    @State private var roomEditor: RoomEditorRequest?
    @State private var rooms = TimetableRooms.values
    @State private var importPhoto: PhotosPickerItem?
    @AppStorage("finishedTimetableRoomSetup") private var finishedTimetableRoomSetup = false
    @State private var errorMessage: String?
    @State private var lastWidgetAttempt: WidgetSyncAttempt?

    private struct RoomEditorRequest: Identifiable {
        let id = UUID()
        let term: TimetableTerm
        var slot: TimetableSlot? = nil
        var photo: PhotosPickerItem? = nil
        var allowsImport = true
    }

    var body: some View {
        TabView {
            assignmentTab
                .tabItem { Label("課題", systemImage: "checklist") }

            WeeklyTimetableView(classes: snapshot?.timetable, rooms: rooms) { term, slot in
                roomEditor = RoomEditorRequest(term: term, slot: slot)
            }
            .tabItem { Label("時間割", systemImage: "tablecells") }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                rooms = TimetableRooms.values
                lastWidgetAttempt = TACTStore.lastWidgetAttempt
                await sync(force: false)
            }
        }
        .onChange(of: importPhoto) { _, selected in
            if let selected { roomEditor = RoomEditorRequest(term: .current(), photo: selected) }
        }
        .sheet(item: $roomEditor, onDismiss: { importPhoto = nil }) { request in
            TimetableEditor(timetable: snapshot?.timetable, term: request.term, slot: request.slot,
                            photo: request.photo, allowsImport: request.allowsImport) {
                rooms = TimetableRooms.values
                finishedTimetableRoomSetup = true
            }
        }
        .sheet(isPresented: $showsSignIn) {
            NavigationStack {
                SignInView { cookies in
                    Task { await completeSignIn(cookies) }
                }
                .navigationTitle("TACTに接続")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { showsSignIn = false }
                    }
                }
            }
        }
    }

    private var assignmentTab: some View {
        NavigationStack {
            List {
                Section {
                    if connected || hasPendingSession {
                        Button {
                            Task { await sync(force: true) }
                        } label: {
                            if syncing {
                                ProgressView("TACTから課題・小テストを取得中")
                            } else {
                                Label("今すぐ更新", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(syncing)
                    }

                    if (!connected && !hasPendingSession) || needsReconnect {
                        Button(connected ? "TACTに再接続" : "TACTに接続") {
                            showsSignIn = true
                        }
                        .disabled(syncing)
                    }

                    if let snapshot {
                        Text("最終同期 \(snapshot.syncedAt.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if connected || lastWidgetAttempt != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ウィジェットの自動同期")
                            if let attempt = lastWidgetAttempt {
                                Text("\(attempt.finishedAt.formatted(.dateTime.month().day().hour().minute()))  \(attempt.result)")
                            } else {
                                Text("実行記録なし")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let failed = snapshot?.failedCourseCount, failed > 0 {
                        Text("\(failed)件の講義を更新できませんでした。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                }

                if connected, !finishedTimetableRoomSetup,
                   snapshot?.timetable?.contains(where: AcademicDay(on: .now).isCurrentTerm) == true {
                    Section {
                        PhotosPicker(selection: $importPhoto, matching: .images) {
                            Label("スクリーンショットを選ぶ", systemImage: "photo")
                        }
                        Button("教室を手入力") {
                            roomEditor = RoomEditorRequest(term: .current(), allowsImport: false)
                        }
                        Button("あとで", role: .cancel) { finishedTimetableRoomSetup = true }
                    } header: {
                        Text("TACT連携完了")
                    } footer: {
                        Text("「すごい時間割」を使っている方は、時間割のスクリーンショットから教室をまとめて登録できます。")
                    }
                }

                if let snapshot {
                    Section("未提出の課題・小テスト") {
                        let assignments = snapshot.upcoming(at: .now)
                        if assignments.isEmpty {
                            Text((snapshot.failedCourseCount ?? 0) > 0
                                 ? "取得できた講義に表示できる未提出の課題・小テストはありません。"
                                 : "表示できる未提出の課題・小テストはありません。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(assignments) { assignment in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(assignment.title).font(.headline)
                                Text(assignment.courseLabel)
                                if assignment.hasDeadline {
                                    Text(assignment.due, format: .dateTime.month().day().weekday().hour().minute())
                                        .foregroundStyle(assignment.due < .now ? Color.orange : Color.secondary)
                                } else {
                                    Text("締切なし").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Link("TACTをブラウザで開く", destination: TACTClient.home)
                }
            }
            .navigationTitle("課題・小テスト")
            .refreshable { await sync(force: true) }
        }
    }

    @MainActor
    private func sync(force: Bool) async {
        guard !syncing else { return }

        do {
            let active = try TACTStore.session()
            connected = active != nil
            snapshot = active.flatMap { TACTStore.snapshot(for: $0.id) }
            let pending = try TACTStore.session(pending: true)
            hasPendingSession = pending != nil
            if let pending {
                await fetch(pending, newSession: true)
                return
            }
            guard let active else { return }
            if !force, let snapshot, snapshot.timetable != nil, Date().timeIntervalSince(snapshot.syncedAt) < 5 * 60 { return }
            await fetch(active)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func completeSignIn(_ cookies: [SessionCookie]) async {
        showsSignIn = false
        guard !syncing else { return }

        do {
            let session = TACTSession(cookies: cookies)
            try TACTStore.save(session, pending: true)
            hasPendingSession = true
            needsReconnect = false
            await fetch(session, newSession: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func fetch(_ session: TACTSession, newSession: Bool = false) async {
        syncing = true
        defer { syncing = false }

        do {
            let updated = try await TACTClient.fetch(using: session)
            try Task.checkCancellation()
            try TACTStore.save(updated)
            if newSession {
                let previous = try TACTStore.session()
                do {
                    try TACTStore.save(session)
                } catch {
                    TACTStore.discardSnapshot(for: session.id)
                    throw error
                }
                try TACTStore.clearPendingSession()
                hasPendingSession = false
                if let previous, previous.id != session.id {
                    TACTStore.discardSnapshot(for: previous.id)
                }
            }
            connected = true
            snapshot = TACTStore.snapshot(for: session.id) ?? updated
            needsReconnect = false
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
        } catch is CancellationError {
            return
        } catch {
            if case TACTError.signInRequired = error {
                needsReconnect = true
                if newSession {
                    do {
                        try TACTStore.clearPendingSession()
                        hasPendingSession = false
                    } catch {
                        errorMessage = error.localizedDescription
                        return
                    }
                }
            }
            errorMessage = error.localizedDescription
        }
    }
}
