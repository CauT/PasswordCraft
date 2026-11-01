import SwiftUI
import VaultCore

struct VaultSwitcher: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    var body: some View {
        let _ = interfaceLanguage
        HStack {
            Menu {
                ForEach(model.registeredVaults, id: \.self) { url in
                    Button { model.selectVault(url) } label: {
                        Label(url.deletingPathExtension().lastPathComponent + " · " + url.deletingLastPathComponent().path,
                              systemImage: model.unlockedVaults.contains { $0.url == url } ? "lock.open" : "lock")
                    }
                }.id(interfaceLanguage)
                Divider()
                Button(L("打开已有密码库…"), action: model.chooseVault)
                Button(L("新建密码库…"), action: model.beginCreateVault)
                if model.url != nil && !model.unlocked { Button(L("从列表移除此库（保留文件）"), action: model.forgetCurrentVault) }
            } label: { Label(model.url?.deletingPathExtension().lastPathComponent ?? L("选择密码库"), systemImage: "externaldrive") }
            .disabled(model.busy || model.hasDocumentSheet)
            Text(L("\(model.unlockedVaults.count) 个库已解锁")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            LanguagePicker().frame(width: 190)
            Button(L("搜索所有已解锁库"), action: model.showQuickAccess).disabled(model.busy || model.hasDocumentSheet)
            Button(L("锁定当前库"), action: model.lockCurrentVault).disabled(!model.canOperate)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct VaultTransferView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var destination: URL?
    @State private var move = false
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 18) {
            Text(L("跨库复制或移动")).font(.title2.bold())
            Text(L("源库：\(model.url?.lastPathComponent ?? "") · \(model.selectedIDs.count) 个项目"))
            if model.transferDestinations.isEmpty {
                Text(L("请先关闭此窗口，打开并解锁另一个密码库，再切回源库选择项目。其他库会保持解锁。"))
            } else {
                Picker(L("目标密码库"), selection: $destination) {
                    Text(L("请选择")).tag(nil as URL?)
                    ForEach(model.transferDestinations) { vault in
                        Text(vault.url.lastPathComponent + " · " + vault.url.deletingLastPathComponent().path).tag(Optional(vault.url))
                    }.id(interfaceLanguage)
                }
                Picker(L("操作"), selection: $move) { Text(L("复制")).tag(false); Text(L("移动")).tag(true) }.pickerStyle(.segmented)
                Text(L("保留项目的历史和附件。相同标识且内容相同的项目不会重复复制；内容冲突时停止，不会覆盖。移动会先保存目标库，再把源项目放入回收站；已有备份仍保留原内容。"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L("切换窗口或应用不会自动锁库；闲置、睡眠或锁屏会锁定所有库。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(move ? L("确认移动") : L("确认复制")) { if let destination { model.transfer(to: destination, move: move) } }
                    .buttonStyle(.borderedProminent).disabled(destination == nil)
            }
        }.padding(24).frame(width: 640).disabled(model.busy).interactiveDismissDisabled(model.busy)
    }
}
