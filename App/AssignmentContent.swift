import Foundation
import PDFKit
import Vision
import libxml2

enum AssignmentContent {
    private struct Detail: Decodable {
        struct Attachment: Decodable {
            let name: String?
            let url: String?
            let ref: String?
            let mimeType: String?
            let type: String?

            var file: AssignmentAttachment? {
                let path = url ?? ref.map { "/access" + $0 }
                guard let path, !path.isEmpty,
                      let target = URL(string: path.hasPrefix("/") || path.contains("://") ? path : "/" + path,
                                       relativeTo: TACTClient.home)?.absoluteURL,
                      target.scheme == "https", target.host == TACTClient.host,
                      target.port == nil || target.port == 443,
                      target.user == nil, target.password == nil,
                      target.path.hasPrefix("/access/") else { return nil }
                let filename = name.flatMap { $0.removingPercentEncoding } ?? name ?? target.lastPathComponent
                let isPDF = (mimeType ?? type)?.lowercased().hasPrefix("application/pdf") == true
                    || filename.lowercased().hasSuffix(".pdf") || target.pathExtension.lowercased() == "pdf"
                return AssignmentAttachment(name: filename, url: target, isPDF: isPDF)
            }
        }

        let id: String
        let instructions: String?
        let attachments: [Attachment]?
    }

    static func fetch(
        _ assignment: Assignment, using session: TACTSession, previous: AssignmentSummaryRecord?, retryIncomplete: Bool
    ) async throws -> AssignmentSummaryRecord {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let network = URLSession(configuration: configuration, delegate: TACTRedirects(cookies: session.cookies), delegateQueue: nil)
        defer { network.finishTasksAndInvalidate() }

        let id = TACTClient.encodePathSegment(assignment.id)
        let url = URL(string: "https://\(TACTClient.host)/direct/assignment/item/\(id).json")!
        let (data, response) = try await network.data(for: request(url, accept: "application/json", using: session))
        try check(response)
        guard let detail = try? JSONDecoder().decode(Detail.self, from: data), detail.id == assignment.id else {
            throw TACTError.requestFailed("課題詳細の取得")
        }

        let instructions = plainText(detail.instructions ?? "")
        let files = detail.attachments ?? []
        var seen = Set<URL>()
        let attachments = files.compactMap(\.file).filter { seen.insert($0.url).inserted }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
        var pdfs: [AssignmentSummaryRecord.PDF] = []
        var unavailablePDFs = files.filter { $0.file == nil && (
            ($0.mimeType ?? $0.type)?.lowercased().hasPrefix("application/pdf") == true
            || $0.name?.lowercased().hasSuffix(".pdf") == true
            || $0.url?.lowercased().hasSuffix(".pdf") == true
        ) }.map { $0.name ?? "添付PDF" }

        for attachment in attachments where attachment.isPDF {
            try Task.checkCancellation()
            do {
                let (file, response) = try await network.download(for: request(attachment.url, accept: "application/pdf", using: session))
                defer { try? FileManager.default.removeItem(at: file) }
                try check(response)
                // Read on disk so the temporary download does not occupy the app's heap.
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 50_000_000 else { throw TACTError.requestFailed("添付PDFの読み取り") }
                let contents = try Data(contentsOf: file, options: .mappedIfSafe)
                let digest = AssignmentSummaryStore.digest(contents)
                if let cached = previous?.pdfs.first(where: { $0.digest == digest && $0.attachment == attachment }),
                   !(retryIncomplete && !cached.unreadablePages.isEmpty) {
                    pdfs.append(cached)
                } else {
                    let (text, unreadablePages) = try readPDF(file)
                    pdfs.append(.init(attachment: attachment, digest: digest, text: text, unreadablePages: unreadablePages))
                }
            } catch {
                try Task.checkCancellation()
                // Keep the previous complete result when a same-revision refresh temporarily fails.
                if let previous, previous.matches(assignment), previous.pdfs.contains(where: { $0.attachment == attachment }) {
                    throw error
                }
                unavailablePDFs.append(attachment.name)
            }
        }

        var record = AssignmentSummaryRecord(revision: assignment.contentRevision, checkedAt: .now, instructions: instructions,
                                             attachments: attachments, pdfs: pdfs, unavailablePDFs: unavailablePDFs)
        if let previous, instructions == previous.instructions,
           pdfs.filter({ !$0.text.isEmpty }).map({ [$0.attachment.name, $0.text] }) ==
                previous.pdfs.filter({ !$0.text.isEmpty }).map({ [$0.attachment.name, $0.text] }) {
            record.summary = previous.summary
            record.notes = previous.notes
        }
        return record
    }

    private static func request(_ url: URL, accept: String, using session: TACTSession) throws -> URLRequest {
        guard let cookie = TACTClient.cookieHeader(session.cookies, path: url.path) else { throw TACTError.signInRequired }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 ||
            ((300..<400).contains(http.statusCode) && (http.value(forHTTPHeaderField: "Location") ?? "").contains("login")) {
            throw TACTError.signInRequired
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
    }

    static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        guard let document = html.withCString({ htmlReadMemory($0, Int32(html.utf8.count), nil, "UTF-8", Int32(options)) }) else { return "" }
        defer { xmlFreeDoc(document) }
        let blocks: Set<String> = ["p", "div", "li", "br", "tr", "table", "h1", "h2", "h3", "h4", "blockquote", "pre"]
        let hidden: Set<String> = ["head", "script", "style", "noscript", "template"]
        var output = ""
        func visit(_ start: xmlNodePtr?) {
            var current = start
            while let node = current {
                current = node.pointee.next
                if node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE {
                    if let content = node.pointee.content { output += String(cString: content) }
                } else if node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name {
                    let tag = String(cString: name)
                    guard !hidden.contains(tag) else { continue }
                    if blocks.contains(tag) { output += "\n" }
                    if tag == "li" { output += "・" }
                    if tag == "td" || tag == "th" { output += " " }
                    visit(node.pointee.children)
                    if blocks.contains(tag) { output += "\n" }
                }
            }
        }
        visit(xmlDocGetRootElement(document))
        return output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func readPDF(_ url: URL) throws -> (text: String, unreadablePages: [Int]) {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw TACTError.requestFailed("添付PDFの読み取り")
        }
        var pages: [String] = []
        var unreadable: [Int] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text: String? = autoreleasepool {
                guard let page = document.page(at: index) else { return nil }
                let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !embedded.isEmpty { return embedded }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                let scale = 2200 / max(bounds.width, bounds.height)
                let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let image = thumbnail.cgImage else { return nil }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                } catch {
                    return nil
                }
            }
            if let text, !text.isEmpty {
                pages.append("p.\(index + 1)\n" + text)
            } else {
                unreadable.append(index + 1)
            }
        }
        return (pages.joined(separator: "\n\n"), unreadable)
    }
}
