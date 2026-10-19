// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Yours",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.executable(name: "Yours", targets: ["Yours"])],
    targets: [
        .executableTarget(
            name: "Yours",
            resources: [
                .copy("Resources/CodeFormatting"), .copy("Resources/Fonts"), .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"), .process("Resources/EditorIcons.xcassets"),
                .copy("Resources/EditorIcons-LICENSE.txt"), .copy("Resources/DocumentRendering"),
            ]),
        .testTarget(name: "YoursTests", dependencies: ["Yours"]),
    ]
)
