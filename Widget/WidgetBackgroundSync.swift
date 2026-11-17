import CryptoKit
import Foundation
import WidgetKit

private struct WidgetSyncJob: Codable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date

    private static func root() throws -> URL {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TACTStore.group) else {
            throw TACTError.storage
        }
        return group.appendingPathComponent("Library/Caches/TACTWidgetSync", isDirectory: true)
    }

    var directory: URL {
        get throws { try Self.root().appendingPathComponent(id.uuidString, isDirectory: true) }
    }

    static func current() throws -> Self? {
        let file = try root().appendingPathComponent("current.plist")
        do {
            return try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func begin(sessionID: UUID, at date: Date) throws -> Self {
        let job = Self(id: UUID(), sessionID: sessionID, startedAt: date)
        let directory = try job.directory
        let parent = try root()
        // A process termination can leave an unreferenced directory behind.
        if let old = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            for file in old where UUID(uuidString: file.lastPathComponent) != nil {
                try? FileManager.default.removeItem(at: file)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try PropertyListEncoder().encode(job).write(
                to: root().appendingPathComponent("current.plist"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return job
    }

    func remove() throws {
        guard try Self.current()?.id == id else { return }
        try FileManager.default.removeItem(at: Self.root().appendingPathComponent("current.plist"))
        try? FileManager.default.removeItem(at: directory)
    }

    func responseFile(for url: URL) throws -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try directory.appendingPathComponent(name + ".plist")
    }
}

private struct WidgetDownloadResult: Codable {
    let status: Int
    let error: Int?
    let body: Data

    func response(for url: URL) throws -> (Data, HTTPURLResponse) {
        if let error {
            if error == URLError.timedOut.rawValue { throw URLError(.timedOut) }
            throw URLError(.badServerResponse)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }
}

private final class WidgetDownloadReceiver: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, let url = response.url else {
                throw URLError(.badServerResponse)
            }
            // The background daemon follows redirects. Store only the result of a TACT-origin request.
            let leftTACT = url.scheme != "https" || url.host != TACTClient.host || (url.port != nil && url.port != 443)
            let login = url.path.hasPrefix("/portal/login") || url.path.contains("/Shibboleth.sso/")
            if leftTACT || login {
                store(WidgetDownloadResult(status: 401, error: nil, body: Data()), for: downloadTask)
                return
            }

            let status = response.statusCode
            let data: Data
            if status == 200 {
                let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, size <= 24 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                data = try Data(contentsOf: location)
            } else {
                data = Data()
            }
            store(WidgetDownloadResult(status: status, error: nil, body: data), for: downloadTask)
        } catch {
            store(WidgetDownloadResult(status: 0, error: (error as NSError).code, body: Data()), for: downloadTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            store(WidgetDownloadResult(status: 0, error: (error as NSError).code, body: Data()), for: task)
        }
        guard let id = task.taskDescription, let url = task.originalRequest?.url else { return }
        Task { @MainActor in
            await WidgetBackgroundSync.shared.downloadCompleted(jobID: id, url: url)
        }
    }

    private func store(_ result: WidgetDownloadResult, for task: URLSessionTask) {
        do {
            guard let job = try WidgetSyncJob.current(), task.taskDescription == job.id.uuidString,
                  let url = task.originalRequest?.url else { return }
            let file = try job.responseFile(for: url)
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(result).write(
                to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // A future timeline can retry from the persisted job if this result couldn't be saved.
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await WidgetBackgroundSync.shared.finishEvents()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor in
            await WidgetBackgroundSync.shared.sessionInvalidated()
        }
    }
}

@MainActor
final class WidgetBackgroundSync {
    static let shared = WidgetBackgroundSync()
    static let identifier = "jp.matsuokakoki.tact-ios.widget.background-sync"

    private static let maximumJobAge: TimeInterval = 30 * 60
    private let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: TACTStore.group)
    private var backgroundSession: URLSession?
    private var pumpTask: Task<Void, Never>?
    private var queuedURLs = Set<URL>()
    private var eventCompletions: [() -> Void] = []

    private var network: URLSession {
        if let backgroundSession { return backgroundSession }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sharedContainerIdentifier = TACTStore.group
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieStorage = cookies
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: WidgetDownloadReceiver(), delegateQueue: nil)
        backgroundSession = session
        return session
    }

    func entry(firstDayEnd: Date?) async -> AssignmentEntry {
        let now = Date()
        do {
            guard let session = try TACTStore.session() else {
                return AssignmentEntry(date: now, snapshot: nil, status: .signedOut)
            }
            let cached = TACTStore.snapshot(for: session.id)
            if let active = try WidgetSyncJob.current() {
                if active.sessionID == session.id, now.timeIntervalSince(active.startedAt) < Self.maximumJobAge {
                    await pump()
                    return currentEntry(for: session, date: now)
                }
                try await abandon(active)
                if active.sessionID == session.id {
                    TACTStore.recordWidgetAttempt("バックグラウンド転送が時間内に完了しませんでした", for: session.id, outcome: .failure)
                }
            }

            let previous = currentEntry(for: session, date: now)
            let lastAttempt = previous.lastAttemptAt ?? cached?.syncedAt ?? .distantPast
            let due = WidgetSyncSchedule.nextAttempt(after: lastAttempt, at: now, firstDayEnd: firstDayEnd) <= now
            if due, previous.status != .reconnect {
                clearCookies()
                _ = try WidgetSyncJob.begin(sessionID: session.id, at: now)
                await pump()
                return currentEntry(for: session, date: now)
            }
            return previous
        } catch {
            let session = try? TACTStore.session()
            TACTStore.recordWidgetAttempt("バックグラウンド同期の準備に失敗", for: session?.id, outcome: .failure)
            return AssignmentEntry(date: now, snapshot: session.flatMap { TACTStore.snapshot(for: $0.id) },
                                   status: .delayed, lastAttemptAt: now)
        }
    }

    private func currentEntry(for session: TACTSession, date: Date) -> AssignmentEntry {
        let cached = TACTStore.snapshot(for: session.id)
        let job = try? WidgetSyncJob.current()
        if let job, job.sessionID == session.id {
            return AssignmentEntry(date: date, snapshot: cached, status: .syncing, lastAttemptAt: date)
        }

        let attempt = TACTStore.lastWidgetAttempt
        let relevant = attempt.flatMap { value in
            value.sessionID == session.id && value.finishedAt >= (cached?.syncedAt ?? .distantPast) ? value : nil
        }
        let status: SyncStatus
        switch relevant?.outcome {
        case .reconnect: status = .reconnect
        case .failure: status = .delayed
        default: status = .ready
        }
        return AssignmentEntry(date: date, snapshot: cached, status: status, lastAttemptAt: relevant?.finishedAt)
    }

    func receiveEvents(completion: @escaping () -> Void) {
        eventCompletions.append(completion)
        _ = network
    }

    func downloadCompleted(jobID: String, url: URL) async {
        guard (try? WidgetSyncJob.current()?.id.uuidString) == jobID,
              queuedURLs.remove(url) != nil, queuedURLs.isEmpty else { return }
        await pump()
    }

    func finishEvents() async {
        let completions = eventCompletions
        eventCompletions.removeAll()
        await pump()
        completions.forEach { $0() }
    }

    func sessionInvalidated() async {
        backgroundSession = nil
        let completions = eventCompletions
        eventCompletions.removeAll()
        if let job = try? WidgetSyncJob.current() {
            finish(job, message: "iOSのバックグラウンド転送が中断されました", outcome: .failure)
        }
        completions.forEach { $0() }
    }

    private func pump() async {
        while let pending = pumpTask { await pending.value }
        let task = Task {
            await advanceJob()
            pumpTask = nil
        }
        pumpTask = task
        await task.value
    }

    private func advanceJob() async {
        guard let job = try? WidgetSyncJob.current() else { return }

        do {
            guard let session = try TACTStore.session(), session.id == job.sessionID else {
                try await abandon(job)
                return
            }
            // The daemon owns the requests and follows redirects. Use host-scoped cookies
            // rather than forwarding a manually constructed Cookie header across redirects.
            seedCookies(from: session, expiresBy: job.startedAt.addingTimeInterval(Self.maximumJobAge))
            let tasks = await allTasks()
            guard try WidgetSyncJob.current()?.id == job.id else { return }
            queuedURLs = Set(tasks.filter {
                $0.taskDescription == job.id.uuidString && $0.state != .canceling && $0.state != .completed
            }.compactMap { $0.originalRequest?.url })

            let snapshot = try await TACTClient.fetch(using: session, started: job.startedAt) { request in
                try await self.downloadResult(for: request, job: job)
            }
            guard try WidgetSyncJob.current()?.id == job.id else { return }
            guard try TACTStore.session()?.id == session.id else {
                try await abandon(job)
                return
            }
            try TACTStore.save(snapshot)
            let failures = snapshot.failedCourseCount ?? 0
            finish(job, message: failures > 0 ? "一部同期（未取得 \(failures)講義）" : "成功", outcome: .success)
        } catch is TACTDownloadPending {
            return
        } catch TACTError.signInRequired {
            finish(job, message: "要再接続", outcome: .reconnect)
        } catch TACTError.timedOut(let stage) {
            finish(job, message: "\(stage)がタイムアウト", outcome: .failure)
        } catch TACTError.requestFailed(let stage) {
            finish(job, message: "\(stage)に失敗", outcome: .failure)
        } catch {
            finish(job, message: "同期結果の保存に失敗", outcome: .failure)
        }
    }

    private func downloadResult(for request: URLRequest, job: WidgetSyncJob) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == TACTClient.host,
              try WidgetSyncJob.current()?.id == job.id else { throw CancellationError() }
        let file = try job.responseFile(for: url)
        do {
            let data = try Data(contentsOf: file)
            let result = try PropertyListDecoder().decode(WidgetDownloadResult.self, from: data)
            return try result.response(for: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if queuedURLs.insert(url).inserted {
                var request = request
                request.setValue(nil, forHTTPHeaderField: "Cookie")
                let task = network.downloadTask(with: request)
                task.taskDescription = job.id.uuidString
                task.resume()
            }
            throw TACTDownloadPending()
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            network.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func finish(_ job: WidgetSyncJob, message: String, outcome: WidgetSyncAttempt.Outcome) {
        guard (try? WidgetSyncJob.current()?.id) == job.id else { return }
        do {
            try job.remove()
        } catch {
            TACTStore.recordWidgetAttempt("同期の一時ファイルを整理できませんでした", for: job.sessionID, outcome: .failure)
            clearCookies()
            return
        }
        clearCookies()
        backgroundSession?.getAllTasks { tasks in
            for task in tasks where task.taskDescription == job.id.uuidString {
                task.cancel()
            }
        }
        TACTStore.recordWidgetAttempt(message, for: job.sessionID, outcome: outcome)
        WidgetCenter.shared.reloadTimelines(ofKind: "TACTAssignments")
    }

    private func abandon(_ job: WidgetSyncJob) async throws {
        try job.remove()
        clearCookies()
        for task in await allTasks() where task.taskDescription == job.id.uuidString {
            task.cancel()
        }
    }

    private func seedCookies(from session: TACTSession, expiresBy: Date) {
        for cookie in session.cookies {
            let expiry = min(cookie.expires ?? expiresBy, expiresBy)
            guard expiry > .now, let scoped = HTTPCookie(properties: [
                .originURL: TACTClient.home,
                .path: cookie.path,
                .name: cookie.name,
                .value: cookie.value,
                .secure: "TRUE",
                .expires: expiry
            ]) else { continue }
            cookies.setCookie(scoped)
        }
    }

    private func clearCookies() {
        for cookie in cookies.cookies ?? [] where cookie.domain == TACTClient.host {
            cookies.deleteCookie(cookie)
        }
    }
}
