import Foundation

struct Assignment: Identifiable, Codable {
    let id: String
    let title: String
    let course: String
    let due: Date
    let closes: Date
    let submitted: Bool
}

struct Snapshot: Codable {
    let sessionID: UUID
    let syncedAt: Date
    let assignments: [Assignment]

    func upcoming(at date: Date) -> [Assignment] {
        assignments
            .filter { !$0.submitted && $0.closes > date }
            .sorted { ($0.due, $0.id) < ($1.due, $1.id) }
    }
}

struct AssignmentResponse: Decodable {
    let assignment_collection: [TACTAssignment]
}

struct TACTAssignment: Decodable {
    struct Timestamp: Decodable {
        let epochSecond: TimeInterval
        var date: Date { Date(timeIntervalSince1970: epochSecond) }
    }

    struct Submission: Decodable {
        let dateSubmitted: String?
        let submitted: Bool?

        var isSubmitted: Bool {
            if let dateSubmitted, !dateSubmitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return submitted == true
        }
    }

    let id: String
    let title: String
    let context: String
    let dueTime: Timestamp?
    let closeTime: Timestamp?
    let openTime: Timestamp?
    let status: String?
    let draft: Bool?
    let submissions: [Submission]?

    func assignment(courses: [String: String], at date: Date) -> Assignment? {
        guard draft != true, status?.uppercased() != "CLOSED",
              openTime.map({ $0.date <= date }) ?? true,
              let due = dueTime?.date else { return nil }
        return Assignment(
            id: id,
            title: title,
            course: courses[context] ?? context,
            due: due,
            closes: closeTime?.date ?? due,
            submitted: submissions?.contains(where: \.isSubmitted) ?? false
        )
    }
}

struct SiteResponse: Decodable {
    struct Site: Decodable {
        let id: String
        let title: String
    }

    let site_collection: [Site]
}
