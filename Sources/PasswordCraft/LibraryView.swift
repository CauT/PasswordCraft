import SwiftUI
import VaultCore

struct LibraryView: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    var body: some View {
        let _ = interfaceLanguage
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Label("PasswordCraft", systemImage: "lock.shield.fill").font(.title3.bold()).padding(.top, 16)
                Text(model.url?.deletingPathExtension().lastPathComponent ?? L("密码库")).foregroundStyle(.secondary).lineLimit(1)
                List(selection: $model.filter) {
                    Label(L("全部项目 · \(model.activeCount)"), systemImage: "square.grid.2x2").tag(VaultFilter.all)
                    Label(L("收藏"), systemImage: "star").tag(VaultFilter.favorites)
                    Label(L("归档"), systemImage: "archivebox").tag(VaultFilter.archived)
                    Label(L("回收站 · \(model.trashCount)"), systemImage: "trash").tag(VaultFilter.trash)
                    Section(L("分类")) {
                        ForEach(model.categories, id: \.self) { category in Label(L10n.category(category), systemImage: category == "安全笔记" ? "note.text" : "key").tag(VaultFilter.category(category)) }.id(interfaceLanguage)
                    }
                    if !model.tags.isEmpty {
                        Section(L("标签")) { ForEach(model.tags, id: \.self) { tag in Label(tag, systemImage: "tag").tag(VaultFilter.tag(tag)) }.id(interfaceLanguage) }
                    }
                }.listStyle(.sidebar)
                Button { model.showBackups = true } label: { Label(L("自动备份 · \(model.backups.count)"), systemImage: "clock.arrow.circlepath") }.buttonStyle(.link).disabled(model.busy)
                Button(L("本地密码检查")) { model.showHealth = true }.buttonStyle(.link).disabled(model.busy)
                Text(L("闲置 5 分钟后锁定全部库")).font(.caption).foregroundStyle(.secondary)
                Button(L("锁定全部密码库"), systemImage: "lock", action: model.lock).padding(.bottom, 16)
            }.padding(.horizontal, 12).navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } content: {
            VStack(spacing: 0) {
                TextField(L("搜索标题、标签和普通字段"), text: $model.query).textFieldStyle(.roundedBorder).padding(12)
                HStack { Text(model.filter.title).font(.headline); Spacer(); Menu { Button(L("按标题排序")) { model.sortByDate = false }; Button(L("最近修改优先")) { model.sortByDate = true } } label: { Image(systemName: "arrow.up.arrow.down") } }.padding(.horizontal, 14).padding(.bottom, 8)
                if model.filter == .trash { Text(L("回收站会一直保留项目，直到你明确永久删除。")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8) }
                if model.visible.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.filter == .trash ? "trash" : "tray").font(.largeTitle)
                        Text(model.query.isEmpty ? L("这里还没有项目") : L("没有找到匹配项目"))
                        if model.items.isEmpty { Button(L("添加第一个项目"), action: model.newItem); Button(L("导入数据…"), action: model.importFile) }
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selectedIDs) {
                        ForEach(model.visible) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.state == .trashed ? "trash" : "key.fill").frame(width: 32, height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.headline); Text(item.username.isEmpty ? L10n.category(item.category) : item.username).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); if item.favorite { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                            }.padding(.vertical, 5).tag(item.id)
                        }.id(interfaceLanguage)
                    }
                }
            }.navigationSplitViewColumnWidth(min: 280, ideal: 310)
        } detail: {
            if model.selectedIDs.count > 1 { BatchActionsView() }
            else if let item = model.current { ItemDetail(item: item).id(item.id) }
            else { VStack(spacing: 14) { Image(systemName: "lock.rectangle.stack").font(.system(size: 50)); Text(L("选择一个项目查看详情")).font(.title3); Text(L("内容、历史和恢复点，各有清楚的归属。")).font(.callout) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onChange(of: model.query) { _ in model.pruneSelection() }
        .onChange(of: model.filter) { _ in model.pruneSelection() }
        .toolbar {
            ToolbarItem { if model.busy { ProgressView().controlSize(.small) } }
            ToolbarItem { Button(L("新建项目"), systemImage: "plus", action: model.newItem).disabled(model.busy) }
            ToolbarItem { Menu { Button(L("导入数据…"), action: model.importFile); Button(L("导出数据…")) { model.showExport = true }; Button(L("自动备份与恢复…")) { model.showBackups = true }; Button(L("保存加密副本…"), action: model.backup); Button(L("更改主密码…")) { model.changingPassword = true } } label: { Label(L("密码库操作"), systemImage: "ellipsis.circle") }.disabled(model.busy) }
        }
        .safeAreaInset(edge: .bottom) {
            if let notice = model.notice { HStack { Image(systemName: "info.circle"); Text(notice).font(.caption); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(10).background(.bar) }
        }
    }
}

struct ItemDetail: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    let item: VaultItem
    @State private var purging = false
    var body: some View {
        let _ = interfaceLanguage
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(item.title).font(.title.bold())
                HStack { Text(L10n.category(item.category)).foregroundStyle(.secondary); if item.state != .active { Text(item.state == .trashed ? L("在回收站中") : L("已归档")).font(.caption).padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)) } }
                HStack {
                    if item.state == .trashed {
                        Button(L("恢复项目"), systemImage: "arrow.uturn.backward") { model.changeState(item, to: .active) }
                        Button(L("永久删除"), systemImage: "trash.slash", role: .destructive) { purging = true }
                    } else {
                        Button(L("编辑"), systemImage: "pencil") { model.editor = item }
                        Menu(L("更多")) {
                            Button(item.favorite ? L("取消收藏") : L("收藏")) { var changed = item; changed.favorite.toggle(); model.save(changed) }
                            Button(item.state == .archived ? L("取消归档") : L("归档")) { model.changeState(item, to: item.state == .archived ? .active : .archived) }
                            Button(L("复制或移动到其他库…")) { model.showTransfer = true }
                            Button(L("移到回收站")) { model.changeState(item, to: .trashed) }
                        }
                    }
                    Spacer()
                    Button(L("历史 (\(model.history(for: item).count))"), systemImage: "clock.arrow.circlepath") { model.historyItem = item }
                }.disabled(model.busy)
                Divider()
                ItemContents(item: item)
                if item.state != .trashed { Button(L("添加附件"), systemImage: "paperclip") { model.addAttachment(to: item) }.disabled(model.busy) }
                Divider()
                Text(L("创建于 \(item.createdAt.formatted(date: .abbreviated, time: .shortened))\n更新于 \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")).font(.caption).foregroundStyle(.secondary)
                if let date = item.deletedAt { Text(L("移入回收站：\(date.formatted())")).font(.caption).foregroundStyle(.secondary) }
            }.padding(28)
        }
        .confirmationDialog(L("永久删除「\(item.title)」及其历史？"), isPresented: $purging) {
            Button(L("永久删除项目及历史"), role: .destructive) { model.purge(item) }
        } message: { Text(L("此操作不能通过回收站撤销。此前的加密备份仍可能包含该项目。")) }
    }
}

