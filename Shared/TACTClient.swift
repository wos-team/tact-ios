import Foundation
import Security

enum TACTError: LocalizedError {
    case signInRequired
    case timedOut(String)
    case requestFailed(String)
    case storage

    var errorDescription: String? {
        switch self {
        case .signInRequired: "TACTへの再接続が必要です。"
        case .timedOut(let stage): "\(stage)でTACTの応答がタイムアウトしました。「今すぐ更新」で再試行できます。"
        case .requestFailed(let stage): "TACTの\(stage)に失敗しました。「今すぐ更新」で再試行できます。"
        case .storage: "端末の共有ストレージにアクセスできません。"
        }
    }
}

struct TACTSession: Codable {
    let id: UUID
    let cookies: [SessionCookie]

    init(cookies: [SessionCookie]) {
        id = UUID()
        self.cookies = cookies
    }
}

struct SessionCookie: Codable {
    let name: String
    let value: String
    let path: String
    let expires: Date?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        path = cookie.path
        expires = cookie.expiresDate
    }

    func applies(to requestPath: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (expires.map { $0 > Date() } ?? true)
            && (requestPath == path || requestPath.hasPrefix(prefix))
    }
}

struct WidgetSyncAttempt: Codable {
    enum Outcome: String, Codable { case success, failure, reconnect }

    let finishedAt: Date
    let result: String
    var sessionID: UUID? = nil
    var outcome: Outcome? = nil
}

enum TACTStore {
    static let group = "group.jp.matsuokakoki.tact-ios"
    private static let firstDayEndKey = "widgetFirstLaunchDayEnd"
    private static let widgetAttemptKey = "lastWidgetSyncAttempt"

