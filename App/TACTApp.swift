import PhotosUI
import SwiftUI
import WidgetKit

@main
struct TACTApp: App {
    @UIApplicationDelegateAdaptor(SummaryBackgroundRegistration.self) private var summaryRegistration

    var body: some Scene {
        WindowGroup { AssignmentsView() }
    }
}

struct AssignmentsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var summaryWorker = AssignmentSummaryWorker.shared
    @State private var activeTab: Tab = .assignments
    @State private var assignmentPath: [String] = []
    @State private var snapshot: Snapshot?
    @State private var connected = false
    @State private var hasPendingSession = false
    @State private var needsReconnect = false
    @State private var syncing = false
    @State private var showsSignIn = false
    @State private var showsWidgetSetup = false
    @State private var roomEditor: RoomEditorRequest?
    @State private var rooms = TimetableRooms.values
    @State private var importPhoto: PhotosPickerItem?
    @AppStorage("finishedWidgetSetup") private var finishedWidgetSetup = false
    @AppStorage("finishedTimetableRoomSetup") private var finishedTimetableRoomSetup = false
    @State private var errorMessage: String?
    @State private var lastWidgetAttempt: WidgetSyncAttempt?

    private enum Tab { case assignments, timetable, settings }

    private struct RoomEditorRequest: Identifiable {
        let id = UUID()
        let term: TimetableTerm
        var slot: TimetableSlot? = nil
        var photo: PhotosPickerItem? = nil
        var allowsImport = true
    }

    private var requiresWidgetSetup: Bool {
        connected && snapshot != nil && !finishedWidgetSetup && !showsSignIn && roomEditor == nil
    }

    var body: some View {
        TabView(selection: $activeTab) {
            assignmentTab
                .tabItem { Label("課題", systemImage: "checklist") }
                .tag(Tab.assignments)

            WeeklyTimetableView(classes: snapshot?.timetable, rooms: rooms) { term, slot in
                roomEditor = RoomEditorRequest(term: term, slot: slot)
            }
            .tabItem { Label("時間割", systemImage: "tablecells") }
            .tag(Tab.timetable)

            settingsTab
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: requiresWidgetSetup, initial: true) { _, required in
            showsWidgetSetup = required
        }
        .fullScreenCover(isPresented: $showsWidgetSetup) {
            WidgetSetupView {
                if activeTab == .settings { activeTab = .assignments }
                finishedWidgetSetup = true
                showsWidgetSetup = false
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: activeTab) { _, tab in
            if tab == .settings { lastWidgetAttempt = TACTStore.lastWidgetAttempt }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                rooms = TimetableRooms.values
                lastWidgetAttempt = TACTStore.lastWidgetAttempt
                await sync(force: false)
                if !Task.isCancelled { AssignmentSummaryWorker.shared.enterForeground() }
            } else if scenePhase == .background {
                AssignmentSummaryWorker.shared.leaveForeground()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "tact-ios", url.host == "assignment", url.pathComponents.count == 2,
                  let session = try? TACTStore.session(),
                  let cached = TACTStore.snapshot(for: session.id), cached.summaryAccount != nil,
                  let assignment = cached.assignments.first(where: { $0.detailURL == url }) else { return }
            snapshot = cached
            activeTab = .assignments
            assignmentPath = [assignment.id]
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
        NavigationStack(path: $assignmentPath) {
            List {
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
                    let now = Date()
                    let assignments = snapshot.upcoming(at: now)
                    if assignments.isEmpty {
                        ContentUnavailableView(
                            (snapshot.failedCourseCount ?? 0) > 0 ? "課題を取得できませんでした" : "未提出の項目はありません",
                            systemImage: "checkmark.circle"
                        )
                    } else {
                        let groups = Dictionary(grouping: assignments) { DeadlineGroup(assignment: $0, now: now) }
                        ForEach(DeadlineGroup.allCases, id: \.self) { group in
                            if let items = groups[group] {
                                Section(group.rawValue) {
                                    ForEach(items) { assignment in
                                        if assignment.isQuiz != true, let account = snapshot.summaryAccount {
                                            NavigationLink(value: assignment.id) {
                                                assignmentRow(assignment, summaryAccount: account)
                                            }
                                        } else {
                                            assignmentRow(assignment)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if !connected && !hasPendingSession && !syncing {
                    ContentUnavailableView {
                        Label("課題を表示するには", systemImage: "checklist")
                    } description: {
                        Text("設定からTACTに接続してください。")
                    } actions: {
                        Button("設定を開く") { activeTab = .settings }
                    }
                } else if syncing {
                    ProgressView("課題・小テストを取得中")
                } else {
                    Button("設定で同期の状態を確認") { activeTab = .settings }
                }
            }
            .navigationTitle("課題・小テスト")
            .navigationDestination(for: String.self) { id in
                if let snapshot, let account = snapshot.summaryAccount,
                   let assignment = snapshot.assignments.first(where: { $0.id == id && $0.isQuiz != true }) {
                    AssignmentDetailView(assignment: assignment, account: account)
                        .id(account)
                } else {
                    ContentUnavailableView("課題を表示できません", systemImage: "doc.text")
                }
            }
            .refreshable { await sync(force: true) }
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            List {
                Section("TACTアカウント") {
                    if (!connected && !hasPendingSession) || needsReconnect {
                        Button(connected ? "TACTに再接続" : "TACTに接続") {
                            showsSignIn = true
                        }
                        .disabled(syncing)
                    } else {
                        LabeledContent("接続状態", value: connected ? "接続済み" : "接続を確認中")
                    }
                    Link(destination: TACTClient.home) {
                        Label("TACTをブラウザで開く", systemImage: "safari")
                    }
                }

                if connected || hasPendingSession || lastWidgetAttempt != nil || errorMessage != nil {
                    Section("同期") {
                        if connected || hasPendingSession {
                            Button {
                                Task { await sync(force: true) }
                            } label: {
                                if syncing {
                                    ProgressView("課題・小テストを取得中")
                                } else {
                                    Label("今すぐ更新", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(syncing)
                        }
                        if let snapshot {
                            LabeledContent("最終同期") {
                                Text(snapshot.syncedAt, format: syncDateFormat)
                            }
                        }
                        if let failed = snapshot?.failedCourseCount, failed > 0 {
                            Text("\(failed)件の講義を更新できませんでした。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage {
                            Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("ウィジェット") {
                        LabeledContent("自動同期", value: lastWidgetAttempt?.result ?? "実行記録なし")
                        if let attempt = lastWidgetAttempt {
                            LabeledContent("最終実行") {
                                Text(attempt.finishedAt, format: syncDateFormat)
                            }
                        }
                    }
                }
            }
            .navigationTitle("設定")
        }
    }

    private var syncDateFormat: Date.FormatStyle {
        .dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP"))
    }

    private enum DeadlineGroup: String, CaseIterable {
        case overdue = "締切超過"
        case today = "今日"
        case tomorrow = "明日"
        case upcoming = "今後"
        case undated = "締切なし"

        init(assignment: Assignment, now: Date) {
            let calendar = Calendar.current
            if !assignment.hasDeadline { self = .undated }
            else if assignment.due <= now { self = .overdue }
            else if calendar.isDate(assignment.due, inSameDayAs: now) { self = .today }
            else if calendar.date(byAdding: .day, value: 1, to: now).map({
                calendar.isDate(assignment.due, inSameDayAs: $0)
            }) == true { self = .tomorrow }
            else { self = .upcoming }
        }
    }

    private func assignmentRow(_ assignment: Assignment, summaryAccount: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(assignment.isQuiz == true ? "小テスト · \(assignment.displayCourse)" : assignment.displayCourse)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(assignment.title)
                .font(.headline)
                .foregroundStyle(.primary)
            if assignment.hasDeadline {
                Text(assignment.due, format: .dateTime.month().day().weekday().hour().minute()
                    .locale(Locale(identifier: "ja_JP")))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(assignment.due <= .now ? Color.orange : Color.secondary)
            }

            if let summaryAccount {
                let preview = AssignmentSummaryStore.preview(for: assignment, account: summaryAccount)
                if let summary = preview?.text, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview?.includesAllPDFs == false ? "要約（一部のPDFを除く）" : "要約")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineSpacing(3)
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                    .padding(.top, 6)
                } else if summaryWorker.processing == assignment.id {
                    Text("要約を作成中")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 8)
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
            if !force, let snapshot, snapshot.timetable != nil, snapshot.summaryAccount != nil, Date().timeIntervalSince(snapshot.syncedAt) < 5 * 60 { return }
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
            AssignmentSummaryWorker.shared.startAutomaticWork()
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

private struct WidgetSetupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var checkRequest = 0
    @State private var checking = false
    @State private var checkMessage: String?
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("ホーム画面の空いている場所を長押し")
                    } icon: {
                        Text("1")
                    }
                    Label {
                        Text("「編集」→「ウィジェットを追加」を選択")
                    } icon: {
                        Text("2")
                    }
                    Label {
                        Text("「my tact」を検索し、好きなサイズを追加")
                    } icon: {
                        Text("3")
                    }
                } header: {
                    Text("追加する手順")
                }

                Section {
                    LabeledContent("小・中", value: "締切をひと目で確認")
                    LabeledContent("大型・特大", value: "課題のAI要約も表示")
                } header: {
                    Text("サイズの選び方")
                } footer: {
                    Text("AI要約には iOS 26 以降と、有効な Apple Intelligence が必要です。")
                }

                Section {
                    Button {
                        checkRequest += 1
                    } label: {
                        if checking {
                            ProgressView("追加を確認中")
                        } else {
                            Text("追加を確認")
                        }
                    }
                    .disabled(checking)
                } footer: {
                    Text(checkMessage ?? "追加してアプリに戻ると、自動で確認します。")
                }
            }
            .navigationTitle("ウィジェットを追加")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkRequest += 1 }
        }
        .task(id: checkRequest) {
            await checkInstallation(manual: checkRequest > 0)
        }
    }

    @MainActor
    private func checkInstallation(manual: Bool) async {
        checking = true
        checkMessage = nil
        defer { if !Task.isCancelled { checking = false } }

        do {
            for delay in [0, 300, 700] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                let installed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    WidgetCenter.shared.getCurrentConfigurations { result in
                        continuation.resume(with: result.map { widgets in
                            widgets.contains { $0.kind == "TACTAssignments" }
                        })
                    }
                }
                try Task.checkCancellation()
                if installed {
                    onFinish()
                    return
                }
            }
            if manual {
                checkMessage = "ウィジェットがまだ見つかりません。追加したら、もう一度確認してください。"
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                checkMessage = "追加状況を確認できませんでした。「追加を確認」を押してもう一度お試しください。"
            }
        }
    }
}
