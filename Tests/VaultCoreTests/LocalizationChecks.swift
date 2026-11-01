import Foundation
import VaultCore

func withTestLanguage<T>(_ value: String?, _ body: () throws -> T) rethrows -> T {
    let defaults = UserDefaults.standard
    let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var domain = previous
    domain[AppLanguage.preferenceKey] = value
    defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    return try body()
}

func runLocalizationChecks() throws {
    withTestLanguage("unknown") {
        XCTAssertEqual(AppLanguage.current, .english)
        XCTAssertEqual(L("新建密码库…"), "New Vault…")
    }
    let userTitle = "中文 {1} %s \\ secret"
    let message: LocalizedMessage = "永久删除「\(userTitle)」及其历史？"
    XCTAssertEqual(message.rendered(language: .english), "Permanently delete “\(userTitle)” and its history?")
    XCTAssertEqual(message.rendered(language: .simplifiedChinese), "永久删除「\(userTitle)」及其历史？")
    let reordered: LocalizedMessage = "对所选 \(3) 个项目执行「\("Restore {0}")」？"
    XCTAssertEqual(reordered.rendered(language: .english), "Apply “Restore {0}” to 3 selected items?")
    withTestLanguage("zh-Hans") {
        XCTAssertEqual(L("新建密码库…"), "新建密码库…")
        XCTAssertEqual(L10n.category("登录"), "登录")
    }
    withTestLanguage("en") {
        XCTAssertEqual(L10n.category("登录"), "Login")
        XCTAssertEqual(L10n.category("用户的自定义分类"), "用户的自定义分类")
        do { _ = try PasswordGenerator.generate(length: 1); fatalError("Expected generator error") }
        catch { XCTAssertEqual(error.localizedDescription, "Password length must be 12–128.") }
    }
    // Language controls presentation, never imported identity, original text,
    // fallback field labels, category identifiers, or rich-export bytes.
    let source = #"{"uuid":"language-fixture","title":"用户的标题","typeName":"webforms.WebForm","createdAt":1000,"updatedAt":2000,"secureContents":{"notesPlain":"密码 {0}","fields":[{"designation":"username","value":"user"},{"designation":"password","value":"secret"},{"name":"ccnum","value":"1234"}]}}"#
    let english = try withTestLanguage("en") { try OnePasswordImporter.parse(source) }
    let chinese = try withTestLanguage("zh-Hans") { try OnePasswordImporter.parse(source) }
    XCTAssertEqual(english, chinese)
    XCTAssertEqual(english[0].title, "用户的标题")
    XCTAssertEqual(english[0].category, "登录")
    XCTAssertEqual(english[0].notes, "密码 {0}")
    XCTAssertEqual(english[0].importedJSON, source)
    print("PASS English default, bilingual messages, safe interpolation and language-independent import")
}
