# PasswordCraft

A native, offline Mac password manager. No account or subscription.

The interface defaults to English. Use **Language / 语言 → English / 简体中文** in the menu bar or the language selector at the top of the window. The choice persists across launches. Switching language keeps open drafts and does not translate or rewrite stored passwords, notes, or imported source data.

独立、离线的原生 Mac 密码管理应用，面向喜欢 1Password 6 本地密码库方式的用户。无需账号或订阅。不隶属于 1Password，不包含其代码或品牌资源。浏览器自动填充按用户要求不纳入范围。

打开 `PasswordCraft.app`。压缩包为 [GitHub Releases](https://github.com/CauT/PasswordCraft/releases)，面向 Apple silicon，最低系统声明 macOS 13，实际验收环境为 macOS 26.2。0.4.1 使用 Developer ID 签名并通过 Apple 公证，压缩包内附公证票据；已验证新解包副本的签名、票据和 Gatekeeper 评估。交付身份、已验证旅程及限制见 [发布与兼容性说明](docs/release.md)。

## 开始使用

1. 点击「新建密码库」，设置至少 12 个字符的主密码，选择新的 `.localvault` 文件位置。主密码无法找回。已有 PasswordCraft 或旧版 LocalVault 库可从「打开已有密码库」打开。
2. 新建或编辑项目，可添加分类模板、自定义字段分组、标签和多个网址。密码字段会遮蔽显示；日期等类型用于存储和展示，不代替格式校验。
3. 迁移旧库：先创建本地库，再从「密码库 → 导入数据」选择 OPVault、AgileKeychain、1PIF、1PUX、CSV 或完整 JSON。加密旧库要求输入它自己的密码。先核对预览的条目/历史/附件数量与警告，再确认迁入。
4. 旧库仅用于读取迁移，不会成为本应用直接写回的格式。请保留原库并核对字段和附件；未读取你的真实密码库，也没有替你完成真实迁移。源文件不会自动删除或上传。
5. 修改前后的加密恢复点自动保存在本机。重要数据请另存加密副本到独立介质，并验证能解锁；本机自动备份不代替异机灾备。

## 管理、验证码和附件

- 搜索标题、账号、备注、标签、网址和普通字段；密码和 OTP 值不参与搜索。支持收藏、归档、标签筛选和最近修改排序。
- Command 或 Shift 多选后，可一起收藏、归档、加标签、移入回收站、恢复及跨库复制/移动。回收站一直保留到明确永久删除；永久删除同时移除库内相关历史，但旧备份仍可能包含这些内容。
- 「历史」可查看、复制和恢复旧版本。恢复保留项目当前的归档/回收站状态，并把恢复前内容加入历史。来源只提供密码历史时，不能把它当成来源的完整条目历史。
- OTP 字段接受 Base32 种子或 `otpauth://totp/` 地址，离线生成 SHA1/256/512 验证码。没有二维码扫描；请保持 Mac 时间准确。复制验证码后，剪贴板会在该码到期或 30 秒内清除。
- 项目可添加附件，在加密库内保存。文本、PDF、图片可在内存中预览；不支持的内容显示有限十六进制预览。导出是明确确认后的未加密文件，不覆盖已有文件。移除当前附件后，历史及旧备份仍保留它，直到对应内容被永久清理。
- 单附件最多 16 MiB，全库连同历史和附件的序列化内容最多 32 MiB。相同附件内容按摘要共用存储；有历史引用的附件不会被提前清除。
- 「本地密码检查」提示短密码、易猜模式和当前库内复用，覆盖活动及归档项目的主密码值。它不检查自定义密码字段、历史或回收站，不联网查询泄漏库，也不是完整 Watchtower。

## 多库、快速访问与锁定

顶部库列表可切换不同本地文件，每个库独立解锁。切换不会锁定其他库，最多同时解锁 8 个库。列表只记录文件路径；移除列表项保留磁盘文件。

「搜索所有已解锁库」和「密码库 → 快速访问」会同时搜索已解锁库的活动项目，标明来源，可手动复制账号/密码/验证码或进入正确的库。代码提供菜单栏入口及全局 `⌃⌥⌘L`；全局热键人工触发和菜单栏图标入口尚未验收，菜单命令及窗口内入口已验证。

跨库复制/移动保留历史和附件。相同 UUID 且内容相同的项目不会重复复制；内容冲突时停止，不隐式覆盖。移动先保存目标库，再把源项目放入回收站；第二步失败会明确提示，源项目保留。它不是两个文件间的原子事务。

「锁定当前库」仅锁所选库；「锁定全部密码库」及 `⇧⌘L` 清除所有解锁会话。应用内闲置 5 分钟会锁定全部库。睡眠/系统锁屏回调存在，但未执行真实系统睡眠/锁屏验收。普通复制在 30 秒后清除，前提是期间没有被其他复制内容替换；锁定和正常退出也清除本应用仍拥有的剪贴板内容。

Touch ID 设置采用设备专属、当前指纹集合保护的系统钥匙串记录，主密码始终可用。本机没有可用的 Touch ID 设备，已验证无设备提示及禁用状态，**实际指纹认证、Keychain 添加/删除和重新录入指纹后的失效尚未硬件验收**。不能称指纹解锁已验证可用。

## 自动备份和版本升级

每次修改先验证并保存加密恢复点，成功保存后再备份最新状态。写前备份失败停止修改；写后备份失败明确提示“已保存，但最新备份失败”，保留写前恢复点。最近 20 份当前主密码的普通备份轮换；升级、改密恢复点及此前密码的备份额外保留。改主密码后，旧备份仍需旧密码。

备份目录为 `~/Library/Application Support/LocalVault/Backups/<密码库 UUID>/`，文件权限 0600、目录 0700。「自动备份与恢复」将选中的备份恢复为新文件，不覆盖原库；「保存加密副本」可另外保存副本。主文件无法解锁时，可先在 Finder 复制备份到新位置，再通过打开密码库解锁；不要直接编辑自动备份目录里的文件。

旧版 LocalVault 0.1/0.2 文件可读取，首次修改保留旧格式恢复点后升级到格式 3，旧应用无法读取升级后的文件。请先退出旧版应用，再使用 PasswordCraft 编辑同一库。内部库 ID 相同的副本不能同时解锁：先锁原库再打开副本。

## 迁移与导出边界

| 格式 | 支持与边界 |
| --- | --- |
| OPVault | 读取 `default` 配置的加密条目与已验证 v1/v2 附件；保留字段、OTP、状态、密码历史及来源原文。文件夹转为标签，智能规则保留为笔记，不执行。详见 [格式边界](docs/compatibility.md)。 |
| AgileKeychain | 读取 `data/default`、`encryptionKeys.js`、SL5/SL3 条目及已验证的加密附件定义布局。旧格式不提供条目认证；未知附件布局拒绝整批。详见 [格式边界](docs/compatibility.md) 和 [格式边界](docs/compatibility.md)。 |
| 1PIF | 导入文件或含 `data.1pif` 的目录，支持 Mac/Windows 记录与已验证的 `attachments/<owner>/...` 布局。单独选择普通文件时不会猜测周围目录的附件；优先选择完整导出目录。未知 previews/额外文件拒绝。单文件导出不能携带附件或完整原生历史。 |
| 1PUX v3 | 常规 ZIP32 stored/deflate，支持文档与分组文件引用；多个来源库迁入当前库，保留来源标识。未知额外文件、自定义图标文件、ZIP64/加密 ZIP 不支持。详见 [格式边界](docs/compatibility.md)。 |
| 完整 JSON | `LocalVault-Transfer` v2，包含完整字段、来源快照、状态、历史及附件；兼容读取不带附件的 v1。日期为 Swift Codable 自 2001-01-01 起秒数。适合完整迁出和往返。 |
| CSV | 普通常用列可导入，额外列保存为文本；本应用的 `localvault_json` 扩展列保留完整内容和附件，是富 CSV 的权威数据。其他软件可能忽略扩展列，手工只改普通列不会更改它。 |

原始来源快照在库内加密保留，详情明确标明它不是当前内容、可能含旧密码。默认跳过相同本地 ID 或来源 ID，不覆盖本地修改；导入预览可以明确选择生成独立副本。旧格式缺少完整认证库存，无法证明被移走的条目/附件原本就不存在，应自行核对。

导出前必须确认文件未加密，含密码、回收站、历史和所选格式支持的附件。导出权限 0600、不覆盖已有文件。CSV 以 `=` 等开头的值可能被电子表格解释为公式，请按文本导入。明文导入/导出上限 32 MiB；1PUX 压缩包读取上限 64 MiB，并限制解压大小。

## 存储与验证范围

- 使用系统 CommonCrypto PBKDF2-HMAC-SHA256（600,000 次迭代、16 字节随机盐）派生 256 位密钥，CryptoKit AES-GCM 加密并认证格式元数据，随机数来自 Security 框架。标题、字段、附件、标签、历史和来源原文均在密文内。
- 系统提供同卷加密临时文件位置，先 fsync 再原子发布；私有本机锁和内容指纹防止本版本进程间的并发覆盖。不读取受保护父目录以执行目录 fsync，不承诺突然断电时目录项持久性。
- 无网络客户端、遥测或密码恢复服务，不存主密码。你选择同步目录时，其同步服务仍可能同步密文；没有跨设备条目合并协议、网络卷跨主机锁或自动更新。
- 锁定释放持有的密钥和项目，但 Swift/系统内存、交换区、崩溃转储及其他软件的剪贴板历史不保证清零；强制终止也可能使清除定时器失效。
- 未经独立安全审计。请保留旧库和已验证的独立备份，不将本版作为重要密码的唯一副本。没有通行密钥、浏览器自动填充、云账号或团队共享服务。

## 构建与包验证

使用现有 Swift 6.2，无第三方包依赖：

```sh
git clone https://github.com/CauT/PasswordCraft.git
cd PasswordCraft
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift run --disable-sandbox -c release VaultCoreChecks
./scripts/package.sh /absolute/path/to/a-new-package-directory
/usr/bin/python3 scripts/verify-package.py /path/to/PasswordCraft-0.4.1-mac-arm64.zip /path/to/PasswordCraft.app
```

打包始终使用新目录并拒绝覆盖旧目录；产生构建输入摘要、提交身份与包验证回执。可给验证脚本传 `--extract-to /new/directory`，保留新解包结果用于正常 UI 启动。默认核心检查不下载外部参考库；公开样本可按各检查点记录提供给测试，未提供时明确标为未执行。

[兼容性与格式](docs/compatibility.md) · [发布说明](docs/release.md) · [MIT License](LICENSE)
