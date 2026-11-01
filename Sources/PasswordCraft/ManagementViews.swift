import SwiftUI
import VaultCore

struct PasswordHealthView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    var findings: [PasswordHealth.Finding] { PasswordHealth.inspect(model.items) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("本地密码检查").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("只检查当前库项目的密码字段，包含归档，不包含回收站和历史。检查长度、易猜模式和重复使用；没有联网查询泄漏库。未发现提示不代表密码一定安全。").font(.callout).foregroundStyle(.secondary)
            Text("\(findings.count) 个项目需要检查").font(.headline)
            List(findings) { finding in
                if let item = model.items.first(where: { $0.id == finding.itemID }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.headline)
                            Text(finding.reasons.map(\.explanation).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            if finding.reuseCount > 1 { Text("当前库中 \(finding.reuseCount) 个项目复用此密码").font(.caption) }
                        }
                        Spacer()
                        Button("查看项目") { model.filter = item.state == .archived ? .archived : .all; model.query = ""; model.selected = item.id; dismiss() }
                    }.padding(.vertical, 6)
                }
            }
        }.padding(24).frame(width: 760, height: 560)
    }
}

struct BatchActionsView: View {
    @EnvironmentObject var model: VaultModel
    @State private var tag = ""
    @State private var pending: BatchEdit.Operation?
    @State private var actionTitle = ""
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("已选择 \(model.selectedIDs.count) 个项目").font(.title2.bold())
            Text("按住 Command 或 Shift 多选。操作只影响当前列表中已选择的项目；修改会一起保存，并保留历史和自动备份。").foregroundStyle(.secondary)
            if model.filter == .trash {
                Button("恢复所选项目") { propose(.restore, "恢复") }
            } else {
                Button("复制或移动到其他库…") { model.showTransfer = true }
                HStack { Button("收藏") { propose(.favorite(true), "收藏") }; Button("取消收藏") { propose(.favorite(false), "取消收藏") } }
                HStack { Button("归档") { propose(.archive, "归档") }; Button("移到回收站") { propose(.trash, "移到回收站") }; if model.filter == .archived { Button("取消归档") { propose(.restore, "取消归档") } } }
                HStack { TextField("批量添加标签", text: $tag); Button("添加标签") { propose(.addTag(tag), "添加标签") }.disabled(tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            Spacer()
        }.padding(28).disabled(model.busy)
        .confirmationDialog("对所选 \(model.selectedIDs.count) 个项目执行「\(actionTitle)」？", isPresented: $confirm) {
            Button("确认\(actionTitle)") { if let pending { model.batch(pending) } }
        } message: { Text("当前库会统一保存；若保存失败，不会只改一部分。") }
    }
    private func propose(_ action: BatchEdit.Operation, _ title: String) { pending = action; actionTitle = title; confirm = true }
}
