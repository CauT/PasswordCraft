import SwiftUI
import AppKit
import Carbon
import VaultCore

extension Notification.Name { static let passwordCraftQuickAccessRequested = Notification.Name("PasswordCraftQuickAccessRequested") }

/// Registers one system hotkey; does not observe or record arbitrary keystrokes.
final class QuickAccessHotKey {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    let status: OSStatus
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Receive registered hotkeys before AppKit's application event dispatch.
        let target = GetEventDispatcherTarget()
        let installed = InstallEventHandler(target, { _, event, _ in
            var identifier = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x50574346, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            NotificationCenter.default.post(name: .passwordCraftQuickAccessRequested, object: nil)
            return noErr
        }, 1, &event, nil, &handler)
        if installed == noErr {
            status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey | controlKey), EventHotKeyID(signature:0x50574346,id:1), target, 0, &hotKey)
        } else { status = installed }
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor final class QuickAccessPanel: NSObject, NSWindowDelegate {
    private weak var model: VaultModel?
    private let panel: NSPanel
    init(model: VaultModel) {
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:520,height:440),styleMask:[.titled,.closable,.utilityWindow],backing:.buffered,defer:false)
        super.init()
        self.model = model; panel.delegate = self
        panel.title = L("PasswordCraft · 快速访问")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: QuickAccessView().environmentObject(model))
        panel.center()
    }
    func windowWillClose(_ notification: Notification) { model?.hideQuickAccess() }
    func updateLanguage() { panel.title = L("PasswordCraft · 快速访问") }
    func show() { updateLanguage(); NSApp.activate(ignoringOtherApps:true); panel.makeKeyAndOrderFront(nil) }
    func hide() { panel.orderOut(nil) }
}

struct QuickAccessView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    @FocusState private var searching: Bool
    var matches: [VaultSearchHit] { VaultSearch.search(model.unlockedVaults, query: model.quickQuery) }
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(L("快速访问")).font(.title2.bold()); Spacer(); Button(L("关闭"),action:model.hideQuickAccess).keyboardShortcut(.cancelAction) }
            Text(L("⌃⌥⌘L · 所有已解锁库 · 手动查找和复制")).font(.caption).foregroundStyle(.secondary)
            if let status = model.quickAccessStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !model.unlockedVaults.isEmpty {
                TextField(L("搜索所有已解锁库的普通字段"),text:$model.quickQuery).textFieldStyle(.roundedBorder).focused($searching)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(matches.prefix(50)) { hit in
                            let item = hit.item
                            VStack(alignment:.leading,spacing:8) {
                                Text(item.title).font(.headline)
                                Text(hit.vaultURL.deletingPathExtension().lastPathComponent).font(.caption).foregroundStyle(.secondary).help(hit.vaultURL.path)
                                Button(L("在库中查看")) { model.selectVault(hit.vaultURL, itemID: item.id) }.disabled(model.busy)
                                HStack {
                                    if !item.username.isEmpty { Button(L("复制账号")) { model.copy(item.username) }.accessibilityLabel(L("复制账号 \(item.title)")) }
                                    if !item.password.isEmpty { Button(L("复制密码")) { model.copy(item.password) }.accessibilityLabel(L("复制密码 \(item.title)")) }
                                    ForEach(item.sections.flatMap(\.fields).filter { $0.kind == .otp }) { field in
                                        Button(L("复制验证码")) {
                                            do { let now = Date(); let code = try TOTPConfiguration(field.value).code(at:now); model.copy(code.value,validFor:code.remaining(at:now)) }
                                            catch { model.showError(error) }
                                        }.accessibilityLabel(L("复制验证码 \(item.title) \(field.label)"))
                                    }.id(interfaceLanguage)
                                }
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                        }.id(interfaceLanguage)
                        if matches.isEmpty { Text(L("没有匹配项目")).foregroundStyle(.secondary) }
                        if matches.count > 50 { Text(L("显示前 50 项，请缩小搜索范围。")).font(.caption) }
                    }
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Button(L("锁定全部密码库"),action:model.lock)
            } else { Text(L("密码库已锁定。请回到主窗口输入主密码。")).foregroundStyle(.secondary); Spacer() }
        }.padding(20).frame(width:520,height:440)
        .onAppear { searching = true }
        .onChange(of: model.quickAccessVisible) { if $0 { searching = true } }
        .modifier(VaultErrorAlert(enabled: !model.hasDocumentSheet))
    }
}
