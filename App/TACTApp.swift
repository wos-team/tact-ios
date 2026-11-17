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
    @State private var needsReconnect = false
    @State private var syncing = false
    @State private var showsSignIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if connected {
                        Button {
                            Task { await sync(force: true) }
                        } label: {
                            if syncing {
                                ProgressView()
                            } else {
                                Label("今すぐ更新", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(syncing)
                    }

                    if !connected || needsReconnect {
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

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                }

                if let snapshot {
                    Section("未提出の課題") {
                        let assignments = snapshot.upcoming(at: .now)
                        if assignments.isEmpty {
                            Text("表示できる未提出課題はありません。").foregroundStyle(.secondary)
                        }
                        ForEach(assignments) { assignment in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(assignment.title).font(.headline)
                                Text(assignment.course)
                                Text(assignment.due, format: .dateTime.month().day().weekday().hour().minute())
                                    .foregroundStyle(assignment.due < .now ? Color.orange : Color.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Link("TACTをブラウザで開く", destination: TACTClient.home)
                }
            }
            .navigationTitle("TACT 課題")
            .refreshable { await sync(force: true) }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await sync(force: false) }
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

    @MainActor
    private func sync(force: Bool) async {
        guard !syncing else { return }

        do {
            guard let session = try TACTStore.session() else {
                connected = false
                return
            }
            connected = true
            let saved = TACTStore.snapshot(for: session.id)
            snapshot = saved
            if !force, let saved, Date().timeIntervalSince(saved.syncedAt) < 5 * 60 { return }
            await fetch(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func completeSignIn(_ cookies: [SessionCookie]) async {
        showsSignIn = false
        guard !syncing else { return }
        let session = TACTSession(cookies: cookies)
        await fetch(session, newSession: true)
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
                if let previous { TACTStore.discardSnapshot(for: previous.id) }
            }
            connected = true
            snapshot = TACTStore.snapshot(for: session.id) ?? updated
            needsReconnect = false
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
        } catch is CancellationError {
            return
        } catch {
            if case TACTError.signInRequired = error { needsReconnect = true }
            errorMessage = error.localizedDescription
        }
    }
}
