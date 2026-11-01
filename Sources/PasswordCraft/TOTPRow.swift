import SwiftUI
import VaultCore

struct TOTPRow: View {
    @EnvironmentObject var model: VaultModel
    let label: String
    let input: String
    var body: some View {
        if !input.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                switch configuration {
                case .success(let config):
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let code = try? config.code(at: context.date) {
                            HStack {
                                Text(code.value).font(.system(.title2, design: .monospaced)).monospacedDigit().textSelection(.enabled)
                                Spacer()
                                Text("\(Int(ceil(code.remaining(at: context.date)))) 秒").monospacedDigit().foregroundStyle(.secondary)
                                Button("复制验证码") {
                                    // Refresh at click time so a code from the previous frame is never copied.
                                    do { let now = Date(); let current = try config.code(at: now); model.copy(current.value, validFor: current.remaining(at: now)) }
                                    catch { model.showError(error) }
                                }
                            }
                        } else { Text("系统时间无效，无法生成验证码。").foregroundStyle(.orange) }
                    }
                    Text("离线生成 · 请保持 Mac 时间准确").font(.caption).foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
    private var configuration: Result<TOTPConfiguration, Error> { Result { try TOTPConfiguration(input) } }
}
