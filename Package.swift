// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PasswordCraft",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VaultCore", targets: ["VaultCore"]), .executable(name: "PasswordCraft", targets: ["PasswordCraft"])],
    targets: [
        .target(name: "VaultCore"),
        .executableTarget(name: "PasswordCraft", dependencies: ["VaultCore"]),
        .executableTarget(name: "VaultCoreChecks", dependencies: ["VaultCore"], path: "Tests/VaultCoreTests")
    ]
)
