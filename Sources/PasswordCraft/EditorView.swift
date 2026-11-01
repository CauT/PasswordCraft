import SwiftUI
import VaultCore

extension FieldKind {
    var displayName: String {
        switch self {
        case .text: return "文本"
        case .password: return "密码 / 秘密"
        case .url: return "网址"
        case .email: return "电子邮箱"
        case .date: return "日期"
        case .monthYear: return "月 / 年"
        case .phone: return "电话"
        case .otp: return "验证码密钥"
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State var item: VaultItem
    @State private var reveal = false
    @State private var newTag = ""
    @State private var length = 24
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title.isEmpty ? "新建项目" : "编辑项目").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("标题") { TextField("项目标题", text: $item.title) }
                    HStack {
                        Picker("分类", selection: $item.category) { ForEach(Array(Set(ItemTemplates.categories + [item.category])).sorted(), id: \.self) { Text($0).tag($0) } }
                        Button("添加此类模板字段") { addTemplate() }
                    }
                    Text("更改分类不会删除已有字段。模板只添加缺少的分组或字段。").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("账号") { TextField("用户名或邮箱", text: $item.username) }
                    HStack {
                        if reveal { TextField("密码", text: $item.password) } else { SecureField("密码", text: $item.password) }
                        Button(reveal ? "隐藏" : "显示") { reveal.toggle() }
                        Stepper("\(length) 位", value: $length, in: 12...128).frame(width: 110)
                        Button("生成密码") { do { item.password = try PasswordGenerator.generate(length: length) } catch { model.showError(error) } }
                    }
                    LabeledContent("网址") { TextField("主要网址", text: $item.url) }
                    ForEach(item.additionalURLs.indices, id: \.self) { index in
                        HStack { TextField("其他网址 \(index + 1)", text: $item.additionalURLs[index]); Button { item.additionalURLs.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("移除网址 \(index + 1)") }
                    }
                    Button("添加网址", systemImage: "plus") { item.additionalURLs.append("") }
                    Toggle("收藏此项目", isOn: $item.favorite)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { TextField("添加标签", text: $newTag).onSubmit(addTag); Button("添加标签", action: addTag).disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        if !item.tags.isEmpty {
                            ForEach(item.tags, id: \.self) { tag in HStack { Label(tag, systemImage: "tag"); Spacer(); Button("移除") { item.tags.removeAll { $0 == tag } }.accessibilityLabel("移除标签 \(tag)") }.font(.caption) }
                        }
                    }
                    Divider()
                    ForEach($item.sections) { $section in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("分组名称", text: $section.title).font(.headline)
                                Button("删除分组", role: .destructive) { item.sections.removeAll { $0.id == section.id } }
                            }
                            ForEach($section.fields) { $field in
                                FieldEditor(field: $field) { section.fields.removeAll { $0.id == field.id } }
                            }
                            Button("添加字段", systemImage: "plus") { section.fields.append(VaultField(label: "")) }
                        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button("添加一次性验证码", systemImage: "timer") { item.sections.append(VaultSection(title: "两步验证", fields: [VaultField(label: "一次性验证码", kind: .otp)])) }
                    Button("添加字段分组", systemImage: "folder.badge.plus") { item.sections.append(VaultSection(title: "新分组", fields: [VaultField(label: "")])) }
                    Text("备注").font(.headline)
                    TextEditor(text: $item.notes).frame(height: 110).border(.quaternary)
                }.padding(.trailing, 8)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text("正在备份并加密保存…").font(.caption) }
                Button("保存") { addTag(); item.updatedAt = Date(); model.save(item) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            if let index = item.sections.firstIndex(where: { $0.title == template.title }) {
                for field in template.fields where !item.sections[index].fields.contains(where: { $0.label == field.label }) { item.sections[index].fields.append(field) }
            } else { item.sections.append(template) }
        }
    }
}

struct FieldEditor: View {
    @Binding var field: VaultField
    let remove: () -> Void
    @State private var revealed = false
    var body: some View {
        VStack(spacing: 8) {
            if field.kind == .otp { Text("粘贴 Base32 密钥或 otpauth://totp/ 链接；支持 SHA1/256/512。密钥只保存在加密库中。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("字段名称", text: $field.label)
                Picker("类型", selection: $field.kind) { ForEach(FieldKind.allCases, id: \.self) { Text($0.displayName).tag($0) } }.labelsHidden().frame(width: 140)
                Button(action: remove) { Image(systemName: "minus.circle") }.accessibilityLabel("移除字段 \(field.label)")
            }
            HStack {
                if isSensitive(field.kind) && !revealed { SecureField("字段值", text: $field.value) }
                else { TextField("字段值", text: $field.value, axis: .vertical).lineLimit(1...4) }
                if isSensitive(field.kind) { Button(revealed ? "隐藏" : "显示") { revealed.toggle() } }
            }
        }
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("更改主密码").font(.title2.bold())
            Text("至少 12 个字符。新密码无法找回。改密前会自动保留加密恢复点；旧备份仍使用原主密码，请保留原密码。").foregroundStyle(.secondary)
            SecureField("新主密码", text: $password)
            SecureField("再次输入", text: $confirmation)
            HStack { Button("取消") { dismiss() }.disabled(model.busy); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("更新主密码") { model.changePassword(password); password = ""; confirmation = "" }.buttonStyle(.borderedProminent).disabled(model.busy || password.count < 12 || password != confirmation) }
        }.textFieldStyle(.roundedBorder).padding(30).frame(width: 480).interactiveDismissDisabled(model.busy)
    }
}
