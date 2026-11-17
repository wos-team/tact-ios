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

enum TACTStore {
    static let group = "group.jp.matsuokakoki.tact-ios"
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
        if let current = self.snapshot(for: snapshot.sessionID), current.syncedAt > snapshot.syncedAt { return }
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

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum TACTClient {
    static let host = "tact.ac.thers.ac.jp"
    static let home = URL(string: "https://\(host)/portal")!
    static let login = home.appendingPathComponent("login")
    static let refreshInterval: TimeInterval = 60 * 60

    private struct SessionResponse: Decodable {
        let userEid: String?
    }

    static func fetch(using session: TACTSession, foreground: Bool = false) async throws -> Snapshot {
        let started = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = foreground ? 25 : 8
        configuration.timeoutIntervalForResource = foreground ? 35 : 12
        let network = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { network.finishTasksAndInvalidate() }

        return try await fetch(using: session, network: network, started: started)
    }

    static func fetch(using session: TACTSession, network: URLSession, started: Date) async throws -> Snapshot {
        // The API can return an empty HTTP 200 response for anonymous requests.
        let identity: SessionResponse = try await load("/direct/session/current.json", stage: "ログイン状態の確認", using: session, network: network)
        guard let userEid = identity.userEid, !userEid.isEmpty else { throw TACTError.signInRequired }

        let siteList: SiteResponse = try await load("/direct/site.json?_limit=500", stage: "講義一覧の取得", using: session, network: network)
        var knownSites = Set<String>()
        let sites = siteList.site_collection.filter {
            !$0.id.isEmpty && !$0.id.hasPrefix("~") && $0.type != "myworkspace" && knownSites.insert($0.id).inserted
        }
        let courses = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0.title) })
        let prior = TACTStore.snapshot(for: session.id)
        var failedSites = Set<String>()
        var assignments: [Assignment] = []
        var firstFailure: TACTError?

        for offset in stride(from: 0, to: sites.count, by: 4) {
            try Task.checkCancellation()
            let batch = sites[offset..<min(offset + 4, sites.count)]
            try await withThrowingTaskGroup(of: (String, Result<AssignmentResponse, TACTError>).self) { group in
                for site in batch {
                    group.addTask {
                        let stage = "講義別の課題取得"
                        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
                        guard let slug = site.id.addingPercentEncoding(withAllowedCharacters: allowed) else {
                            return (site.id, .failure(.requestFailed(stage)))
                        }
                        do {
                            let response: AssignmentResponse = try await load(
                                "/direct/assignment/site/\(slug).json?_limit=0", stage: stage, using: session, network: network
                            )
                            return (site.id, .success(response))
                        } catch TACTError.signInRequired {
                            throw TACTError.signInRequired
                        } catch let error as TACTError {
                            return (site.id, .failure(error))
                        }
                    }
                }
                for try await (id, result) in group {
                    switch result {
                    case .success(let response):
                        assignments += response.assignment_collection.compactMap {
                            $0.assignment(courses: courses, at: started)
                        }
                    case .failure(let error):
                        failedSites.insert(id)
                        if firstFailure == nil { firstFailure = error }
                    }
                }
            }
        }

        if failedSites.count == sites.count, let firstFailure { throw firstFailure }
        if let prior, !failedSites.isEmpty {
            let failedNames = Set(failedSites.compactMap { courses[$0] })
            assignments += prior.assignments.filter {
                if let id = $0.courseID { return failedSites.contains(id) }
                return failedNames.contains($0.course)
            }
        }
        var seen = Set<String>()
        return Snapshot(
            sessionID: session.id,
            syncedAt: started,
            assignments: assignments.filter { seen.insert($0.id).inserted },
            failedCourseCount: failedSites.count
        )
    }

    private static func load<Value: Decodable>(
        _ path: String,
        stage: String,
        using session: TACTSession,
        network: URLSession
    ) async throws -> Value {
        let url = URL(string: "https://\(host)\(path)")!
        let cookies = session.cookies.filter { $0.applies(to: url.path) }
        guard !cookies.isEmpty else { throw TACTError.signInRequired }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let data: Data
        let raw: URLResponse
        do {
            (data, raw) = try await network.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TACTError.timedOut(stage)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TACTError.requestFailed(stage)
        }
        guard let response = raw as? HTTPURLResponse else { throw TACTError.requestFailed(stage) }
        if response.statusCode == 401 { throw TACTError.signInRequired }
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: url)?.absoluteURL,
           target.path.hasPrefix("/portal/login") || target.path.contains("/Shibboleth.sso/") {
            throw TACTError.signInRequired
        }
        guard response.statusCode == 200 else { throw TACTError.requestFailed(stage) }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TACTError.requestFailed(stage)
        }
    }
}
