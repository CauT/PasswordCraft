import SwiftUI
import VaultCore

struct UnlockView: View {
    @EnvironmentObject var model: VaultModel
    @State private var password = ""
    @State private var confirmation = ""
    private var creating: Bool { model.creatingVault }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "lock.shield.fill").font(.system(size: 58)).foregroundStyle(.white)
                Text("你的密码，\n留在你手中。").font(.system(size: 38, weight: .bold))
                Text("PasswordCraft").font(.caption.monospaced()).tracking(4)
                Spacer()
                Label("本地加密 · 无账号 · 无订阅", systemImage: "externaldrive.fill")
                Text("独立应用 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")\n不隶属于 1Password").font(.caption).opacity(0.7)
            }.padding(44).frame(width: 340).frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [Color(red: 0.08, green: 0.22, blue: 0.31), Color(red: 0.12, green: 0.39, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 20) {
                Text(creating ? "创建你的密码库" : "欢迎回来").font(.largeTitle.bold())
                Text(creating ? "使用至少 12 个字符的主密码。忘记后无法找回。" : "输入主密码，解锁本地文件。") .foregroundStyle(.secondary)
                if !creating {
                    Text(model.url?.lastPathComponent ?? "还没有选择密码库").font(.headline)
                    if let url = model.url { Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                SecureField("主密码", text: $password).textFieldStyle(.roundedBorder).onSubmit(submit)
                if creating { SecureField("再次输入主密码", text: $confirmation).textFieldStyle(.roundedBorder).onSubmit(submit) }
                Button(action: submit) {
                    HStack { Spacer(); if model.busy { ProgressView().controlSize(.small) }; Text(creating ? "选择位置并创建" : "解锁密码库"); Spacer() }.padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).disabled(model.busy || password.isEmpty || (!creating && model.url == nil) || (creating && (password.count < 12 || password != confirmation)))
                if !creating, model.url != nil {
                    if model.biometricEnabled {
                        Button("使用 Touch ID 解锁", action: model.unlockWithBiometrics).disabled(model.busy || !model.biometricAvailable)
                    }
                    Text(model.biometricExplanation).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(creating ? "返回解锁" : "新建密码库") { model.creatingVault.toggle(); password = ""; confirmation = "" }.buttonStyle(.link)
                    Spacer()
                    Button("打开已有密码库…") { model.chooseVault(); model.creatingVault = false; password = "" }.buttonStyle(.link)
                }.disabled(model.busy)
                Divider()
                Text("支持直接读取 OPVault 和 AgileKeychain，也可迁移 1PIF、1PUX、CSV 和完整 JSON。先创建密码库，再从「密码库」菜单导入。").font(.callout).foregroundStyle(.secondary)
                Text("本地加密，修改前自动备份。尚未经过独立安全审计，请保留旧库。").font(.caption).foregroundStyle(.secondary)
            }.padding(48).frame(maxWidth: .infinity)
        }.onChange(of: model.url) { _ in password = ""; confirmation = "" }.onAppear(perform: model.refreshBiometrics).onDisappear { password = ""; confirmation = "" }
    }
    func submit() {
        guard !model.busy, !password.isEmpty else { return }
        if creating {
            guard password.count >= 12, password == confirmation, let target = model.newVaultURL() else { return }
            model.unlock(password: password, createAt: target)
        } else { model.unlock(password: password) }
        password = ""; confirmation = ""
    }
}