    static var lastWidgetAttempt: WidgetSyncAttempt? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: widgetAttemptKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSyncAttempt.self, from: data)
    }

    static func recordWidgetAttempt(_ result: String, for sessionID: UUID?, outcome: WidgetSyncAttempt.Outcome) {
        let attempt = WidgetSyncAttempt(finishedAt: .now, result: result, sessionID: sessionID, outcome: outcome)
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        UserDefaults(suiteName: group)?.set(data, forKey: widgetAttemptKey)
    }

    static var widgetFirstDayEnd: Date? {
        UserDefaults(suiteName: group)?.object(forKey: firstDayEndKey) as? Date
    }

    static func recordFirstLaunch(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let defaults = UserDefaults(suiteName: group),
              defaults.object(forKey: firstDayEndKey) == nil,
              let day = calendar.dateInterval(of: .day, for: date) else { return false }
        defaults.set(day.end, forKey: firstDayEndKey)
        return true
    }

    private static let baseKey: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccessGroup as String: group,
        kSecAttrService as String: "tact.ac.thers.ac.jp"
    ]

    private static func key(pending: Bool) -> [String: Any] {
        var key = baseKey
        key[kSecAttrAccount as String] = pending ? "pending-student-session" : "student-session"
        return key
    }

    static func session(pending: Bool = false) throws -> TACTSession? {
        var query = key(pending: pending)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TACTError.storage }
        return try JSONDecoder().decode(TACTSession.self, from: data)
    }

    static func save(_ session: TACTSession, pending: Bool = false) throws {
        let key = key(pending: pending)
        let data = try JSONEncoder().encode(session)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TACTError.storage }

        var item = key
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TACTError.storage }
    }

    static func clearPendingSession() throws {
        let status = SecItemDelete(key(pending: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TACTError.storage }
    }

    static func snapshot(for id: UUID) -> Snapshot? {
        guard let url = try? snapshotURL(for: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) throws {
        let url = try snapshotURL(for: snapshot.sessionID)
        if let current = self.snapshot(for: snapshot.sessionID),
           (current.startedAt ?? current.syncedAt) > (snapshot.startedAt ?? snapshot.syncedAt) { return }
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func discardSnapshot(for id: UUID) {
        guard let url = try? snapshotURL(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func snapshotURL(for id: UUID) throws -> URL {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TACTError.storage
        }
        return directory.appendingPathComponent("assignments-\(id.uuidString).json")
    }
}

enum WidgetSyncSchedule {
    static func nextAttempt(after lastAttempt: Date, at now: Date, firstDayEnd: Date?) -> Date {
        let firstDayAttempt = lastAttempt.addingTimeInterval(10 * 60)
        if let firstDayEnd, max(now, firstDayAttempt) < firstDayEnd {
            return firstDayAttempt
        }
        return lastAttempt.addingTimeInterval(60 * 60)
    }
}

final class TACTRedirects: NSObject, URLSessionTaskDelegate {
    let cookies: [SessionCookie]

    init(cookies: [SessionCookie]) {
        self.cookies = cookies
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              original.path.hasPrefix("/portal/tool/"), destination.scheme == "https",
              destination.host == TACTClient.host, destination.port == nil || destination.port == 443,
              original.pathComponents.prefix(4).elementsEqual(destination.pathComponents.prefix(4)) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.setValue(TACTClient.cookieHeader(cookies, path: destination.path), forHTTPHeaderField: "Cookie")
        completionHandler(redirected)
    }
}

struct TACTDownloadPending: Error {}

enum TACTClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let host = "tact.ac.thers.ac.jp"
    static let home = URL(string: "https://\(host)/portal")!
    static let login = home.appendingPathComponent("login")

    private struct SessionResponse: Decodable {
        let userEid: String?
    }

    static func fetch(using session: TACTSession) async throws -> Snapshot {
        let started = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        let network = URLSession(configuration: configuration, delegate: TACTRedirects(cookies: session.cookies), delegateQueue: nil)
        defer { network.finishTasksAndInvalidate() }

        return try await fetch(using: session, network: network, started: started)
    }

    static func fetch(using session: TACTSession, network: URLSession, started: Date) async throws -> Snapshot {
        try await fetch(using: session, started: started) { request in
            let (data, response) = try await network.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    static func fetch(using session: TACTSession, started: Date, transport: @escaping Transport) async throws -> Snapshot {
        // Schedule both read requests together when using the background transport.
        async let identityRequest = attempt {
            let identity: SessionResponse = try await load(
                "/direct/session/current.json", stage: "ログイン状態の確認", using: session, transport: transport
            )
            guard let userEid = identity.userEid, !userEid.isEmpty else { throw TACTError.signInRequired }
        }
        async let sitesRequest = attempt {
            let sites: SiteResponse = try await load(
                "/direct/site.json?_limit=500", stage: "講義一覧の取得", using: session, transport: transport
            )
            return sites
        }
        let (identity, sitesResult) = try await (identityRequest, sitesRequest)
        try identity.value()
        let siteList = try sitesResult.value()
        var knownSites = Set<String>()
        let sites = siteList.site_collection.filter {
            !$0.id.isEmpty && !$0.id.hasPrefix("~") && $0.type != "myworkspace" && knownSites.insert($0.id).inserted
        }
        let courses = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0.title) })
        let prior = TACTStore.snapshot(for: session.id)
        var failedSites = Set<String>()
        var assignments: [Assignment] = []
        var firstFailure: TACTError?
        var successfulRequests = 0
        var hasPendingDownloads = false

        for offset in stride(from: 0, to: sites.count, by: 4) {
            try Task.checkCancellation()
            let batch = sites[offset..<min(offset + 4, sites.count)]
            try await withThrowingTaskGroup(of: CourseSync.self) { group in
                for site in batch {
                    group.addTask {
                        let slug = encodePathSegment(site.id)
                        let assignments = try await attempt {
                            let response: AssignmentResponse = try await load(
                                "/direct/assignment/site/\(slug).json?_limit=0",
                                stage: "講義別の課題取得", using: session, transport: transport
                            )
                            return response.assignment_collection.compactMap { $0.assignment(courses: courses, at: started) }
                        }
                        let quizzes = try await attempt {
                            try await loadQuizzes(site: site, slug: slug, date: started, using: session, transport: transport)
                        }
                        return CourseSync(site: site, assignments: assignments, quizzes: quizzes)
                    }
                }
                for try await result in group {
                    let previous = prior?.assignments.filter {
                        $0.courseID.map { $0 == result.site.id } ?? ($0.course == result.site.title)
                    } ?? []

                    switch result.assignments {
                    case .success(let entries):
                        successfulRequests += 1
                        assignments += entries
                    case .pending:
                        hasPendingDownloads = true
                    case .failure(let error):
                        failedSites.insert(result.site.id)
                        if firstFailure == nil { firstFailure = error }
                        assignments += previous.filter { $0.isQuiz != true }
                    }

                    switch result.quizzes {
                    case .success(let sync):
                        successfulRequests += 1
                        if sync.submissionStatusUnavailable {
                            failedSites.insert(result.site.id)
                            let previouslySubmitted = Set(previous.filter { $0.isQuiz == true && $0.submitted }.map(\.id))
                            assignments += sync.entries.map { entry in
                                var entry = entry
                                entry.submitted = entry.submitted || previouslySubmitted.contains(entry.id)
                                return entry
                            }
                        } else {
                            assignments += sync.entries
                        }
                    case .pending:
                        hasPendingDownloads = true
                    case .failure(let error):
                        failedSites.insert(result.site.id)
                        if firstFailure == nil { firstFailure = error }
                        assignments += previous.filter { $0.isQuiz == true }
                    }
                }
            }
        }

        if hasPendingDownloads { throw TACTDownloadPending() }
        if successfulRequests == 0, let firstFailure { throw firstFailure }
        var seen = Set<String>()
        return Snapshot(
            sessionID: session.id,
            syncedAt: .now,
            assignments: assignments.filter { seen.insert($0.id).inserted },
            failedCourseCount: failedSites.count,
            startedAt: started
        )
    }

    private struct CourseSync {
        let site: SiteResponse.Site
        let assignments: FetchResult<[Assignment]>
        let quizzes: FetchResult<QuizSync>
    }

    private struct QuizSync {
        let entries: [Assignment]
        let submissionStatusUnavailable: Bool
    }

    private enum FetchResult<Value> {
        case success(Value)
        case failure(TACTError)
        case pending

        func value() throws -> Value {
            switch self {
            case .success(let value): return value
            case .failure(let error): throw error
            case .pending: throw TACTDownloadPending()
            }
        }
    }

    private static func attempt<Value>(_ operation: () async throws -> Value) async throws -> FetchResult<Value> {
        do {
            return .success(try await operation())
        } catch is TACTDownloadPending {
            return .pending
        } catch TACTError.signInRequired {
            throw TACTError.signInRequired
        } catch let error as TACTError {
            return .failure(error)
        }
    }

    private static func loadQuizzes(
        site: SiteResponse.Site, slug: String, date: Date, using session: TACTSession, transport: Transport
    ) async throws -> QuizSync {
        let response: QuizResponse = try await load(
            "/direct/sam_pub/context/\(slug).json", stage: "小テスト一覧の取得", using: session, transport: transport
        )
        let candidates = response.sam_pub_collection.compactMap { quiz in
            quiz.assignment(site: site, at: date).map { (quiz, $0) }
        }
        guard !candidates.isEmpty else { return QuizSync(entries: [], submissionStatusUnavailable: false) }

        let verified = try await attempt {
            try await quizSubmissions(site: site, slug: slug, using: session, transport: transport)
        }
        switch verified {
        case .success(let submitted):
            // Older TACT pages only expose the title for tests without feedback links.
            let titleCounts = Dictionary(grouping: response.sam_pub_collection) {
                SubmittedQuizzes.normalizedTitle($0.title)
            }.mapValues(\.count)
            let entries = candidates.map { quiz, task in
                var entry = task
                let title = SubmittedQuizzes.normalizedTitle(quiz.title)
                entry.submitted = submitted.assessmentIDs.contains(quiz.assessmentID)
                    || (titleCounts[title] == 1 && submitted.titles.contains(title))
                return entry
            }
            let ambiguous = candidates.contains { quiz, _ in
                let title = SubmittedQuizzes.normalizedTitle(quiz.title)
                return !submitted.assessmentIDs.contains(quiz.assessmentID)
                    && titleCounts[title, default: 0] > 1 && submitted.titles.contains(title)
            }
            return QuizSync(entries: entries, submissionStatusUnavailable: ambiguous)
        case .pending:
            throw TACTDownloadPending()
        case .failure:
            return QuizSync(entries: candidates.map { $0.1 }, submissionStatusUnavailable: true)
        }
    }

    private static func quizSubmissions(
        site: SiteResponse.Site, slug: String, using session: TACTSession, transport: Transport
    ) async throws -> SubmittedQuizzes {
        let stage = "小テストの提出状態の確認"
        var placement = site.sitePages?.compactMap(\.quizPlacement).first
        if placement == nil {
            let pages: [SiteResponse.Page] = try await load(
                "/direct/site/\(slug)/pages.json", stage: stage, using: session, transport: transport
            )
            placement = pages.compactMap(\.quizPlacement).first
        }
        guard let placement, !placement.isEmpty else { throw TACTError.requestFailed(stage) }
        let html = try await loadData(
            "/portal/tool/\(encodePathSegment(placement))", stage: stage,
            accept: "text/html", using: session, transport: transport
        )
        guard let submitted = SubmittedQuizzes(html: html) else { throw TACTError.requestFailed(stage) }
        return submitted
    }

    private static func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func cookieHeader(_ cookies: [SessionCookie], path: String) -> String? {
        let applicable = cookies.filter { $0.applies(to: path) }
        guard !applicable.isEmpty else { return nil }
        return applicable.sorted { $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func load<Value: Decodable>(
        _ path: String,
        stage: String,
        using session: TACTSession,
        transport: Transport
    ) async throws -> Value {
        let data = try await loadData(path, stage: stage, accept: "application/json", using: session, transport: transport)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TACTError.requestFailed(stage)
        }
    }

    private static func loadData(
        _ path: String, stage: String, accept: String, using session: TACTSession, transport: Transport
    ) async throws -> Data {
        let url = URL(string: "https://\(host)\(path)")!
        guard let cookie = cookieHeader(session.cookies, path: url.path) else {
            if accept == "text/html" { throw TACTError.requestFailed(stage) }
            throw TACTError.signInRequired
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch is TACTDownloadPending {
            throw TACTDownloadPending()
        } catch let error as URLError where error.code == .timedOut {
            throw TACTError.timedOut(stage)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TACTError.requestFailed(stage)
        }
        if response.statusCode == 401 { throw TACTError.signInRequired }
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: url)?.absoluteURL,
           target.path.hasPrefix("/portal/login") || target.path.contains("/Shibboleth.sso/") {
            throw TACTError.signInRequired
        }
        guard response.statusCode == 200 else { throw TACTError.requestFailed(stage) }
        return data
    }
}
