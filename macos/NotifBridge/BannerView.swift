import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct BannerView: View {
    let frame: NotifFrame
    @Bindable var status: ReceiverModel.ActionStatus
    var compact = true
    var onDismiss: () -> Void
    var onClear: () -> Void
    var onAction: (NotifFrame.Action, String?) -> Void
    var onRetry: () -> Void
    @State private var activeTextAction: NotifFrame.Action?
    @State private var draft = ""
    @State private var confirmRetry = false
    @State private var exporting = false
    @State private var exportAttachment: NotifFrame.Attachment?
    @State private var exportError: String?
    @State private var richText: NSAttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 20) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let label = priorityLabel { Label(label, systemImage: priorityIcon).font(.caption.bold()) }
                    if !frame.title.isEmpty { Text(frame.title).font(compact ? .headline : .title2.weight(.semibold)).textSelection(.enabled) }
                    if !frame.subtitle.isEmpty { Text(frame.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                    if !frame.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Summary", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                            Text(frame.summary).font(.body).textSelection(.enabled)
                        }
                    }
                    if let richText { RichBody(text: richText).frame(minHeight: 30) }
                    else if !frame.body.isEmpty { Text(frame.body).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if !frame.attachments.isEmpty { attachments }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 230 : 600)
            if !frame.isCleared && frame.transportSessionID != nil {
                if let action = activeTextAction { replyEditor(action) }
                else { actionButtons }
            }
            if frame.transportSessionID != nil { statusView }
        }
        .padding(compact ? 12 : 0)
        .frame(width: compact ? 356 : nil, alignment: .leading)
        .background { if compact { RoundedRectangle(cornerRadius: 14).fill(.thickMaterial) } }
        .overlay { if compact { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) } }
        .task(id: frame.richBody) {
            guard let data = frame.richBody else { richText = nil; return }
            if let decoded = try? NSMutableAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
                decoded.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: decoded.length))
                richText = decoded
            } else { richText = nil }
        }
        .onChange(of: status.phase) { _, phase in
            if phase == .succeeded { draft = ""; activeTextAction = nil; status.isEditing = false }
        }
        .onDisappear { status.isEditing = false }
        .confirmationDialog("The iPhone may already have sent this reply. Retry anyway?", isPresented: $confirmRetry) {
            Button("Retry response") { onRetry() }
        }
        .fileExporter(isPresented: $exporting, document: exportAttachment.map { AttachmentDocument(data: $0.data) },
            contentType: exportAttachment.flatMap { UTType($0.uti) } ?? .data,
            defaultFilename: "Notification attachment") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = frame.displayIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            } else { Image(systemName: "app").font(.title2).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text(frame.sourceName.isEmpty ? frame.sourceIdentifier : frame.sourceName).font(.caption.bold())
                if let date = frame.displayDate {
                    if frame.displayDateIsAllDay { Text(date, format: .dateTime.day().month().year()).font(.caption2) }
                    else { Text(date, style: .relative).font(.caption2) }
                }
                if frame.isCleared { Label("Cleared", systemImage: "checkmark").font(.caption2) }
            }
            .foregroundStyle(.secondary)
            Spacer()
            if frame.transportSessionID != nil {
            Button("Clear from iPhone", systemImage: "xmark.bin", action: onClear)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Clear from iPhone")
                .disabled(frame.isCleared || frame.transportSessionID == nil || status.phase == .pending)
            }
            if compact {
                Button("Dismiss on Mac", systemImage: "xmark.circle.fill", action: onDismiss)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Dismiss on Mac")
            }
        }
    }
    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ForEach(availableActions) { action in actionButton(action) } }
            VStack(alignment: .leading) { ForEach(availableActions) { action in actionButton(action) } }
        }
        .disabled(status.phase == .pending)
    }
    private var availableActions: [NotifFrame.Action] {
        frame.actions.filter { if case .unknown = $0.type { return false }; return true }
    }
    private func actionButton(_ action: NotifFrame.Action) -> some View {
        Button(action.title.isEmpty ? "Action" : action.title) {
            if case .textInput = action.type { activeTextAction = action; status.isEditing = true }
            else { onAction(action, nil) }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
    private func replyEditor(_ action: NotifFrame.Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder(action), text: $draft, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Reply")
            HStack {
                Button("Send") { onAction(action, draft) }
                    .buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { activeTextAction = nil; status.isEditing = false }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(status.phase == .pending)
    }
    private func placeholder(_ action: NotifFrame.Action) -> String {
        if case .textInput(let placeholder) = action.type { return placeholder.isEmpty ? "Reply" : placeholder }
        return "Reply"
    }
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.phase == .pending { HStack { ProgressView().controlSize(.small); Text(status.message).font(.caption) } }
            else if !status.message.isEmpty {
                Label(status.message, systemImage: status.phase == .failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(status.phase == .failed ? .orange : .secondary)
                if status.phase == .failed {
                    Button("Retry") {
                        if status.retryMayRepeat { confirmRetry = true } else { onRetry() }
                    }.controlSize(.small)
                }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
        }
        .frame(minHeight: compact ? 36 : 0, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
    private var priorityLabel: String? {
        switch frame.alertKind {
        case .incomingCall: return "Incoming call"
        case .alarm: return "Alarm"
        case .timer: return "Timer"
        case .notification:
            if frame.attributes.contains(.critical) { return "Critical alert" }
            if frame.attributes.contains(.timeSensitive) { return "Time-sensitive" }
            if frame.attributes.contains(.priority) { return "Priority" }
            return nil
        }
    }
    private var priorityIcon: String {
        switch frame.alertKind {
        case .incomingCall: "phone.fill"
        case .alarm: "alarm.fill"
        case .timer: "timer"
        case .notification: "exclamationmark.circle"
        }
    }
    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(frame.attachments) { attachment in
                if let reason = attachment.unavailableReason {
                    Label(reason, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                } else if let image = NSImage(data: attachment.data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: compact ? 120 : 300)
                        .accessibilityLabel("Notification image attachment")
                } else if UTType(attachment.uti)?.conforms(to: .pdf) == true {
                    PDFPreview(data: attachment.data).frame(height: compact ? 140 : 300)
                        .accessibilityLabel("PDF attachment preview")
                } else if UTType(attachment.uti)?.conforms(to: .text) == true,
                          let text = String(data: attachment.data, encoding: .utf8) {
                    Text(text).font(.caption).lineLimit(compact ? 4 : 30).textSelection(.enabled)
                } else {
                    Label(UTType(attachment.uti)?.localizedDescription ?? "Attachment", systemImage: "paperclip")
                }
                Button("Save attachment…", systemImage: "square.and.arrow.down") {
                    exportAttachment = attachment; exporting = true
                }.font(.caption).disabled(attachment.data.isEmpty)
            }
        }
    }
    struct AttachmentDocument: FileDocument {
        static var readableContentTypes: [UTType] { [.data] }
        var data: Data
        init(data: Data) { self.data = data }
        init(configuration: ReadConfiguration) { data = configuration.file.regularFileContents ?? Data() }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
    }
    struct RichBody: NSViewRepresentable {
        let text: NSAttributedString
        func makeNSView(context: Context) -> NSTextView {
            let view = NSTextView()
            view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
            view.textContainerInset = NSSize(width: 0, height: 2)
            view.textContainer?.lineFragmentPadding = 0
            view.isHorizontallyResizable = false
            return view
        }
        func updateNSView(_ view: NSTextView, context: Context) { view.textStorage?.setAttributedString(text) }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
            let width = proposal.width ?? 340
            guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            return CGSize(width: width, height: max(24, manager.usedRect(for: container).height + 4))
        }
    }
    struct PDFPreview: NSViewRepresentable {
        let data: Data
        class Coordinator { var data: Data? }
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
        func updateNSView(_ view: PDFView, context: Context) {
            if context.coordinator.data != data { view.document = PDFDocument(data: data); context.coordinator.data = data }
        }
    }
}
