import SwiftUI
import VaultCore

extension FieldKind {
    var displayName: String {
        switch self {
        case .text: return L("文本")
        case .password: return L("密码 / 秘密")
        case .url: return L("网址")
        case .email: return L("电子邮箱")
        case .date: return L("日期")
        case .monthYear: return L("月 / 年")
        case .phone: return L("电话")
        case .otp: return L("验证码密钥")
        }
    }
}

struct EditorView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State var item: VaultItem
    @State private var reveal = false
    @State private var newTag = ""
    @State private var length = 24
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title.isEmpty ? L("新建项目") : L("编辑项目")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent(L("标题")) { TextField(L("项目标题"), text: $item.title) }
                    HStack {
                        Picker(L("分类"), selection: $item.category) { ForEach(Array(Set(ItemTemplates.categories + [item.category])).sorted(), id: \.self) { Text(L10n.category($0)).tag($0) }.id(interfaceLanguage) }.id(interfaceLanguage)
                        Button(L("添加此类模板字段")) { addTemplate() }
                    }
                    Text(L("更改分类不会删除已有字段。模板只添加缺少的分组或字段。")).font(.caption).foregroundStyle(.secondary)
                    LabeledContent(L("账号")) { TextField(L("用户名或邮箱"), text: $item.username) }
                    HStack {
                        if reveal { TextField(L("密码"), text: $item.password) } else { SecureField(L("密码"), text: $item.password) }
                        Button(reveal ? L("隐藏") : L("显示")) { reveal.toggle() }
                        Stepper(L("\(length) 位"), value: $length, in: 12...128).frame(width: 110)
                        Button(L("生成密码")) { do { item.password = try PasswordGenerator.generate(length: length) } catch { model.showError(error) } }
                    }
                    LabeledContent(L("网址")) { TextField(L("主要网址"), text: $item.url) }
                    ForEach(item.additionalURLs.indices, id: \.self) { index in
                        HStack { TextField(L("其他网址 \(index + 1)"), text: $item.additionalURLs[index]); Button { item.additionalURLs.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel(L("移除网址 \(index + 1)")) }
                    }.id(interfaceLanguage)
                    Button(L("添加网址"), systemImage: "plus") { item.additionalURLs.append("") }
                    Toggle(L("收藏此项目"), isOn: $item.favorite)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField(L("添加标签"), text: $newTag).onSubmit(addTag); Button(L("添加标签"), action: addTag).disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        if !item.tags.isEmpty {
                            ForEach(item.tags, id: \.self) { tag in HStack { Label(tag, systemImage: "tag"); Spacer(); Button(L("移除")) { item.tags.removeAll { $0 == tag } }.accessibilityLabel(L("移除标签 \(tag)")) }.font(.caption) }.id(interfaceLanguage)
                        }
                    }
                    Divider()
                    ForEach($item.sections) { $section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField(L("分组名称"), text: $section.title).font(.headline)
                                Button(L("删除分组"), role: .destructive) { item.sections.removeAll { $0.id == section.id } }
                            }
                            ForEach($section.fields) { $field in
                                FieldEditor(field: $field) { section.fields.removeAll { $0.id == field.id } }
                            }.id(interfaceLanguage)
                            Button(L("添加字段"), systemImage: "plus") { section.fields.append(VaultField(label: "")) }
                        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }.id(interfaceLanguage)
                    Button(L("添加一次性验证码"), systemImage: "timer") { item.sections.append(VaultSection(title: L("两步验证"), fields: [VaultField(label: L("一次性验证码"), kind: .otp)])) }
                    Button(L("添加字段分组"), systemImage: "folder.badge.plus") { item.sections.append(VaultSection(title: L("新分组"), fields: [VaultField(label: "")])) }
                    Text(L("备注")).font(.headline)
                    TextEditor(text: $item.notes).frame(height: 110).border(.quaternary)
                }.padding(.trailing, 8)
            }
            HStack {
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text(L("正在备份并加密保存…")).font(.caption) }
                Button(L("保存")) { addTag(); item.updatedAt = Date(); model.save(item) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 720, height: 720).interactiveDismissDisabled()
    }
    func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty && !item.tags.contains(tag) { item.tags.append(tag) }
        newTag = ""
    }
    func addTemplate() {
        for template in ItemTemplates.makeItem(category: item.category).sections {
            if let index = item.sections.firstIndex(where: { L10n.label($0.title, language: .english) == L10n.label(template.title, language: .english) }) {
                for field in template.fields where !item.sections[index].fields.contains(where: { L10n.label($0.label, language: .english) == L10n.label(field.label, language: .english) }) {
                    var added = field; added.label = L10n.label(field.label); item.sections[index].fields.append(added)
                }
            } else {
                var added = template; added.title = L10n.label(template.title)
                added.fields = template.fields.map { var field = $0; field.label = L10n.label(field.label); return field }
                item.sections.append(added)
            }
        }
    }
}

struct FieldEditor: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @Binding var field: VaultField
    let remove: () -> Void
    @State private var revealed = false
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 8) {
            if field.kind == .otp { Text(L("粘贴 Base32 密钥或 otpauth://totp/ 链接；支持 SHA1/256/512。密钥只保存在加密库中。")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField(L("字段名称"), text: $field.label)
                Picker(L("类型"), selection: $field.kind) { ForEach(FieldKind.allCases, id: \.self) { Text($0.displayName).tag($0) }.id(interfaceLanguage) }.id(interfaceLanguage).labelsHidden().frame(width: 140)
                Button(action: remove) { Image(systemName: "minus.circle") }.accessibilityLabel(L("移除字段 \(field.label)"))
            }
            HStack {
                if isSensitive(field.kind) && !revealed { SecureField(L("字段值"), text: $field.value) }
                else { TextField(L("字段值"), text: $field.value, axis: .vertical).lineLimit(1...4) }
                if isSensitive(field.kind) { Button(revealed ? L("隐藏") : L("显示")) { revealed.toggle() } }
            }
        }
    }
}

struct ChangePasswordView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 18) {
            Text(L("更改主密码")).font(.title2.bold())
            Text(L("至少 12 个字符。新密码无法找回。改密前会自动保留加密恢复点；旧备份仍使用原主密码，请保留原密码。")).foregroundStyle(.secondary)
            SecureField(L("新主密码"), text: $password)
            SecureField(L("再次输入"), text: $confirmation)
            HStack { Button(L("取消")) { dismiss() }.disabled(model.busy); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button(L("更新主密码")) { model.changePassword(password); password = ""; confirmation = "" }.buttonStyle(.borderedProminent).disabled(model.busy || password.count < 12 || password != confirmation) }
        }.textFieldStyle(.roundedBorder).padding(30).frame(width: 480).interactiveDismissDisabled(model.busy)
    }
}
