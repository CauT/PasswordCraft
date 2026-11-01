import SwiftUI
import AppKit
import VaultCore

@main struct PasswordCraftApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @StateObject private var model = VaultModel()
    var body: some Scene {
        Window("PasswordCraft", id: "vault") {
            RootView().environmentObject(model)
                .environment(\.locale, (AppLanguage(rawValue: interfaceLanguage) ?? .english).locale)
                .frame(minWidth: 1040, minHeight: 680)
        }.defaultSize(width: 1180, height: 800)
        .commands {
            CommandMenu("Language / 语言") { LanguagePicker() }
            CommandGroup(replacing: .newItem) {
                Button(L("新建密码库…"), action: model.beginCreateVault).disabled(model.busy || model.hasDocumentSheet)
                Button(L("打开密码库…"), action: model.chooseVault).keyboardShortcut("o").disabled(model.busy || model.hasDocumentSheet)
                Button(L("新建项目")) { model.newItem() }.keyboardShortcut("n").disabled(!model.canOperate)
            }
            CommandMenu(L("密码库")) {
                Button(L("快速访问"), action: model.showQuickAccess)
                Button(L("锁定全部密码库"), action: model.lock).keyboardShortcut("l", modifiers: [.command, .shift])
                Button(L("关闭全部密码库"), action: model.closeVault).disabled(model.busy)
                Divider()
                Button(L("导入数据…"), action: model.importFile).disabled(!model.canOperate)
                Button(L("本地密码检查…")) { model.showHealth = true }.disabled(!model.canOperate)
                Button("Touch ID…") { model.showBiometrics = true }.disabled(!model.canOperate)
                Button(L("导出数据…")) { model.showExport = true }.disabled(!model.canOperate)
                Divider()
                Button(L("自动备份与恢复…")) { model.showBackups = true }.disabled(!model.canOperate)
                Button(L("保存加密副本…"), action: model.backup).disabled(!model.canOperate)
                Button(L("更改主密码…")) { model.changingPassword = true }.disabled(!model.canOperate)
            }
        }
        MenuBarExtra("PasswordCraft", systemImage: "lock.shield") {
            Button(L("快速访问 ⌃⌥⌘L"), action: model.showQuickAccess)
            if let status = model.quickAccessStatus { Text(status) }
            Button(L("锁定全部密码库"), action: model.lock)
        }

    }
}

struct RootView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            VaultSwitcher()
            Divider()
            Group { if model.unlocked { LibraryView() } else { UnlockView() } }
        }
            .onChange(of: interfaceLanguage) { _ in model.languageChanged() }
            .onChange(of: model.hasDocumentSheet) { if $0 { model.hideQuickAccess() } }
            .tint(Color(red: 0.18, green: 0.54, blue: 0.72))
            .modifier(VaultErrorAlert(enabled: !model.hasSheet))
            .sheet(item: $model.editor) { EditorView(item: $0).modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(item: $model.historyItem) { HistoryView(item: $0).modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.changingPassword) { ChangePasswordView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.showBackups) { BackupView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.showHealth) { PasswordHealthView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.showBiometrics) { BiometricSettingsView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.showTransfer) { VaultTransferView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: $model.showExport) { ExportView().modifier(VaultErrorAlert()).environmentObject(model) }
            .sheet(isPresented: Binding(get: { model.importFlow != nil }, set: { if !$0 { model.importFlow = nil } })) {
                Group {
                    switch model.importFlow {
                    case .encrypted(let source): EncryptedImportView(source: source)
                    case .preview: ImportView()
                    case nil: EmptyView()
                    }
                }.modifier(VaultErrorAlert()).environmentObject(model)
            }
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    var body: some View {
        let _ = interfaceLanguage
        Picker("Language / 语言", selection: $interfaceLanguage) {
            Text("English").tag(AppLanguage.english.rawValue)
            Text("简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
        }
    }
}

/// Present errors on the active sheet, not behind it on the library window.
struct VaultErrorAlert: ViewModifier {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    var enabled = true
    func body(content: Content) -> some View {
        let _ = interfaceLanguage
        content.alert(L("操作未完成"), isPresented: Binding(get: { enabled && model.error != nil }, set: { if !$0 && enabled { model.error = nil } })) {
            Button(L("好"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
