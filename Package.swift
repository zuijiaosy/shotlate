// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shotlate",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 自动更新；二进制包，只需 Command Line Tools
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // 不依赖 AppKit 的纯逻辑：坐标换算、文本分块、取色、翻译接口
        .target(name: "ShotlateCore"),
        // 菜单栏应用：截图覆盖层、标注、翻译回显、贴图、设置
        .executableTarget(
            name: "Shotlate",
            dependencies: ["ShotlateCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Shotlate.app/Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ShotlateCoreTests", dependencies: ["ShotlateCore"]),
    ],
    swiftLanguageModes: [.v5]
)