struct ItemContents: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    let item: VaultItem
    var revisionID: UUID? = nil
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 20) {
            if !item.tags.isEmpty { Label(item.tags.joined(separator: " · "), systemImage: "tag").font(.callout).foregroundStyle(.secondary) }
            ValueRow(label: L("账号"), value: item.username)
            ValueRow(label: L("密码"), value: item.password, sensitive: true)
            ValueRow(label: L("网址"), value: item.url)
            ForEach(Array(item.additionalURLs.enumerated()), id: \.offset) { index, value in ValueRow(label: L("其他网址 \(index + 1)"), value: value) }.id(interfaceLanguage)
            ForEach(item.sections) { section in
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.title.isEmpty ? L("其他字段") : section.title).font(.headline)
                    ForEach(section.fields) { field in
                        if field.kind == .otp { TOTPRow(label: field.label, input: field.value) }
                        else { ValueRow(label: field.label, value: field.value, sensitive: isSensitive(field.kind)) }
                    }.id(interfaceLanguage)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }.id(interfaceLanguage)
            if !item.notes.isEmpty { VStack(alignment: .leading, spacing: 8) { Text(L("备注")).font(.caption).foregroundStyle(.secondary); Text(item.notes).textSelection(.enabled) } }
            if !item.attachments.isEmpty { AttachmentList(item: item, revisionID: revisionID) }
            if let original = item.importedJSON {
                DisclosureGroup(L("原始来源快照（不是当前内容，可能含旧密码）")) {
                    Text(original).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
        }
    }
}

struct ValueRow: View {
    @AppStorage(AppLanguage.preferenceKey) private var interfaceLanguage = AppLanguage.english.rawValue
    @EnvironmentObject var model: VaultModel
    let label: String
    let value: String
    var sensitive = false
    @State private var revealed = false
    var body: some View {
        let _ = interfaceLanguage
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(sensitive && !revealed ? "••••••••••••" : value).font(sensitive ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if sensitive { Button(revealed ? L("隐藏") : L("显示")) { revealed.toggle() }.accessibilityLabel("\(revealed ? L("隐藏") : L("显示"))\(label)") }
                    Button(L("复制")) { model.copy(value) }.accessibilityLabel(L("复制\(label)"))
                }
            }
        }
    }
}
