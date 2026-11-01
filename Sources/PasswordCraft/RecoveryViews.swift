import SwiftUI
import VaultCore

struct HistoryView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    let item: VaultItem
    @State private var selected: UUID?
    @State private var confirming = false
    var revision: VaultRevision? { model.history(for: item).first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("历史版本 · \(item.title)").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(model.busy) }
            Text("每次修改前保留完整版本。恢复会保留当前的归档／回收站状态，并将恢复前内容记入历史。").foregroundStyle(.secondary).font(.callout)
            if model.history(for: item).isEmpty {
                Text("还没有历史版本。保存第一次修改后会在这里出现。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(model.history(for: item)) { revision in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(revision.createdAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                                Text(revision.snapshot.title).font(.caption).lineLimit(1)
                            }.padding(.vertical, 5).tag(revision.id)
                        }
                    }.frame(width: 250)
                    Divider()
                    if let revision {
                        ScrollView { VStack(alignment: .leading, spacing: 16) { Text("所选历史版本").font(.headline); ItemContents(item: revision.snapshot, revisionID: revision.id).id(revision.id) }.padding(20) }
                    } else { Text("选择一个版本查看和复制旧字段").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                }
                HStack { Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("恢复所选版本") { confirming = true }.buttonStyle(.borderedProminent).disabled(revision == nil || model.busy) }
            }
        }.padding(24).frame(width: 880, height: 650).interactiveDismissDisabled(model.busy)
        .confirmationDialog("恢复此历史版本？", isPresented: $confirming) {
            Button("恢复版本") { if let revision { model.restore(revision) } }
        } message: { Text("当前字段会被所选版本替换，但当前内容也会保留为新的历史记录。") }
    }
}

struct BackupView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: String?
    @State private var password = ""
    var backup: VaultBackup? { model.backups.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("自动备份与恢复").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(model.busy) }
            Text("修改前保存加密恢复点，保存后再备份最新状态。保留最近 20 份普通当前密码备份，升级、改密恢复点及旧密码备份另行保留。写前备份失败会停止修改；写后备份失败会提示已保存但最新备份未完成。").font(.callout).foregroundStyle(.secondary)
            if let directory = model.backupDirectory {
                HStack { Text(directory.path).font(.caption).textSelection(.enabled); Spacer(); Button("在 Finder 中查看", action: model.revealBackups) }
            }
            Text("这些备份与本机位于同一台设备，请另存加密副本到独立介质。").font(.caption).foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach(model.backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(backup.createdAt.formatted(date: .abbreviated, time: .standard)).font(.headline); Text(backup.reason.hasPrefix("upgrade-v") ? "旧格式升级恢复点" : backup.reason == "before-password-change" ? "更改主密码前" : "自动保存恢复点").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(backup.usesCurrentPassword ? "当前主密码" : "需要此备份创建时的密码").font(.caption).foregroundStyle(backup.usesCurrentPassword ? Color.secondary : Color.orange)
                    }.padding(.vertical, 5).tag(backup.id)
                }
            }.overlay { if model.backups.isEmpty { Text("首次修改前会自动创建恢复点。").foregroundStyle(.secondary) } }
            if let backup {
                Text("所选：\(backup.url.lastPathComponent)").font(.caption).lineLimit(2)
                SecureField("此备份的主密码", text: $password).textFieldStyle(.roundedBorder)
                HStack { Text("恢复为新文件，不覆盖现有密码库。").font(.caption).foregroundStyle(.secondary); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("选择位置并恢复") { model.recover(backup, password: password); password = "" }.buttonStyle(.borderedProminent).disabled(model.busy || password.isEmpty) }
            }
        }.padding(24).frame(width: 780, height: 610).interactiveDismissDisabled(model.busy)
        .onChange(of: selected) { _ in password = "" }
    }
}

