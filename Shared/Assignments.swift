import Foundation
import libxml2

struct Assignment: Identifiable, Codable {
    let id: String
    let title: String
    let course: String
    let due: Date
    let closes: Date
    var submitted: Bool
    var courseID: String? = nil
    var isQuiz: Bool? = nil

    var courseLabel: String { isQuiz == true ? "小テスト · \(course)" : course }
    var hasDeadline: Bool { due != .distantFuture }
}

struct Snapshot: Codable {
    let sessionID: UUID
    let syncedAt: Date
    let assignments: [Assignment]
    var failedCourseCount: Int? = nil
    var startedAt: Date? = nil

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
            submitted: submissions?.contains(where: \.isSubmitted) ?? false,
            courseID: context
        )
    }
}

struct SiteResponse: Decodable {
    struct Site: Decodable {
        let id: String
        let title: String
        let type: String?
        let sitePages: [Page]?
    }

    struct Page: Decodable {
        struct Tool: Decodable {
            let id: String?
            let placementId: String?
            let toolId: String?
        }

        let tools: [Tool]?

        var quizPlacement: String? {
            let tool = tools?.first { $0.toolId == "sakai.samigo" }
            return tool?.placementId ?? tool?.id
        }
    }

    let site_collection: [Site]
}

struct QuizResponse: Decodable {
    let sam_pub_collection: [TACTQuiz]
}

struct TACTQuiz: Decodable {
    struct Number: Decodable {
        let value: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self), let number = Int64(string) {
                value = number
            } else {
                value = try container.decode(Int64.self)
            }
        }

        var time: Date? {
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
    }

    let publishedAssessmentId: Number
    let title: String
    let startDate: Number?
    let dueDate: Number?
    let retractDate: Number?
    let status: Number?

    var assessmentID: String { String(publishedAssessmentId.value) }

    func assignment(site: SiteResponse.Site, at date: Date) -> Assignment? {
        guard status?.value != 0, startDate?.time.map({ $0 <= date }) ?? true else { return nil }
        let due = dueDate?.time ?? retractDate?.time ?? .distantFuture
        let closes = retractDate?.time ?? due
        guard closes > date else { return nil }
        return Assignment(id: "quiz:\(site.id):\(assessmentID)", title: title, course: site.title,
                          due: due, closes: closes, submitted: false, courseID: site.id, isQuiz: true)
    }
}

struct SubmittedQuizzes {
    let assessmentIDs: Set<String>
    let titles: Set<String>

    init?(html: Data) {
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard let document = html.withUnsafeBytes({ bytes in
            htmlReadMemory(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count),
                           nil, "UTF-8", Int32(options))
        }) else { return nil }
        defer { xmlFreeDoc(document) }

        guard let context = xmlXPathNewContext(document) else { return nil }
        defer { xmlXPathFreeContext(context) }

        func matches<Value>(_ expression: String, from node: xmlNodePtr? = nil, read: (xmlNodePtr) -> Value?) -> [Value] {
            let result = node.map { xmlXPathNodeEval($0, expression, context) } ?? xmlXPathEvalExpression(expression, context)
            guard let result else { return [] }
            defer { xmlXPathFreeObject(result) }
            guard let nodes = result.pointee.nodesetval?.pointee, let table = nodes.nodeTab else { return [] }
            return (0..<Int(nodes.nodeNr)).compactMap { index in table[index].flatMap(read) }
        }

        func text(_ node: xmlNodePtr) -> String? {
            guard let value = xmlNodeGetContent(node) else { return nil }
            defer { xmlFree(value) }
            return String(cString: value)
        }

        let form = "//form[@id='selectIndexForm']"
        guard !matches(form, read: { _ in true }).isEmpty else { return nil }
        let rows = form + "//table[@id='selectIndexForm:reviewTable' or @id='reviewTable']//tr[td]"
        let idPattern = #/['"](?:publishedId|publishedAssessmentId)['"]\s*[:,]\s*['"](\d+)['"]/#
        var ids = Set<String>()
        var names = Set<String>()
        _ = matches(rows) { row in
            let links = matches("./td//a/@onclick", from: row, read: text)
            let rowIDs = links.flatMap { $0.matches(of: idPattern).map { String($0.1) } }
            ids.formUnion(rowIDs)
            if rowIDs.isEmpty {
                let selector = "./td[1]/span[contains(concat(' ',normalize-space(@class),' '),' currentSort ')]"
                let rowTitles = matches(selector, from: row, read: text)
                names.formUnion(rowTitles.map(Self.normalizedTitle).filter { !$0.isEmpty })
            }
            return true
        }
        assessmentIDs = ids
        titles = names
    }

    static func normalizedTitle(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
    }
}
