import CryptoKit
import Foundation

struct AssignmentAttachment: Codable, Identifiable, Equatable {
    let name: String
    let url: URL
    let isPDF: Bool

    var id: URL { url }
}

struct AssignmentSummaryRecord: Codable {
    struct PDF: Codable, Equatable {
        let attachment: AssignmentAttachment
        let digest: String
        let text: String
        let unreadablePages: [Int]
    }

    var revision: String?
    var checkedAt: Date
    var instructions: String
    var attachments: [AssignmentAttachment]
    var pdfs: [PDF]
    var unavailablePDFs: [String]
    var notes: [String] = []
    var summary: String?

    var hasSource: Bool { !instructions.isEmpty || pdfs.contains { !$0.text.isEmpty } }

    var hasIncompletePDF: Bool {
        !unavailablePDFs.isEmpty || pdfs.contains { !$0.unreadablePages.isEmpty }
    }

    func matches(_ assignment: Assignment) -> Bool { revision == assignment.contentRevision }

    var checkAgainAfter: TimeInterval? {
        if !unavailablePDFs.isEmpty { return 30 * 60 }
        // A resource may be replaced in place without changing the assignment timestamp.
        let needsPeriodicCheck = revision?.isEmpty != false || attachments.contains(where: \.isPDF)
        return needsPeriodicCheck ? 24 * 60 * 60 : nil
    }

    func needsFetch(for assignment: Assignment, at date: Date) -> Bool {
        !matches(assignment) || checkAgainAfter.map { date.timeIntervalSince(checkedAt) >= $0 } == true
    }
}

struct AssignmentSummaryPreview: Codable, Equatable {
    var checkedAt: Date = .now
    var hasSource = true
    var checkAgainAfter: TimeInterval? = nil
    var revision: String?
    var text: String?
    var includesAllPDFs: Bool
    var originalExcerpt: String?

    var needsWork: Bool {
        (hasSource && text == nil) || checkAgainAfter.map { Date().timeIntervalSince(checkedAt) >= $0 } == true
    }
}

enum AssignmentSummaryStore {
    static func preview(for assignment: Assignment, account: String) -> AssignmentSummaryPreview? {
        guard let url = try? file(for: assignment, account: account, suffix: "-preview.json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(AssignmentSummaryPreview.self, from: data),
              result.revision == assignment.contentRevision else { return nil }
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func record(for assignment: Assignment, account: String) -> AssignmentSummaryRecord? {
        guard let url = try? file(for: assignment, account: account),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AssignmentSummaryRecord.self, from: data)
    }

    static func save(
        _ record: AssignmentSummaryRecord, for assignment: Assignment, account: String, updatePreview: Bool = true
    ) throws {
        let url = try file(for: assignment, account: account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        try JSONEncoder().encode(record).write(to: url, options: options)
        if updatePreview {
            let preview = AssignmentSummaryPreview(checkedAt: record.checkedAt, hasSource: record.hasSource,
                                                   checkAgainAfter: record.checkAgainAfter, revision: record.revision,
                                                   text: record.summary,
                                                   includesAllPDFs: !record.hasIncompletePDF,
                                                   originalExcerpt: record.instructions.isEmpty ? nil : String(record.instructions.prefix(180)))
            let previewURL = try file(for: assignment, account: account, suffix: "-preview.json")
            try JSONEncoder().encode(preview).write(to: previewURL, options: options)
        }
    }

    private static func file(for assignment: Assignment, account: String, suffix: String = ".json") throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TACTStore.group) else {
            throw TACTError.storage
        }
        let key = digest(Data((account + ":" + assignment.id).utf8))
        return root.appendingPathComponent("AssignmentSummaries", isDirectory: true).appendingPathComponent(key + suffix)
    }
}
