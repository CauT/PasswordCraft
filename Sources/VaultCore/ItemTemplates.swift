import Foundation

/// Original, editable local templates. Category labels never imply hidden fields.
public enum ItemTemplates {
    public static let categories = ["登录", "密码", "安全笔记", "文档", "信用卡", "银行账户", "身份信息", "护照", "驾驶证", "软件许可证", "数据库", "服务器", "无线网络", "API 凭据", "其他"]
    public static func makeItem(category: String) -> VaultItem {
        var item = VaultItem(category: category)
        func section(_ title: String, _ values: [(String, FieldKind)]) -> VaultSection {
            VaultSection(title: title, fields: values.map { VaultField(label: $0.0, kind: $0.1) })
        }
        switch category {
        case "信用卡": item.sections = [section("卡片", [("持卡人", .text), ("卡号", .password), ("有效期", .monthYear), ("安全码", .password), ("PIN", .password), ("发卡银行", .text)])]
        case "银行账户": item.sections = [section("账户", [("银行名称", .text), ("账户持有人", .text), ("账号", .password), ("银行代码", .text), ("IBAN", .text), ("SWIFT", .text), ("PIN", .password)])]
        case "身份信息": item.sections = [section("个人信息", [("姓名", .text), ("出生日期", .date), ("证件号码", .password), ("电子邮件", .email), ("电话", .phone), ("地址", .text), ("邮政编码", .text)])]
        case "护照": item.sections = [section("护照", [("姓名", .text), ("护照号码", .password), ("国籍", .text), ("签发日期", .date), ("有效期", .date), ("签发机关", .text)])]
        case "驾驶证": item.sections = [section("驾驶证", [("姓名", .text), ("证件号码", .password), ("准驾车型", .text), ("签发日期", .date), ("有效期", .date)])]
        case "软件许可证": item.sections = [section("许可证", [("软件名称", .text), ("许可证密钥", .password), ("注册人", .text), ("注册邮箱", .email), ("版本", .text), ("购买日期", .date)])]
        case "数据库": item.sections = [section("连接", [("数据库类型", .text), ("主机", .text), ("端口", .text), ("数据库名", .text), ("连接参数", .text)])]
        case "服务器": item.sections = [section("服务器", [("主机", .text), ("端口", .text), ("管理地址", .url)])]
        case "无线网络": item.sections = [section("无线网络", [("网络名称 SSID", .text), ("安全类型", .text), ("路由器地址", .url)])]
        case "API 凭据": item.sections = [section("API", [("服务名称", .text), ("端点", .url), ("访问密钥", .password), ("私密密钥", .password), ("有效期", .date)])]
        default: break
        }
        return item
    }
}
