import SwiftUI
import AppKit
import PDFKit
import ImageIO
import VaultCore

private final class AttachmentPreview: Identifiable {
    enum Content { case pdf(PDFDocument), image(NSImage), text(String), binary(String) }
    let attachment: VaultAttachment
    let content: Content
    var id: UUID { attachment.id }
    init(attachment: VaultAttachment, bytes: Data) {
        self.attachment = attachment
        // Parse once per explicit open, never on each SwiftUI body update.
        if bytes.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: bytes),
           !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 1000 { content = .pdf(pdf) }
        else if let image = Self.boundedImage(bytes) { content = .image(image) }
        else if bytes.count <= 1024 * 1024, let text = String(data: bytes, encoding: .utf8), !text.contains("\0") { content = .text(text) }
        else { content = .binary(bytes.prefix(512).map { String(format: "%02x", $0) }.joined(separator: " ")) }
    }
    private static func boundedImage(_ bytes: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? NSNumber, let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 20_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct AttachmentList: View {
    @EnvironmentObject var model: VaultModel
    let item: VaultItem
    var revisionID: UUID?
    @State private var preview: AttachmentPreview?
    @State private var removing: VaultAttachment?
    @State private var exporting: VaultAttachment?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("附件 · \(item.attachments.count)").font(.headline)
            ForEach(item.attachments) { attachment in
                VStack(alignment: .leading, spacing: 8) {
                    Text(attachment.name).font(.headline)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)) · \(attachment.mediaType)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("查看") { load(attachment) }.accessibilityLabel("查看附件 \(attachment.name)")
                        Button("导出…") { exporting = attachment }.accessibilityLabel("导出附件 \(attachment.name)")
                        if revisionID == nil, item.state != .trashed {
                            Button("移除", role: .destructive) { removing = attachment }.accessibilityLabel("移除附件 \(attachment.name)")
                        }
                    }.disabled(model.busy || loading)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if loading { ProgressView("读取附件…").controlSize(.small) }
        }
        .sheet(item: $preview) { value in AttachmentPreviewView(value: value) }
        .onChange(of: model.unlocked) { if !$0 { preview = nil; removing = nil; exporting = nil } }
        .confirmationDialog("移除当前版本中的附件？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除附件", role: .destructive) { if let removing { model.removeAttachment(removing, from: item) }; removing = nil }
        } message: { Text("历史版本和已有备份仍保留附件，可通过恢复历史找回。") }
        .confirmationDialog("导出未加密的附件？", isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } })) {
            Button("选择位置并导出明文") { if let exporting { model.exportAttachment(exporting, itemID: item.id, revisionID: revisionID) }; exporting = nil }
        } message: { Text("导出的文件不受密码库保护。任何能读取该文件的人都能看到其内容；不会覆盖已有文件。") }
    }
    private func load(_ attachment: VaultAttachment) {
        loading = true
        Task {
            do {
                let bytes = try await model.attachmentData(attachment, itemID: item.id, revisionID: revisionID)
                if model.unlocked { preview = AttachmentPreview(attachment: attachment, bytes: bytes) }
            } catch { if model.unlocked { model.showError(error) } }
            loading = false
        }
    }
}

private struct AttachmentPreviewView: View {
    @Environment(\.dismiss) var dismiss
    let value: AttachmentPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(value.attachment.name).font(.title2.bold()).lineLimit(2); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("在内存中查看，未生成临时明文文件。").font(.caption).foregroundStyle(.secondary)
            switch value.content {
            case .pdf(let pdf):
                AttachmentPDF(document: pdf)
            case .image(let image):
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("预览显示第一帧，最长边最多 2048 像素；导出保留原始文件。").font(.caption).foregroundStyle(.secondary)
            case .text(let string):
                ScrollView { Text(string.isEmpty ? "（空文件）" : string).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            case .binary(let hex):
                Text("此类型或大小不支持完整预览，可返回后导出原始文件查看。以下只显示前 512 字节。").foregroundStyle(.secondary)
                ScrollView { Text(hex).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            }
        }.padding(24).frame(width: 760, height: 600)
    }
}

private struct AttachmentPDF: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = document; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
