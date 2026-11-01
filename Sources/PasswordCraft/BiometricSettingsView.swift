import SwiftUI

struct BiometricSettingsView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Touch ID").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(model.busy) }
            Text(model.biometricExplanation)
            Text("启用后，此密码库的解密密钥由这台 Mac 的系统钥匙串和当前指纹集合保护，不保存主密码，不通过 iCloud 同步。更换文件位置、修改主密码或重新录入指纹后，需要重新启用。").foregroundStyle(.secondary)
            Text("退出、锁屏或闲置锁定后，仍需通过 Touch ID 或主密码重新解锁。请牢记主密码并保留加密备份。").font(.callout)
            if model.biometricEnabled {
                Button("停用并移除设备解锁密钥", action: model.disableBiometrics).disabled(model.busy)
            } else {
                Button("为当前密码库启用 Touch ID", action: model.enableBiometrics)
                    .disabled(model.busy || !model.biometricAvailable || !model.unlockedWithMasterPassword)
                if !model.unlockedWithMasterPassword { Text("启用前，请先锁定并用主密码解锁当前库。").font(.caption) }
                Button("清理旧设备解锁记录", action: model.disableBiometrics).disabled(model.busy)
            }
        }.padding(24).frame(width: 560)
            .onAppear(perform: model.refreshBiometrics)
    }
}
