import Foundation
import Security

enum TACTError: LocalizedError {
    case signInRequired
    case unavailable
    case storage

    var errorDescription: String? {
        switch self {
        case .signInRequired: "TACTへの再接続が必要です。"
        case .unavailable: "TACTを更新できませんでした。時間をおいてお試しください。"
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
    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccessGroup as String: group,
        kSecAttrService as String: "tact.ac.thers.ac.jp",
        kSecAttrAccount as String: "student-session"
    ]

    static func session() throws -> TACTSession? {
        var query = key
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TACTError.storage }
        return try JSONDecoder().decode(TACTSession.self, from: data)
    }

    static func save(_ session: TACTSession) throws {
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

    static func fetch(using session: TACTSession) async throws -> Snapshot {
        let started = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let network = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { network.finishTasksAndInvalidate() }

        async let siteList: SiteResponse? = try? load("/direct/site.json?_limit=500", using: session, network: network)
        let response: AssignmentResponse = try await load("/direct/assignment/my.json?_limit=0", using: session, network: network)
        let sites = await siteList
        let courses = Dictionary(sites?.site_collection.map { ($0.id, $0.title) } ?? [], uniquingKeysWith: { first, _ in first })
        return Snapshot(sessionID: session.id, syncedAt: started, assignments: response.assignment_collection.compactMap {
            $0.assignment(courses: courses, at: started)
        })
    }

    private static func load<Value: Decodable>(
        _ path: String,
        using session: TACTSession,
        network: URLSession
    ) async throws -> Value {
        let url = URL(string: "https://\(host)\(path)")!
        let cookies = session.cookies.filter { $0.applies(to: url.path) }
        guard !cookies.isEmpty else { throw TACTError.signInRequired }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let (data, raw) = try await network.data(for: request)
        guard let response = raw as? HTTPURLResponse else { throw TACTError.unavailable }
        if response.statusCode == 401 { throw TACTError.signInRequired }
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let target = URL(string: location, relativeTo: url)?.absoluteURL,
           target.path.hasPrefix("/portal/login") || target.path.contains("/Shibboleth.sso/") {
            throw TACTError.signInRequired
        }
        guard response.statusCode == 200 else { throw TACTError.unavailable }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TACTError.unavailable
        }
    }
}
