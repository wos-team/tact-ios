import SwiftUI
import WebKit

struct AssignmentDetailView: View {
    let assignment: Assignment
    let account: String
    @ObservedObject private var worker = AssignmentSummaryWorker.shared
    @State private var record: AssignmentSummaryRecord?
    @State private var selectedAttachment: AssignmentAttachment?

    var body: some View {
        List {
            Section {
                Text(assignment.displayCourse)
                    .foregroundStyle(.secondary)
                if assignment.hasDeadline {
                    LabeledContent("締切") {
                        Text(assignment.due, format: .dateTime.month().day().weekday().hour().minute()
                            .locale(Locale(identifier: "ja_JP")))
                    }
                }
            }
            Section {
                if let summary = record?.summary {
                    Text(summary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                } else if worker.processing == assignment.id {
                    ProgressView("課題本文と添付資料を処理しています")
                } else if let record, !record.hasSource {
                    Text("読み取れた本文はありません。").foregroundStyle(.secondary)
                } else if !AssignmentSummaryWorker.modelAvailable {
                    Text("要約には iOS 26 以降と、有効な Apple Intelligence が必要です。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("要約の準備中です。").foregroundStyle(.secondary)
                }

                if record?.hasIncompletePDF == true {
                    Text("一部のPDFまたはページを読み取れませんでした。提出条件は元の資料も確認してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = worker.errors[assignment.id] {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                if worker.processing != assignment.id,
                   worker.errors[assignment.id] != nil || record?.hasIncompletePDF == true
                   || (record?.summary == nil && AssignmentSummaryWorker.modelAvailable && record?.hasSource != false) {
                    Button("今すぐ処理") { Task { await worker.load(assignment, account: account, userRequested: true) } }
                }
            } header: {
                Text("課題の要約")
            } footer: {
                if record?.summary != nil { Text("Apple Intelligence が端末内で作成した要約です。") }
            }
            if let record, !record.instructions.isEmpty {
                Section("TACTの指示文") {
                    Text(record.instructions).textSelection(.enabled)
                }
            }
            if let record, !record.attachments.isEmpty {
                Section("添付ファイル") {
                    ForEach(record.attachments) { attachment in
                        Button {
                            selectedAttachment = attachment
                        } label: {
                            Label(attachment.name, systemImage: "doc")
                        }
                    }
                }
            }
        }
        .navigationTitle(assignment.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: assignment.contentRevision) {
            reloadRecord()
            await worker.load(assignment, account: account)
            reloadRecord()
        }
        .onChange(of: worker.updateCount) { _, _ in reloadRecord() }
        .sheet(item: $selectedAttachment) { attachment in
            NavigationStack {
                AttachmentWebView(url: attachment.url)
                    .navigationTitle(attachment.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { selectedAttachment = nil }
                        }
                    }
            }
        }
    }

    private func reloadRecord() {
        let cached = AssignmentSummaryStore.record(for: assignment, account: account)
        record = cached.flatMap { $0.matches(assignment) ? $0 : nil }
    }
}

private struct AttachmentWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        // Uses the same first-party browser session as the in-app TACT sign-in screen.
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