struct ImportView: View {
    @EnvironmentObject var model: VaultModel
    @State private var copies = false
    var plan: VaultImportMerge? {
        guard let preview = model.pendingImport else { return nil }
        return try? VaultInterchange.planMerge(preview, existing: model.items, existingRevisions: model.revisions, existingBlobs: model.blobs, policy: copies ? .copies : .skipExisting)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("核对并导入").font(.title2.bold())
            if let preview = model.pendingImport {
                Text("格式：\(preview.formatName)").font(.headline)
                HStack(spacing: 24) { stat("普通项目", preview.activeCount); stat("归档", preview.archivedCount); stat("回收站", preview.trashedCount); stat("历史版本", preview.revisions.count) }
                if !preview.document.blobs.isEmpty { Text("当前项目附件 \(preview.items.reduce(0) { $0 + $1.attachments.count }) 个；当前与历史共用 \(preview.document.blobs.count) 份文件内容。").font(.callout) }
                Toggle("已有项目也导入为独立副本", isOn: $copies)
                Text("默认跳过相同来源 ID 或相同本地 ID，不覆盖已有内容。勾选后会创建副本。").font(.caption).foregroundStyle(.secondary)
                if let plan {
                    Text("计划新增 \(plan.addedCount) 项，跳过 \(plan.skippedCount) 项；需要注意的内容差异 \(plan.conflictCount) 项。").font(.headline)
                    ScrollView { VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in Label(warning, systemImage: "exclamationmark.triangle").font(.callout) }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                } else { Text("无法生成导入计划，请取消并检查文件。").foregroundStyle(.red) }
                Text(preview.sourceIsEncrypted ? "源库保持原来的加密格式和密码，请保留用于核对和恢复；本应用不会修改或删除源文件。" : "原始导出可能包含明文密码。核对完成后请自行妥善处理；本应用不会删除源文件。").font(.caption).foregroundStyle(.secondary)
                HStack { Button("取消") { model.pendingImport = nil }.disabled(model.busy); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("确认导入") { model.commitImport(copies: copies) }.buttonStyle(.borderedProminent).disabled(model.busy || plan == nil) }
            }
        }.padding(28).frame(width: 640).interactiveDismissDisabled(model.busy)
    }
    func stat(_ label: String, _ value: Int) -> some View { VStack(alignment: .leading) { Text("\(value)").font(.title2.bold()); Text(label).font(.caption).foregroundStyle(.secondary) } }
}

struct ExportView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var format = VaultExportFormat.nativeJSON
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出数据").font(.title2.bold())
            Picker("格式", selection: $format) {
                Text("完整 JSON（含历史，可无损迁移）").tag(VaultExportFormat.nativeJSON)
                Text("1Password Interchange（1PIF）").tag(VaultExportFormat.onePIF)
                Text("CSV（含完整数据扩展列）").tag(VaultExportFormat.csv)
            }
            Text("包含 \(model.items.count) 个项目（含归档和回收站）、\(model.revisions.count) 个历史版本。完整 JSON 保留全部数据；其他软件可能忽略扩展字段。").font(.callout).foregroundStyle(.secondary)
            Text(format.warning).font(.callout)
            Label("导出文件未加密，能读取文件的人可以看到密码。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Toggle("我了解这是明文导出，并会妥善保管文件", isOn: $confirmed)
            HStack { Button("取消") { dismiss() }.disabled(model.busy); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("选择位置并导出") { model.export(format) }.buttonStyle(.borderedProminent).disabled(!confirmed || model.busy) }
        }.padding(28).frame(width: 620).interactiveDismissDisabled(model.busy)
    }
}

struct EncryptedImportView: View {
    @EnvironmentObject var model: VaultModel
    let source: URL
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("读取旧 \(LegacyVaultFormat(url: source)?.title ?? "") 密码库").font(.title2.bold())
            Text(source.lastPathComponent).font(.headline)
            Text(source.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("输入这个旧库的主密码。读取只在本机进行，源库不会被修改；解密后先核对项目和附件，再确认迁入当前本地库。").font(.callout)
            SecureField("旧库主密码", text: $password).textFieldStyle(.roundedBorder).onSubmit(read)
            HStack {
                Button("取消") { password = ""; model.importFlow = nil }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView("读取并核对…").controlSize(.small) }
                Button("读取并预览", action: read).buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.padding(28).frame(width: 560).interactiveDismissDisabled(model.busy)
    }
    private func read() {
        guard !model.busy else { return }
        model.decryptImport(password: password); password = ""
    }
}
